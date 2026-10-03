#import "IXLaunchGuard.h"

#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import <sys/stat.h>

static volatile int ix_safe_mode = 0;

static int IXGuardPath(char *out, size_t outLen) {
    const char *home = getenv("HOME");
    if (!home || !home[0]) return 0;
#if IX_ADDON
    int n = snprintf(out, outLen, "%s/Library/Caches/ix_addon_launch_guard", home);
#else
    int n = snprintf(out, outLen, "%s/Library/Caches/ix_launch_guard", home);
#endif
    return n > 0 && (size_t)n < outLen;
}

static void IXGuardWrite(const char *path, const char *text) {
    char dir[1024];
    strlcpy(dir, path, sizeof(dir));
    char *slash = strrchr(dir, '/');
    if (slash) {
        *slash = 0;
        mkdir(dir, 0755);
    }
    FILE *file = fopen(path, "w");
    if (!file) return;
    fputs(text, file);
    fflush(file);
    fclose(file);
}

__attribute__((constructor(101)))
static void IXLaunchGuardRecord(void) {
    char path[1024];
    if (!IXGuardPath(path, sizeof(path))) return;

    int previous = 0;
    int wasStarting = 0;
    FILE *file = fopen(path, "r");
    if (file) {
        char buf[64];
        if (fgets(buf, sizeof(buf), file)) {
            int n = 0;
            if (sscanf(buf, "starting %d", &n) == 1) {
                wasStarting = 1;
                previous = n;
            }
        }
        fclose(file);
    }

    int count = wasStarting ? previous + 1 : 1;
    if (count < 1) count = 1;
    ix_safe_mode = (wasStarting && count >= 2) ? 1 : 0;

    char text[32];
    snprintf(text, sizeof(text), "starting %d\n", count);
    IXGuardWrite(path, text);
    if (ix_safe_mode) {
        fprintf(stderr, "[InstagramX] safe mode: launch %d started before the previous one was ready\n", count);
    }
}

BOOL IXLaunchGuardIsSafeMode(void) {
    return ix_safe_mode != 0;
}

void IXLaunchGuardMarkReady(void) {
    char path[1024];
    if (!IXGuardPath(path, sizeof(path))) return;
    IXGuardWrite(path, "ready 0\n");
}
