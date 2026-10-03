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
void IXSymbolRebindRestore(void);

#endif
