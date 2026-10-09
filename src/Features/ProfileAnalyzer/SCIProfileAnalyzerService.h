#import <Foundation/Foundation.h>
#import "SCIProfileAnalyzerModels.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SCIProfileAnalyzerError) {
    SCIProfileAnalyzerErrorNoSession = 1,
    SCIProfileAnalyzerErrorNetwork,
    SCIProfileAnalyzerErrorCancelled,
    SCIProfileAnalyzerErrorRateLimited,
};

typedef void(^SCIPAProgress)(NSString *status, double fraction);
typedef void(^SCIPACompletion)(SCIProfileAnalyzerSnapshot * _Nullable snapshot, NSError * _Nullable error);
// Fires once, right after the self-user-info call returns. Lets the UI
// paint the header immediately instead of waiting for the full run to finish.
typedef void(^SCIPAHeaderInfo)(NSDictionary *userInfo);
// Fired as soon as the following list exists and again as follow-back
// checks land, so Mutuals and Not following you back fill in live.
typedef void(^SCIPAIncremental)(SCIProfileAnalyzerSnapshot *snapshot);

@interface SCIProfileAnalyzerService : NSObject

@property (nonatomic, readonly) BOOL isRunning;
@property (nonatomic, readonly, getter=isPaused) BOOL paused;
// In-memory snapshot for the run in progress. Nil when idle.
@property (nonatomic, readonly, nullable) SCIProfileAnalyzerSnapshot *liveSnapshot;

+ (instancetype)sharedService;

- (void)runForSelfWithHeaderInfo:(nullable SCIPAHeaderInfo)headerInfo
                        progress:(nullable SCIPAProgress)progress
                     incremental:(nullable SCIPAIncremental)incremental
                      completion:(SCIPACompletion)completion;
- (void)pause;
- (void)resume;
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
