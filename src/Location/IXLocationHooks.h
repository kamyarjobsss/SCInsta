#ifndef IX_LOCATION_HOOKS_H
#define IX_LOCATION_HOOKS_H

/// Install the fake-location swizzles. Safe to call more than once.
/// Does nothing until the user (or a non-safe launch) asks for it.
void IXLocationHooksInstall(void);

#endif
