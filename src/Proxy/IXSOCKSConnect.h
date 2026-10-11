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

// lookup4 returns 1 and writes a hostname when addrNetwork is a fake IPv4
// that must be dialed by name. Returns 0 to keep the numeric address.
// IXSOCKSDestFromIPv4 always leaves a non-empty inet_pton-valid IPv4, or a
// hostname with no zone, brackets, or colon. Returns 1 (domain), 0 (numeric),
// or -1 (refused: empty or malformed).
typedef int (*IXSOCKSLookup4)(uint32_t addrNetwork, char *host, size_t hostLen, void *ctx);
int IXSOCKSDestFromIPv4(uint32_t addrNetwork, char *host, size_t hostLen, IXSOCKSLookup4 lookup, void *ctx);

// Accepts SOCKS5 on 127.0.0.1:listenPort and dials 127.0.0.1:upstreamPort.
// IPv4 destinations in 198.18.0.0/15 are rewritten through lookup4. IPv6
// destinations are refused. Safe to call once; later calls are ignored.
void IXSOCKSFrontStart(uint16_t listenPort, uint16_t upstreamPort, IXSOCKSLookup4 lookup, void *ctx);

#endif
