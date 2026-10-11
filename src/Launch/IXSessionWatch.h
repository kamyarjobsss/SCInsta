#import <Foundation/Foundation.h>

// Records who removes the session at launch, whether device-id hashes stay
// the same, and the first Instagram HTTP status. Queries are not rewritten
// and deletes are not blocked. Values, tokens, and raw ids are not logged.
void IXSessionWatchArm(void);
void IXSessionWatchSnapshot(NSString *phase);

NSArray<NSString *> *IXSessionSavedUsernames(void);
void IXSessionSaveUsernames(NSArray<NSString *> *names);
void IXSessionClearUsernames(void);
int IXSessionCookiePresent(void);
int IXSessionWithinRestoreWindow(void);
