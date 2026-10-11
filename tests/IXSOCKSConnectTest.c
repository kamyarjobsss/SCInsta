// Local stand-in for a non-blocking client (folly/EventBase uses kqueue).
// A tiny SOCKS5 server accepts the handshake. After IXSOCKSDial the socket
// must already be a normal connected stream: kqueue reports it writable,
// SO_ERROR is 0, and read/write are the libc calls with no extra hook.
#include "../src/Proxy/IXSOCKSConnect.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <sys/event.h>
#endif

static int gFailures = 0;

static void expect(int ok, const char *message) {
    if (ok) return;
    gFailures++;
    fprintf(stderr, "FAIL: %s (errno %d)\n", message, errno);
}

static int wait_fd(int fd, short events) {
    struct pollfd pfd = {.fd = fd, .events = events};
    for (;;) {
        int rc = poll(&pfd, 1, 2000);
        if (rc < 0 && errno == EINTR) continue;
        return rc == 1 ? 0 : -1;
    }
}

static int read_full(int fd, void *buf, size_t len) {
    uint8_t *p = buf;
    size_t got = 0;
    while (got < len) {
        ssize_t n = recv(fd, p + got, len - got, 0);
        if (n > 0) {
            got += (size_t)n;
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (wait_fd(fd, POLLIN) != 0) return -1;
            continue;
        }
        return -1;
    }
    return 0;
}

static int write_full(int fd, const void *buf, size_t len) {
    const uint8_t *p = buf;
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = send(fd, p + sent, len - sent, 0);
        if (n > 0) {
            sent += (size_t)n;
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (wait_fd(fd, POLLOUT) != 0) return -1;
            continue;
        }
        return -1;
    }
    return 0;
}

static int handle_one(int fd) {
    uint8_t hello[3];
    if (read_full(fd, hello, 3) != 0 || hello[0] != 0x05) return -1;
    uint8_t method[2] = {0x05, 0x00};
    if (write_full(fd, method, 2) != 0) return -1;
    uint8_t head[4];
    if (read_full(fd, head, 4) != 0 || head[1] != 0x01) return -1;
    size_t skip = 0;
    if (head[3] == 0x01) skip = 4;
    else if (head[3] == 0x04) skip = 16;
    else if (head[3] == 0x03) {
        uint8_t nlen = 0;
        if (read_full(fd, &nlen, 1) != 0) return -1;
        skip = nlen;
    } else return -1;
    uint8_t sink[300];
    if (skip && read_full(fd, sink, skip) != 0) return -1;
    if (read_full(fd, sink, 2) != 0) return -1;
    uint8_t reply[10] = {0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0};
    if (write_full(fd, reply, sizeof(reply)) != 0) return -1;
    char line[64];
    size_t got = 0;
    while (got + 1 < sizeof(line)) {
        char ch = 0;
        if (read_full(fd, &ch, 1) != 0) return -1;
        line[got++] = ch;
        if (ch == '\n') break;
    }
    line[got] = 0;
    return write_full(fd, line, got);
}

static void *server_main(void *arg) {
    int lfd = *(int *)arg;
    for (int i = 0; i < 2; i++) {
        int fd = accept(lfd, NULL, NULL);
        if (fd < 0) continue;
        handle_one(fd);
        close(fd);
    }
    return NULL;
}

static int listen_loopback(struct sockaddr_in *out) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
#ifdef __APPLE__
    addr.sin_len = sizeof(addr);
#endif
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }
    if (listen(fd, 8) != 0) {
        close(fd);
        return -1;
    }
    socklen_t len = sizeof(addr);
    if (getsockname(fd, (struct sockaddr *)&addr, &len) != 0) {
        close(fd);
        return -1;
    }
    *out = addr;
    return fd;
}

static int dial_and_exchange(const struct sockaddr_in *proxy, int nonblock, const char *payload) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    expect(fd >= 0, "socket");
    if (fd < 0) return -1;
    if (nonblock) {
        int flags = fcntl(fd, F_GETFL, 0);
        expect(fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0, "set nonblock");
    }
    errno = 0;
    int rc = IXSOCKSDial(fd, (const struct sockaddr *)proxy, sizeof(*proxy), "api.ipify.org", 443);
    if (nonblock) {
        expect(rc == IX_SOCKS_IN_PROGRESS, "nonblocking dial reports in progress");
        int flags = fcntl(fd, F_GETFL, 0);
        expect((flags & O_NONBLOCK) != 0, "O_NONBLOCK restored");
#if defined(__APPLE__)
        int kq = kqueue();
        expect(kq >= 0, "kqueue");
        struct kevent change, event;
        EV_SET(&change, fd, EVFILT_WRITE, EV_ADD, 0, 0, NULL);
        struct timespec ts = {.tv_sec = 1, .tv_nsec = 0};
        int n = kevent(kq, &change, 1, &event, 1, &ts);
        expect(n == 1, "kqueue reports the connected socket writable");
        expect(event.filter == EVFILT_WRITE, "kqueue filter is write");
        expect((event.flags & EV_ERROR) == 0, "kqueue event has no error");
        close(kq);
#else
        struct pollfd pfd = {.fd = fd, .events = POLLOUT};
        expect(poll(&pfd, 1, 1000) == 1, "poll reports the connected socket writable");
#endif
        int soerr = 1;
        socklen_t sl = sizeof(soerr);
        expect(getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &sl) == 0, "SO_ERROR");
        expect(soerr == 0, "SO_ERROR is 0 after the handshake");
    } else {
        expect(rc == IX_SOCKS_OK, "blocking dial returns success");
    }
    expect(write_full(fd, payload, strlen(payload)) == 0, "write payload on the plain socket");
    char got[64];
    memset(got, 0, sizeof(got));
    expect(read_full(fd, got, strlen(payload)) == 0, "read payload on the plain socket");
    expect(memcmp(got, payload, strlen(payload)) == 0, "echo matches");
    close(fd);
    return 0;
}

static int lookup_instagram(uint32_t addr, char *host, size_t hostLen, void *ctx) {
    (void)ctx;
    uint32_t ip = ntohl(addr);
    if ((ip & 0xFFFE0000u) != 0xC6120000u) return 0;
    if ((ip & 0x1FFFFu) != 7) return 0;
    snprintf(host, hostLen, "i.instagram.com");
    return 1;
}

static int lookup_bad(uint32_t addr, char *host, size_t hostLen, void *ctx) {
    (void)addr;
    (void)ctx;
    snprintf(host, hostLen, "fd00::1%%en0");
    return 1;
}

static void check_dest(void) {
    char host[64];
    uint32_t fake = htonl(0xC6120007u);
    expect(IXSOCKSDestFromIPv4(fake, host, sizeof(host), lookup_instagram, NULL) == 1, "fake maps to a hostname");
    expect(strcmp(host, "i.instagram.com") == 0, "hostname is the mapped name");
    expect(strchr(host, '%') == NULL && strchr(host, '[') == NULL, "mapped name has no zone or brackets");

    uint32_t real = htonl(0x08080808u);
    expect(IXSOCKSDestFromIPv4(real, host, sizeof(host), lookup_instagram, NULL) == 0, "public v4 stays numeric");
    expect(strcmp(host, "8.8.8.8") == 0, "8.8.8.8");

    expect(IXSOCKSDestFromIPv4(fake, host, sizeof(host), lookup_bad, NULL) == 0, "malformed lookup falls back to numeric");
    expect(strcmp(host, "198.18.0.7") == 0, "fallback is the dotted fake");
    expect(host[0] != 0, "fallback is not empty");
}

int main(void) {
    check_dest();
    struct sockaddr_in proxy;
    int lfd = listen_loopback(&proxy);
    expect(lfd >= 0, "listen");
    if (lfd < 0) return 1;
    pthread_t thread;
    expect(pthread_create(&thread, NULL, server_main, &lfd) == 0, "server thread");

    dial_and_exchange(&proxy, 1, "nb-ping\n");
    dial_and_exchange(&proxy, 0, "bk-ping\n");
    pthread_join(thread, NULL);
    close(lfd);

    struct sockaddr_in closed = proxy;
    int down = socket(AF_INET, SOCK_STREAM, 0);
    int flags = fcntl(down, F_GETFL, 0);
    fcntl(down, F_SETFL, flags | O_NONBLOCK);
    int rc = IXSOCKSDial(down, (const struct sockaddr *)&closed, sizeof(closed), "example.com", 80);
    expect(rc == IX_SOCKS_REFUSED, "closed inbound is refused");
    expect(errno == ECONNREFUSED, "errno is ECONNREFUSED");
    close(down);

    if (gFailures) {
        fprintf(stderr, "%d socks harness failure(s)\n", gFailures);
        return 1;
    }
    printf("socks connect harness ok\n");
    return 0;
}
