#include <stdio.h>
#include <string.h>

#include "../src/Launch/IXSessionPersist.h"

static int g_failed = 0;

static void expect(int cond, const char *name) {
    if (cond) {
        printf("ok %s\n", name);
        return;
    }
    printf("FAIL %s\n", name);
    g_failed++;
}

static void expect_str(const char *got, const char *want, const char *name) {
    expect(got && want && strcmp(got, want) == 0, name);
    if (got && want && strcmp(got, want) != 0) printf("  got [%s] want [%s]\n", got, want);
}

int main(void) {
    char out[256];
    expect(IXSessionProbedGroup("TEAMID1234.com.burbn.instagram", out, sizeof out) == 1, "probe set");
    expect_str(out, "TEAMID1234.com.burbn.instagram", "probe value");
    expect(IXSessionProbedGroup("", out, sizeof out) == 0, "empty probe");
    expect_str(out, "", "empty probe clears");
    expect(IXSessionProbedGroup(NULL, out, sizeof out) == 0, "null probe");

    expect(IXSessionContainerComponent("group.com.burbn.instagram", out, sizeof out) == 1, "bare container");
    expect_str(out, "group.com.burbn.instagram", "bare container value");
    expect(IXSessionContainerComponent("TEAMID1234.group.com.burbn.instagram", out, sizeof out) == 1, "prefixed container");
    expect_str(out, "TEAMID1234.group.com.burbn.instagram", "prefix is not stripped");
    expect(IXSessionContainerComponent(NULL, out, sizeof out) == 1, "null container");
    expect_str(out, "group.com.burbn.instagram", "null container default");
    expect(IXSessionContainerComponent("a/b", out, sizeof out) == 0, "slash rejected");
    expect(IXSessionProbedGroup("x", out, 1) == 0, "short buffer");

    expect(IXPrefsSharedSuite("group.com.burbn.instagram", out, sizeof out) == 1, "ig suite");
    expect_str(out, "instagramx.appgroup", "ig suite value");
    expect(IXPrefsSharedSuite("group.com.burbn.instagram.773S3XDQX7", out, sizeof out) == 1, "ig team suite");
    expect_str(out, "instagramx.appgroup", "ig team shares one store");
    expect(IXPrefsSharedSuite("group.com.facebook.family", out, sizeof out) == 1, "family suite");
    expect_str(out, "instagramx.appgroup", "family shares the ig store");
    expect(IXPrefsSharedSuite("instagramx.appgroup", out, sizeof out) == 0, "mapped name does not remap");
    expect(IXPrefsSharedSuite("instagramx.vpn", out, sizeof out) == 0, "vpn suite left alone");
    expect(IXPrefsSharedSuite("com.burbn.instagram", out, sizeof out) == 0, "app domain left alone");
    expect(IXPrefsSharedSuite(NULL, out, sizeof out) == 0, "null suite");
    expect(IXPrefsSharedSuite("group.com.burbn.instagram", out, 4) == 0, "short suite buffer");
    return g_failed ? 1 : 0;
}
