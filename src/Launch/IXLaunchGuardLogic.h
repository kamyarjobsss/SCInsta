#ifndef IXLAUNCHGUARDLOGIC_H
#define IXLAUNCHGUARDLOGIC_H

// Persisted watchdog. "starting" means the process has not yet survived 5s.
// Dying in that window makes the next launch "safe" and stays there until
// the user exits. "alive" is a launch that did survive.
typedef enum {
    IX_GUARD_NONE = 0,
    IX_GUARD_STARTING = 1,
    IX_GUARD_ALIVE = 2,
    IX_GUARD_SAFE = 3
} IXGuardState;

IXGuardState IXLaunchGuardParse(const char *text);
const char *IXLaunchGuardFormat(IXGuardState state);
IXGuardState IXLaunchGuardDecide(IXGuardState previous, int forceSafe);

#endif
