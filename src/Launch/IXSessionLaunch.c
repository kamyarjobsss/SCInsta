#include "IXSessionLaunch.h"

#include <string.h>

static int ix_fb_ready;

void IXSessionLaunchReset(void) {
    ix_fb_ready = 0;
}

void IXSessionLaunchNoteImage(const char *path) {
    const char *base;
    if (!path || ix_fb_ready) return;
    base = strrchr(path, '/');
    base = base ? base + 1 : path;
    if (strcmp(base, "FBSharedFramework") == 0) ix_fb_ready = 1;
}

int IXSessionLaunchMayWalkClasses(void) {
    return ix_fb_ready ? 1 : 0;
}

int IXSessionFrameworkName(const char *name) {
    const char *base;
    if (!name || !name[0]) return 0;
    base = strrchr(name, '/');
    base = base ? base + 1 : name;
    return strcmp(base, "FBSharedFramework") == 0;
}
