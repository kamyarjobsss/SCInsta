#import "IXLaunchGuard.h"
#import "IXLaunchGuardLogic.h"

#import <dispatch/dispatch.h>
#import <pthread.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <time.h>
#import <unistd.h>
#import <sys/stat.h>

static volatile int ix_safe_mode = 0;
static volatile int ix_feed_shown = 0;
static int ix_marked = 0;
static int64_t ix_record_ms = 0;
static pthread_mutex_t ix_log_mu = PTHREAD_MUTEX_INITIALIZER;

static int64_t IXMonoMs(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + (int64_t)ts.tv_nsec / 1000000;
}

static int IXHomePath(char *out, size_t outLen, const char *name) {
    const char *home = getenv("HOME");
    if (!home || !home[0] || !name) return 0;
    int n = snprintf(out, outLen, "%s/Library/Caches/%s", home, name);
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

static void IXTrimLog(const char *path) {
    struct stat st;
    if (stat(path, &st) != 0 || st.st_size <= 65536) return;
    FILE *file = fopen(path, "r");
    if (!file) return;
    long keep = 48000;
    if (fseek(file, -keep, SEEK_END) != 0) {
        fclose(file);
        return;
    }
    int ch = 0;
    while ((ch = fgetc(file)) != EOF && ch != '\n') {}
    char *buf = malloc((size_t)keep + 1);
    if (!buf) {
        fclose(file);
        return;
    }
    size_t n = fread(buf, 1, (size_t)keep, file);
    fclose(file);
    buf[n] = 0;
    IXGuardWrite(path, buf);
    free(buf);
}

void IXLaunchGuardAppendLog(const char *line) {
    if (!line || !line[0]) return;
    pthread_mutex_lock(&ix_log_mu);
    char path[1024];
    if (!IXHomePath(path, sizeof(path), "ix_vpn_log.txt")) {
        pthread_mutex_unlock(&ix_log_mu);
        return;
    }
    char dir[1024];
    strlcpy(dir, path, sizeof(dir));
    char *slash = strrchr(dir, '/');
    if (slash) {
        *slash = 0;
        mkdir(dir, 0755);
    }
    time_t now = time(NULL);
    struct tm tm;
    localtime_r(&now, &tm);
    char stamp[16];
    strftime(stamp, sizeof(stamp), "%H:%M:%S", &tm);
    FILE *file = fopen(path, "a");
    if (file) {
        fprintf(file, "%s %s\n", stamp, line);
        fclose(file);
        IXTrimLog(path);
    }
    pthread_mutex_unlock(&ix_log_mu);
}

NSString *IXLaunchGuardPersistedLog(void) {
    char path[1024];
    if (!IXHomePath(path, sizeof(path), "ix_vpn_log.txt")) return @"";
    NSString *text = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:path] encoding:NSUTF8StringEncoding error:nil];
    return text ?: @"";
}

static void IXWriteState(IXGuardState state) {
    char path[1024];
    if (!IXHomePath(path, sizeof(path), "ix_launch_guard")) return;
    IXGuardWrite(path, IXLaunchGuardFormat(state));
}

void IXLaunchGuardRecord(void) {
    char path[1024];
    char bpath[1024];
    int bypass = 0;
    if (IXHomePath(bpath, sizeof(bpath), "ix_launch_bypass") && access(bpath, F_OK) == 0) {
        bypass = 1;
        unlink(bpath);
    }
    ix_record_ms = IXMonoMs();
    ix_marked = 0;
    ix_feed_shown = 0;
    IXGuardState previous = IX_GUARD_NONE;
    if (IXHomePath(path, sizeof(path), "ix_launch_guard")) {
        FILE *file = fopen(path, "r");
        if (file) {
            char buf[64];
            if (fgets(buf, sizeof(buf), file)) previous = IXLaunchGuardParse(buf);
            fclose(file);
        }
    }
    IXGuardState next = IXLaunchGuardDecide(previous, bypass);
    ix_safe_mode = next == IX_GUARD_SAFE;
    IXWriteState(next);
    if (ix_safe_mode) {
        fprintf(stderr, "[InstagramX] safe mode: hooks stay off until Exit safe mode\n");
        IXLaunchGuardAppendLog("safe mode: previous launch died before 5s, hooks stay off");
    }
}

BOOL IXLaunchGuardIsSafeMode(void) {
    return ix_safe_mode != 0;
}

BOOL IXLaunchGuardFeedShown(void) {
    return ix_feed_shown != 0;
}

void IXLaunchGuardMarkReady(void) {
    if (ix_safe_mode) return;
    if (ix_record_ms == 0 || IXMonoMs() - ix_record_ms < 5000) return;
    ix_feed_shown = 1;
    if (ix_marked) return;
    ix_marked = 1;
    IXWriteState(IX_GUARD_ALIVE);
    IXLaunchGuardAppendLog("watchdog cleared after 5s");
}

void IXLaunchGuardEngageBypass(void) {
    if (ix_feed_shown) return;
    ix_safe_mode = 1;
    ix_marked = 0;
    IXWriteState(IX_GUARD_SAFE);
    IXLaunchGuardAppendLog("manual bypass: VPN hooks stay off until Exit safe mode");
    fprintf(stderr, "[InstagramX] manual bypass\n");
}

void IXLaunchGuardExitSafeMode(void) {
    ix_safe_mode = 0;
    ix_feed_shown = 0;
    ix_marked = 0;
    ix_record_ms = IXMonoMs();
    IXWriteState(IX_GUARD_STARTING);
    IXLaunchGuardAppendLog("safe mode exited");
    fprintf(stderr, "[InstagramX] safe mode exited\n");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        IXLaunchGuardMarkReady();
    });
}
