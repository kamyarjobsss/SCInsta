// The strings Tigon hands to folly::IPAddress must be real numeric addresses.
// A hostname, a zone id, or a truncated sockaddr makes that constructor throw,
// and nothing in FBSharedFramework catches it.
#include "../src/Proxy/IXAddrCheck.h"

#include <arpa/inet.h>
#include <netdb.h>
#include <stdio.h>
#include <string.h>

static int gFailures = 0;

static void expect(int ok, const char *message) {
    if (ok) return;
    gFailures++;
    fprintf(stderr, "FAIL: %s\n", message);
}

static void check_numeric(const struct sockaddr *sa, socklen_t len, int family) {
    char host[INET6_ADDRSTRLEN];
    int rc = IXAddrWriteNumeric(sa, len, host, sizeof(host));
    expect(rc == 0, "numeric write");
    expect(host[0] != 0, "numeric non-empty");
    expect(strchr(host, '%') == NULL, "no zone");
    expect(strchr(host, '[') == NULL && strchr(host, ']') == NULL, "no brackets");
    expect(strchr(host, ' ') == NULL, "no space");
    expect(strchr(host, ':') == NULL || family == AF_INET6, "v4 has no colon");
    unsigned char back[16];
    expect(inet_pton(family, host, back) == 1, "inet_pton accepts the string");
#ifdef __APPLE__
    expect(sa->sa_len == len, "sa_len matches the buffer");
#endif
}

int main(void) {
    struct sockaddr_in v4;
    expect(IXFakeIPv4Bits(1) == htonl(0xC6120001u), "token 1 is 198.18.0.1");
    expect(IXFakeIPv4Token(IXFakeIPv4Bits(1)) == 1, "token round trip");
    expect(IXFakeIPv4Bits(0) == 0, "token 0 is not an address");
    expect(IXFakeIPv4Token(htonl(0x08080808u)) == 0, "8.8.8.8 is not a fake");
    expect(IXAddrFillInet(&v4, IXFakeIPv4Bits(1), htons(443)) == 0, "fill v4");
    check_numeric((struct sockaddr *)&v4, sizeof(v4), AF_INET);
    expect(strcmp(inet_ntoa(v4.sin_addr), "198.18.0.1") == 0, "198.18.0.1");
    expect(strchr(inet_ntoa(v4.sin_addr), ':') == NULL, "minted address is IPv4 only");

    struct in6_addr raw;
    memset(&raw, 0, sizeof(raw));
    raw.s6_addr[0] = 0xfd;
    raw.s6_addr[15] = 1;
    struct sockaddr_in6 v6;
    expect(IXAddrFillInet6(&v6, &raw, htons(443)) == 0, "fill v6");
    v6.sin6_scope_id = 12;
    check_numeric((struct sockaddr *)&v6, sizeof(v6), AF_INET6);

    char host[INET6_ADDRSTRLEN];
    expect(IXAddrWriteNumeric((struct sockaddr *)&v6, sizeof(v6), host, sizeof(host)) == 0, "v6 numeric");
    expect(strchr(host, '%') == NULL, "scope was dropped");
    expect(strcmp(host, "fd00::1") == 0, "fd00::1");

    struct sockaddr_storage stored;
    socklen_t storedLen = 0;
    expect(IXAddrCanonical((struct sockaddr *)&v6, sizeof(v6), &stored, &storedLen) == 0, "canonical v6");
    expect(storedLen == sizeof(struct sockaddr_in6), "canonical length is the full v6 size");
    expect(((struct sockaddr_in6 *)&stored)->sin6_scope_id == 0, "canonical scope is 0");

    expect(IXAddrCanonical((struct sockaddr *)&v6, 16, &stored, &storedLen) != 0, "truncated v6 is rejected");

    char tiny[4];
    expect(IXAddrWriteNumeric((struct sockaddr *)&v4, sizeof(v4), tiny, sizeof(tiny)) == EAI_OVERFLOW, "short buffer fails cleanly");
    expect(IXEndpointSkipsTunnel(1, 443) == 1, "direct host skips the tunnel");
    expect(IXEndpointSkipsTunnel(0, 9443) == 1, "panel port skips the tunnel");
    expect(IXEndpointSkipsTunnel(0, 443) == 0, "other ports stay eligible");
    expect(IXEndpointSkipsTunnel(0, 0) == 0, "missing port stays eligible");

    if (gFailures) {
        fprintf(stderr, "%d address checks failed\n", gFailures);
        return 1;
    }
    printf("address checks passed\n");
    return 0;
}
