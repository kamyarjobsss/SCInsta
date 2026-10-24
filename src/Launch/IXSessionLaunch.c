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
