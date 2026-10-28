#import <Foundation/Foundation.h>
#import <stdint.h>

/* Clang 11's iOS toolchain does not emit this compiler helper. A newer
   Apple clang provides a strong copy; this one stays out of the way. */
__attribute__((weak))
int32_t __isOSVersionAtLeast(int32_t major, int32_t minor, int32_t subminor) {
    NSOperatingSystemVersion version = [[NSProcessInfo processInfo] operatingSystemVersion];
    if (version.majorVersion != major) return version.majorVersion > major;
    if (version.minorVersion != minor) return version.minorVersion > minor;
    return version.patchVersion >= subminor;
}
