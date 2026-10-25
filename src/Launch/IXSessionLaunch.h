#ifndef IX_SESSION_LAUNCH_H
#define IX_SESSION_LAUNCH_H

/* FBSharedFramework has to be mapped before any constructor looks up
   Instagram classes or rebinds SecItem. 2.4.9 initialized SCInsta first
   and crashed. Note each dyld image, then ask before a class walk. */

void IXSessionLaunchReset(void);
void IXSessionLaunchNoteImage(const char *path);
int IXSessionLaunchMayWalkClasses(void);

/* 1 when `name` is FBSharedFramework, with or without a directory prefix.
   The image-add callback uses this so the keychain rebind can run as soon
   as that image is mapped, without moving SCInsta ahead of it. */
int IXSessionFrameworkName(const char *name);

#endif
