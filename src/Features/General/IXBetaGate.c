#include "IXBetaGate.h"

#include <string.h>

static int ix_has(const char *name, const char *needle) {
    return name && needle && strstr(name, needle) != NULL;
}

int IXBetaBlockerClassName(const char *name) {
    if (!name || !name[0]) return 0;
    /* Registration is an opt-in screen, not the expiry blocker. */
    if (ix_has(name, "IGTestFlightRegistration")) return 0;
    if (ix_has(name, "TestFlightUpdateNudge")) return 1;
    if (ix_has(name, "IGTestFlightUpdateNag")) return 1;
    if (ix_has(name, "IGTestFlightNagController")) return 1;
    if (ix_has(name, "IGTestFlightBuildGate")) return 1;
    if (ix_has(name, "IGTestFlightVersionChecker")) return 1;
    return 0;
}

int IXBetaSandboxReceiptName(const char *lastComponent) {
    return lastComponent && strcmp(lastComponent, "sandboxReceipt") == 0;
}
