#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define READABLE 1u
#define WRITABLE 2u
#define PEER_EOF 8u
#define WAKE 16u
#define WAKE_KEY UINT64_C(0xFFFFFFFFFFFFFFFF)
#define EPOLL_CTL_ADD 1
#define EPOLL_CTL_DEL 2
#define EPOLL_CTL_MOD 3

typedef struct __attribute__((packed)) { uint32_t events; uint64_t data; } gio_epoll_event;

extern int64_t goose_io_epoll_create(void);
extern int32_t goose_io_epoll_ctl(int64_t,int32_t,int32_t,uint32_t,uint64_t);
extern int32_t goose_io_epoll_wait(int64_t,gio_epoll_event*,int32_t,int32_t);
extern int32_t goose_io_epoll_wake(int64_t);
extern void goose_io_epoll_close(int64_t);
extern int32_t goose_io_listen(uint8_t,const uint8_t*,uint16_t,uint8_t,int32_t);
extern int32_t goose_io_accept(int32_t,uint8_t*,uint8_t*,uint16_t*);
extern int32_t goose_io_connect_start(uint8_t,const uint8_t*,uint16_t);
extern int32_t goose_io_connect_result(int32_t);
extern int64_t goose_io_recv(int32_t,uint8_t*,int64_t);
extern int64_t goose_io_send(int32_t,const uint8_t*,int64_t);
extern int32_t goose_io_shutdown_write(int32_t);
extern void goose_io_close(int32_t);
extern uint64_t goose_io_monotonic_ns(void);

static void test_epoll_and_wake(void) {
    int fds[2]; assert(socketpair(AF_UNIX,SOCK_STREAM,0,fds)==0);
    int64_t ep=goose_io_epoll_create(); assert(ep>0);
    uint64_t key=((uint64_t)9<<32)|3;
    assert(goose_io_epoll_ctl(ep,EPOLL_CTL_ADD,fds[0],READABLE,key)==0);
    assert(write(fds[1],"a",1)==1);
    gio_epoll_event events[8];
    int n=goose_io_epoll_wait(ep,events,8,100);
    assert(n==1 && events[0].data==key && (events[0].events&READABLE));
    char ch=0; assert(goose_io_recv(fds[0],(uint8_t*)&ch,1)==1 && ch=='a');
    assert(goose_io_epoll_ctl(ep,EPOLL_CTL_MOD,fds[0],WRITABLE,key)==0);
    n=goose_io_epoll_wait(ep,events,8,100);
    assert(n==1 && events[0].data==key && (events[0].events&WRITABLE));
    assert(goose_io_epoll_ctl(ep,EPOLL_CTL_DEL,fds[0],0,0)==0);
    assert(goose_io_epoll_wake(ep)==0);
    assert(goose_io_epoll_wake(ep)==0);
    n=goose_io_epoll_wait(ep,events,8,100);
    assert(n==1 && events[0].data==WAKE_KEY && (events[0].events&WAKE));
    goose_io_epoll_close(ep); close(fds[0]); close(fds[1]);
}


static void test_raw_epoll_fast_path(void) {
    int fds[2]; assert(socketpair(AF_UNIX,SOCK_STREAM,0,fds)==0);
    int64_t ep=goose_io_epoll_create_raw(); assert(ep>0);
    const uint64_t key=UINT64_C(0x123456789ABCDEF0);
    assert(goose_io_epoll_ctl_raw(ep,EPOLL_CTL_ADD,fds[0],
                                  EPOLLIN|EPOLLRDHUP|EPOLLET,key)==0);
    assert(write(fds[1],"raw",3)==3);
    gio_epoll_event events[256];
    int n=goose_io_epoll_wait_raw(ep,events,256,100);
    assert(n==1);
    assert(events[0].data==key);
    assert(events[0].events&EPOLLIN);
    char buf[8]; assert(read(fds[0],buf,sizeof(buf))==3);
    assert(goose_io_epoll_ctl_raw(ep,EPOLL_CTL_DEL,fds[0],0,0)==0);
    goose_io_epoll_close(ep); close(fds[0]); close(fds[1]);
}

static void test_tcp(void) {
    const uint8_t ip[16]={127,0,0,1};
    int32_t listener=goose_io_listen(0,ip,39173,0,32); assert(listener>=0);
    int64_t ep=goose_io_epoll_create(); assert(ep>0);
    uint64_t lk=((uint64_t)1<<32)|1, ck=((uint64_t)1<<32)|2;
    assert(goose_io_epoll_ctl(ep,EPOLL_CTL_ADD,listener,READABLE,lk)==0);
    int32_t client=goose_io_connect_start(0,ip,39173); assert(client>=0);
    assert(goose_io_epoll_ctl(ep,EPOLL_CTL_ADD,client,WRITABLE,ck)==0);
    gio_epoll_event events[8]; uint8_t got_l=0,got_c=0;
    for(int t=0;t<10 && (!got_l||!got_c);t++){
        int n=goose_io_epoll_wait(ep,events,8,100); assert(n>=0);
        for(int i=0;i<n;i++){
            if(events[i].data==lk && (events[i].events&READABLE)) got_l=1;
            if(events[i].data==ck && (events[i].events&WRITABLE)) got_c=1;
        }
    }
    assert(got_l && got_c && goose_io_connect_result(client)==0);
    uint8_t v6=0,peer[16]={0}; uint16_t peer_port=0;
    int32_t accepted=goose_io_accept(listener,&v6,peer,&peer_port);
    assert(accepted>=0 && v6==0 && peer[0]==127 && peer_port!=0);
    uint64_t ak=((uint64_t)1<<32)|3;
    assert(goose_io_epoll_ctl(ep,EPOLL_CTL_ADD,accepted,0,ak)==0);

    const char request[]="goose-io-tcp";
    assert(goose_io_send(client,(const uint8_t*)request,sizeof(request))==(int64_t)sizeof(request));
    uint8_t buf[64]={0}; int64_t n=-EAGAIN;
    for(int t=0;t<50 && n==-EAGAIN;t++){ n=goose_io_recv(accepted,buf,sizeof(buf)); if(n==-EAGAIN) usleep(1000); }
    assert(n==(int64_t)sizeof(request) && memcmp(buf,request,sizeof(request))==0);

    assert(goose_io_shutdown_write(client)==0);
    uint8_t eof=0;
    for(int t=0;t<10 && !eof;t++){
        int count=goose_io_epoll_wait(ep,events,8,100); assert(count>=0);
        for(int i=0;i<count;i++) if(events[i].data==ak && (events[i].events&PEER_EOF)) eof=1;
    }
    assert(eof);
    n=-EAGAIN;
    for(int t=0;t<50 && n==-EAGAIN;t++){ n=goose_io_recv(accepted,buf,sizeof(buf)); if(n==-EAGAIN) usleep(1000); }
    assert(n==0);
    const char response[]="half-close-ok";
    assert(goose_io_send(accepted,(const uint8_t*)response,sizeof(response))==(int64_t)sizeof(response));
    memset(buf,0,sizeof(buf)); n=-EAGAIN;
    for(int t=0;t<50 && n==-EAGAIN;t++){ n=goose_io_recv(client,buf,sizeof(buf)); if(n==-EAGAIN) usleep(1000); }
    assert(n==(int64_t)sizeof(response) && memcmp(buf,response,sizeof(response))==0);

    goose_io_close(client); goose_io_close(accepted); goose_io_close(listener); goose_io_epoll_close(ep);
}

int main(void) {
    test_epoll_and_wake(); test_raw_epoll_fast_path(); test_tcp();
    assert(goose_io_monotonic_ns()>0);
    puts("EPOLL_NATIVE_SOCKET_SMOKE: ok");
    return 0;
}
