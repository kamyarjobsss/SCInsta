#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "../src/Launch/IXSessionLaunch.h"
#include "../src/Launch/IXSessionPersist.h"

static void mkdir_p(const char *path) {
    char buf[1024];
    size_t n = strlen(path);
    char *slash;
    if (n == 0 || n >= sizeof buf) _exit(96);
    memcpy(buf, path, n + 1);
    for (slash = buf + 1; *slash; slash++) {
        if (*slash != '/') continue;
        *slash = 0;
        mkdir(buf, 0755);
        *slash = '/';
    }
    mkdir(buf, 0755);
}

static void write_kept(const char *path) {
    char dir[1024];
    char *slash;
    FILE *file;
    memcpy(dir, path, strlen(path) + 1);
    slash = strrchr(dir, '/');
    if (!slash) _exit(89);
    *slash = 0;
    mkdir_p(dir);
    file = fopen(path, "w");
    if (!file) _exit(88);
    if (fputs("kept\n", file) < 0) _exit(87);
    if (fclose(file) != 0) _exit(86);
}

static void write_suite(const char *docs, const char *suite) {
    char path[1024];
    char dir[1024];
    char *slash;
    FILE *file;
    if (!IXSessionSuitePlist(docs, suite, path, sizeof path)) _exit(95);
    memcpy(dir, path, strlen(path) + 1);
    slash = strrchr(dir, '/');
    if (!slash) _exit(94);
    *slash = 0;
    mkdir_p(dir);
    file = fopen(path, "w");
    if (!file) _exit(93);
    if (fputs("account=kept\n", file) < 0) _exit(92);
    if (fclose(file) != 0) _exit(91);
}

__attribute__((constructor))
static void ix_launch_inject(void) {
    const char *docs = getenv("IX_DOCS");
    if (!docs || !docs[0]) _exit(90);
    IXSessionLaunchReset();
    IXSessionLaunchNoteImage("/usr/lib/libSystem.B.dylib");
    if (IXSessionLaunchMayWalkClasses()) _exit(97);
    IXSessionLaunchNoteImage("Payload/Instagram.app/Frameworks/FBSharedFramework");
    if (!IXSessionLaunchMayWalkClasses()) _exit(98);
    write_suite(docs, "group.com.burbn.instagram");
    write_suite(docs, "group.com.facebook.family");
    {
        char group[128];
        char path[1024];
        if (!IXSessionStoredAccessGroup("group.com.facebook.family", "PROBEGROUP", group, sizeof group)) _exit(85);
        if (strcmp(group, "PROBEGROUP") != 0) _exit(84);
        if (!IXSessionAuthStorePath(docs, group, path, sizeof path)) _exit(83);
        write_kept(path);
        if (!IXSessionSharedSessionPath(docs, path, sizeof path)) _exit(82);
        write_kept(path);
        if (!IXSessionKeptDefaultsPath(docs, path, sizeof path)) _exit(81);
        write_kept(path);
        if (!IXSessionKeptDocumentPath(docs, path, sizeof path)) _exit(80);
        write_kept(path);
        if (!IXSessionInstallMarkerPath(docs, path, sizeof path)) _exit(79);
        write_kept(path);
    }
}
