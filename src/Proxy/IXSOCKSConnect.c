#include "IXSOCKSConnect.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

// Local handshake budget. The tunnel-readiness wait is separate and never
// runs on the main thread. This cap is only so a stuck inbound cannot sit
// inside connect forever.
#define IX_SOCKS_BUDGET_MS 2000

static int (*ix_socks_connect)(int, const struct sockaddr *, socklen_t) = connect;

void IXSOCKSUseConnect(int (*fn)(int, const struct sockaddr *, socklen_t)) {
    if (fn) ix_socks_connect = fn;
}

static int64_t IXNowMs(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (int64_t)tv.tv_sec * 1000 + (int64_t)tv.tv_usec / 1000;
}

static int IXPoll(int fd, short events, int timeoutMs) {
    if (timeoutMs < 0) timeoutMs = 0;
    for (;;) {
        struct pollfd pfd;
        pfd.fd = fd;
        pfd.events = events;
        pfd.revents = 0;
        int rc = poll(&pfd, 1, timeoutMs);
        if (rc < 0 && errno == EINTR) continue;
        if (rc <= 0) return -1;
        if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) return -1;
        if (pfd.revents & events) return 0;
        return -1;
    }
}

static int IXWriteFull(int fd, const void *buf, size_t len, int64_t deadlineMs) {
    const uint8_t *p = buf;
    size_t sent = 0;
    while (sent < len) {
        int left = (int)(deadlineMs - IXNowMs());
        if (left <= 0) return -1;
        ssize_t n = send(fd, p + sent, len - sent, 0);
        if (n > 0) {
            sent += (size_t)n;
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (IXPoll(fd, POLLOUT, left) != 0) return -1;
            continue;
        }
        return -1;
    }
    return 0;
}

static int IXReadFull(int fd, void *buf, size_t len, int64_t deadlineMs) {
    uint8_t *p = buf;
    size_t got = 0;
    while (got < len) {
        int left = (int)(deadlineMs - IXNowMs());
        if (left <= 0) return -1;
        ssize_t n = recv(fd, p + got, len - got, 0);
        if (n > 0) {
            got += (size_t)n;
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (IXPoll(fd, POLLIN, left) != 0) return -1;
            continue;
        }
        return -1;
    }
    return 0;
}

static int IXTimedConnect(int fd, const struct sockaddr *proxy, socklen_t proxyLen, int64_t deadlineMs) {
    for (;;) {
        int rc = ix_socks_connect(fd, proxy, proxyLen);
        if (rc == 0) return 0;
        if (errno == EINTR) continue;
        if (errno != EINPROGRESS && errno != EALREADY) return -1;
        break;
    }
    int left = (int)(deadlineMs - IXNowMs());
    if (left <= 0 || IXPoll(fd, POLLOUT, left) != 0) return -1;
    int err = 0;
    socklen_t len = sizeof(err);
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) != 0) return -1;
    if (err != 0) {
        errno = err;
        return -1;
    }
    return 0;
}

static int IXSOCKSRequest(uint8_t *req, size_t cap, const char *host, uint16_t port) {
    if (!req || !host || cap < 10) return -1;
    size_t len = 0;
    req[len++] = 0x05;
    req[len++] = 0x01;
    req[len++] = 0x00;
    struct in_addr v4;
    struct in6_addr v6;
    if (inet_pton(AF_INET, host, &v4) == 1) {
        req[len++] = 0x01;
        memcpy(req + len, &v4, 4);
        len += 4;
    } else if (inet_pton(AF_INET6, host, &v6) == 1) {
        req[len++] = 0x04;
        memcpy(req + len, &v6, 16);
        len += 16;
    } else {
        size_t n = strlen(host);
        if (n == 0 || n > 255 || len + 3 + n + 2 > cap) return -1;
        req[len++] = 0x03;
        req[len++] = (uint8_t)n;
        memcpy(req + len, host, n);
        len += n;
    }
    req[len++] = (uint8_t)(port >> 8);
    req[len++] = (uint8_t)(port & 0xff);
    return (int)len;
}

int IXSOCKSDial(int fd, const struct sockaddr *proxy, socklen_t proxyLen, const char *host, uint16_t port) {
    if (fd < 0 || !proxy || proxyLen == 0 || !host || !host[0] || port == 0) {
        errno = EINVAL;
        return IX_SOCKS_REFUSED;
    }

    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) flags = 0;
    int nonblock = (flags & O_NONBLOCK) != 0;

    struct timeval savedRecv, savedSend;
    memset(&savedRecv, 0, sizeof(savedRecv));
    memset(&savedSend, 0, sizeof(savedSend));
    socklen_t timeLen = sizeof(savedRecv);
    getsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &savedRecv, &timeLen);
    timeLen = sizeof(savedSend);
    getsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &savedSend, &timeLen);
    struct timeval budget = {.tv_sec = IX_SOCKS_BUDGET_MS / 1000, .tv_usec = 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &budget, sizeof(budget));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &budget, sizeof(budget));

    // Non-blocking connect plus poll, then a blocking handshake. Restoring
    // `flags` (not `!O_NONBLOCK`) keeps the caller's other file status bits.
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    int64_t deadline = IXNowMs() + IX_SOCKS_BUDGET_MS;
    int ok = IXTimedConnect(fd, proxy, proxyLen, deadline) == 0;
    if (ok) fcntl(fd, F_SETFL, flags & ~O_NONBLOCK);

    if (ok) {
        uint8_t hello[3] = {0x05, 0x01, 0x00};
        uint8_t method[2];
        ok = IXWriteFull(fd, hello, sizeof(hello), deadline) == 0 &&
             IXReadFull(fd, method, sizeof(method), deadline) == 0 &&
             method[0] == 0x05 && method[1] == 0x00;
    }
    if (ok) {
        uint8_t req[512];
        int reqLen = IXSOCKSRequest(req, sizeof(req), host, port);
        uint8_t reply[4];
        ok = reqLen > 0 && IXWriteFull(fd, req, (size_t)reqLen, deadline) == 0 &&
             IXReadFull(fd, reply, sizeof(reply), deadline) == 0 &&
             reply[0] == 0x05 && reply[1] == 0x00;
        size_t skip = 0;
        if (ok && reply[3] == 0x01) skip = 4;
        else if (ok && reply[3] == 0x04) skip = 16;
        else if (ok && reply[3] == 0x03) {
            uint8_t nlen = 0;
            ok = IXReadFull(fd, &nlen, 1, deadline) == 0;
            skip = nlen;
        } else ok = 0;
        uint8_t sink[256];
        if (ok && skip && IXReadFull(fd, sink, skip, deadline) != 0) ok = 0;
        if (ok && IXReadFull(fd, sink, 2, deadline) != 0) ok = 0;
    }

    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &savedRecv, sizeof(savedRecv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &savedSend, sizeof(savedSend));
    fcntl(fd, F_SETFL, flags);
    if (!ok) {
        errno = ECONNREFUSED;
        return IX_SOCKS_REFUSED;
    }
    return nonblock ? IX_SOCKS_IN_PROGRESS : IX_SOCKS_OK;
}

int IXSOCKSSendAll(int fd, const void *buf, size_t len) {
    if (!buf && len) {
        errno = EINVAL;
        return -1;
    }
    return IXWriteFull(fd, buf, len, IXNowMs() + IX_SOCKS_BUDGET_MS);
}

static int IXHostRejected(const char *host) {
    if (!host || !host[0]) return 1;
    size_t n = strlen(host);
    if (n > 253) return 1;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)host[i];
        if (c <= 32 || c >= 127) return 1;
        if (c == '%' || c == '[' || c == ']' || c == '/' || c == '\\' || c == ' ' || c == ':') return 1;
    }
    return 0;
}

int IXSOCKSDestFromIPv4(uint32_t addrNetwork, char *host, size_t hostLen, IXSOCKSLookup4 lookup, void *ctx) {
    if (!host || hostLen < 8) return -1;
    host[0] = 0;
    if (lookup && lookup(addrNetwork, host, hostLen, ctx) == 1 && !IXHostRejected(host)) return 1;
    host[0] = 0;
    if (!inet_ntop(AF_INET, &addrNetwork, host, (socklen_t)hostLen)) {
        host[0] = 0;
        return -1;
    }
    struct in_addr back;
    if (host[0] == 0 || inet_pton(AF_INET, host, &back) != 1 || back.s_addr != addrNetwork) {
        host[0] = 0;
        return -1;
    }
    return 0;
}

static _Atomic uint16_t ix_front_upstream = 0;
static IXSOCKSLookup4 ix_front_lookup = NULL;
static void *ix_front_ctx = NULL;
static _Atomic int ix_front_started = 0;

static int IXFrontReply(int fd, uint8_t code) {
    uint8_t reply[10] = {0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0};
    return IXWriteFull(fd, reply, sizeof(reply), IXNowMs() + IX_SOCKS_BUDGET_MS);
}

static int IXFrontReadDest(int fd, char *host, size_t hostLen, uint16_t *port) {
    uint8_t head[4];
    if (IXReadFull(fd, head, sizeof(head), IXNowMs() + IX_SOCKS_BUDGET_MS) != 0) return -1;
    if (head[0] != 0x05 || head[1] != 0x01) return -1;
    if (head[3] == 0x04) return -2;
    if (head[3] == 0x01) {
        uint8_t raw[4];
        uint8_t p[2];
        if (IXReadFull(fd, raw, 4, IXNowMs() + IX_SOCKS_BUDGET_MS) != 0) return -1;
        if (IXReadFull(fd, p, 2, IXNowMs() + IX_SOCKS_BUDGET_MS) != 0) return -1;
        uint32_t be = 0;
        memcpy(&be, raw, 4);
        *port = (uint16_t)((p[0] << 8) | p[1]);
        return IXSOCKSDestFromIPv4(be, host, hostLen, ix_front_lookup, ix_front_ctx) < 0 ? -1 : 0;
    }
    if (head[3] == 0x03) {
        uint8_t nlen = 0;
        uint8_t p[2];
        if (IXReadFull(fd, &nlen, 1, IXNowMs() + IX_SOCKS_BUDGET_MS) != 0) return -1;
        if (nlen == 0 || (size_t)nlen + 1 > hostLen) return -1;
        if (IXReadFull(fd, host, nlen, IXNowMs() + IX_SOCKS_BUDGET_MS) != 0) return -1;
        host[nlen] = 0;
        if (IXReadFull(fd, p, 2, IXNowMs() + IX_SOCKS_BUDGET_MS) != 0) return -1;
        *port = (uint16_t)((p[0] << 8) | p[1]);
        if (IXHostRejected(host)) return -1;
        struct in_addr v4;
        if (inet_pton(AF_INET, host, &v4) == 1) {
            return IXSOCKSDestFromIPv4(v4.s_addr, host, hostLen, ix_front_lookup, ix_front_ctx) < 0 ? -1 : 0;
        }
        return 0;
    }
    return -2;
}

static void IXFrontSplice(int a, int b) {
    int fa = fcntl(a, F_GETFL, 0);
    int fb = fcntl(b, F_GETFL, 0);
    if (fa >= 0) fcntl(a, F_SETFL, fa | O_NONBLOCK);
    if (fb >= 0) fcntl(b, F_SETFL, fb | O_NONBLOCK);
    uint8_t buf[4096];
    for (;;) {
        struct pollfd pfds[2];
        pfds[0].fd = a;
        pfds[0].events = POLLIN;
        pfds[1].fd = b;
        pfds[1].events = POLLIN;
        int rc = poll(pfds, 2, 60000);
        if (rc <= 0) {
            if (rc < 0 && errno == EINTR) continue;
            return;
        }
        for (int i = 0; i < 2; i++) {
            if (!(pfds[i].revents & (POLLIN | POLLHUP | POLLERR))) continue;
            int src = pfds[i].fd;
            int dst = src == a ? b : a;
            ssize_t n = recv(src, buf, sizeof(buf), 0);
            if (n <= 0) return;
            if (IXWriteFull(dst, buf, (size_t)n, IXNowMs() + 30000) != 0) return;
        }
    }
}

static void IXNoSigPipe(int fd) {
#ifdef SO_NOSIGPIPE
    int nosig = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, sizeof(nosig));
#else
    (void)fd;
#endif
}

static void *IXFrontClient(void *arg) {
    int fd = (int)(intptr_t)arg;
    IXNoSigPipe(fd);
    uint8_t hello[2];
    int64_t deadline = IXNowMs() + IX_SOCKS_BUDGET_MS;
    if (IXReadFull(fd, hello, 2, deadline) != 0 || hello[0] != 0x05 || hello[1] == 0) {
        close(fd);
        return NULL;
    }
    uint8_t methods[32];
    size_t nmethods = hello[1];
    if (nmethods > sizeof(methods) || IXReadFull(fd, methods, nmethods, deadline) != 0) {
        close(fd);
        return NULL;
    }
    uint8_t method[2] = {0x05, 0x00};
    if (IXWriteFull(fd, method, 2, deadline) != 0) {
        close(fd);
        return NULL;
    }
    char host[256];
    uint16_t port = 0;
    host[0] = 0;
    int dest = IXFrontReadDest(fd, host, sizeof(host), &port);
    if (dest != 0 || port == 0 || host[0] == 0) {
        IXFrontReply(fd, dest == -2 ? 0x08 : 0x01);
        close(fd);
        return NULL;
    }
    int up = socket(AF_INET, SOCK_STREAM, 0);
    if (up < 0) {
        IXFrontReply(fd, 0x01);
        close(fd);
        return NULL;
    }
    IXNoSigPipe(up);
    struct sockaddr_in proxy;
    memset(&proxy, 0, sizeof(proxy));
    proxy.sin_family = AF_INET;
#ifdef __APPLE__
    proxy.sin_len = sizeof(proxy);
#endif
    proxy.sin_port = htons(atomic_load(&ix_front_upstream));
    proxy.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int dialed = IXSOCKSDial(up, (const struct sockaddr *)&proxy, sizeof(proxy), host, port);
    if (dialed == IX_SOCKS_REFUSED) {
        IXFrontReply(fd, 0x05);
        close(up);
        close(fd);
        return NULL;
    }
    if (IXFrontReply(fd, 0x00) != 0) {
        close(up);
        close(fd);
        return NULL;
    }
    IXFrontSplice(fd, up);
    close(up);
    close(fd);
    return NULL;
}

static void *IXFrontAccept(void *arg) {
    int lfd = (int)(intptr_t)arg;
    for (;;) {
        int fd = accept(lfd, NULL, NULL);
        if (fd < 0) {
            if (errno == EINTR) continue;
            continue;
        }
        pthread_t thread;
        if (pthread_create(&thread, NULL, IXFrontClient, (void *)(intptr_t)fd) != 0) {
            close(fd);
            continue;
        }
        pthread_detach(thread);
    }
    return NULL;
}

void IXSOCKSFrontStart(uint16_t listenPort, uint16_t upstreamPort, IXSOCKSLookup4 lookup, void *ctx) {
    if (!listenPort || !upstreamPort) return;
    atomic_store(&ix_front_upstream, upstreamPort);
    ix_front_lookup = lookup;
    ix_front_ctx = ctx;
    if (atomic_exchange(&ix_front_started, 1)) return;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        atomic_store(&ix_front_started, 0);
        return;
    }
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
#ifdef __APPLE__
    addr.sin_len = sizeof(addr);
#endif
    addr.sin_port = htons(listenPort);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 64) != 0) {
        close(fd);
        atomic_store(&ix_front_started, 0);
        return;
    }
    pthread_t thread;
    if (pthread_create(&thread, NULL, IXFrontAccept, (void *)(intptr_t)fd) != 0) {
        close(fd);
        atomic_store(&ix_front_started, 0);
        return;
    }
    pthread_detach(thread);
}
