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

/* Combine followed_by (`status`) with an exact follower search.
   1 follows you, 0 does not, -1 unknown.
   A yes from either method wins, including after a rename.
   A no is listed only when both methods say no.
   One no, or any unknown, stays unknown and must not be listed. */
int IXPAClassify(int status, int search);

/* exact: this page contains the same account.
   page_valid: the body is a real user list with status ok.
   has_more: a later page might still contain the account.
   A match is yes. A complete valid page with no match is no.
   An invalid or incomplete page is unknown, never a no. */
int IXPASearchVerdict(int exact, int page_valid, int has_more);

/* 1 when the pks match, or the usernames match ignoring ASCII case.
   A renamed account still matches on pk. A prefix does not match. */
int IXPASameAccount(const char *query_name, const char *query_pk, const char *name, const char *pk);

/* Next request. 0 stop, 1 bulk followed_by, 2 follower search,
   3 one-account followed_by.
   status_attempts: 0 none, 1 bulk already asked, 2 individual show already asked.
   search_attempts: 0 none, 1 search already finished, including an incomplete page. */
int IXPANextCheck(int status, int search, int status_attempts, int search_attempts);

#endif
