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

/* The iCloud-keychain read helpers below are not the relaunch fix.
   A sideload log mentioned synchronizable items only as a clue. v2.4.2
   still logged out with SecItem hooks off, and the probe item survived. */

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

/* 1 when `key` is an Instagram fresh-install marker. Names that contain
   password, token, or session are rejected so this store cannot hold them.
   The match is ASCII case-insensitive. NULL and overlong names are 0. */
int IXFreshInstallKey(const char *key);

/* The two markers v2.4.2 printed while the preference plists were absent. */
int IXFreshKnownKey(const char *key);

/* 1 when a missing persistent value should be replaced by the Documents copy.
   A value already in the persistent domain is kept. Registered defaults do
   not count as persisted: the v2.4.2 log showed the key names through
   dictionaryRepresentation while both plists were missing. */
int IXFreshMarkerRestore(int persistent_present, int saved_present);

/* 1 when a known marker that has never been stored should be created.
   A saved or persisted value is not replaced by the placeholder. */
int IXFreshMarkerSeed(int persistent_present, int saved_present, int known_key);

/* 1 when SecItemDelete may run.
   our_service is the diagnostics, backend, or VPN item and is always allowed.
   password_class is a generic password, an internet password, or a query
   with no class. Other classes are always allowed.
   marker_persisted is 1 when a fresh-install marker was already in the
   Documents file or a preference domain at process start. Registered
   defaults do not count.
   A previous install whose marker was missing refuses password deletes
   until didFinishLaunching returns. That is the v2.4.2 window: existing
   launch, both plists absent, accounts already 0 when launch returned,
   and the v2.4.1 delete that returned success. Once the marker is on
   disk, launch deletes stay allowed so a normal token refresh still
   works. After launch, a real logout is allowed. The first install is
   allowed. */
int IXSessionDeleteAllowed(int existing_install, int launch_finished, int marker_persisted, int our_service, int password_class);

/* 1 for instagramx.diag, instagramx.backend, and instagramx.vpn. */
int IXSessionOurService(const char *service);

/* 1 for "genp", "inet", an empty class, or NULL. Certificates and keys are 0. */
int IXSessionPasswordClass(const char *cls);

/* Directory leaf for a missing app-group container. v2.2.4 used one leaf for
   every group id. e0b8495 used the identifier, so the session directory moved
   when that string changed. The identifier is ignored. */
int IXSessionFallbackLeaf(const char *identifier, char *out, size_t outLen);

/* Suite used when METAAppGroup has no user defaults. v2.2.4 always used
   group.com.burbn.instagram. e0b8495 used the identifier. */
int IXSessionDefaultsSuite(const char *identifier, char *out, size_t outLen);

/* What to write into a nil METAAppGroup identifier. Returns 0 when `current`
   is already set: v2.2.4 left it alone, and replacing it made the next launch
   miss the session. A nil identifier gets the SecItem probe group, then the
   requested name. */
int IXSessionIdentifierFill(const char *current, const char *requested, const char *probe, char *out, size_t outLen);

#endif
