#import <Foundation/Foundation.h>

// Records who removes the session at launch, whether device-id hashes stay
// the same, and the first Instagram HTTP status. SecItem add, copy, update,
// and delete are rewritten onto the access group SecItem assigned to the
// sideload probe item. Deletes are not blocked. Values, tokens, and raw ids
// are not logged.
void IXSessionWatchArm(void);
void IXSessionWatchSnapshot(NSString *phase);

NSArray<NSString *> *IXSessionSavedUsernames(void);
void IXSessionSaveUsernames(NSArray<NSString *> *names);
void IXSessionClearUsernames(void);
int IXSessionCookiePresent(void);
int IXSessionWithinRestoreWindow(void);
