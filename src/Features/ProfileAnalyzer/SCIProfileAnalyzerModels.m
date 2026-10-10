#import "SCIProfileAnalyzerModels.h"
#import "IXFollowBack.h"

#pragma mark - User

static NSInteger SCIFollowsYouValue(id value) {
    if ([value isKindOfClass:[NSNumber class]]) return IXPAParseFollowedBy(1, [(NSNumber *)value longValue], NULL);
    if ([value isKindOfClass:[NSString class]]) return IXPAParseFollowedBy(0, 0, [(NSString *)value UTF8String]);
    return -1;
}

static NSInteger SCIFollowsYou(NSDictionary *d) {
    if (![d isKindOfClass:[NSDictionary class]]) return -1;
    NSDictionary *status = [d[@"friendship_status"] isKindOfClass:[NSDictionary class]] ? d[@"friendship_status"] : nil;
    NSArray *sources = status ? @[status, d] : @[d];
    for (NSDictionary *src in sources) {
        for (NSString *key in @[@"followed_by", @"followed_by_viewer", @"follows_viewer"]) {
            NSInteger parsed = SCIFollowsYouValue(src[key]);
            if (parsed >= 0) return parsed;
        }
    }
    return -1;
}

@implementation SCIProfileAnalyzerUser

+ (instancetype)userFromAPIDict:(NSDictionary *)d {
    id pkRaw = d[@"pk"] ?: d[@"pk_id"] ?: d[@"id"];
    NSString *pk = [pkRaw isKindOfClass:[NSString class]] ? pkRaw
                                                          : [pkRaw respondsToSelector:@selector(stringValue)] ? [pkRaw stringValue] : nil;
    if (!pk.length) return nil;

    SCIProfileAnalyzerUser *u = [self new];
    u.pk = pk;
    u.username = [d[@"username"] isKindOfClass:[NSString class]] ? d[@"username"] : @"";
    u.fullName = [d[@"full_name"] isKindOfClass:[NSString class]] ? d[@"full_name"] : nil;
    u.profilePicURL = [d[@"profile_pic_url"] isKindOfClass:[NSString class]] ? d[@"profile_pic_url"] : nil;
    id pid = d[@"profile_pic_id"];
    if ([pid isKindOfClass:[NSString class]]) u.profilePicID = pid;
    else if ([pid respondsToSelector:@selector(stringValue)]) u.profilePicID = [pid stringValue];
    u.isPrivate = [d[@"is_private"] boolValue];
    u.isVerified = [d[@"is_verified"] boolValue];
    // A false flag on the following list is one method, not a result.
    // It stays unknown until an exact follower search agrees.
    NSInteger parsed = SCIFollowsYou(d);
    u.followStatus = parsed > 0 ? 1 : -1;
    u.followSearch = -1;
    u.followsYou = IXPAClassify((int)u.followStatus, (int)u.followSearch);
    return u;
}

+ (instancetype)userFromJSONDict:(NSDictionary *)d {
    if (![d[@"pk"] isKindOfClass:[NSString class]]) return nil;
    SCIProfileAnalyzerUser *u = [self new];
    u.pk = d[@"pk"];
    u.username = d[@"username"] ?: @"";
    u.fullName = d[@"full_name"];
    u.profilePicURL = d[@"profile_pic_url"];
    u.profilePicID = d[@"profile_pic_id"];
    u.isPrivate = [d[@"is_private"] boolValue];
    u.isVerified = [d[@"is_verified"] boolValue];
    BOOL hasEvidence = d[@"follow_status"] != nil || d[@"follow_search"] != nil;
    if (hasEvidence) {
        u.followStatus = d[@"follow_status"] == nil ? -1 : [d[@"follow_status"] integerValue];
        u.followSearch = d[@"follow_search"] == nil ? -1 : [d[@"follow_search"] integerValue];
    } else {
        // Older saves treated a single no as final. Those rows are checked again.
        NSInteger old = d[@"follows_you"] == nil ? -1 : [d[@"follows_you"] integerValue];
        u.followStatus = old > 0 ? 1 : -1;
        u.followSearch = -1;
    }
    u.followsYou = IXPAClassify((int)u.followStatus, (int)u.followSearch);
    return u;
}

- (NSDictionary *)toJSONDict {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"pk"] = self.pk ?: @"";
    d[@"username"] = self.username ?: @"";
    if (self.fullName) d[@"full_name"] = self.fullName;
    if (self.profilePicURL) d[@"profile_pic_url"] = self.profilePicURL;
    if (self.profilePicID)  d[@"profile_pic_id"]  = self.profilePicID;
    d[@"is_private"] = @(self.isPrivate);
    d[@"is_verified"] = @(self.isVerified);
    d[@"follow_status"] = @(self.followStatus);
    d[@"follow_search"] = @(self.followSearch);
    d[@"follows_you"] = @(self.followsYou);
    return d;
}

- (id)copyWithZone:(NSZone *)zone {
    SCIProfileAnalyzerUser *u = [SCIProfileAnalyzerUser new];
    u.pk = self.pk;
    u.username = self.username;
    u.fullName = self.fullName;
    u.profilePicURL = self.profilePicURL;
    u.profilePicID = self.profilePicID;
    u.isPrivate = self.isPrivate;
    u.isVerified = self.isVerified;
    u.followStatus = self.followStatus;
    u.followSearch = self.followSearch;
    u.followsYou = self.followsYou;
    return u;
}

- (NSUInteger)hash { return self.pk.hash; }
- (BOOL)isEqual:(id)other {
    if (![other isKindOfClass:[SCIProfileAnalyzerUser class]]) return NO;
    return [self.pk isEqualToString:((SCIProfileAnalyzerUser *)other).pk];
}

@end

#pragma mark - Snapshot

@implementation SCIProfileAnalyzerSnapshot

+ (instancetype)snapshotFromJSONDict:(NSDictionary *)d {
    if (!d[@"self_pk"]) return nil;
    SCIProfileAnalyzerSnapshot *s = [self new];
    s.scanDate = [NSDate dateWithTimeIntervalSince1970:[d[@"scan_date"] doubleValue]];
    s.selfPK = d[@"self_pk"];
    s.selfUsername = d[@"self_username"];
    s.selfFullName = d[@"self_full_name"];
    s.selfProfilePicURL = d[@"self_profile_pic_url"];
    s.followerCount = [d[@"follower_count"] integerValue];
    s.followingCount = [d[@"following_count"] integerValue];
    s.mediaCount = [d[@"media_count"] integerValue];

    s.followers = @[];

    NSMutableArray *g = [NSMutableArray array];
    for (id item in d[@"following"]) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        SCIProfileAnalyzerUser *user = [SCIProfileAnalyzerUser userFromJSONDict:item];
        if (user) [g addObject:user];
    }
    s.following = g;
    return s;
}

- (NSDictionary *)toJSONDict {
    NSMutableArray *g = [NSMutableArray arrayWithCapacity:self.following.count];
    for (SCIProfileAnalyzerUser *u in self.following) [g addObject:[u toJSONDict]];

    return @{
        @"scan_date": @([self.scanDate timeIntervalSince1970]),
        @"self_pk": self.selfPK ?: @"",
        @"self_username": self.selfUsername ?: @"",
        @"self_full_name": self.selfFullName ?: @"",
        @"self_profile_pic_url": self.selfProfilePicURL ?: @"",
        @"follower_count": @(self.followerCount),
        @"following_count": @(self.followingCount),
        @"media_count": @(self.mediaCount),
        @"followers": @[],
        @"following": g,
    };
}

@end

#pragma mark - Profile change

@implementation SCIProfileAnalyzerProfileChange
- (BOOL)usernameChanged  { return ![self.previous.username isEqualToString:self.current.username]; }
- (BOOL)fullNameChanged  { return ![(self.previous.fullName ?: @"") isEqualToString:(self.current.fullName ?: @"")]; }
// Compare profile_pic_id (stable per pic; changes only on upload). URL
// diffing was unusable — IG rotates the CDN host + path hash per request.
// Skip when either side is missing the id (old snapshots pre-feature).
- (BOOL)profilePicChanged {
    NSString *a = self.previous.profilePicID;
    NSString *b = self.current.profilePicID;
    if (!a.length || !b.length) return NO;
    return ![a isEqualToString:b];
}
@end

#pragma mark - Report

@implementation SCIProfileAnalyzerReport

+ (SCIProfileAnalyzerReport *)reportFromCurrent:(SCIProfileAnalyzerSnapshot *)current
                                        previous:(SCIProfileAnalyzerSnapshot *)previous {
    SCIProfileAnalyzerReport *r = [self new];
    r.current = current;
    r.previous = previous;
    r.mutualFollowers = @[];
    r.notFollowingYouBack = @[];
    r.youDontFollowBack = @[];
    r.recentFollowers = @[];
    r.lostFollowers = @[];
    r.youStartedFollowing = @[];
    r.youUnfollowed = @[];
    r.profileUpdates = @[];
    (void)previous;
    if (!current) return r;

    NSMutableArray *mutual = [NSMutableArray array];
    NSMutableArray *notBack = [NSMutableArray array];
    for (SCIProfileAnalyzerUser *user in current.following) {
        if (user.followsYou > 0) [mutual addObject:user];
        else if (user.followsYou == 0) [notBack addObject:user];
    }
    r.mutualFollowers = mutual;
    r.notFollowingYouBack = notBack;
    return r;
}

@end
