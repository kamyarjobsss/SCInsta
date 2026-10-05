#include "IXSOCKSConnect.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
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
