// SPDX-License-Identifier: Apache-2.0
// Linux socket + epoll backend. The syscall boundary follows tcprouter's
// proven approach: nonblocking CLOEXEC sockets, sockaddr built in C, packed
// epoll event isolation, negative errno returns, and MSG_NOSIGNAL.

#define _GNU_SOURCE
#include <stdint.h>

#if defined(__linux__)
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/socket.h>
#include <sys/types.h>

#define GIO_WAKE_KEY UINT64_C(0xFFFFFFFFFFFFFFFF)
#define GIO_READABLE 1u
#define GIO_WRITABLE 2u
#define GIO_ERROR 4u
#define GIO_PEER_EOF 8u
#define GIO_WAKE 16u
#define GIO_MAX_EVENTS 128

typedef struct __attribute__((packed)) {
    uint32_t events;
    uint64_t data;
} gio_epoll_event;
_Static_assert(sizeof(gio_epoll_event) == 12, "goose-io epoll event ABI must be 12 bytes");

typedef struct { int epoll_fd; int wake_fd; } gio_epoll_state;

static gio_epoll_state *get_state(int64_t handle) {
    return handle > 0 ? (gio_epoll_state *)(intptr_t)handle : NULL;
}

static socklen_t fill_addr(struct sockaddr_storage *ss, uint8_t v6,
                           const uint8_t *ip, uint16_t port) {
    memset(ss, 0, sizeof(*ss));
    if (v6) {
        struct sockaddr_in6 *a = (struct sockaddr_in6 *)ss;
        a->sin6_family = AF_INET6; a->sin6_port = htons(port);
        memcpy(&a->sin6_addr, ip, 16); return sizeof(*a);
    }
    struct sockaddr_in *a = (struct sockaddr_in *)ss;
    a->sin_family = AF_INET; a->sin_port = htons(port);
    memcpy(&a->sin_addr, ip, 4); return sizeof(*a);
}

static uint32_t to_epoll_events(uint32_t flags) {
    uint32_t events = EPOLLRDHUP;
    if (flags & GIO_READABLE) events |= EPOLLIN;
    if (flags & GIO_WRITABLE) events |= EPOLLOUT;
    return events;
}

static uint32_t from_epoll_events(uint32_t events) {
    uint32_t flags = 0;
    if (events & (EPOLLIN | EPOLLPRI)) flags |= GIO_READABLE;
    if (events & EPOLLOUT) flags |= GIO_WRITABLE;
    if (events & EPOLLERR) flags |= GIO_ERROR;
    if (events & (EPOLLRDHUP | EPOLLHUP)) flags |= GIO_PEER_EOF;
    return flags;
}

int64_t goose_io_epoll_create(void) {
    gio_epoll_state *s = (gio_epoll_state *)calloc(1, sizeof(*s));
    if (!s) return -ENOMEM;
    s->epoll_fd = epoll_create1(EPOLL_CLOEXEC);
    if (s->epoll_fd < 0) { int e=errno; free(s); return -e; }
    s->wake_fd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    if (s->wake_fd < 0) { int e=errno; close(s->epoll_fd); free(s); return -e; }
    struct epoll_event ev; memset(&ev, 0, sizeof(ev));
    ev.events = EPOLLIN; ev.data.u64 = GIO_WAKE_KEY;
    if (epoll_ctl(s->epoll_fd, EPOLL_CTL_ADD, s->wake_fd, &ev) < 0) {
        int e=errno; close(s->wake_fd); close(s->epoll_fd); free(s); return -e;
    }
    return (int64_t)(intptr_t)s;
}

int32_t goose_io_epoll_ctl(int64_t handle, int32_t op, int32_t fd,
                           uint32_t flags, uint64_t key) {
    gio_epoll_state *s=get_state(handle);
    if (!s || fd<0 || key==GIO_WAKE_KEY) return -EINVAL;
    if (op==EPOLL_CTL_DEL) {
        if (epoll_ctl(s->epoll_fd, op, fd, NULL)<0) {
            if (errno==ENOENT || errno==EBADF) return 0;
            return -errno;
        }
        return 0;
    }
    struct epoll_event ev; memset(&ev,0,sizeof(ev));
    ev.events=to_epoll_events(flags); ev.data.u64=key;
    return epoll_ctl(s->epoll_fd,op,fd,&ev)<0 ? -errno : 0;
}

int32_t goose_io_epoll_wait(int64_t handle, gio_epoll_event *out,
                            int32_t max_events, int32_t timeout_ms) {
    gio_epoll_state *s=get_state(handle);
    if (!s || !out || max_events<1 || timeout_ms < -1) return -EINVAL;
    if (max_events>GIO_MAX_EVENTS) max_events=GIO_MAX_EVENTS;
    struct epoll_event native_events[GIO_MAX_EVENTS];
    int n=epoll_wait(s->epoll_fd,native_events,max_events,timeout_ms);
    if (n<0) return errno==EINTR ? 0 : -errno;
    for (int i=0;i<n;i++) {
        uint64_t key=native_events[i].data.u64;
        out[i].data=key;
        if (key==GIO_WAKE_KEY) {
            uint64_t value;
            while (read(s->wake_fd,&value,sizeof(value))==(ssize_t)sizeof(value)) {}
            out[i].events=GIO_WAKE;
        } else out[i].events=from_epoll_events(native_events[i].events);
    }
    return n;
}


/* Backend-specific raw epoll API for optimized engines such as tcprouter.
   Native event bits and the opaque 64-bit key pass through unchanged. This
   avoids per-event normalization or handle-table translation in hot paths. */
int64_t goose_io_epoll_create_raw(void) {
    gio_epoll_state *state = (gio_epoll_state *)calloc(1, sizeof(*state));
    if (!state) return -ENOMEM;
    state->epoll_fd = epoll_create1(EPOLL_CLOEXEC);
    state->wake_fd = -1;
    if (state->epoll_fd < 0) {
        int e = errno;
        free(state);
        return -e;
    }
    return (int64_t)(intptr_t)state;
}

int32_t goose_io_epoll_ctl_raw(int64_t handle, int32_t op, int32_t fd,
                               uint32_t native_events, uint64_t key) {
    gio_epoll_state *state = get_state(handle);
    if (!state || fd < 0) return -EINVAL;
    if (op == EPOLL_CTL_DEL) {
        if (epoll_ctl(state->epoll_fd, op, fd, NULL) != 0) {
            if (errno == ENOENT || errno == EBADF) return 0;
            return -errno;
        }
        return 0;
    }
    struct epoll_event ev;
    memset(&ev, 0, sizeof(ev));
    ev.events = native_events;
    ev.data.u64 = key;
    if (epoll_ctl(state->epoll_fd, op, fd, &ev) != 0) return -errno;
    return 0;
}

int32_t goose_io_epoll_wait_raw(int64_t handle, gio_epoll_event *out,
                                int32_t max_events, int32_t timeout_ms) {
    gio_epoll_state *state = get_state(handle);
    if (!state || !out || max_events < 1 || timeout_ms < -1) return -EINVAL;
    if (max_events > 256) max_events = 256;
    struct epoll_event events[256];
    int n = epoll_wait(state->epoll_fd, events, max_events, timeout_ms);
    if (n < 0) return errno == EINTR ? 0 : -errno;
    for (int i = 0; i < n; i++) {
        out[i].events = events[i].events;
        out[i].data = events[i].data.u64;
    }
    return n;
}

int32_t goose_io_epoll_wake(int64_t handle) {
    gio_epoll_state *s=get_state(handle);
    if (!s) return -EINVAL;
    uint64_t one=1; ssize_t n=write(s->wake_fd,&one,sizeof(one));
    if (n==(ssize_t)sizeof(one) || (n<0 && errno==EAGAIN)) return 0;
    return n<0 ? -errno : -EIO;
}

void goose_io_epoll_close(int64_t handle) {
    gio_epoll_state *s=get_state(handle); if (!s) return;
    close(s->wake_fd); close(s->epoll_fd); free(s);
}

int32_t goose_io_listen(uint8_t v6,const uint8_t *ip,uint16_t port,
                        uint8_t reuseport,int32_t backlog) {
    if (!ip || !port || backlog<1) return -EINVAL;
    int fd=socket(v6?AF_INET6:AF_INET,SOCK_STREAM|SOCK_NONBLOCK|SOCK_CLOEXEC,0);
    if (fd<0) return -errno;
    int one=1,err=0; struct sockaddr_storage ss;
    socklen_t len=fill_addr(&ss,v6,ip,port);
    if (setsockopt(fd,SOL_SOCKET,SO_REUSEADDR,&one,sizeof(one))<0) err=errno;
    else if (reuseport && setsockopt(fd,SOL_SOCKET,SO_REUSEPORT,&one,sizeof(one))<0) err=errno;
    else if (v6 && setsockopt(fd,IPPROTO_IPV6,IPV6_V6ONLY,&one,sizeof(one))<0) err=errno;
    else if (setsockopt(fd,IPPROTO_TCP,TCP_NODELAY,&one,sizeof(one))<0) err=errno;
    else if (bind(fd,(struct sockaddr *)&ss,len)<0) err=errno;
    else if (listen(fd,backlog)<0) err=errno;
    if (err) { close(fd); return -err; }
    return fd;
}

int32_t goose_io_accept(int32_t listener,uint8_t *peer_v6,
                        uint8_t *peer_ip,uint16_t *peer_port) {
    if (listener<0 || !peer_v6 || !peer_ip || !peer_port) return -EINVAL;
    struct sockaddr_storage ss; socklen_t len=sizeof(ss); int fd;
    do { fd=accept4(listener,(struct sockaddr *)&ss,&len,SOCK_NONBLOCK|SOCK_CLOEXEC); }
    while (fd<0 && errno==EINTR);
    if (fd<0) return -errno;
    memset(peer_ip,0,16);
    if (ss.ss_family==AF_INET6) {
        struct sockaddr_in6 *a=(struct sockaddr_in6 *)&ss;
        *peer_v6=1; memcpy(peer_ip,&a->sin6_addr,16); *peer_port=ntohs(a->sin6_port);
    } else if (ss.ss_family==AF_INET) {
        struct sockaddr_in *a=(struct sockaddr_in *)&ss;
        *peer_v6=0; memcpy(peer_ip,&a->sin_addr,4); *peer_port=ntohs(a->sin_port);
    } else { close(fd); return -EAFNOSUPPORT; }
    int one=1; (void)setsockopt(fd,IPPROTO_TCP,TCP_NODELAY,&one,sizeof(one));
    return fd;
}

int32_t goose_io_connect_start(uint8_t v6,const uint8_t *ip,uint16_t port) {
    if (!ip || !port) return -EINVAL;
    int fd=socket(v6?AF_INET6:AF_INET,SOCK_STREAM|SOCK_NONBLOCK|SOCK_CLOEXEC,0);
    if (fd<0) return -errno;
    int one=1; (void)setsockopt(fd,IPPROTO_TCP,TCP_NODELAY,&one,sizeof(one));
    struct sockaddr_storage ss; socklen_t len=fill_addr(&ss,v6,ip,port);
    if (connect(fd,(struct sockaddr *)&ss,len)<0 &&
        errno!=EINPROGRESS && errno!=EALREADY && errno!=EINTR) {
        int e=errno; close(fd); return -e;
    }
    return fd;
}

int32_t goose_io_connect_result(int32_t fd) {
    if (fd<0) return EINVAL;
    int e=0; socklen_t len=sizeof(e);
    return getsockopt(fd,SOL_SOCKET,SO_ERROR,&e,&len)<0 ? errno : e;
}
int32_t goose_io_socket_error(int32_t fd) { return goose_io_connect_result(fd); }

int64_t goose_io_recv(int32_t fd,uint8_t *dst,int64_t len) {
    if (fd<0 || !dst || len<0) return -EINVAL;
    ssize_t n; do { n=recv(fd,dst,(size_t)len,0); } while(n<0 && errno==EINTR);
    return n<0 ? -errno : n;
}
int64_t goose_io_send(int32_t fd,const uint8_t *src,int64_t len) {
    if (fd<0 || (!src && len) || len<0) return -EINVAL;
    ssize_t n; do { n=send(fd,src,(size_t)len,MSG_NOSIGNAL); } while(n<0 && errno==EINTR);
    return n<0 ? -errno : n;
}
int32_t goose_io_shutdown_write(int32_t fd) {
    return fd<0 ? -EINVAL : (shutdown(fd,SHUT_WR)<0 ? -errno : 0);
}
void goose_io_close(int32_t fd) { if(fd>=0) close(fd); }
void goose_io_reset(int32_t fd) {
    if(fd<0) return;
    struct linger lg={1,0}; (void)setsockopt(fd,SOL_SOCKET,SO_LINGER,&lg,sizeof(lg)); close(fd);
}
uint64_t goose_io_monotonic_ns(void) {
    struct timespec ts; if(clock_gettime(CLOCK_MONOTONIC,&ts)<0) return 0;
    return (uint64_t)ts.tv_sec*UINT64_C(1000000000)+(uint64_t)ts.tv_nsec;
}

#else
#include <stdint.h>
int64_t goose_io_epoll_create_raw(void) { return -1; }
int32_t goose_io_epoll_ctl_raw(int64_t a, int32_t b, int32_t c, uint32_t d, uint64_t e) { (void)a;(void)b;(void)c;(void)d;(void)e;return -1; }
int32_t goose_io_epoll_wait_raw(int64_t a, void *b, int32_t c, int32_t d) { (void)a;(void)b;(void)c;(void)d;return -1; }
int64_t goose_io_epoll_create(void){return -1;}
int32_t goose_io_epoll_ctl(int64_t a,int32_t b,int32_t c,uint32_t d,uint64_t e){(void)a;(void)b;(void)c;(void)d;(void)e;return -1;}
int32_t goose_io_epoll_wait(int64_t a,void*b,int32_t c,int32_t d){(void)a;(void)b;(void)c;(void)d;return -1;}
int32_t goose_io_epoll_wake(int64_t a){(void)a;return -1;}
void goose_io_epoll_close(int64_t a){(void)a;}
int32_t goose_io_listen(uint8_t a,const uint8_t*b,uint16_t c,uint8_t d,int32_t e){(void)a;(void)b;(void)c;(void)d;(void)e;return -1;}
int32_t goose_io_accept(int32_t a,uint8_t*b,uint8_t*c,uint16_t*d){(void)a;(void)b;(void)c;(void)d;return -1;}
int32_t goose_io_connect_start(uint8_t a,const uint8_t*b,uint16_t c){(void)a;(void)b;(void)c;return -1;}
int32_t goose_io_connect_result(int32_t a){(void)a;return -1;}
int32_t goose_io_socket_error(int32_t a){(void)a;return -1;}
int64_t goose_io_recv(int32_t a,uint8_t*b,int64_t c){(void)a;(void)b;(void)c;return -1;}
int64_t goose_io_send(int32_t a,const uint8_t*b,int64_t c){(void)a;(void)b;(void)c;return -1;}
int32_t goose_io_shutdown_write(int32_t a){(void)a;return -1;}
void goose_io_close(int32_t a){(void)a;}
void goose_io_reset(int32_t a){(void)a;}
uint64_t goose_io_monotonic_ns(void){return 0;}
#endif
