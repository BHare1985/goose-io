// SPDX-License-Identifier: Apache-2.0
// Minimal Linux epoll + eventfd backend for goose-io.
// This file intentionally contains no protocol or framework policy.

#if defined(__linux__)
#define _GNU_SOURCE
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>

#define GIO_WAKE_KEY UINT64_C(0xFFFFFFFFFFFFFFFF)
#define GIO_EVENT_READABLE (1u << 0)
#define GIO_EVENT_WRITABLE (1u << 1)
#define GIO_EVENT_ERROR    (1u << 2)
#define GIO_EVENT_PEER_EOF (1u << 3)

typedef struct { uint64_t *data; int64_t len; } gio_slice_u64;
typedef struct { uint32_t *data; int64_t len; } gio_slice_u32;

typedef struct { int epoll_fd; int wake_fd; } gio_epoll_state;

static uint32_t to_native_events(uint32_t flags) {
    uint32_t events = EPOLLRDHUP;
    if (flags & GIO_EVENT_READABLE) events |= EPOLLIN;
    if (flags & GIO_EVENT_WRITABLE) events |= EPOLLOUT;
    return events;
}

static uint32_t from_native_events(uint32_t events) {
    uint32_t flags = 0;
    if (events & (EPOLLIN | EPOLLPRI)) flags |= GIO_EVENT_READABLE;
    if (events & EPOLLOUT) flags |= GIO_EVENT_WRITABLE;
    if (events & (EPOLLERR | EPOLLPRI)) flags |= GIO_EVENT_ERROR;
    if (events & (EPOLLRDHUP | EPOLLHUP)) flags |= GIO_EVENT_PEER_EOF;
    return flags;
}

int64_t goose_io_epoll_create(void) {
    gio_epoll_state *state = (gio_epoll_state *)calloc(1, sizeof(*state));
    if (!state) return -1;
    state->epoll_fd = epoll_create1(EPOLL_CLOEXEC);
    state->wake_fd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    if (state->epoll_fd < 0 || state->wake_fd < 0) {
        if (state->epoll_fd >= 0) close(state->epoll_fd);
        if (state->wake_fd >= 0) close(state->wake_fd);
        free(state); return -1;
    }
    struct epoll_event ev;
    memset(&ev, 0, sizeof(ev));
    ev.events = EPOLLIN; ev.data.u64 = GIO_WAKE_KEY;
    if (epoll_ctl(state->epoll_fd, EPOLL_CTL_ADD, state->wake_fd, &ev) != 0) {
        close(state->wake_fd); close(state->epoll_fd); free(state); return -1;
    }
    return (int64_t)(intptr_t)state;
}

static gio_epoll_state *get_state(int64_t handle) {
    return handle > 0 ? (gio_epoll_state *)(intptr_t)handle : NULL;
}

int32_t goose_io_epoll_add(int64_t handle, int64_t fd, uint64_t key, uint32_t flags) {
    gio_epoll_state *state = get_state(handle);
    if (!state || fd < 0 || key == GIO_WAKE_KEY) return -EINVAL;
    struct epoll_event ev; memset(&ev, 0, sizeof(ev));
    ev.events = to_native_events(flags); ev.data.u64 = key;
    if (epoll_ctl(state->epoll_fd, EPOLL_CTL_ADD, (int)fd, &ev) != 0) return -errno;
    return 0;
}

int32_t goose_io_epoll_mod(int64_t handle, int64_t fd, uint64_t key, uint32_t flags) {
    gio_epoll_state *state = get_state(handle);
    if (!state || fd < 0 || key == GIO_WAKE_KEY) return -EINVAL;
    struct epoll_event ev; memset(&ev, 0, sizeof(ev));
    ev.events = to_native_events(flags); ev.data.u64 = key;
    if (epoll_ctl(state->epoll_fd, EPOLL_CTL_MOD, (int)fd, &ev) != 0) return -errno;
    return 0;
}

int32_t goose_io_epoll_del(int64_t handle, int64_t fd) {
    gio_epoll_state *state = get_state(handle);
    if (!state || fd < 0) return -EINVAL;
    if (epoll_ctl(state->epoll_fd, EPOLL_CTL_DEL, (int)fd, NULL) != 0) {
        if (errno == ENOENT || errno == EBADF) return 0;
        return -errno;
    }
    return 0;
}

int32_t goose_io_epoll_wait(int64_t handle, gio_slice_u64 keys, gio_slice_u32 flags, int32_t timeout_ms) {
    gio_epoll_state *state = get_state(handle);
    if (!state || !keys.data || !flags.data || keys.len <= 0 || flags.len <= 0) return -EINVAL;
    int capacity = (int)(keys.len < flags.len ? keys.len : flags.len);
    if (capacity > 64) capacity = 64;
    struct epoll_event events[64];
    int count = epoll_wait(state->epoll_fd, events, capacity, timeout_ms);
    if (count < 0) { if (errno == EINTR) return 0; return -errno; }
    int out = 0;
    for (int i = 0; i < count; i++) {
        uint64_t key = events[i].data.u64;
        if (key == GIO_WAKE_KEY) {
            uint64_t value;
            while (read(state->wake_fd, &value, sizeof(value)) == (ssize_t)sizeof(value)) { }
            keys.data[out] = GIO_WAKE_KEY; flags.data[out] = 1u << 5;
        } else {
            keys.data[out] = key; flags.data[out] = from_native_events(events[i].events);
        }
        out++;
    }
    return out;
}

int32_t goose_io_epoll_wake(int64_t handle) {
    gio_epoll_state *state = get_state(handle);
    if (!state) return -EINVAL;
    uint64_t one = 1;
    ssize_t rc = write(state->wake_fd, &one, sizeof(one));
    if (rc == (ssize_t)sizeof(one) || errno == EAGAIN) return 0;
    return -errno;
}

uint64_t goose_io_monotonic_ns(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return (uint64_t)ts.tv_sec * UINT64_C(1000000000) + (uint64_t)ts.tv_nsec;
}

void goose_io_epoll_close(int64_t handle) {
    gio_epoll_state *state = get_state(handle);
    if (!state) return;
    if (state->wake_fd >= 0) close(state->wake_fd);
    if (state->epoll_fd >= 0) close(state->epoll_fd);
    free(state);
}
#else
#include <stdint.h>
int64_t goose_io_epoll_create(void) { return -1; }
int32_t goose_io_epoll_add(int64_t a, int64_t b, uint64_t c, uint32_t d) { (void)a;(void)b;(void)c;(void)d;return -1; }
int32_t goose_io_epoll_mod(int64_t a, int64_t b, uint64_t c, uint32_t d) { (void)a;(void)b;(void)c;(void)d;return -1; }
int32_t goose_io_epoll_del(int64_t a, int64_t b) { (void)a;(void)b;return -1; }
int32_t goose_io_epoll_wait(int64_t a, void *b, void *c, int32_t d) { (void)a;(void)b;(void)c;(void)d;return -1; }
int32_t goose_io_epoll_wake(int64_t a) { (void)a;return -1; }
uint64_t goose_io_monotonic_ns(void) { return 0; }
void goose_io_epoll_close(int64_t a) { (void)a; }
#endif
