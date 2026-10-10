#include "IXPanelURL.h"

#include <string.h>

static int ix_copy(char *out, size_t cap, const char *value) {
    size_t n;
    if (!out || cap == 0 || !value) return 0;
    n = strlen(value);
    if (n == 0 || n + 1 > cap) return 0;
    memcpy(out, value, n + 1);
    return 1;
}

static int ix_prefix(const char *text, const char *prefix) {
    size_t n = strlen(prefix);
    return strncmp(text, prefix, n) == 0;
}

int IXPanelHostNeedsPin(const char *host) {
    if (!host || !host[0]) return 0;
    return strcmp(host, "77.110.125.217") == 0;
}

int IXPanelJoinURL(const char *origin, const char *path, char *out, size_t cap) {
    size_t olen;
    size_t rlen;
    const char *rel;
    if (!out || cap == 0) return 0;
    out[0] = 0;
    if (!origin || !origin[0] || !path || !path[0]) return 0;
    if (strstr(path, "://") || strstr(path, "..")) return 0;
    olen = strlen(origin);
    while (olen > 0 && origin[olen - 1] == '/') olen--;
    if (olen == 0) return 0;
    rel = path[0] == '/' ? path + 1 : path;
    rlen = strlen(rel);
    if (rlen == 0 || olen + 1 + rlen + 1 > cap) return 0;
    memcpy(out, origin, olen);
    out[olen] = '/';
    memcpy(out + olen + 1, rel, rlen + 1);
    return 1;
}

int IXPanelStaticPath(const char *url, char *out, size_t cap) {
    const char *path = url;
    const char *rest = NULL;
    if (!out || cap == 0) return 0;
    out[0] = 0;
    if (!url || !url[0]) return 0;
    if (ix_prefix(url, "https://zovidar.duckdns.org")) {
        path = url + strlen("https://zovidar.duckdns.org");
    } else if (ix_prefix(url, "https://77.110.125.217:9443")) {
        path = url + strlen("https://77.110.125.217:9443");
    } else if (ix_prefix(url, "https://") || ix_prefix(url, "http://")) {
        return 0;
    }
    if (!path || path[0] != '/') return 0;
    if (strstr(path, "..") || strchr(path, '?') || strchr(path, '#')) return 0;
    if (ix_prefix(path, "/static/fonts/")) rest = path + strlen("/static/fonts/");
    else if (ix_prefix(path, "/static/stickers/")) rest = path + strlen("/static/stickers/");
    if (!rest || !rest[0] || strchr(rest, '/')) return 0;
    return ix_copy(out, cap, path);
}
