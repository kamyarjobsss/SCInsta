#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Lightweight user record — what we cache per follower/following entry.
@interface SCIProfileAnalyzerUser : NSObject <NSCopying>

@property (nonatomic, copy) NSString *pk;
@property (nonatomic, copy) NSString *username;
@property (nonatomic, copy, nullable) NSString *fullName;
@property (nonatomic, copy, nullable) NSString *profilePicURL;
// Stable IG-internal ID of the current profile picture — changes only when
// the user uploads a new one. Used for reliable change detection.
@property (nonatomic, copy, nullable) NSString *profilePicID;
@property (nonatomic, assign) BOOL isPrivate;
@property (nonatomic, assign) BOOL isVerified;
// 1 when this account follows the viewer, 0 when it does not, -1 when unknown.
// A 0 is stored only after followed_by and an exact follower search both say no.
@property (nonatomic, assign) NSInteger followsYou;
// Evidence behind followsYou. 1 yes, 0 no, -1 unknown.
@property (nonatomic, assign) NSInteger followStatus;
@property (nonatomic, assign) NSInteger followSearch;

+ (nullable instancetype)userFromAPIDict:(NSDictionary *)dict;
+ (nullable instancetype)userFromJSONDict:(NSDictionary *)dict;
- (NSDictionary *)toJSONDict;

@end

// One saved following list plus the profile header. Followers are never stored.
@interface SCIProfileAnalyzerSnapshot : NSObject

@property (nonatomic, strong) NSDate *scanDate;
@property (nonatomic, copy) NSString *selfPK;
@property (nonatomic, copy, nullable) NSString *selfUsername;
@property (nonatomic, copy, nullable) NSString *selfFullName;
@property (nonatomic, copy, nullable) NSString *selfProfilePicURL;
@property (nonatomic, assign) NSInteger followerCount;
@property (nonatomic, assign) NSInteger followingCount;
@property (nonatomic, assign) NSInteger mediaCount;
@property (nonatomic, copy) NSArray<SCIProfileAnalyzerUser *> *followers;
@property (nonatomic, copy) NSArray<SCIProfileAnalyzerUser *> *following;

+ (nullable instancetype)snapshotFromJSONDict:(NSDictionary *)dict;
- (NSDictionary *)toJSONDict;

@end

// Per-profile change entry (username/fullName/pic edited since last scan).
@interface SCIProfileAnalyzerProfileChange : NSObject
@property (nonatomic, strong) SCIProfileAnalyzerUser *previous;
@property (nonatomic, strong) SCIProfileAnalyzerUser *current;
@property (nonatomic, readonly) BOOL usernameChanged;
@property (nonatomic, readonly) BOOL fullNameChanged;
@property (nonatomic, readonly) BOOL profilePicChanged;
@end

// Mutuals and accounts that do not follow back, from the following list only.
@interface SCIProfileAnalyzerReport : NSObject

@property (nonatomic, strong, nullable) SCIProfileAnalyzerSnapshot *current;
@property (nonatomic, strong, nullable) SCIProfileAnalyzerSnapshot *previous;

@property (nonatomic, copy) NSArray<SCIProfileAnalyzerUser *> *mutualFollowers;
@property (nonatomic, copy) NSArray<SCIProfileAnalyzerUser *> *notFollowingYouBack;
@property (nonatomic, copy) NSArray<SCIProfileAnalyzerUser *> *youDontFollowBack;
// `new*` getters are reserved by ARC's Cocoa new-family rule, hence the name.
@property (nonatomic, copy) NSArray<SCIProfileAnalyzerUser *> *recentFollowers;
@property (nonatomic, copy) NSArray<SCIProfileAnalyzerUser *> *lostFollowers;
@property (nonatomic, copy) NSArray<SCIProfileAnalyzerUser *> *youStartedFollowing;
@property (nonatomic, copy) NSArray<SCIProfileAnalyzerUser *> *youUnfollowed;
@property (nonatomic, copy) NSArray<SCIProfileAnalyzerProfileChange *> *profileUpdates;

+ (SCIProfileAnalyzerReport *)reportFromCurrent:(nullable SCIProfileAnalyzerSnapshot *)current
                                        previous:(nullable SCIProfileAnalyzerSnapshot *)previous;

@end

NS_ASSUME_NONNULL_END
