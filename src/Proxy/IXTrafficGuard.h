#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <sys/socket.h>

NS_ASSUME_NONNULL_BEGIN

/// In-process traffic policy shared by the VLESS engine and the socket hooks.
/// Hooks are installed at load and no-op until a proxy is actually up.

void IXTrafficGuardInstall(void);

void IXTrafficGuardSetRuntime(BOOL vpnOn, BOOL proxyUp, BOOL killSwitch, BOOL blockUDP);
void IXTrafficGuardSetPorts(uint16_t socksPort, uint16_t httpPort);
void IXTrafficGuardSetProxyHost(const char *host, uint16_t port);

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

NS_ASSUME_NONNULL_END
