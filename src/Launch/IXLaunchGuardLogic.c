#include "IXLaunchGuardLogic.h"

#include <string.h>

IXGuardState IXLaunchGuardParse(const char *text) {
    if (!text || !text[0]) return IX_GUARD_NONE;
    if (strncmp(text, "starting", 8) == 0) return IX_GUARD_STARTING;
    if (strncmp(text, "safe", 4) == 0) return IX_GUARD_SAFE;
    if (strncmp(text, "alive", 5) == 0) return IX_GUARD_ALIVE;
    // 2.2.3 wrote "clear" at the start of a safe launch. That is not a crash.
    if (strncmp(text, "clear", 5) == 0) return IX_GUARD_NONE;
    return IX_GUARD_NONE;
}

const char *IXLaunchGuardFormat(IXGuardState state) {
    if (state == IX_GUARD_STARTING) return "starting\n";
    if (state == IX_GUARD_SAFE) return "safe\n";
    return "alive\n";
}

IXGuardState IXLaunchGuardDecide(IXGuardState previous, int forceSafe) {
    if (forceSafe || previous == IX_GUARD_STARTING || previous == IX_GUARD_SAFE) return IX_GUARD_SAFE;
    return IX_GUARD_STARTING;
}
