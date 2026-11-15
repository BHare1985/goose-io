#define _GNU_SOURCE
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/socket.h>
#include <unistd.h>

typedef struct { uint64_t *data; int64_t len; } gio_slice_u64;
typedef struct { uint32_t *data; int64_t len; } gio_slice_u32;
extern int64_t goose_io_epoll_create(void);
extern int32_t goose_io_epoll_add(int64_t, int64_t, uint64_t, uint32_t);
extern int32_t goose_io_epoll_mod(int64_t, int64_t, uint64_t, uint32_t);
extern int32_t goose_io_epoll_del(int64_t, int64_t);
extern int32_t goose_io_epoll_wait(int64_t, gio_slice_u64, gio_slice_u32, int32_t);
extern int32_t goose_io_epoll_wake(int64_t);
extern void goose_io_epoll_close(int64_t);
extern uint64_t goose_io_monotonic_ns(void);

int main(void) {
  int fds[2];
  assert(socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0);
  int64_t r = goose_io_epoll_create();
  assert(r > 0);
  const uint64_t key = ((uint64_t)7 << 32) | 5;
  assert(goose_io_epoll_add(r, fds[0], key, 1) == 0);
  assert(write(fds[1], "x", 1) == 1);
  uint64_t keys[8] = {0};
  uint32_t flags[8] = {0};
  gio_slice_u64 ks = { keys, 8 };
  gio_slice_u32 fs = { flags, 8 };
  int n = goose_io_epoll_wait(r, ks, fs, 100);
  assert(n == 1 && keys[0] == key && (flags[0] & 1));
  char byte = 0;
  assert(read(fds[0], &byte, 1) == 1 && byte == 'x');
  assert(goose_io_epoll_mod(r, fds[0], key, 1) == 0);
  assert(goose_io_epoll_wake(r) == 0);
  n = goose_io_epoll_wait(r, ks, fs, 100);
  assert(n == 1 && keys[0] == UINT64_C(0xFFFFFFFFFFFFFFFF) && (flags[0] & (1u << 5)));
  assert(goose_io_epoll_del(r, fds[0]) == 0);
  assert(goose_io_monotonic_ns() > 0);
  goose_io_epoll_close(r);
  close(fds[0]); close(fds[1]);
  puts("EPOLL_C_SHIM_SMOKE: ok");
  return 0;
}
