#ifndef IX_KEYCHAIN_GROUP_H
#define IX_KEYCHAIN_GROUP_H

#include <stddef.h>

// Apple team ids are 10 alphanumeric characters. The signed
// application-identifier looks like "TEAMID1234.com.burbn.instagram".
// Returns 1 and writes the 10-character prefix when that shape matches.
int IXKeychainTeamPrefix(const char *applicationIdentifier, char prefix[11]);

// Copies `group` without a leading team prefix. A name that does not start
// with a team id, such as "group.com.burbn.instagram", is copied unchanged.
int IXKeychainStripTeamPrefix(const char *group, char *bare, size_t bareLen);

// Access group to pass to SecItem for `requested`.
// An already-entitled group is kept, so two accounts that share it are not
// split and a group zxPluginsInject already proved is left alone.
// A bare or stale-prefix Instagram group is rewritten to "PREFIX.bare" when
// that string is in `entitled` or a "PREFIX.*" wildcard allows it. Otherwise
// the signed application-identifier is used when it is entitled.
// `entitledCount == 0` means the entitlement list was not readable: `requested`
// is kept rather than inventing a group SecItem would reject.
int IXKeychainCanonicalGroup(const char *applicationIdentifier,
                             const char *requested,
                             const char *const *entitled,
                             int entitledCount,
                             char *out,
                             size_t outLen);

// 1 when `identifier` already carries a team prefix and it is not the signed
// one, and "PREFIX.bare" is entitled. Bare names return 0: replacing
// "group.com.burbn.instagram" with the SecItem default group is what made
// 2.1.4 miss the saved session.
int IXKeychainStalePrefixedGroup(const char *applicationIdentifier,
                                 const char *identifier,
                                 const char *const *entitled,
                                 int entitledCount,
                                 char *out,
                                 size_t outLen);

#endif
