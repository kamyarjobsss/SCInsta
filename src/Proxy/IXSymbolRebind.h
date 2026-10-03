#ifndef IX_SYMBOL_REBIND_H
#define IX_SYMBOL_REBIND_H

#include <stddef.h>

/// Replace lazy and non-lazy symbol pointers (GOT / __la_symbol_ptr / __auth_got)
/// in already-loaded images. Writes data pages only, with VM_PROT_COPY.
/// Never patches __TEXT. `names` are C names ("connect"); Mach-O's leading
/// underscore is added here. Originals must already have been taken with dlsym.
/// Returns how many slots were updated.
int IXSymbolRebindSlots(const char *const *names, void *const *replacements, unsigned count);

/// Put every slot from the last successful rebind back.
/// Slots written by IXSymbolRebindPermanent are left in place.
void IXSymbolRebindRestore(void);

/// Same data-pointer rebind, but VPN restore does not undo it, and a later
/// IXSymbolRebindSlots call does not drop these names. Used for the app-group
/// symbols Instagram calls directly after login.
int IXSymbolRebindPermanent(const char *const *names, void *const *replacements, unsigned count);

#endif
