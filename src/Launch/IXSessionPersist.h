#ifndef IX_SESSION_PERSIST_H
#define IX_SESSION_PERSIST_H

#include <stddef.h>

// Access group forced onto every SecItem query.
// A non-empty probed group (the one SecItem itself assigned when no group
// was requested) is copied and the return value is 1: callers must set
// kSecAttrAccessGroup to that exact string on add, copy, update, and delete.
// An empty probe returns 0: callers must remove kSecAttrAccessGroup so the
// system default is used for both reads and writes. The caller's group is
// never kept, and a team id is never invented here.
int IXSessionProbedGroup(const char *probed, char *out, size_t outLen);

// Last path component for an app-group container. The identifier is copied
// unchanged, including a team prefix, so the directory does not move when
// the signed prefix is re-read. NULL or empty becomes group.com.burbn.instagram.
// Returns 0 when `out` is too small or the identifier contains a slash.
int IXSessionContainerComponent(const char *identifier, char *out, size_t outLen);

#endif
