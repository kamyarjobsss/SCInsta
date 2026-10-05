#include "IXAddrCheck.h"

#include <arpa/inet.h>
#include <netdb.h>
#include <string.h>

int IXAddrFillInet(struct sockaddr_in *out, uint32_t addrNetwork, uint16_t portNetwork) {
    if (!out) return -1;
    memset(out, 0, sizeof(*out));
#ifdef __APPLE__
    out->sin_len = (uint8_t)sizeof(*out);
#endif
    out->sin_family = AF_INET;
    out->sin_port = portNetwork;
    out->sin_addr.s_addr = addrNetwork;
    return 0;
}

int IXAddrFillInet6(struct sockaddr_in6 *out, const struct in6_addr *addr, uint16_t portNetwork) {
    if (!out || !addr) return -1;
    memset(out, 0, sizeof(*out));
#ifdef __APPLE__
    out->sin6_len = (uint8_t)sizeof(*out);
#endif
    out->sin6_family = AF_INET6;
    out->sin6_port = portNetwork;
    out->sin6_flowinfo = 0;
    out->sin6_scope_id = 0;
    out->sin6_addr = *addr;
    return 0;
}

static int IXEnough(const struct sockaddr *in, socklen_t inLen, socklen_t need) {
    if (!in) return 0;
    if (inLen >= need) return 1;
#ifdef __APPLE__
    if (in->sa_len >= need) return 1;
#endif
    return 0;
}

int IXAddrCanonical(const struct sockaddr *in, socklen_t inLen, struct sockaddr_storage *out, socklen_t *outLen) {
    if (!in || !out || !outLen) return -1;
    memset(out, 0, sizeof(*out));
    if (in->sa_family == AF_INET) {
        if (!IXEnough(in, inLen, (socklen_t)sizeof(struct sockaddr_in))) return -1;
        const struct sockaddr_in *src = (const struct sockaddr_in *)in;
        struct sockaddr_in *dst = (struct sockaddr_in *)out;
        if (IXAddrFillInet(dst, src->sin_addr.s_addr, src->sin_port) != 0) return -1;
        *outLen = (socklen_t)sizeof(*dst);
        return 0;
    }
    if (in->sa_family == AF_INET6) {
        if (!IXEnough(in, inLen, (socklen_t)sizeof(struct sockaddr_in6))) return -1;
        const struct sockaddr_in6 *src = (const struct sockaddr_in6 *)in;
        struct sockaddr_in6 *dst = (struct sockaddr_in6 *)out;
        // Drop the zone id. "fd00::1%en0" is not a host folly::IPAddress accepts.
        if (IXAddrFillInet6(dst, &src->sin6_addr, src->sin6_port) != 0) return -1;
        *outLen = (socklen_t)sizeof(*dst);
        return 0;
    }
    return -1;
}

int IXAddrWriteNumeric(const struct sockaddr *sa, socklen_t salen, char *host, size_t hostLen) {
    struct sockaddr_storage canon;
    socklen_t canonLen = 0;
    if (!host || hostLen < 2) return EAI_OVERFLOW;
    host[0] = 0;
    if (IXAddrCanonical(sa, salen, &canon, &canonLen) != 0) return EAI_FAMILY;

    char tmp[INET6_ADDRSTRLEN];
    const void *src = NULL;
    int family = canon.ss_family;
    if (family == AF_INET) src = &((struct sockaddr_in *)&canon)->sin_addr;
    else src = &((struct sockaddr_in6 *)&canon)->sin6_addr;
    if (!inet_ntop(family, src, tmp, sizeof(tmp))) return EAI_FAIL;

    size_t n = strlen(tmp);
    if (n == 0 || n + 1 > sizeof(tmp)) return EAI_FAIL;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)tmp[i];
        if (c == '%' || c == '[' || c == ']' || c == '/' || c == ' ' || c == '.') {
            if (c != '.') return EAI_FAIL;
        }
        if (c < 33 || c > 126) return EAI_FAIL;
    }
    if (strchr(tmp, '%') || strchr(tmp, '[') || strchr(tmp, ']')) return EAI_FAIL;

    unsigned char back[16];
    memset(back, 0, sizeof(back));
    if (inet_pton(family, tmp, back) != 1) return EAI_FAIL;
    if (family == AF_INET) {
        if (memcmp(back, &((struct sockaddr_in *)&canon)->sin_addr, 4) != 0) return EAI_FAIL;
    } else if (memcmp(back, &((struct sockaddr_in6 *)&canon)->sin6_addr, 16) != 0) {
        return EAI_FAIL;
    }
    if (n + 1 > hostLen) return EAI_OVERFLOW;
    memcpy(host, tmp, n + 1);
    return 0;
}
