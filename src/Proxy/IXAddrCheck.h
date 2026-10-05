#ifndef IXADDRCHECK_H
#define IXADDRCHECK_H

#include <stddef.h>
#include <stdint.h>
#include <netinet/in.h>
#include <sys/socket.h>

// Builds a sockaddr whose length, family, and address bytes agree.
// Unused fields (sin_zero, flowinfo, scope id) are zero. Returns 0 on success.
int IXAddrFillInet(struct sockaddr_in *out, uint32_t addrNetwork, uint16_t portNetwork);
int IXAddrFillInet6(struct sockaddr_in6 *out, const struct in6_addr *addr, uint16_t portNetwork);

// Copies into a complete sockaddr_storage. A short or unknown family fails
// instead of returning a truncated address that inet_ntop would misread.
// Returns 0 on success and sets *outLen to the real size.
int IXAddrCanonical(const struct sockaddr *in, socklen_t inLen, struct sockaddr_storage *out, socklen_t *outLen);

// Writes a numeric host that inet_pton accepts again. No brackets, zone id,
// port, or trailing dot. Returns 0, or an EAI_* code.
int IXAddrWriteNumeric(const struct sockaddr *sa, socklen_t salen, char *host, size_t hostLen);

#endif
