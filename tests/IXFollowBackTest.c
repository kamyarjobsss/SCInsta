#include <stdio.h>

#include "../src/Features/ProfileAnalyzer/IXFollowBack.h"

static int g_failed = 0;

static void expect(int cond, const char *name) {
    if (cond) {
        printf("ok %s\n", name);
        return;
    }
    printf("FAIL %s\n", name);
    g_failed++;
}

int main(void) {
    /* The v2.4.1 bug: a saved following list with an empty cursor and
       every follow-back still unknown was treated as finished. */
    expect(IXPANextStep(500, 0, 500) == IXPA_STEP_RESOLVE, "unchecked list resolves");
    expect(IXPANextStep(500, 0, 1) == IXPA_STEP_RESOLVE, "one unchecked still resolves");
    expect(IXPANextStep(500, 0, 0) == IXPA_STEP_FINISH, "fully checked finishes");
    expect(IXPANextStep(10, 4, 10) == IXPA_STEP_PAGE, "cursor keeps paging");
    expect(IXPANextStep(0, 0, 0) == IXPA_STEP_PAGE, "empty starts paging");
    expect(IXPANextStep(-1, -1, -1) == IXPA_STEP_PAGE, "negatives are safe");

    expect(IXPAParseFollowedBy(1, 1, NULL) == 1, "number yes");
    expect(IXPAParseFollowedBy(1, 0, NULL) == 0, "number no");
    expect(IXPAParseFollowedBy(1, 2, NULL) == 1, "nonzero yes");
    expect(IXPAParseFollowedBy(0, 0, "true") == 1, "string true");
    expect(IXPAParseFollowedBy(0, 0, "FALSE") == 0, "string false");
    expect(IXPAParseFollowedBy(0, 0, "1") == 1, "string one");
    expect(IXPAParseFollowedBy(0, 0, "0") == 0, "string zero");
    expect(IXPAParseFollowedBy(0, 0, "maybe") == -1, "unknown text");
    expect(IXPAParseFollowedBy(0, 0, "") == -1, "empty text");
    expect(IXPAParseFollowedBy(0, 0, NULL) == -1, "null text");

    expect(IXPAUsernameExact("kami", "kami") == 1, "exact");
    expect(IXPAUsernameExact("Kami", "kami") == 1, "case");
    expect(IXPAUsernameExact("kami", "kami2") == 0, "prefix is not exact");
    expect(IXPAUsernameExact("kami", "kam") == 0, "shorter is not exact");
    expect(IXPAUsernameExact("", "kami") == 0, "empty query");
    expect(IXPAUsernameExact("kami", NULL) == 0, "null name");
    expect(IXPAUsernameExact(NULL, NULL) == 0, "null both");

    return g_failed ? 1 : 0;
}
