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

// Instagram's fresh-install markers live in several group suite names.
// Those names share one sandbox suite, instagramx.appgroup, because a
// sideload cannot persist real group.com.* plists. Returns 1 when `suite`
// is one of those names. Other suites, including instagramx.appgroup
// itself, return 0 so the mapping cannot recurse.
int IXPrefsSharedSuite(const char *suite, char *out, size_t outLen);

/* How a SecItem read asked about iCloud keychain.
   ABSENT means the query omitted kSecAttrSynchronizable, which by default
   searches only the local partition and misses a synchronizable login item. */
#define IX_SYNC_ABSENT 0
#define IX_SYNC_FALSE 1
#define IX_SYNC_TRUE 2
#define IX_SYNC_ANY 3

#define IX_KC_OK 0
#define IX_KC_NOT_FOUND (-25300)
#define IX_KC_MISSING_ENTITLEMENT (-34018)

/* First synchronizable mode to use. An omitted attribute becomes Any so
   one read sees both partitions. An explicit true, false, or Any is kept. */
int IXKeychainReadFirstSync(int incoming);

/* Second mode after `status`, or -1 when the first result stands.
   Not-found and a missing iCloud entitlement try the other partition.
   Success is never repeated. */
int IXKeychainReadFallbackSync(int incoming, int status);

#endif
