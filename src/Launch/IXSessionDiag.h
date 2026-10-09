#import <Foundation/Foundation.h>

// Append-only launch log. Lines never include account names, tokens,
// passwords, or keychain item data. The file lives under Documents so a
// cache clear does not erase the next report.
void IXSessionDiagLine(NSString *line);
void IXSessionDiagContext(NSString *containerPath, NSString *probedGroup, int probeStatus, unsigned long entitledCount);
void IXSessionDiagKeychain(const char *op, int status, NSString *group, int callerSuppliedGroup);
void IXSessionDiagAccounts(NSString *phase);
void IXSessionDiagNoteContainer(NSString *path, NSString *source);
void IXSessionDiagBoot(void);
// Replay fresh-install markers before Instagram reads them.
void IXPrefsSeedFreshMarkers(void);
// didFinishLaunching has returned. Password deletes are allowed after this.
void IXSessionLaunchFinished(void);
NSString *IXSessionDiagReport(void);
void IXSessionDiagPresentCopy(void);
