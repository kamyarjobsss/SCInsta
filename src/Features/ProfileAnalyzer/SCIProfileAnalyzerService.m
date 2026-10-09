#import "SCIProfileAnalyzerService.h"
#import "SCIProfileAnalyzerStorage.h"
#import <math.h>
#import "../../Networking/SCIInstagramAPI.h"
#import "../../Utils.h"

#define SCI_PA_PAGE_DELAY_S 0.6
#define SCI_PA_MAX_ATTEMPTS 6
#define SCI_PA_MAX_PAGES 10000

@interface SCIProfileAnalyzerService ()
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, assign) BOOL isRunning;
@end

@implementation SCIProfileAnalyzerService

+ (instancetype)sharedService {
    static SCIProfileAnalyzerService *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [self new]; });
    return s;
}

- (void)cancel { self.cancelled = YES; }

- (void)finishWithSnapshot:(SCIProfileAnalyzerSnapshot *)s error:(NSError *)e completion:(SCIPACompletion)completion {
    self.isRunning = NO;
    self.cancelled = NO;
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
                      completion:(SCIPACompletion)completion {
    if (self.isRunning) {
        if (completion) completion(nil, [self errorWithCode:SCIProfileAnalyzerErrorCancelled
                                                    message:SCILocalized(@"Another analysis is already running")]);
        return;
    }
    self.isRunning = YES;
    self.cancelled = NO;

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
        if (headerInfo) dispatch_async(dispatch_get_main_queue(), ^{ headerInfo(user); });
        [strongSelf fetchFollowingForPK:selfPK snapshot:snap progress:progress completion:completion];
    }];
}

- (BOOL)rateLimited:(NSInteger)status body:(NSDictionary *)resp {
    if (status == 429) return YES;
    NSString *message = [resp[@"message"] isKindOfClass:[NSString class]] ? resp[@"message"] : @"";
    return [message isEqualToString:@"feedback_required"] || [message isEqualToString:@"rate_limit_error"];
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
    __weak typeof(self) weakSelf = self;
    [SCIInstagramAPI sendRequestWithMethod:method path:path body:body httpHandler:^(NSDictionary *response, NSError *error, NSInteger statusCode, NSTimeInterval retryAfter) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        BOOL limited = [strongSelf rateLimited:statusCode body:response];
        if (!limited && !error) {
            completion(response, nil);
            return;
        }
        if (strongSelf.cancelled || attempt + 1 >= SCI_PA_MAX_ATTEMPTS) {
            NSString *msg = limited
                ? SCILocalized(@"Rate limited too many times. Run analysis again to resume.")
                : (error.localizedDescription ?: SCILocalized(@"Couldn't fetch profile information"));
            completion(nil, [strongSelf errorWithCode:strongSelf.cancelled ? SCIProfileAnalyzerErrorCancelled : SCIProfileAnalyzerErrorNetwork message:msg]);
            return;
        }
        NSTimeInterval wait = retryAfter > 0 ? retryAfter : MIN(60.0, 2.0 * pow(2, attempt));
        [strongSelf reportProgress:progress status:SCILocalized(@"Waiting for Instagram rate limit…") fraction:-1];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf requestPath:path method:method body:body attempt:attempt + 1 progress:progress completion:completion];
        });
    }];
}

- (NSArray *)jsonUsers:(NSArray<SCIProfileAnalyzerUser *> *)users {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:users.count];
    for (SCIProfileAnalyzerUser *user in users) {
        if (user.pk.length) [out addObject:[user toJSONDict]];
    }
    return out;
}

- (dispatch_queue_t)progressQueue {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("com.instagramx.analyzer.progress", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

- (void)saveProgressUsers:(NSArray<SCIProfileAnalyzerUser *> *)users next:(NSString *)next pk:(NSString *)pk {
    if (!pk.length) return;
    NSArray *json = [self jsonUsers:users];
    NSDictionary *payload = @{ @"next_max_id": next ?: @"", @"users": json };
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

- (void)applyStatuses:(NSDictionary *)statuses toUsers:(NSMutableArray<SCIProfileAnalyzerUser *> *)users {
    if (![statuses isKindOfClass:[NSDictionary class]]) return;
    for (SCIProfileAnalyzerUser *user in users) {
        if (user.followsYou >= 0) continue;
        NSDictionary *row = [statuses[user.pk] isKindOfClass:[NSDictionary class]] ? statuses[user.pk] : nil;
        if (!row) continue;
        for (NSString *key in @[@"followed_by", @"followed_by_viewer", @"follows_viewer"]) {
            id value = row[key];
            if ([value isKindOfClass:[NSNumber class]]) {
                user.followsYou = [value boolValue] ? 1 : 0;
                break;
            }
        }
    }
}

- (void)resolveUnknownIn:(NSMutableArray<SCIProfileAnalyzerUser *> *)users
                    from:(NSUInteger)start
                attempt:(NSInteger)attempt
               progress:(SCIPAProgress)progress
             completion:(void (^)(NSError *error))completion {
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    NSUInteger cursor = start;
    for (; cursor < users.count && missing.count < 40; cursor++) {
        SCIProfileAnalyzerUser *user = users[cursor];
        if (user.followsYou < 0 && user.pk.length) [missing addObject:user.pk];
    }
    if (missing.count == 0 || self.cancelled) {
        if (completion) completion(self.cancelled ? [self errorWithCode:SCIProfileAnalyzerErrorCancelled message:SCILocalized(@"Cancelled")] : nil);
        return;
    }
    __weak typeof(self) weakSelf = self;
    [self requestPath:@"friendships/show_many/"
               method:@"POST"
                 body:@{ @"user_ids": [missing componentsJoinedByString:@","] }
              attempt:attempt
             progress:progress
           completion:^(NSDictionary *resp, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || error || strongSelf.cancelled) {
            if (completion) completion(error ?: [strongSelf errorWithCode:SCIProfileAnalyzerErrorCancelled message:SCILocalized(@"Cancelled")]);
            return;
        }
        id raw = resp[@"friendship_statuses"];
        [strongSelf applyStatuses:[raw isKindOfClass:[NSDictionary class]] ? raw : nil toUsers:users];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SCI_PA_PAGE_DELAY_S * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf resolveUnknownIn:users from:cursor attempt:0 progress:progress completion:completion];
        });
    }];
}

- (void)fetchFollowingForPK:(NSString *)pk
                   snapshot:(SCIProfileAnalyzerSnapshot *)snap
                   progress:(SCIPAProgress)progress
                 completion:(SCIPACompletion)completion {
    NSMutableArray<SCIProfileAnalyzerUser *> *acc = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSDictionary *saved = [SCIProfileAnalyzerStorage progressForUserPK:pk];
    NSString *resume = nil;
    if ([saved isKindOfClass:[NSDictionary class]]) {
        for (id item in saved[@"users"]) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            SCIProfileAnalyzerUser *user = [SCIProfileAnalyzerUser userFromJSONDict:item];
            if (!user.pk.length || [seen containsObject:user.pk]) continue;
            [seen addObject:user.pk];
            [acc addObject:user];
        }
        id next = saved[@"next_max_id"];
        if ([next isKindOfClass:[NSString class]]) resume = next;
        else if ([next respondsToSelector:@selector(stringValue)]) resume = [next stringValue];
    }
    if (acc.count && resume.length == 0 && saved) {
        snap.following = acc;
        [self clearProgress:pk];
        [self finishWithSnapshot:snap error:nil completion:completion];
        return;
    }
    if (acc.count) {
        [self reportProgress:progress status:SCILocalized(@"Resuming saved following list…") fraction:0.05];
    }
    [self pageFollowing:pk
                    acc:acc
                   seen:seen
                  maxId:resume
                  pages:0
                  total:snap.followingCount
               snapshot:snap
               progress:progress
             completion:completion];
}

- (void)appendPageUsers:(NSArray *)raw to:(NSMutableArray<SCIProfileAnalyzerUser *> *)acc seen:(NSMutableSet<NSString *> *)seen {
    if (![raw isKindOfClass:[NSArray class]]) return;
    @autoreleasepool {
        for (id item in raw) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            SCIProfileAnalyzerUser *user = [SCIProfileAnalyzerUser userFromAPIDict:item];
            if (!user.pk.length || [seen containsObject:user.pk]) continue;
            [seen addObject:user.pk];
            [acc addObject:user];
        }
    }
}

- (void)finishFollowing:(NSMutableArray<SCIProfileAnalyzerUser *> *)acc
                     pk:(NSString *)pk
               snapshot:(SCIProfileAnalyzerSnapshot *)snap
             completion:(SCIPACompletion)completion {
    snap.following = [acc copy];
    [self clearProgress:pk];
    [self finishWithSnapshot:snap error:nil completion:completion];
}

- (void)pageFollowing:(NSString *)pk
                  acc:(NSMutableArray<SCIProfileAnalyzerUser *> *)acc
                 seen:(NSMutableSet<NSString *> *)seen
                maxId:(NSString *)maxId
                pages:(NSInteger)pages
                total:(NSInteger)total
             snapshot:(SCIProfileAnalyzerSnapshot *)snap
             progress:(SCIPAProgress)progress
           completion:(SCIPACompletion)completion {
    if (self.cancelled) {
        [self saveProgressUsers:acc next:maxId pk:pk];
        [self finishWithSnapshot:nil error:[self errorWithCode:SCIProfileAnalyzerErrorCancelled message:SCILocalized(@"Cancelled")] completion:completion];
        return;
    }
    if (pages >= SCI_PA_MAX_PAGES) {
        [self finishFollowing:acc pk:pk snapshot:snap completion:completion];
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
            [strongSelf saveProgressUsers:acc next:maxId pk:pk];
            [strongSelf finishWithSnapshot:nil
                                    error:error ?: [strongSelf errorWithCode:SCIProfileAnalyzerErrorCancelled message:SCILocalized(@"Saved progress. Run analysis again to resume.")]
                               completion:completion];
            return;
        }
        [strongSelf appendPageUsers:resp[@"users"] to:acc seen:seen];
        double frac = total > 0 ? MIN(0.98, 0.03 + (double)acc.count / (double)total * 0.95) : 0.5;
        [strongSelf reportProgress:progress
                            status:[NSString stringWithFormat:SCILocalized(@"Fetching following (%lu/%ld)…"), (unsigned long)acc.count, (long)total]
                          fraction:frac];
        id next = resp[@"next_max_id"];
        NSString *nextMax = [next isKindOfClass:[NSString class]] ? next : ([next respondsToSelector:@selector(stringValue)] ? [next stringValue] : nil);
        BOOL stuck = nextMax.length && maxId.length && [nextMax isEqualToString:maxId];
        if (!nextMax.length || stuck || strongSelf.cancelled) {
            if (strongSelf.cancelled) {
                [strongSelf saveProgressUsers:acc next:nextMax ?: maxId pk:pk];
                [strongSelf finishWithSnapshot:nil error:[strongSelf errorWithCode:SCIProfileAnalyzerErrorCancelled message:SCILocalized(@"Cancelled")] completion:completion];
                return;
            }
            [strongSelf resolveUnknownIn:acc from:0 attempt:0 progress:progress completion:^(NSError *resolveError) {
                if (resolveError && resolveError.code == SCIProfileAnalyzerErrorCancelled) {
                    [strongSelf saveProgressUsers:acc next:nextMax pk:pk];
                    [strongSelf finishWithSnapshot:nil error:resolveError completion:completion];
                    return;
                }
                [strongSelf finishFollowing:acc pk:pk snapshot:snap completion:completion];
            }];
            return;
        }
        [strongSelf saveProgressUsers:acc next:nextMax pk:pk];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SCI_PA_PAGE_DELAY_S * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf pageFollowing:pk acc:acc seen:seen maxId:nextMax pages:pages + 1 total:total snapshot:snap progress:progress completion:completion];
        });
    }];
}

@end
