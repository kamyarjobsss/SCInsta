#import "IXLaunchGuard.h"

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
static pthread_mutex_t ix_log_mu = PTHREAD_MUTEX_INITIALIZER;

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

void IXLaunchGuardRecord(void) {
    char path[1024];
    if (!IXHomePath(path, sizeof(path), "ix_launch_guard")) return;

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

    int bypass = 0;
    char bpath[1024];
    if (IXHomePath(bpath, sizeof(bpath), "ix_launch_bypass") && access(bpath, F_OK) == 0) {
        bypass = 1;
        unlink(bpath);
    }

    int count = wasStarting ? previous + 1 : 1;
    if (count < 1) count = 1;
    ix_safe_mode = (wasStarting || bypass) ? 1 : 0;

    char text[32];
    snprintf(text, sizeof(text), "starting %d\n", count);
    IXGuardWrite(path, text);
    if (ix_safe_mode) {
        fprintf(stderr, "[InstagramX] safe mode: previous launch did not reach the feed\n");
        IXLaunchGuardAppendLog("safe mode: VPN hooks stay off so the log can be opened");
    }
}

BOOL IXLaunchGuardIsSafeMode(void) {
    return ix_safe_mode != 0;
}

BOOL IXLaunchGuardFeedShown(void) {
    return ix_feed_shown != 0;
}

void IXLaunchGuardMarkReady(void) {
    ix_feed_shown = 1;
    if (ix_marked) return;
    ix_marked = 1;
    char path[1024];
    if (IXHomePath(path, sizeof(path), "ix_launch_guard")) IXGuardWrite(path, "ready 0\n");
    char bpath[1024];
    if (IXHomePath(bpath, sizeof(bpath), "ix_launch_bypass")) unlink(bpath);
    IXLaunchGuardAppendLog("feed visible, launch marked ready");
}

void IXLaunchGuardEngageBypass(void) {
    if (ix_feed_shown) return;
    ix_safe_mode = 1;
    char bpath[1024];
    if (IXHomePath(bpath, sizeof(bpath), "ix_launch_bypass")) IXGuardWrite(bpath, "bypass\n");
    IXLaunchGuardAppendLog("manual bypass: finger held on the splash, VPN hooks off");
    fprintf(stderr, "[InstagramX] manual bypass\n");
}
