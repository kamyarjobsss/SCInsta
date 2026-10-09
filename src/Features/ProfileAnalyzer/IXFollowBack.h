#ifndef IX_FOLLOW_BACK_H
#define IX_FOLLOW_BACK_H

/* What to do with a saved following list.
   FINISH: every account already has a follow-back answer.
   PAGE: the following list itself is incomplete.
   RESOLVE: the list is complete and some accounts are still unchecked.
   A finished list with unchecked accounts must RESOLVE, never FINISH. */
typedef enum {
    IXPA_STEP_FINISH = 0,
    IXPA_STEP_PAGE = 1,
    IXPA_STEP_RESOLVE = 2
} IXPAStep;

IXPAStep IXPANextStep(int user_count, int next_len, int unknown_count);

/* 1 follows you, 0 does not, -1 unknown.
   has_number uses `number` (any non-zero is yes). Otherwise `text` is
   true/false/yes/no/1/0. Anything else stays unknown. */
int IXPAParseFollowedBy(int has_number, long number, const char *text);

/* Exact username match, ASCII case-insensitive. Prefixes do not match. */
int IXPAUsernameExact(const char *query, const char *name);

#endif
