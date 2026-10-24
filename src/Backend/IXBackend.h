#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Shown when every server VPN config fails the connect test. Do not enable the VPN.
extern NSString *const IXBackendVPNUnavailableMessage;
extern NSString *const IXBackendConfigDidChangeNotification;

void IXBackendStart(void);
void IXBackendHeartbeat(NSString * _Nullable reason);
void IXBackendPostEvent(NSString *name, NSDictionary * _Nullable props);
void IXBackendSetVPNLabel(NSString * _Nullable label);

NSArray<NSDictionary *> *IXBackendAnnouncements(void);
void IXBackendDismissAnnouncement(NSInteger announcementID);
NSArray<NSDictionary *> *IXBackendFontFaces(void);
NSDictionary *IXBackendStickerCatalog(void);
/// Decrypted server links. Memory only. Keys: id, label, protocol, link, order.
NSArray<NSDictionary *> *IXBackendVPNItems(void);

extern NSString *const IXBackendStatusDidChangeNotification;
NSDictionary *IXBackendPanelStatus(void);
NSString *IXBackendPanelReport(void);
void IXBackendRetryNow(void);
UIViewController *IXBackendPanelController(void);

NS_ASSUME_NONNULL_END
