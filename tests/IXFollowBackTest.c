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

    expect(IXPAClassify(1, -1) == 1, "status yes is mutual");
    expect(IXPAClassify(-1, 1) == 1, "search yes is mutual");
    expect(IXPAClassify(1, 0) == 1, "yes wins over no");
    expect(IXPAClassify(0, 0) == 0, "both no is not following");
    expect(IXPAClassify(0, -1) == -1, "one no stays unknown");
    expect(IXPAClassify(-1, 0) == -1, "search no alone stays unknown");
    expect(IXPAClassify(-1, -1) == -1, "both unknown");
    expect(IXPAClassify(0, 1) == 1, "search corrects a false status");

    expect(IXPASearchVerdict(1, 0, 1) == 1, "exact match wins");
    expect(IXPASearchVerdict(0, 1, 0) == 0, "complete page miss is no");
    expect(IXPASearchVerdict(0, 1, 1) == -1, "more pages is not a no");
    expect(IXPASearchVerdict(0, 0, 0) == -1, "invalid page is unknown");

    expect(IXPASameAccount("OldName", "42", "newname", "42") == 1, "rename matches pk");
    expect(IXPASameAccount("Kami", NULL, "kami", NULL) == 1, "username case");
    expect(IXPASameAccount("kami", "1", "kami2", "2") == 0, "prefix is a different account");
    expect(IXPASameAccount("kami", "", "kami", "") == 1, "empty pk uses the name");
    expect(IXPASameAccount(NULL, NULL, "kami", "1") == 0, "missing query");

    expect(IXPANextCheck(-1, -1, 0, 0) == 1, "unchecked asks followed_by");
    expect(IXPANextCheck(0, -1, 0, 0) == 2, "suspected no asks search");
    expect(IXPANextCheck(-1, -1, 1, 0) == 2, "missed bulk asks search");
    expect(IXPANextCheck(-1, 0, 1, 1) == 3, "search no asks one show");
    expect(IXPANextCheck(0, 0, 1, 1) == 0, "confirmed no stops");
    expect(IXPANextCheck(1, -1, 0, 0) == 0, "confirmed yes stops");
    expect(IXPANextCheck(0, -1, 1, 1) == 0, "incomplete search is not listed");
    expect(IXPANextCheck(-1, -1, 2, 1) == 0, "exhausted checks stay unknown");

    return g_failed ? 1 : 0;
}
