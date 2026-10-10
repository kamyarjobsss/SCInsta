#include "../src/Launch/IXLaunchGuardLogic.h"

#include <stdio.h>
#include <string.h>

static int gFailures = 0;

static void expect(int ok, const char *message) {
    if (ok) return;
    gFailures++;
    fprintf(stderr, "FAIL: %s\n", message);
}

int main(void) {
    expect(IXLaunchGuardParse("starting\n") == IX_GUARD_STARTING, "parse starting");
    expect(IXLaunchGuardParse("safe\n") == IX_GUARD_SAFE, "parse safe");
    expect(IXLaunchGuardParse("alive\n") == IX_GUARD_ALIVE, "parse alive");
    expect(IXLaunchGuardParse("clear\n") == IX_GUARD_NONE, "clear is not a crash");
    expect(IXLaunchGuardParse(NULL) == IX_GUARD_NONE, "missing file");
    expect(IXLaunchGuardParse("") == IX_GUARD_NONE, "empty file");

    expect(IXLaunchGuardDecide(IX_GUARD_NONE, 0) == IX_GUARD_STARTING, "first launch arms the watchdog");
    expect(IXLaunchGuardDecide(IX_GUARD_ALIVE, 0) == IX_GUARD_STARTING, "a launch that lived is not sticky");
    expect(IXLaunchGuardDecide(IX_GUARD_STARTING, 0) == IX_GUARD_SAFE, "death before 5s persists safe mode");
    expect(IXLaunchGuardDecide(IX_GUARD_SAFE, 0) == IX_GUARD_SAFE, "safe mode stays until exit");
    expect(IXLaunchGuardDecide(IX_GUARD_ALIVE, 1) == IX_GUARD_SAFE, "manual bypass persists");

    expect(strcmp(IXLaunchGuardFormat(IX_GUARD_SAFE), "safe\n") == 0, "format safe");
    expect(strcmp(IXLaunchGuardFormat(IX_GUARD_STARTING), "starting\n") == 0, "format starting");
    expect(IXLaunchGuardParse(IXLaunchGuardFormat(IX_GUARD_SAFE)) == IX_GUARD_SAFE, "round trip safe");
    expect(IXLaunchGuardDecide(IXLaunchGuardParse("starting\n"), 0) == IX_GUARD_SAFE, "file left starting tripping the guard");

    if (gFailures) {
        fprintf(stderr, "%d launch-guard checks failed\n", gFailures);
        return 1;
    }
    printf("launch guard checks passed\n");
    return 0;
}
