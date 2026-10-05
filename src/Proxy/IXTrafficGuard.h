#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <sys/socket.h>

NS_ASSUME_NONNULL_BEGIN

/// In-process traffic policy shared by the VLESS engine and the socket hooks.
/// Symbol rebinding is installed only when the VPN is turned on, and removed
/// when it is turned off. Nothing here runs from a constructor.

BOOL IXTrafficGuardInstall(void);
void IXTrafficGuardUninstall(void);
void IXTrafficHooksInstall(void);

void IXTrafficGuardSetRuntime(BOOL vpnOn, BOOL proxyUp, BOOL killSwitch, BOOL blockUDP);
void IXTrafficGuardSetPorts(uint16_t socksPort, uint16_t httpPort);
void IXTrafficGuardSetProxyHost(const char *host, uint16_t port);
NSString * _Nullable IXTrafficGuardProxyHost(void);

BOOL IXTrafficGuardVPNOn(void);
BOOL IXTrafficGuardProxyUp(void);
BOOL IXTrafficGuardKillSwitch(void);
BOOL IXTrafficGuardBlockUDP(void);
uint16_t IXTrafficGuardSocksPort(void);
uint16_t IXTrafficGuardHTTPPort(void);

/// Original libc symbols (never re-enter the hooks).
int IXOrigConnect(int fd, const struct sockaddr *addr, socklen_t len);
int IXOrigGetaddrinfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **res);

NSDictionary *IXTrafficGuardProxyDictionary(void);

/// If `host` is a fake address minted by the DNS hook, the original hostname.
NSString * _Nullable IXTrafficGuardLookupHost(NSString * _Nullable host);

/// Mint the same fake addresses getaddrinfo returns, without calling the system resolver.
BOOL IXTrafficGuardFakeSockaddrs(const char * _Nullable host, struct sockaddr_in * _Nullable v4, struct sockaddr_in6 * _Nullable v6);

/// Newest last. Keys: image, api, path, host, port, up, down, reason (tunneled or blocked).
NSArray<NSDictionary *> *IXTrafficGuardRecentConnections(void);
void IXTrafficGuardNoteSession(NSString * _Nullable host, uint16_t port, uint64_t up, uint64_t down, NSString * _Nullable reason);
void IXTrafficGuardNote(NSString * _Nullable path, NSString * _Nullable host, uint16_t port, NSString * _Nullable reason);
void IXTrafficGuardNoteFull(NSString * _Nullable image, NSString * _Nullable api, NSString * _Nullable host, uint16_t port, NSString * _Nullable reason);
BOOL IXTrafficGuardCallerIsSelf(void);
/// `returnAddress` is __builtin_return_address(0) from the hook itself.
BOOL IXTrafficGuardAddressIsSelf(const void *returnAddress);
/// Sockets created on this thread are left alone. Used around Xray's own dial.
void IXTrafficGuardSetThreadBypass(BOOL bypass);
BOOL IXTrafficGuardNWProxyReady(void);

NS_ASSUME_NONNULL_END
