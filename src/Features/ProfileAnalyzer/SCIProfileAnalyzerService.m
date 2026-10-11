#import "SCIProfileAnalyzerService.h"
#import "SCIProfileAnalyzerStorage.h"
#import "IXFollowBack.h"
#import <math.h>
#import <stdlib.h>
#import "../../Networking/SCIInstagramAPI.h"
#import "../../Utils.h"

#define SCI_PA_MAX_ATTEMPTS 6
#define SCI_PA_MAX_PAGES 10000
#define SCI_PA_SHOW_MANY 100
#define SCI_PA_SAVE_EVERY 10

@interface SCIProfileAnalyzerService ()
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, assign) BOOL isRunning;
@property (nonatomic, assign, readwrite, getter=isPaused) BOOL paused;
@property (nonatomic, assign) BOOL showManyDead;
@property (nonatomic, assign) NSInteger showManyLimit;
@property (nonatomic, assign) NSInteger searchFailures;
@property (nonatomic, assign) NSInteger checksSinceSave;
@property (nonatomic, copy) NSString *rankToken;
@property (nonatomic, strong) NSMutableSet<NSString *> *skippedPKs;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *statusAttempts;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *searchAttempts;
@property (nonatomic, copy) SCIPAIncremental incremental;
@property (nonatomic, strong, readwrite) SCIProfileAnalyzerSnapshot *liveSnapshot;
@end

@implementation SCIProfileAnalyzerService

+ (instancetype)sharedService {
    static SCIProfileAnalyzerService *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [self new]; });
    return s;
}

- (void)cancel { self.cancelled = YES; }
- (void)pause { if (self.isRunning) self.paused = YES; }
- (void)resume { self.paused = NO; }

- (void)finishWithSnapshot:(SCIProfileAnalyzerSnapshot *)s error:(NSError *)e completion:(SCIPACompletion)completion {
    self.isRunning = NO;
    self.cancelled = NO;
    self.paused = NO;
    self.liveSnapshot = s;
    self.incremental = nil;
    if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(s, e); });
}

- (NSError *)errorWithCode:(SCIProfileAnalyzerError)code message:(NSString *)msg {
    return [NSError errorWithDomain:@"SCIProfileAnalyzer" code:code
                           userInfo:@{ NSLocalizedDescriptionKey: msg ?: @"" }];
}

- (void)reportProgress:(SCIPAProgress)p status:(NSString *)s fraction:(double)f {
    if (!p) return;
    dispatch_async(dispatch_get_main_queue(), ^{ p(s, f); });
}

- (void)runForSelfWithHeaderInfo:(SCIPAHeaderInfo)headerInfo
                        progress:(SCIPAProgress)progress
                     incremental:(SCIPAIncremental)incremental
                      completion:(SCIPACompletion)completion {
    if (self.isRunning) {
        if (completion) completion(nil, [self errorWithCode:SCIProfileAnalyzerErrorCancelled
                                                    message:SCILocalized(@"Another analysis is already running")]);
        return;
    }
    self.isRunning = YES;
    self.cancelled = NO;
    self.paused = NO;
    self.showManyDead = NO;
    self.showManyLimit = SCI_PA_SHOW_MANY;
    self.searchFailures = 0;
    self.checksSinceSave = 0;
    self.skippedPKs = [NSMutableSet set];
    self.statusAttempts = [NSMutableDictionary dictionary];
    self.searchAttempts = [NSMutableDictionary dictionary];
    self.rankToken = [[NSUUID UUID] UUIDString];
    self.incremental = incremental;
    self.liveSnapshot = nil;

    NSString *selfPK = [SCIUtils currentUserPK];
    if (!selfPK.length) {
        [self finishWithSnapshot:nil
                           error:[self errorWithCode:SCIProfileAnalyzerErrorNoSession message:SCILocalized(@"No active Instagram session found")]
                      completion:completion];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [self reportProgress:progress status:SCILocalized(@"Fetching profile info…") fraction:0.02];
    [self requestPath:[NSString stringWithFormat:@"users/%@/info/", selfPK]
               method:@"GET"
                 body:nil
              attempt:0
             progress:progress
           completion:^(NSDictionary *resp, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.cancelled) {
            [strongSelf finishWithSnapshot:nil error:[strongSelf errorWithCode:SCIProfileAnalyzerErrorCancelled message:SCILocalized(@"Cancelled")]
                                completion:completion];
            return;
        }
        NSDictionary *user = [resp[@"user"] isKindOfClass:[NSDictionary class]] ? resp[@"user"] : nil;
        if (error || !user) {
            [strongSelf finishWithSnapshot:nil
                                     error:error ?: [strongSelf errorWithCode:SCIProfileAnalyzerErrorNetwork message:SCILocalized(@"Couldn't fetch profile information")]
                                completion:completion];
            return;
        }

        SCIProfileAnalyzerSnapshot *snap = [SCIProfileAnalyzerSnapshot new];
        snap.selfPK = selfPK;
        snap.selfUsername = [user[@"username"] isKindOfClass:[NSString class]] ? user[@"username"] : @"";
        snap.selfFullName = [user[@"full_name"] isKindOfClass:[NSString class]] ? user[@"full_name"] : nil;
        snap.selfProfilePicURL = [user[@"profile_pic_url"] isKindOfClass:[NSString class]] ? user[@"profile_pic_url"] : nil;
        snap.followerCount = [user[@"follower_count"] integerValue];
        snap.followingCount = [user[@"following_count"] integerValue];
        snap.mediaCount = [user[@"media_count"] integerValue];
        snap.scanDate = [NSDate date];
        snap.followers = @[];
        snap.following = @[];
        strongSelf.liveSnapshot = snap;
        if (headerInfo) dispatch_async(dispatch_get_main_queue(), ^{ headerInfo(user); });
        [strongSelf fetchFollowingForPK:selfPK snapshot:snap progress:progress completion:completion];
    }];
}

- (BOOL)challenged:(NSDictionary *)resp {
    if (![resp isKindOfClass:[NSDictionary class]]) return NO;
    if (resp[@"challenge"] || resp[@"checkpoint_url"]) return YES;
    NSString *message = [resp[@"message"] isKindOfClass:[NSString class]] ? resp[@"message"] : @"";
    NSString *errorType = [resp[@"error_type"] isKindOfClass:[NSString class]] ? resp[@"error_type"] : @"";
    return [message isEqualToString:@"challenge_required"]
        || [message isEqualToString:@"checkpoint_required"]
        || [errorType isEqualToString:@"challenge_required"]
        || [errorType isEqualToString:@"checkpoint_required"];
}

- (BOOL)rateLimited:(NSInteger)status body:(NSDictionary *)resp {
    if (status == 429) return YES;
    if ([self challenged:resp]) return YES;
    NSString *message = [resp[@"message"] isKindOfClass:[NSString class]] ? resp[@"message"] : @"";
    NSString *errorType = [resp[@"error_type"] isKindOfClass:[NSString class]] ? resp[@"error_type"] : @"";
    return [message isEqualToString:@"feedback_required"]
        || [message isEqualToString:@"rate_limit_error"]
        || [errorType isEqualToString:@"rate_limit_error"]
        || [errorType isEqualToString:@"feedback_required"];
}

- (void)requestPath:(NSString *)path
             method:(NSString *)method
               body:(NSDictionary *)body
            attempt:(NSInteger)attempt
           progress:(SCIPAProgress)progress
         completion:(void (^)(NSDictionary *resp, NSError *error))completion {
    if (self.cancelled) {
        completion(nil, [self errorWithCode:SCIProfileAnalyzerErrorCancelled message:SCILocalized(@"Cancelled")]);
        return;
    }
    if (self.paused) {
        __weak typeof(self) weakSelf = self;
        [self reportProgress:progress status:SCILocalized(@"Paused") fraction:-1];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf requestPath:path method:method body:body attempt:attempt progress:progress completion:completion];
        });
        return;
    }
    __weak typeof(self) weakSelf = self;
    [SCIInstagramAPI sendRequestWithMethod:method path:path body:body httpHandler:^(NSDictionary *response, NSError *error, NSInteger statusCode, NSTimeInterval retryAfter) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        @try {
            BOOL limited = [strongSelf rateLimited:statusCode body:response];
            if (!limited && !error) {
                completion(response, nil);
                return;
            }
            BOOL clientError = statusCode >= 400 && statusCode < 500 && !limited;
            if (strongSelf.cancelled || (clientError && attempt >= 1) || attempt + 1 >= SCI_PA_MAX_ATTEMPTS) {
                BOOL challenge = [strongSelf challenged:response];
                NSString *msg = challenge
                    ? SCILocalized(@"Instagram challenged the follow-back check. Showing the accounts already checked.")
                    : (limited
                        ? SCILocalized(@"Rate limited too many times. Run analysis again to resume.")
                        : (error.localizedDescription ?: SCILocalized(@"Couldn't check every follow-back. Showing the accounts already checked.")));
                SCIProfileAnalyzerError code = strongSelf.cancelled ? SCIProfileAnalyzerErrorCancelled
                    : (limited ? SCIProfileAnalyzerErrorRateLimited : SCIProfileAnalyzerErrorNetwork);
                completion(nil, [strongSelf errorWithCode:code message:msg]);
                return;
            }
            NSTimeInterval wait = retryAfter > 0 ? retryAfter : MIN(60.0, 2.0 * pow(2, attempt));
            [strongSelf reportProgress:progress status:SCILocalized(@"Waiting for Instagram rate limit…") fraction:-1];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [weakSelf requestPath:path method:method body:body attempt:attempt + 1 progress:progress completion:completion];
            });
        } @catch (__unused NSException *ex) {
            completion(nil, [strongSelf errorWithCode:SCIProfileAnalyzerErrorNetwork
                                              message:SCILocalized(@"Couldn't check every follow-back. Showing the accounts already checked.")]);
        }
    }];
}

- (NSArray *)jsonUsers:(NSArray<SCIProfileAnalyzerUser *> *)users {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:users.count];
    @autoreleasepool {
        for (SCIProfileAnalyzerUser *user in users) {
            if (user.pk.length) [out addObject:[user toJSONDict]];
        }
    }
    return out;
}

- (dispatch_queue_t)progressQueue {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("com.instagramx.analyzer.progress", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

- (void)saveProgressUsers:(NSArray<SCIProfileAnalyzerUser *> *)users next:(NSString *)next phase:(NSString *)phase pk:(NSString *)pk {
    if (!pk.length) return;
    NSArray *json = [self jsonUsers:users];
    NSDictionary *payload = @{ @"next_max_id": next ?: @"", @"phase": phase ?: @"following", @"users": json };
    dispatch_async([self progressQueue], ^{
        [SCIProfileAnalyzerStorage saveProgress:payload forUserPK:pk];
    });
}

- (void)clearProgress:(NSString *)pk {
    if (!pk.length) return;
    dispatch_async([self progressQueue], ^{
        [SCIProfileAnalyzerStorage clearProgressForUserPK:pk];
    });
}

- (NSDictionary<NSString *, NSNumber *> *)knownFollowsForPK:(NSString *)pk {
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    @try {
        SCIProfileAnalyzerSnapshot *cur = [SCIProfileAnalyzerStorage currentSnapshotForUserPK:pk];
        for (SCIProfileAnalyzerUser *user in cur.following) {
            if (user.pk.length && user.followsYou >= 0) map[user.pk] = @(user.followsYou);
        }
    } @catch (__unused NSException *e) {}
    return map;
}

- (NSInteger)unknownCount:(NSArray<SCIProfileAnalyzerUser *> *)users {
    NSInteger n = 0;
    for (SCIProfileAnalyzerUser *user in users) {
        if (user.followsYou < 0 && user.pk.length && ![self.skippedPKs containsObject:user.pk]) n++;
    }
    return n;
}

- (void)countsIn:(NSArray<SCIProfileAnalyzerUser *> *)users mutuals:(NSUInteger *)m notBack:(NSUInteger *)n checked:(NSUInteger *)c {
    NSUInteger mm = 0, nn = 0, cc = 0;
    for (SCIProfileAnalyzerUser *user in users) {
        if (user.followsYou > 0) { mm++; cc++; }
        else if (user.followsYou == 0) { nn++; cc++; }
    }
    if (m) *m = mm;
    if (n) *n = nn;
    if (c) *c = cc;
}

- (NSInteger)followsYouInRow:(NSDictionary *)row {
    if (![row isKindOfClass:[NSDictionary class]]) return -1;
    NSDictionary *nested = [row[@"friendship_status"] isKindOfClass:[NSDictionary class]] ? row[@"friendship_status"] : nil;
    NSArray *sources = nested ? @[row, nested] : @[row];
    for (NSDictionary *src in sources) {
        for (NSString *key in @[@"followed_by", @"followed_by_viewer", @"follows_viewer"]) {
            id value = src[key];
            int parsed = -1;
            if ([value isKindOfClass:[NSNumber class]]) parsed = IXPAParseFollowedBy(1, [(NSNumber *)value longValue], NULL);
            else if ([value isKindOfClass:[NSString class]]) parsed = IXPAParseFollowedBy(0, 0, [(NSString *)value UTF8String]);
            if (parsed >= 0) return parsed;
        }
    }
    return -1;
}

- (NSString *)pkString:(id)raw {
    if ([raw isKindOfClass:[NSString class]]) return raw;
    if ([raw respondsToSelector:@selector(stringValue)]) return [raw stringValue];
    return nil;
}

- (NSDictionary *)statusMapFromResponse:(NSDictionary *)resp {
    if (![resp isKindOfClass:[NSDictionary class]]) return @{};
    id raw = resp[@"friendship_statuses"] ?: resp[@"statuses"];
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    if ([raw isKindOfClass:[NSDictionary class]]) {
        for (id key in (NSDictionary *)raw) {
            id val = ((NSDictionary *)raw)[key];
            if (![val isKindOfClass:[NSDictionary class]]) continue;
            NSString *pk = [self pkString:key];
            if (!pk.length) pk = [self pkString:((NSDictionary *)val)[@"pk"] ?: ((NSDictionary *)val)[@"user_id"] ?: ((NSDictionary *)val)[@"id"]];
            if (pk.length) map[pk] = val;
        }
    } else if ([raw isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)raw) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSString *pk = [self pkString:item[@"pk"] ?: item[@"pk_id"] ?: item[@"user_id"] ?: item[@"id"]];
            if (pk.length) map[pk] = item;
        }
    }
    return map;
}

- (NSUInteger)applyStatusMap:(NSDictionary *)map toUsers:(NSArray<SCIProfileAnalyzerUser *> *)users {
    if (!map.count) return 0;
    NSUInteger applied = 0;
    for (SCIProfileAnalyzerUser *user in users) {
        if (!user.pk.length) continue;
        NSInteger value = [self followsYouInRow:map[user.pk]];
        if (value < 0) continue;
        [self noteStatus:value user:user];
        applied++;
    }
    return applied;
}

- (void)publishUsers:(NSArray<SCIProfileAnalyzerUser *> *)users
            snapshot:(SCIProfileAnalyzerSnapshot *)snap
            progress:(SCIPAProgress)progress
              status:(NSString *)status
            fraction:(double)fraction {
    @try {
        snap.following = [users copy] ?: @[];
        snap.scanDate = [NSDate date];
        self.liveSnapshot = snap;
        SCIPAIncremental block = self.incremental;
        if (block) dispatch_async(dispatch_get_main_queue(), ^{ block(snap); });
        if (status) [self reportProgress:progress status:status fraction:fraction];
    } @catch (__unused NSException *e) {}
}

- (NSString *)mutualStatusForUsers:(NSArray<SCIProfileAnalyzerUser *> *)users {
    NSUInteger mutuals = 0, notBack = 0, checked = 0;
    [self countsIn:users mutuals:&mutuals notBack:&notBack checked:&checked];
    return [NSString stringWithFormat:SCILocalized(@"%lu/%lu checked · %lu mutuals · %lu not following you back"),
            (unsigned long)checked, (unsigned long)users.count, (unsigned long)mutuals, (unsigned long)notBack];
}

- (double)mutualFractionForUsers:(NSArray<SCIProfileAnalyzerUser *> *)users {
    if (!users.count) return 0.35;
    NSUInteger checked = 0;
    [self countsIn:users mutuals:NULL notBack:NULL checked:&checked];
    return MIN(0.99, 0.35 + (double)checked / (double)users.count * 0.64);
}

- (void)persistIfNeeded:(NSArray<SCIProfileAnalyzerUser *> *)users pk:(NSString *)pk force:(BOOL)force {
    self.checksSinceSave++;
    if (!force && self.checksSinceSave < SCI_PA_SAVE_EVERY) return;
    self.checksSinceSave = 0;
    [self saveProgressUsers:users next:@"" phase:@"mutuals" pk:pk];
    @try {
        if (self.liveSnapshot) [SCIProfileAnalyzerStorage updateCurrentSnapshot:self.liveSnapshot forUserPK:pk];
    } @catch (__unused NSException *e) {}
}

- (void)afterGate:(void (^)(void))block progress:(SCIPAProgress)progress {
    if (self.cancelled) {
        if (block) block();
        return;
    }
    if (self.paused) {
        __weak typeof(self) weakSelf = self;
        [self reportProgress:progress status:SCILocalized(@"Paused") fraction:-1];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf afterGate:block progress:progress];
        });
        return;
    }
    uint32_t ms = 700u + arc4random_uniform(801u);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms * NSEC_PER_MSEC)), dispatch_get_main_queue(), block);
}

- (int)attemptsIn:(NSDictionary *)map pk:(NSString *)pk {
    if (!pk.length) return 0;
    return [map[pk] intValue];
}

- (void)setAttempt:(int)value in:(NSMutableDictionary *)map pk:(NSString *)pk {
    if (!pk.length || value < 0) return;
    int current = [map[pk] intValue];
    if (value > current) map[pk] = @(value);
}

- (void)reclassify:(SCIProfileAnalyzerUser *)user {
    user.followsYou = IXPAClassify((int)user.followStatus, (int)user.followSearch);
}

- (void)noteStatus:(NSInteger)value user:(SCIProfileAnalyzerUser *)user {
    if (value < 0 || !user) return;
    if (value > 0 || user.followStatus < 0) user.followStatus = value > 0 ? 1 : 0;
    [self reclassify:user];
}

- (void)noteSearch:(NSInteger)value user:(SCIProfileAnalyzerUser *)user {
    if (value < 0 || !user) return;
    if (value > 0 || user.followSearch < 0) user.followSearch = value > 0 ? 1 : 0;
    [self reclassify:user];
}

- (void)applyKnown:(NSNumber *)cached toUser:(SCIProfileAnalyzerUser *)user {
    if (!cached || user.followsYou >= 0) return;
    NSInteger value = cached.integerValue;
    if (value > 0) user.followStatus = 1;
    else if (value == 0) {
        user.followStatus = 0;
        user.followSearch = 0;
    }
    [self reclassify:user];
}

- (int)workForUser:(SCIProfileAnalyzerUser *)user {
    if (!user.pk.length || [self.skippedPKs containsObject:user.pk]) return 0;
    return IXPANextCheck((int)user.followStatus, (int)user.followSearch,
                          [self attemptsIn:self.statusAttempts pk:user.pk],
                          [self attemptsIn:self.searchAttempts pk:user.pk]);
}

- (NSArray<SCIProfileAnalyzerUser *> *)usersNeedingWork:(int)work
                                                  users:(NSArray<SCIProfileAnalyzerUser *> *)users
                                                  limit:(NSUInteger)limit {
    NSMutableArray *batch = [NSMutableArray array];
    for (SCIProfileAnalyzerUser *user in users) {
        if ([self workForUser:user] != work) continue;
        [batch addObject:user];
        if (limit && batch.count >= limit) break;
    }
    return batch;
}

- (void)finishClassified:(NSMutableArray<SCIProfileAnalyzerUser *> *)users
                       pk:(NSString *)pk
                 snapshot:(SCIProfileAnalyzerSnapshot *)snap
                    error:(NSError *)error
                 progress:(SCIPAProgress)progress
               completion:(SCIPACompletion)completion {
    [self publishUsers:users snapshot:snap progress:progress status:nil fraction:1];
    if (error) {
        [self saveProgressUsers:users next:@"" phase:@"mutuals" pk:pk];
        @try { [SCIProfileAnalyzerStorage updateCurrentSnapshot:snap forUserPK:pk]; } @catch (__unused NSException *e) {}
    } else {
        @try { [SCIProfileAnalyzerStorage saveSnapshot:snap forUserPK:pk]; } @catch (__unused NSException *e) {}
        [self clearProgress:pk];
    }
    [self finishWithSnapshot:snap error:error completion:completion];
}

- (void)stepMutuals:(NSMutableArray<SCIProfileAnalyzerUser *> *)users
                 pk:(NSString *)pk
           snapshot:(SCIProfileAnalyzerSnapshot *)snap
           progress:(SCIPAProgress)progress
         completion:(SCIPACompletion)completion {
    @try {
        if (self.cancelled) {
            [self finishClassified:users pk:pk snapshot:snap
                             error:[self errorWithCode:SCIProfileAnalyzerErrorCancelled
                                               message:SCILocalized(@"Analysis stopped. Showing the accounts already checked.")]
                          progress:progress completion:completion];
            return;
        }
        NSInteger cap = self.showManyLimit > 0 ? self.showManyLimit : SCI_PA_SHOW_MANY;
        NSArray<SCIProfileAnalyzerUser *> *bulk = self.showManyDead ? @[] : [self usersNeedingWork:1 users:users limit:(NSUInteger)cap];
        NSArray<SCIProfileAnalyzerUser *> *search = bulk.count ? @[] : [self usersNeedingWork:2 users:users limit:1];
        NSArray<SCIProfileAnalyzerUser *> *single = (bulk.count || search.count) ? @[] : [self usersNeedingWork:3 users:users limit:1];
        if (bulk.count == 0 && search.count == 0 && single.count == 0) {
            NSInteger leftover = 0;
            for (SCIProfileAnalyzerUser *user in users) if (user.followsYou < 0 && user.pk.length) leftover++;
            NSError *error = leftover > 0
                ? [self errorWithCode:SCIProfileAnalyzerErrorNetwork message:SCILocalized(@"Couldn't check every follow-back. Showing the accounts already checked.")]
                : nil;
            [self finishClassified:users pk:pk snapshot:snap error:error progress:progress completion:completion];
            return;
        }
        [self publishUsers:users snapshot:snap progress:progress
                    status:[self mutualStatusForUsers:users]
                  fraction:[self mutualFractionForUsers:users]];
        if (bulk.count) {
            [self showMany:bulk users:users pk:pk snapshot:snap progress:progress completion:completion];
        } else if (search.count) {
            [self searchUser:search.firstObject page:@"" pages:0 users:users pk:pk snapshot:snap progress:progress completion:completion];
        } else {
            [self showOne:single.firstObject users:users pk:pk snapshot:snap progress:progress completion:completion];
        }
    } @catch (__unused NSException *e) {
        [self finishClassified:users pk:pk snapshot:snap
                         error:[self errorWithCode:SCIProfileAnalyzerErrorNetwork
                                           message:SCILocalized(@"Couldn't check every follow-back. Showing the accounts already checked.")]
                      progress:progress completion:completion];
    }
}

- (void)showMany:(NSArray<SCIProfileAnalyzerUser *> *)batch
           users:(NSMutableArray<SCIProfileAnalyzerUser *> *)users
              pk:(NSString *)pk
        snapshot:(SCIProfileAnalyzerSnapshot *)snap
        progress:(SCIPAProgress)progress
      completion:(SCIPACompletion)completion {
    NSMutableArray<NSString *> *ids = [NSMutableArray arrayWithCapacity:batch.count];
    for (SCIProfileAnalyzerUser *user in batch) if (user.pk.length) [ids addObject:user.pk];
    if (!ids.count) {
        self.showManyDead = YES;
        [self stepMutuals:users pk:pk snapshot:snap progress:progress completion:completion];
        return;
    }
    __weak typeof(self) weakSelf = self;
    [self requestPath:@"friendships/show_many/"
               method:@"POST"
                 body:@{ @"user_ids": [ids componentsJoinedByString:@","] }
              attempt:0
             progress:progress
           completion:^(NSDictionary *resp, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.cancelled || error.code == SCIProfileAnalyzerErrorCancelled) {
            [strongSelf finishClassified:users pk:pk snapshot:snap
                                   error:[strongSelf errorWithCode:SCIProfileAnalyzerErrorCancelled
                                                            message:SCILocalized(@"Analysis stopped. Showing the accounts already checked.")]
                                progress:progress completion:completion];
            return;
        }
        if (error.code == SCIProfileAnalyzerErrorRateLimited) {
            [strongSelf finishClassified:users pk:pk snapshot:snap error:error progress:progress completion:completion];
            return;
        }
        if (!error) {
            for (SCIProfileAnalyzerUser *user in batch) [strongSelf setAttempt:1 in:strongSelf.statusAttempts pk:user.pk];
            NSUInteger applied = [strongSelf applyStatusMap:[strongSelf statusMapFromResponse:resp] toUsers:batch];
            if (applied == 0) strongSelf.showManyDead = YES;
        } else if (strongSelf.showManyLimit > 20) {
            strongSelf.showManyLimit = MAX(20, strongSelf.showManyLimit / 2);
        } else {
            for (SCIProfileAnalyzerUser *user in batch) [strongSelf setAttempt:1 in:strongSelf.statusAttempts pk:user.pk];
            strongSelf.showManyDead = YES;
        }
        [strongSelf publishUsers:users snapshot:snap progress:progress
                          status:[strongSelf mutualStatusForUsers:users]
                        fraction:[strongSelf mutualFractionForUsers:users]];
        [strongSelf persistIfNeeded:users pk:pk force:YES];
        [strongSelf afterGate:^{
            [weakSelf stepMutuals:users pk:pk snapshot:snap progress:progress completion:completion];
        } progress:progress];
    }];
}

- (BOOL)page:(NSDictionary *)resp matchesUser:(SCIProfileAnalyzerUser *)user valid:(BOOL *)valid {
    if (valid) *valid = NO;
    if (![resp isKindOfClass:[NSDictionary class]] || !user) return NO;
    id lists[2] = { resp[@"users"], resp[@"items"] };
    BOOL saw = NO;
    BOOL match = NO;
    @autoreleasepool {
        for (int i = 0; i < 2; i++) {
            if (![lists[i] isKindOfClass:[NSArray class]]) continue;
            saw = YES;
            for (id item in (NSArray *)lists[i]) {
                if (![item isKindOfClass:[NSDictionary class]]) continue;
                NSString *name = [item[@"username"] isKindOfClass:[NSString class]] ? item[@"username"] : @"";
                NSString *itemPK = [self pkString:item[@"pk"] ?: item[@"pk_id"] ?: item[@"id"]];
                if (IXPASameAccount(user.username.UTF8String, user.pk.UTF8String, name.UTF8String, itemPK.UTF8String)) {
                    match = YES;
                    break;
                }
            }
            if (match) break;
        }
    }
    if (valid) *valid = saw;
    return match;
}

- (BOOL)pageHasMore:(NSDictionary *)resp {
    if (![resp isKindOfClass:[NSDictionary class]]) return NO;
    id more = resp[@"has_more"] ?: resp[@"more_available"];
    if ([more respondsToSelector:@selector(boolValue)] && [more boolValue]) return YES;
    id next = resp[@"next_max_id"];
    if ([next isKindOfClass:[NSString class]]) return [(NSString *)next length] > 0;
    if ([next respondsToSelector:@selector(stringValue)]) return [[next stringValue] length] > 0;
    return NO;
}

- (NSString *)pageCursor:(NSDictionary *)resp {
    id next = [resp isKindOfClass:[NSDictionary class]] ? resp[@"next_max_id"] : nil;
    if ([next isKindOfClass:[NSString class]]) return next;
    if ([next respondsToSelector:@selector(stringValue)]) return [next stringValue];
    return @"";
}

- (NSString *)queryToken:(NSString *)username {
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._"];
    return [username stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

- (void)searchUser:(SCIProfileAnalyzerUser *)user
                page:(NSString *)cursor
               pages:(NSInteger)pages
               users:(NSMutableArray<SCIProfileAnalyzerUser *> *)users
                  pk:(NSString *)pk
            snapshot:(SCIProfileAnalyzerSnapshot *)snap
            progress:(SCIPAProgress)progress
          completion:(SCIPACompletion)completion {
    if (!user.username.length) {
        [self setAttempt:1 in:self.searchAttempts pk:user.pk];
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf stepMutuals:users pk:pk snapshot:snap progress:progress completion:completion];
        });
        return;
    }
    NSString *query = [self queryToken:user.username];
    NSString *rank = [self queryToken:self.rankToken ?: @""];
    NSString *path = [NSString stringWithFormat:@"friendships/%@/followers/?query=%@&search_surface=follow_list_page&rank_token=%@",
                      pk, query, rank];
    if (cursor.length) {
        NSString *escaped = [cursor stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]] ?: @"";
        if (escaped.length) path = [path stringByAppendingFormat:@"&max_id=%@", escaped];
    }
    __weak typeof(self) weakSelf = self;
    [self requestPath:path method:@"GET" body:nil attempt:0 progress:progress completion:^(NSDictionary *resp, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.cancelled || error.code == SCIProfileAnalyzerErrorCancelled) {
            [strongSelf finishClassified:users pk:pk snapshot:snap
                                   error:[strongSelf errorWithCode:SCIProfileAnalyzerErrorCancelled
                                                            message:SCILocalized(@"Analysis stopped. Showing the accounts already checked.")]
                                progress:progress completion:completion];
            return;
        }
        if (error.code == SCIProfileAnalyzerErrorRateLimited) {
            [strongSelf finishClassified:users pk:pk snapshot:snap error:error progress:progress completion:completion];
            return;
        }
        if (error) {
            strongSelf.searchFailures++;
            [strongSelf setAttempt:1 in:strongSelf.searchAttempts pk:user.pk];
            if (strongSelf.searchFailures >= 3) {
                [strongSelf finishClassified:users pk:pk snapshot:snap error:error progress:progress completion:completion];
                return;
            }
        } else {
            BOOL valid = NO;
            BOOL match = [strongSelf page:resp matchesUser:user valid:&valid];
            NSString *status = [resp[@"status"] isKindOfClass:[NSString class]] ? resp[@"status"] : @"";
            if (status.length && ![status isEqualToString:@"ok"]) valid = NO;
            BOOL more = [strongSelf pageHasMore:resp];
            int verdict = IXPASearchVerdict(match, valid, more);
            if (verdict == -1 && more && pages < 2) {
                NSString *next = [strongSelf pageCursor:resp];
                if (next.length && ![next isEqualToString:cursor ?: @""]) {
                    [strongSelf searchUser:user page:next pages:pages + 1 users:users pk:pk snapshot:snap progress:progress completion:completion];
                    return;
                }
            }
            [strongSelf setAttempt:1 in:strongSelf.searchAttempts pk:user.pk];
            if (verdict >= 0) {
                [strongSelf noteSearch:verdict user:user];
                strongSelf.searchFailures = 0;
            } else {
                strongSelf.searchFailures++;
                if (strongSelf.searchFailures >= 3) {
                    [strongSelf finishClassified:users pk:pk snapshot:snap
                                           error:[strongSelf errorWithCode:SCIProfileAnalyzerErrorNetwork
                                                                   message:SCILocalized(@"Couldn't check every follow-back. Showing the accounts already checked.")]
                                        progress:progress completion:completion];
                    return;
                }
            }
        }
        [strongSelf publishUsers:users snapshot:snap progress:progress
                          status:[strongSelf mutualStatusForUsers:users]
                        fraction:[strongSelf mutualFractionForUsers:users]];
        [strongSelf persistIfNeeded:users pk:pk force:NO];
        [strongSelf afterGate:^{
            [weakSelf stepMutuals:users pk:pk snapshot:snap progress:progress completion:completion];
        } progress:progress];
    }];
}

- (void)showOne:(SCIProfileAnalyzerUser *)user
          users:(NSMutableArray<SCIProfileAnalyzerUser *> *)users
             pk:(NSString *)pk
       snapshot:(SCIProfileAnalyzerSnapshot *)snap
       progress:(SCIPAProgress)progress
     completion:(SCIPACompletion)completion {
    if (!user.pk.length) {
        [self stepMutuals:users pk:pk snapshot:snap progress:progress completion:completion];
        return;
    }
    NSString *path = [NSString stringWithFormat:@"friendships/show/%@/", user.pk];
    __weak typeof(self) weakSelf = self;
    [self requestPath:path method:@"GET" body:nil attempt:0 progress:progress completion:^(NSDictionary *resp, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.cancelled || error.code == SCIProfileAnalyzerErrorCancelled) {
            [strongSelf finishClassified:users pk:pk snapshot:snap
                                   error:[strongSelf errorWithCode:SCIProfileAnalyzerErrorCancelled
                                                            message:SCILocalized(@"Analysis stopped. Showing the accounts already checked.")]
                                progress:progress completion:completion];
            return;
        }
        if (error.code == SCIProfileAnalyzerErrorRateLimited) {
            [strongSelf finishClassified:users pk:pk snapshot:snap error:error progress:progress completion:completion];
            return;
        }
        [strongSelf setAttempt:2 in:strongSelf.statusAttempts pk:user.pk];
        if (!error) {
            NSInteger value = [strongSelf followsYouInRow:resp];
            if (value >= 0) [strongSelf noteStatus:value user:user];
        }
        [strongSelf publishUsers:users snapshot:snap progress:progress
                          status:[strongSelf mutualStatusForUsers:users]
                        fraction:[strongSelf mutualFractionForUsers:users]];
        [strongSelf persistIfNeeded:users pk:pk force:NO];
        [strongSelf afterGate:^{
            [weakSelf stepMutuals:users pk:pk snapshot:snap progress:progress completion:completion];
        } progress:progress];
    }];
}

- (void)beginMutuals:(NSMutableArray<SCIProfileAnalyzerUser *> *)acc
                  pk:(NSString *)pk
            snapshot:(SCIProfileAnalyzerSnapshot *)snap
            progress:(SCIPAProgress)progress
          completion:(SCIPACompletion)completion {
    [self publishUsers:acc snapshot:snap progress:progress
                status:[self mutualStatusForUsers:acc]
              fraction:[self mutualFractionForUsers:acc]];
    [self saveProgressUsers:acc next:@"" phase:@"mutuals" pk:pk];
    [self stepMutuals:acc pk:pk snapshot:snap progress:progress completion:completion];
}

- (void)fetchFollowingForPK:(NSString *)pk
                   snapshot:(SCIProfileAnalyzerSnapshot *)snap
                   progress:(SCIPAProgress)progress
                 completion:(SCIPACompletion)completion {
    NSMutableArray<SCIProfileAnalyzerUser *> *acc = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSDictionary *known = [self knownFollowsForPK:pk];
    NSDictionary *saved = [SCIProfileAnalyzerStorage progressForUserPK:pk];
    NSString *resume = nil;
    if ([saved isKindOfClass:[NSDictionary class]]) {
        for (id item in saved[@"users"]) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            SCIProfileAnalyzerUser *user = [SCIProfileAnalyzerUser userFromJSONDict:item];
            if (!user.pk.length || [seen containsObject:user.pk]) continue;
            if (user.followsYou < 0) [self applyKnown:known[user.pk] toUser:user];
            [seen addObject:user.pk];
            [acc addObject:user];
        }
        id next = saved[@"next_max_id"];
        if ([next isKindOfClass:[NSString class]]) resume = next;
        else if ([next respondsToSelector:@selector(stringValue)]) resume = [next stringValue];
    }
    int unknown = (int)MIN(INT_MAX, [self unknownCount:acc]);
    IXPAStep step = IXPANextStep((int)MIN(INT_MAX, acc.count), (int)resume.length, unknown);
    if (step == IXPA_STEP_FINISH) {
        [self finishClassified:acc pk:pk snapshot:snap error:nil progress:progress completion:completion];
        return;
    }
    if (step == IXPA_STEP_RESOLVE) {
        NSString *checking = [NSString stringWithFormat:SCILocalized(@"Checking who follows you back (%lu/%lu)…"),
                              (unsigned long)(acc.count - (NSUInteger)MAX(unknown, 0)), (unsigned long)acc.count];
        [self reportProgress:progress status:checking fraction:0.35];
        [self beginMutuals:acc pk:pk snapshot:snap progress:progress completion:completion];
        return;
    }
    if (acc.count) {
        [self reportProgress:progress status:SCILocalized(@"Resuming saved following list…") fraction:0.05];
    }
    [self pageFollowing:pk
                    acc:acc
                   seen:seen
                  known:known
                  maxId:resume
                  pages:0
                  total:snap.followingCount
               snapshot:snap
               progress:progress
             completion:completion];
}

- (void)appendPageUsers:(NSArray *)raw
                     to:(NSMutableArray<SCIProfileAnalyzerUser *> *)acc
                   seen:(NSMutableSet<NSString *> *)seen
                  known:(NSDictionary<NSString *, NSNumber *> *)known {
    if (![raw isKindOfClass:[NSArray class]]) return;
    @autoreleasepool {
        for (id item in raw) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            SCIProfileAnalyzerUser *user = [SCIProfileAnalyzerUser userFromAPIDict:item];
            if (!user.pk.length || [seen containsObject:user.pk]) continue;
            if (user.followsYou < 0) [self applyKnown:known[user.pk] toUser:user];
            [seen addObject:user.pk];
            [acc addObject:user];
        }
    }
}

- (void)pageFollowing:(NSString *)pk
                  acc:(NSMutableArray<SCIProfileAnalyzerUser *> *)acc
                 seen:(NSMutableSet<NSString *> *)seen
                known:(NSDictionary *)known
                maxId:(NSString *)maxId
                pages:(NSInteger)pages
                total:(NSInteger)total
             snapshot:(SCIProfileAnalyzerSnapshot *)snap
             progress:(SCIPAProgress)progress
           completion:(SCIPACompletion)completion {
    if (self.cancelled) {
        [self saveProgressUsers:acc next:maxId phase:@"following" pk:pk];
        [self publishUsers:acc snapshot:snap progress:progress status:nil fraction:-1];
        @try { [SCIProfileAnalyzerStorage updateCurrentSnapshot:snap forUserPK:pk]; } @catch (__unused NSException *e) {}
        [self finishWithSnapshot:snap error:[self errorWithCode:SCIProfileAnalyzerErrorCancelled message:SCILocalized(@"Analysis stopped. Showing the accounts already checked.")] completion:completion];
        return;
    }
    if (pages >= SCI_PA_MAX_PAGES) {
        [self beginMutuals:acc pk:pk snapshot:snap progress:progress completion:completion];
        return;
    }
    NSString *base = [NSString stringWithFormat:@"friendships/%@/following/", pk];
    NSString *escaped = maxId.length ? [maxId stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] : nil;
    NSString *path = escaped.length ? [NSString stringWithFormat:@"%@?max_id=%@", base, escaped] : base;
    __weak typeof(self) weakSelf = self;
    [self requestPath:path method:@"GET" body:nil attempt:0 progress:progress completion:^(NSDictionary *resp, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (error || strongSelf.cancelled) {
            [strongSelf saveProgressUsers:acc next:maxId phase:@"following" pk:pk];
            [strongSelf publishUsers:acc snapshot:snap progress:progress status:nil fraction:-1];
            if (acc.count) {
                @try { [SCIProfileAnalyzerStorage updateCurrentSnapshot:snap forUserPK:pk]; } @catch (__unused NSException *e) {}
            }
            NSError *out = error ?: [strongSelf errorWithCode:SCIProfileAnalyzerErrorCancelled message:SCILocalized(@"Saved progress. Run analysis again to resume.")];
            [strongSelf finishWithSnapshot:acc.count ? snap : nil error:out completion:completion];
            return;
        }
        [strongSelf appendPageUsers:resp[@"users"] to:acc seen:seen known:known];
        double frac = total > 0 ? MIN(0.34, 0.03 + (double)acc.count / (double)total * 0.31) : 0.2;
        [strongSelf reportProgress:progress
                            status:[NSString stringWithFormat:SCILocalized(@"Fetching following (%lu/%ld)…"), (unsigned long)acc.count, (long)total]
                          fraction:frac];
        id next = resp[@"next_max_id"];
        NSString *nextMax = [next isKindOfClass:[NSString class]] ? next : ([next respondsToSelector:@selector(stringValue)] ? [next stringValue] : nil);
        BOOL stuck = nextMax.length && maxId.length && [nextMax isEqualToString:maxId];
        if (!nextMax.length || stuck || strongSelf.cancelled) {
            if (strongSelf.cancelled) {
                [strongSelf saveProgressUsers:acc next:nextMax ?: maxId phase:@"following" pk:pk];
                [strongSelf publishUsers:acc snapshot:snap progress:progress status:nil fraction:frac];
                @try { [SCIProfileAnalyzerStorage updateCurrentSnapshot:snap forUserPK:pk]; } @catch (__unused NSException *e) {}
                [strongSelf finishWithSnapshot:snap error:[strongSelf errorWithCode:SCIProfileAnalyzerErrorCancelled message:SCILocalized(@"Analysis stopped. Showing the accounts already checked.")] completion:completion];
                return;
            }
            [strongSelf beginMutuals:acc pk:pk snapshot:snap progress:progress completion:completion];
            return;
        }
        [strongSelf saveProgressUsers:acc next:nextMax phase:@"following" pk:pk];
        [strongSelf afterGate:^{
            [weakSelf pageFollowing:pk acc:acc seen:seen known:known maxId:nextMax pages:pages + 1 total:total snapshot:snap progress:progress completion:completion];
        } progress:progress];
    }];
}

@end
