#include <stdio.h>
#include <string.h>

#include "../src/Launch/IXKeychainGroup.h"

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
    char prefix[11];
    expect(IXKeychainTeamPrefix("ABCDE12345.com.burbn.instagram", prefix) == 1, "prefix ok");
    expect_str(prefix, "ABCDE12345", "prefix value");
    expect(IXKeychainTeamPrefix("group.com.burbn.instagram", prefix) == 0, "bare group is not a team id");
    expect(IXKeychainTeamPrefix("SHORT.com.burbn.instagram", prefix) == 0, "short prefix rejected");

    char bare[128];
    expect(IXKeychainStripTeamPrefix("ABCDE12345.group.com.burbn.instagram", bare, sizeof bare) == 1, "strip");
    expect_str(bare, "group.com.burbn.instagram", "stripped bare");
    expect(IXKeychainStripTeamPrefix("group.com.burbn.instagram", bare, sizeof bare) == 1, "strip bare");
    expect_str(bare, "group.com.burbn.instagram", "bare unchanged");

    const char *appOnly[] = {"ABCDE12345.com.burbn.instagram"};
    char out[256];
    expect(IXKeychainCanonicalGroup("ABCDE12345.com.burbn.instagram",
                                    "group.com.burbn.instagram",
                                    appOnly, 1, out, sizeof out) == 1,
           "bare maps");
    expect_str(out, "ABCDE12345.com.burbn.instagram", "bare uses application-identifier");

    expect(IXKeychainCanonicalGroup("ABCDE12345.com.burbn.instagram",
                                    "ABCDE12345.com.burbn.instagram",
                                    appOnly, 1, out, sizeof out) == 1,
           "entitled kept");
    expect_str(out, "ABCDE12345.com.burbn.instagram", "entitled unchanged");

    const char *wild[] = {"ABCDE12345.*"};
    expect(IXKeychainCanonicalGroup("ABCDE12345.com.burbn.instagram",
                                    "group.com.burbn.instagram",
                                    wild, 1, out, sizeof out) == 1,
           "wildcard maps");
    expect_str(out, "ABCDE12345.group.com.burbn.instagram", "wildcard prefixed group");

    expect(IXKeychainCanonicalGroup("ABCDE12345.com.burbn.instagram",
                                    "ZZZZZZZZZZ.group.com.burbn.instagram",
                                    wild, 1, out, sizeof out) == 1,
           "stale canonical");
    expect_str(out, "ABCDE12345.group.com.burbn.instagram", "stale prefix replaced");

    expect(IXKeychainCanonicalGroup("ABCDE12345.com.burbn.instagram",
                                    "ZZZZZZZZZZ.group.com.burbn.instagram",
                                    appOnly, 1, out, sizeof out) == 1,
           "stale falls back");
    expect_str(out, "ABCDE12345.com.burbn.instagram", "stale uses application-identifier");

    const char *star[] = {"*"};
    expect(IXKeychainCanonicalGroup("ABCDE12345.com.burbn.instagram",
                                    "group.com.burbn.instagram",
                                    star, 1, out, sizeof out) == 1,
           "star keeps");
    expect_str(out, "group.com.burbn.instagram", "star leaves bare group");

    expect(IXKeychainCanonicalGroup("ABCDE12345.com.burbn.instagram",
                                    "group.com.burbn.instagram",
                                    NULL, 0, out, sizeof out) == 1,
           "unknown entitlements");
    expect_str(out, "group.com.burbn.instagram", "unknown entitlements keep requested");

    expect(IXKeychainStalePrefixedGroup("ABCDE12345.com.burbn.instagram",
                                        "group.com.burbn.instagram",
                                        wild, 1, out, sizeof out) == 0,
           "bare identifier is not rewritten");
    expect(IXKeychainStalePrefixedGroup("ABCDE12345.com.burbn.instagram",
                                        "ABCDE12345.group.com.burbn.instagram",
                                        wild, 1, out, sizeof out) == 0,
           "current prefix is not rewritten");
    expect(IXKeychainStalePrefixedGroup("ABCDE12345.com.burbn.instagram",
                                        "ZZZZZZZZZZ.group.com.burbn.instagram",
                                        wild, 1, out, sizeof out) == 1,
           "stale identifier rewrites");
    expect_str(out, "ABCDE12345.group.com.burbn.instagram", "stale identifier value");
    expect(IXKeychainStalePrefixedGroup("ABCDE12345.com.burbn.instagram",
                                        "ZZZZZZZZZZ.group.com.burbn.instagram",
                                        appOnly, 1, out, sizeof out) == 0,
           "stale identifier stays when prefixed group is not entitled");

    if (g_failed) {
        printf("%d failed\n", g_failed);
        return 1;
    }
    printf("all ok\n");
    return 0;
}
