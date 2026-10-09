#include "IXFollowBack.h"

#include <ctype.h>
#include <string.h>

IXPAStep IXPANextStep(int user_count, int next_len, int unknown_count) {
    if (user_count < 0) user_count = 0;
    if (next_len < 0) next_len = 0;
    if (unknown_count < 0) unknown_count = 0;
    if (next_len > 0) return IXPA_STEP_PAGE;
    if (user_count > 0 && unknown_count > 0) return IXPA_STEP_RESOLVE;
    if (user_count > 0) return IXPA_STEP_FINISH;
    return IXPA_STEP_PAGE;
}

static int ix_word(const char *text, const char *word) {
    size_t n = strlen(word);
    size_t i;
    if (!text) return 0;
    for (i = 0; i < n; i++) {
        if (tolower((unsigned char)text[i]) != (unsigned char)word[i]) return 0;
    }
    return text[n] == '\0';
}

int IXPAParseFollowedBy(int has_number, long number, const char *text) {
    if (has_number) return number ? 1 : 0;
    if (!text || !text[0]) return -1;
    if (ix_word(text, "true") || ix_word(text, "yes") || ix_word(text, "1")) return 1;
    if (ix_word(text, "false") || ix_word(text, "no") || ix_word(text, "0")) return 0;
    return -1;
}

int IXPAUsernameExact(const char *query, const char *name) {
    size_t i;
    if (!query || !name || !query[0] || !name[0]) return 0;
    for (i = 0;; i++) {
        unsigned char a = (unsigned char)query[i];
        unsigned char b = (unsigned char)name[i];
        if (tolower(a) != tolower(b)) return 0;
        if (a == 0) return 1;
    }
}
