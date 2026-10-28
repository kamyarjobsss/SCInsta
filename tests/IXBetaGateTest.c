#include <stdio.h>

#include "../src/Features/General/IXBetaGate.h"

static int g_failed;

static void expect(int cond, const char *name) {
    if (cond) {
        printf("ok %s\n", name);
        return;
    }
    printf("FAIL %s\n", name);
    g_failed++;
}

int main(void) {
    expect(IXBetaBlockerClassName("_TtC29IGCoreRootTestFlightNagPlugin35TestFlightUpdateNudgeViewController") == 1, "nudge vc");
    expect(IXBetaBlockerClassName("IGTestFlightUpdateNagController") == 1, "update nag");
    expect(IXBetaBlockerClassName("IGTestFlightNagController") == 1, "nag");
    expect(IXBetaBlockerClassName("_TtC23IGTestFlightVersionGate21IGTestFlightBuildGate") == 1, "build gate");
    expect(IXBetaBlockerClassName("_TtC23IGTestFlightVersionGate26IGTestFlightVersionChecker") == 1, "version checker");
    expect(IXBetaBlockerClassName("IGTestFlightRegistration.IGTFRegistrationMainViewController") == 0, "registration stays");
    expect(IXBetaBlockerClassName("IGUserSession") == 0, "session class");
    expect(IXBetaBlockerClassName(NULL) == 0, "null class");
    expect(IXBetaSandboxReceiptName("sandboxReceipt") == 1, "sandbox receipt");
    expect(IXBetaSandboxReceiptName("receipt") == 0, "app store receipt");
    expect(IXBetaSandboxReceiptName(NULL) == 0, "null receipt");
    return g_failed ? 1 : 0;
}
