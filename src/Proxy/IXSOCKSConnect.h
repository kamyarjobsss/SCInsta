#ifndef IXSOCKSCONNECT_H
#define IXSOCKSCONNECT_H

#include <stddef.h>
#include <stdint.h>
#include <sys/socket.h>

// Same shape as proxychains-ng timed_connect: connect and finish the SOCKS5
// handshake while the socket is blocking, then put the caller's flags back.
// The app's poll/kqueue/read/write path is never wrapped.
#define IX_SOCKS_OK 0
#define IX_SOCKS_IN_PROGRESS 1
#define IX_SOCKS_REFUSED (-1)

// IX_SOCKS_OK: caller should return 0 from connect.
// IX_SOCKS_IN_PROGRESS: the tunnel is up and the socket is writable. Caller
// should return -1 with errno EINPROGRESS, which is what a non-blocking
// connect reports once the TCP handshake has finished.
// IX_SOCKS_REFUSED: caller should return -1 with errno ECONNREFUSED.
// `fn` is the libc connect. The dialer must not call the hooked symbol.
void IXSOCKSUseConnect(int (*fn)(int, const struct sockaddr *, socklen_t));

int IXSOCKSDial(int fd, const struct sockaddr *proxy, socklen_t proxyLen, const char *host, uint16_t port);

// Writes the whole buffer. Used only for the bytes connectx carried, after
// the handshake. Later application writes go through the real libc.
int IXSOCKSSendAll(int fd, const void *buf, size_t len);

#endif
