#include "IXSessionPersist.h"

#include <string.h>

static int ix_copy(char *out, size_t outLen, const char *value) {
    if (!out || outLen == 0 || !value) return 0;
    size_t n = strlen(value);
    if (n == 0 || n + 1 > outLen) return 0;
    memcpy(out, value, n + 1);
    return 1;
}

int IXSessionProbedGroup(const char *probed, char *out, size_t outLen) {
    if (!out || outLen == 0) return 0;
    out[0] = 0;
    if (!probed || !probed[0]) return 0;
    return ix_copy(out, outLen, probed);
}

int IXSessionContainerComponent(const char *identifier, char *out, size_t outLen) {
    if (!out || outLen == 0) return 0;
    out[0] = 0;
    const char *src = (identifier && identifier[0]) ? identifier : "group.com.burbn.instagram";
    if (strchr(src, '/') || strchr(src, '\\')) return 0;
    return ix_copy(out, outLen, src);
}
