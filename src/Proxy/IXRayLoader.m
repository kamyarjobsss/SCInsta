#import "IXRayLoader.h"
#import "IXTrafficGuard.h"

#import <dlfcn.h>
#import <stdlib.h>

#if IX_HAS_XRAY

static void *ix_ray_handle = NULL;
static char *(*ix_ray_start)(char *) = NULL;
static void (*ix_ray_stop)(void) = NULL;
static char *(*ix_ray_version)(void) = NULL;
static char *(*ix_ray_copy_log)(void) = NULL;
static void (*ix_ray_traffic)(uint64_t *, uint64_t *) = NULL;
static int (*ix_ray_probe_open)(char *) = NULL;
static void (*ix_ray_probe_close)(int) = NULL;
static char *(*ix_ray_prepare)(char *) = NULL;
static void (*ix_ray_prepare_abort)(void) = NULL;
static char *(*ix_ray_commit)(void) = NULL;

static NSError *IXRayError(NSString *message) {
    return [NSError errorWithDomain:@"InstagramX.Xray" code:1 userInfo:@{NSLocalizedDescriptionKey: message ?: @"Xray failed"}];
}

BOOL IXRayCoreLoad(NSError **error) {
    if (ix_ray_handle && ix_ray_start && ix_ray_stop) return YES;
    Dl_info info;
    if (!dladdr((const void *)IXRayCoreLoad, &info) || !info.dli_fname) {
        if (error) *error = IXRayError(@"Could not find the tweak directory.");
        return NO;
    }
    NSString *path = [[[NSString stringWithUTF8String:info.dli_fname] stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"IXRayCore.dylib"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        if (error) *error = IXRayError(@"IXRayCore.dylib is not in Frameworks.");
        return NO;
    }
    ix_ray_handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!ix_ray_handle) {
        const char *reason = dlerror();
        if (error) *error = IXRayError([NSString stringWithFormat:@"Could not load Xray: %s", reason ? reason : "dlopen failed"]);
        return NO;
    }
    ix_ray_start = dlsym(ix_ray_handle, "ixray_start");
    ix_ray_stop = dlsym(ix_ray_handle, "ixray_stop");
    ix_ray_version = dlsym(ix_ray_handle, "ixray_version");
    ix_ray_copy_log = dlsym(ix_ray_handle, "ixray_copy_log");
    ix_ray_traffic = dlsym(ix_ray_handle, "ixray_traffic");
    ix_ray_probe_open = dlsym(ix_ray_handle, "ixray_probe_open");
    ix_ray_probe_close = dlsym(ix_ray_handle, "ixray_probe_close");
    ix_ray_prepare = dlsym(ix_ray_handle, "ixray_prepare");
    ix_ray_prepare_abort = dlsym(ix_ray_handle, "ixray_prepare_abort");
    ix_ray_commit = dlsym(ix_ray_handle, "ixray_commit");
    if (!ix_ray_start || !ix_ray_stop) {
        dlclose(ix_ray_handle);
        ix_ray_handle = NULL;
        ix_ray_start = NULL;
        ix_ray_stop = NULL;
        ix_ray_version = NULL;
        if (error) *error = IXRayError(@"IXRayCore.dylib is missing its start and stop entry points.");
        return NO;
    }
    return YES;
}

char *IXRayStart(char *configJSON) {
    if (!ix_ray_start) return strdup("xray is not loaded");
    IXTrafficGuardSetThreadBypass(YES);
    char *result = ix_ray_start(configJSON);
    IXTrafficGuardSetThreadBypass(NO);
    return result;
}

void IXRayStop(void) {
    if (ix_ray_stop) ix_ray_stop();
}

char *IXRayVersion(void) {
    if (!ix_ray_version) return NULL;
    return ix_ray_version();
}

char *IXRayCopyLog(void) {
    if (!ix_ray_copy_log) return NULL;
    return ix_ray_copy_log();
}

void IXRayTraffic(uint64_t *uplink, uint64_t *downlink) {
    if (uplink) *uplink = 0;
    if (downlink) *downlink = 0;
    if (ix_ray_traffic) ix_ray_traffic(uplink, downlink);
}

int IXRayProbeOpen(char *configJSON) {
    if (!ix_ray_probe_open || !configJSON) return 0;
    IXTrafficGuardSetThreadBypass(YES);
    int probeID = ix_ray_probe_open(configJSON);
    IXTrafficGuardSetThreadBypass(NO);
    return probeID;
}

void IXRayProbeClose(int probeID) {
    if (probeID > 0 && ix_ray_probe_close) ix_ray_probe_close(probeID);
}

char *IXRayPrepare(char *configJSON) {
    if (!ix_ray_prepare) return strdup("xray probe entry points are missing");
    IXTrafficGuardSetThreadBypass(YES);
    char *result = ix_ray_prepare(configJSON);
    IXTrafficGuardSetThreadBypass(NO);
    return result;
}

void IXRayPrepareAbort(void) {
    if (ix_ray_prepare_abort) ix_ray_prepare_abort();
}

char *IXRayCommit(void) {
    if (!ix_ray_commit) return strdup("xray commit entry point is missing");
    return ix_ray_commit();
}

#else

BOOL IXRayCoreLoad(NSError **error) {
    if (error) *error = [NSError errorWithDomain:@"InstagramX.Xray" code:1 userInfo:@{NSLocalizedDescriptionKey: @"This build has no Xray core."}];
    return NO;
}

char *IXRayStart(char *configJSON) {
    (void)configJSON;
    return strdup("this build has no xray core");
}

void IXRayStop(void) {}

char *IXRayVersion(void) { return NULL; }

char *IXRayCopyLog(void) { return NULL; }

void IXRayTraffic(uint64_t *uplink, uint64_t *downlink) {
    if (uplink) *uplink = 0;
    if (downlink) *downlink = 0;
}

int IXRayProbeOpen(char *configJSON) {
    (void)configJSON;
    return 0;
}

void IXRayProbeClose(int probeID) { (void)probeID; }

char *IXRayPrepare(char *configJSON) {
    (void)configJSON;
    return strdup("this build has no xray core");
}

void IXRayPrepareAbort(void) {}

char *IXRayCommit(void) { return strdup("this build has no xray core"); }

#endif
