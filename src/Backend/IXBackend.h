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
/// Marks the stable server id seen and keeps it on screen until dismiss.
void IXBackendNoteAnnouncementShown(NSString *announcementID);
void IXBackendDismissAnnouncementID(NSString *announcementID);
NSArray<NSDictionary *> *IXBackendFontFaces(void);
NSDictionary *IXBackendStickerCatalog(void);
/// Stable ids the signed config tells the story tray to omit.
NSSet<NSString *> *IXBackendHiddenStickerIDs(void);
/// Preferred order for the remaining default tray ids. Empty keeps Instagram's order.
NSArray<NSString *> *IXBackendStickerOrder(void);
/// POST /api/v1/stickers/defaults. Items are id, type, name, and an optional thumbnail.
void IXBackendReportStickerDefaults(NSArray<NSDictionary *> *items);
/// Decrypted server links. Memory only. Keys: id, label, protocol, link, order.
NSArray<NSDictionary *> *IXBackendVPNItems(void);

extern NSString *const IXBackendStatusDidChangeNotification;
NSDictionary *IXBackendPanelStatus(void);
NSString *IXBackendPanelReport(void);
void IXBackendRetryNow(void);
UIViewController *IXBackendPanelController(void);

NS_ASSUME_NONNULL_END
