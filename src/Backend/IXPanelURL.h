#ifndef IX_PANEL_URL_H
#define IX_PANEL_URL_H

#include <stddef.h>

/* 1 when this host is the pinned IP fallback. The Let's Encrypt name uses
   the system trust store and returns 0. NULL and any other host return 0. */
int IXPanelHostNeedsPin(const char *host);

/* origin + path, with a single slash between them. `path` must be relative
   (no scheme) and must not contain "..". Returns 0 on a bad argument or
   when `out` is too small. */
int IXPanelJoinURL(const char *origin, const char *path, char *out, size_t cap);

/* Copies a font or sticker path (/static/fonts/<file> or
   /static/stickers/<file>). An absolute URL is accepted only for the
   primary name or the pinned IP, and only the path is copied. Other hosts,
   queries, fragments, and ".." are rejected. */
int IXPanelStaticPath(const char *url, char *out, size_t cap);

#endif
