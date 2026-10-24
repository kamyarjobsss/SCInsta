#ifndef IX_SESSION_LAUNCH_H
#define IX_SESSION_LAUNCH_H

/* FBSharedFramework has to be mapped before any constructor looks up
   Instagram classes or rebinds SecItem. 2.4.9 initialized SCInsta first
   and crashed. Note each dyld image, then ask before a class walk. */

void IXSessionLaunchReset(void);
void IXSessionLaunchNoteImage(const char *path);
int IXSessionLaunchMayWalkClasses(void);

#endif
