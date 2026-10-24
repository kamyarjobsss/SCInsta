#ifndef IX_SYMBOL_REBIND_H
#define IX_SYMBOL_REBIND_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Replace lazy and non-lazy symbol pointers (GOT / __la_symbol_ptr / __auth_got)
/// in already-loaded images, including images loaded later. Also walks
/// LC_DYLD_CHAINED_FIXUPS for app binaries such as FBSharedFramework, where
/// the bind slots are not classic lazy pointers. Writes data pages only.
/// Never patches __TEXT or Objective-C selector tables. `names` are C names
/// ("connect"); Mach-O's leading underscore is added here. Originals must
/// already have been taken with dlsym. Returns how many slots were updated.
int IXSymbolRebindSlots(const char *const *names, void *const *replacements, unsigned count);

/// Put every slot from the last successful rebind back.
/// Slots written by IXSymbolRebindPermanent are left in place.
void IXSymbolRebindRestore(void);

/// Same data-pointer rebind, but VPN restore does not undo it, and a later
/// IXSymbolRebindSlots call does not drop these names. Used for the app-group
/// symbols Instagram calls directly after login.
int IXSymbolRebindPermanent(const char *const *names, void *const *replacements, unsigned count);

/// The function a permanent rebind replaced, when one was already installed.
/// NULL until IXSymbolRebindPermanent has seen that name. The raw export is
/// returned when no earlier hook was in the slot.
void *IXSymbolPrevious(const char *name);

#ifdef __cplusplus
}
#endif

#endif
