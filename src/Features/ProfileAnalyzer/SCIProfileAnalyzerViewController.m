#import "SCIProfileAnalyzerViewController.h"
#import "SCIProfileAnalyzerModels.h"
#import "SCIProfileAnalyzerStorage.h"
#import "SCIProfileAnalyzerService.h"
#import "SCIProfileAnalyzerListViewController.h"
#import "../../Utils.h"
#import "../../SCIImageCache.h"
#import "../../Networking/SCIInstagramAPI.h"
#import "../../Localization/SCILocalization.h"
#import <objc/runtime.h>

extern NSNotificationName const SCIProfileAnalyzerDataDidChangeNotification;

#pragma mark - Category descriptor

typedef NS_ENUM(NSInteger, SCIPACategory) {
    SCIPACategoryMutual,
    SCIPACategoryNotFollowingBack,
};

@interface SCIPACategoryDescriptor : NSObject
@property (nonatomic, assign) SCIPACategory category;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy) NSString *symbol;
@property (nonatomic, strong) UIColor *color;
@property (nonatomic, assign) NSInteger count;
@property (nonatomic, assign) BOOL requiresPrevious;
@end
@implementation SCIPACategoryDescriptor @end

#pragma mark - Avatar with progress ring

@interface SCIPAAvatarRingView : UIView
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) CAShapeLayer *trackLayer;
@property (nonatomic, strong) CAShapeLayer *progressLayer;
@property (nonatomic, assign) double progress;   // 0..1
@property (nonatomic, assign) BOOL showProgress;
@end

@implementation SCIPAAvatarRingView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return self;

    _trackLayer = [CAShapeLayer layer];
    _trackLayer.fillColor = UIColor.clearColor.CGColor;
    _trackLayer.strokeColor = [UIColor systemGray5Color].CGColor;
    _trackLayer.lineWidth = 3.5;
    _trackLayer.hidden = YES;
    [self.layer addSublayer:_trackLayer];

    _progressLayer = [CAShapeLayer layer];
    _progressLayer.fillColor = UIColor.clearColor.CGColor;
    _progressLayer.strokeColor = ([SCIUtils SCIColor_Primary] ?: [UIColor systemBlueColor]).CGColor;
    _progressLayer.lineWidth = 3.5;
    _progressLayer.lineCap = kCALineCapRound;
    _progressLayer.strokeEnd = 0;
    _progressLayer.hidden = YES;
    [self.layer addSublayer:_progressLayer];

    _imageView = [UIImageView new];
    _imageView.contentMode = UIViewContentModeScaleAspectFill;
    _imageView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    _imageView.layer.masksToBounds = YES;
    _imageView.image = [UIImage systemImageNamed:@"person.circle.fill"];
    _imageView.tintColor = [UIColor systemGrayColor];
    [self addSubview:_imageView];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat size = MIN(self.bounds.size.width, self.bounds.size.height);
    if (size < 16) return;   // transient tiny bounds during transitions
    CGFloat inset = 7;
    CGRect imgFrame = CGRectInset(CGRectMake(0, 0, size, size), inset, inset);
    self.imageView.frame = imgFrame;
    self.imageView.layer.cornerRadius = imgFrame.size.width / 2.0;

    UIBezierPath *path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(size / 2.0, size / 2.0)
                                                         radius:size / 2.0 - 2
                                                     startAngle:-M_PI_2
                                                       endAngle:-M_PI_2 + 2 * M_PI
                                                      clockwise:YES];
    self.trackLayer.frame = self.bounds;
    self.progressLayer.frame = self.bounds;
    self.trackLayer.path = path.CGPath;
    self.progressLayer.path = path.CGPath;
}

- (void)setProgress:(double)progress {
    _progress = MAX(0, MIN(1, progress));
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.25];
    self.progressLayer.strokeEnd = _progress;
    [CATransaction commit];
}

- (void)setShowProgress:(BOOL)show {
    _showProgress = show;
    self.trackLayer.hidden = !show;
    self.progressLayer.hidden = !show;
    if (show) self.progressLayer.strokeEnd = _progress;
}
@end

#pragma mark - Header

@interface SCIPAHeaderView : UIView
@property (nonatomic, strong) SCIPAAvatarRingView *avatar;
@property (nonatomic, strong) UILabel *fullNameLabel;
@property (nonatomic, strong) UILabel *usernameLabel;
@property (nonatomic, strong) UIStackView *statsRow;
@property (nonatomic, strong) UILabel *scanDateLabel;
@property (nonatomic, strong) UILabel *warningLabel;
@property (nonatomic, strong) UIButton *scanButton;
@property (nonatomic, strong) UIButton *cancelButton;
@property (nonatomic, strong) UIStackView *buttonRow;
@property (nonatomic, strong) UILabel *progressLabel;
@end

@implementation SCIPAHeaderView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return self;
    self.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.layer.cornerRadius = 18;

    _avatar = [[SCIPAAvatarRingView alloc] init];
    _avatar.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_avatar];

    _fullNameLabel = [UILabel new];
    _fullNameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _fullNameLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
    _fullNameLabel.textColor = [UIColor labelColor];
    _fullNameLabel.textAlignment = NSTextAlignmentCenter;
    [self addSubview:_fullNameLabel];

    _usernameLabel = [UILabel new];
    _usernameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _usernameLabel.font = [UIFont systemFontOfSize:14];
    _usernameLabel.textColor = [UIColor secondaryLabelColor];
    _usernameLabel.textAlignment = NSTextAlignmentCenter;
    [self addSubview:_usernameLabel];

    _statsRow = [[UIStackView alloc] init];
    _statsRow.translatesAutoresizingMaskIntoConstraints = NO;
    _statsRow.axis = UILayoutConstraintAxisHorizontal;
    _statsRow.distribution = UIStackViewDistributionFillEqually;
    _statsRow.spacing = 0;
    [self addSubview:_statsRow];

    _scanDateLabel = [UILabel new];
    _scanDateLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _scanDateLabel.font = [UIFont systemFontOfSize:12];
    _scanDateLabel.textColor = [UIColor tertiaryLabelColor];
    _scanDateLabel.textAlignment = NSTextAlignmentCenter;
    [self addSubview:_scanDateLabel];

    _warningLabel = [UILabel new];
    _warningLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _warningLabel.font = [UIFont systemFontOfSize:12];
    _warningLabel.textColor = [UIColor systemOrangeColor];
    _warningLabel.numberOfLines = 0;
    _warningLabel.textAlignment = NSTextAlignmentCenter;
    _warningLabel.hidden = YES;
    [self addSubview:_warningLabel];

    _scanButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _scanButton.translatesAutoresizingMaskIntoConstraints = NO;
    _scanButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _scanButton.backgroundColor = [SCIUtils SCIColor_Primary] ?: [UIColor systemBlueColor];
    [_scanButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _scanButton.layer.cornerRadius = 18;
    _scanButton.contentEdgeInsets = UIEdgeInsetsMake(0, 22, 0, 22);
    [_scanButton setTitle:SCILocalized(@"Run analysis") forState:UIControlStateNormal];

    _cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    _cancelButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _cancelButton.backgroundColor = [UIColor systemRedColor];
    [_cancelButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _cancelButton.layer.cornerRadius = 18;
    _cancelButton.contentEdgeInsets = UIEdgeInsetsMake(0, 18, 0, 18);
    [_cancelButton setTitle:SCILocalized(@"Cancel") forState:UIControlStateNormal];
    _cancelButton.hidden = YES;

    _buttonRow = [[UIStackView alloc] initWithArrangedSubviews:@[_scanButton, _cancelButton]];
    _buttonRow.translatesAutoresizingMaskIntoConstraints = NO;
    _buttonRow.axis = UILayoutConstraintAxisHorizontal;
    _buttonRow.spacing = 8;
    _buttonRow.alignment = UIStackViewAlignmentCenter;
    _buttonRow.distribution = UIStackViewDistributionFillProportionally;
    [self addSubview:_buttonRow];

    _progressLabel = [UILabel new];
    _progressLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _progressLabel.font = [UIFont systemFontOfSize:12];
    _progressLabel.textColor = [UIColor secondaryLabelColor];
    _progressLabel.textAlignment = NSTextAlignmentCenter;
    _progressLabel.numberOfLines = 2;
    _progressLabel.hidden = YES;
    [self addSubview:_progressLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_avatar.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_avatar.topAnchor constraintEqualToAnchor:self.topAnchor constant:18],
        [_avatar.widthAnchor constraintEqualToConstant:96],
        [_avatar.heightAnchor constraintEqualToConstant:96],

        [_fullNameLabel.topAnchor constraintEqualToAnchor:_avatar.bottomAnchor constant:10],
        [_fullNameLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [_fullNameLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],

        [_usernameLabel.topAnchor constraintEqualToAnchor:_fullNameLabel.bottomAnchor constant:2],
        [_usernameLabel.leadingAnchor constraintEqualToAnchor:_fullNameLabel.leadingAnchor],
        [_usernameLabel.trailingAnchor constraintEqualToAnchor:_fullNameLabel.trailingAnchor],

        [_statsRow.topAnchor constraintEqualToAnchor:_usernameLabel.bottomAnchor constant:14],
        [_statsRow.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
        [_statsRow.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
        [_statsRow.heightAnchor constraintEqualToConstant:44],

        [_scanDateLabel.topAnchor constraintEqualToAnchor:_statsRow.bottomAnchor constant:10],
        [_scanDateLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [_scanDateLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],

        [_warningLabel.topAnchor constraintEqualToAnchor:_scanDateLabel.bottomAnchor constant:6],
        [_warningLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:20],
        [_warningLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-20],

        [_scanButton.heightAnchor constraintEqualToConstant:36],
        [_scanButton.widthAnchor constraintGreaterThanOrEqualToConstant:120],
        [_cancelButton.heightAnchor constraintEqualToConstant:36],
        [_cancelButton.widthAnchor constraintGreaterThanOrEqualToConstant:96],

        [_buttonRow.topAnchor constraintEqualToAnchor:_warningLabel.bottomAnchor constant:12],
        [_buttonRow.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_buttonRow.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor constant:16],
        [_buttonRow.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-16],

        [_progressLabel.topAnchor constraintEqualToAnchor:_buttonRow.bottomAnchor constant:6],
        [_progressLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [_progressLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        [_progressLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-16],
    ]];
    return self;
}

- (void)setStatsLabelsPosts:(NSString *)posts followers:(NSString *)followers following:(NSString *)following {
    for (UIView *v in self.statsRow.arrangedSubviews) [self.statsRow removeArrangedSubview:v], [v removeFromSuperview];
    [self.statsRow addArrangedSubview:[self statColumn:posts caption:SCILocalized(@"Posts")]];
    [self.statsRow addArrangedSubview:[self statColumn:followers caption:SCILocalized(@"Followers")]];
    [self.statsRow addArrangedSubview:[self statColumn:following caption:SCILocalized(@"Following")]];
}

- (UIView *)statColumn:(NSString *)value caption:(NSString *)caption {
    UIView *w = [UIView new];
    UILabel *v = [UILabel new];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    v.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    v.textColor = [UIColor labelColor];
    v.textAlignment = NSTextAlignmentCenter;
    v.text = value;
    [w addSubview:v];

    UILabel *c = [UILabel new];
    c.translatesAutoresizingMaskIntoConstraints = NO;
    c.font = [UIFont systemFontOfSize:12];
    c.textColor = [UIColor secondaryLabelColor];
    c.textAlignment = NSTextAlignmentCenter;
    c.text = caption;
    [w addSubview:c];

    [NSLayoutConstraint activateConstraints:@[
        [v.topAnchor constraintEqualToAnchor:w.topAnchor],
        [v.leadingAnchor constraintEqualToAnchor:w.leadingAnchor],
        [v.trailingAnchor constraintEqualToAnchor:w.trailingAnchor],
        [c.topAnchor constraintEqualToAnchor:v.bottomAnchor constant:1],
        [c.leadingAnchor constraintEqualToAnchor:w.leadingAnchor],
        [c.trailingAnchor constraintEqualToAnchor:w.trailingAnchor],
        [c.bottomAnchor constraintEqualToAnchor:w.bottomAnchor],
    ]];
    return w;
}
@end

#pragma mark - Category cell

@interface SCIPACategoryCell : UITableViewCell
@property (nonatomic, strong) UIView *iconBadge;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UILabel *countLabel;
@end

@implementation SCIPACategoryCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
    self = [super initWithStyle:style reuseIdentifier:rid];
    if (!self) return self;
    self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    _iconBadge = [UIView new];
    _iconBadge.translatesAutoresizingMaskIntoConstraints = NO;
    _iconBadge.layer.cornerRadius = 8;
    [self.contentView addSubview:_iconBadge];

    _iconView = [UIImageView new];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    _iconView.tintColor = [UIColor whiteColor];
    [_iconBadge addSubview:_iconView];

    _titleLabel = [UILabel new];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [UIFont systemFontOfSize:16];
    [self.contentView addSubview:_titleLabel];

    _subtitleLabel = [UILabel new];
    _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _subtitleLabel.font = [UIFont systemFontOfSize:12];
    _subtitleLabel.textColor = [UIColor tertiaryLabelColor];
    [self.contentView addSubview:_subtitleLabel];

    _countLabel = [UILabel new];
    _countLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _countLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _countLabel.textColor = [UIColor secondaryLabelColor];
    _countLabel.textAlignment = NSTextAlignmentRight;
    [self.contentView addSubview:_countLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_iconBadge.leadingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.leadingAnchor],
        [_iconBadge.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_iconBadge.widthAnchor constraintEqualToConstant:32],
        [_iconBadge.heightAnchor constraintEqualToConstant:32],

        [_iconView.centerXAnchor constraintEqualToAnchor:_iconBadge.centerXAnchor],
        [_iconView.centerYAnchor constraintEqualToAnchor:_iconBadge.centerYAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:18],
        [_iconView.heightAnchor constraintEqualToConstant:18],

        [_titleLabel.leadingAnchor constraintEqualToAnchor:_iconBadge.trailingAnchor constant:12],
        [_titleLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:10],
        [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_countLabel.leadingAnchor constant:-8],

        [_subtitleLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_subtitleLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:1],
        [_subtitleLabel.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],
        [_subtitleLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-10],

        [_countLabel.trailingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.trailingAnchor],
        [_countLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_countLabel.widthAnchor constraintGreaterThanOrEqualToConstant:40],
    ]];
    return self;
}
@end

#pragma mark - Main VC

@interface SCIProfileAnalyzerViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *headerContainer;
@property (nonatomic, strong) SCIPAHeaderView *headerView;

@property (nonatomic, strong) SCIProfileAnalyzerReport *report;
@property (nonatomic, strong) NSArray<SCIPACategoryDescriptor *> *categories;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, copy) NSString *partialNotice;
@property (nonatomic, copy) NSString *lastHeaderPK;
@property (nonatomic, assign) BOOL pendingHeaderFetch;
@end

@implementation SCIProfileAnalyzerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.title = SCILocalized(@"Profile Analyzer");
    self.navigationItem.titleView = [self buildTitleViewWithBeta];

    [self setupTable];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(analyzerDataChanged:)
                                                 name:SCIProfileAnalyzerDataDidChangeNotification
                                               object:nil];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (void)analyzerDataChanged:(NSNotification *)note {
    if (self.running || [SCIProfileAnalyzerService sharedService].isRunning) return;
    if (!self.isViewLoaded || !self.view.window) return;
    NSString *pk = note.userInfo[@"user_pk"];
    NSString *current = [SCIUtils currentUserPK];
    if (pk.length && current.length && ![pk isEqualToString:current]) return;
    @try {
        [self loadCachedReport];
        SCIProfileAnalyzerSnapshot *cur = self.report.current;
        if (cur) {
            [self.headerView setStatsLabelsPosts:[self compactNumber:cur.mediaCount]
                                      followers:[self compactNumber:cur.followerCount]
                                      following:[self compactNumber:cur.followingCount]];
        }
    } @catch (__unused NSException *e) {}
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    @try {
        SCIProfileAnalyzerService *svc = [SCIProfileAnalyzerService sharedService];
        if (svc.isRunning) {
            self.running = YES;
            if (svc.liveSnapshot) [self showPartialSnapshot:svc.liveSnapshot];
            else [self loadCachedReport];
            [self syncRunButtons];
        } else {
            [self loadCachedReport];
        }
    } @catch (__unused NSException *e) {}
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // Header merge + any network fetch wait until the transition settles.
    @try { [self loadHeaderLayered]; } @catch (__unused NSException *e) {}
    if (self.pendingHeaderFetch) {
        self.pendingHeaderFetch = NO;
        @try { [self fetchAndCacheHeader]; } @catch (__unused NSException *e) {}
    }
}

- (UIView *)buildTitleViewWithBeta {
    UILabel *title = [UILabel new];
    title.text = SCILocalized(@"Profile Analyzer");
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    title.textColor = [UIColor labelColor];

    UILabel *beta = [UILabel new];
    beta.text = @" BETA ";
    beta.font = [UIFont systemFontOfSize:10 weight:UIFontWeightHeavy];
    beta.textColor = [UIColor whiteColor];
    beta.backgroundColor = [UIColor systemOrangeColor];
    beta.layer.cornerRadius = 5;
    beta.layer.masksToBounds = YES;
    beta.textAlignment = NSTextAlignmentCenter;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[title, beta]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 6;
    return row;
}

- (void)setupTable {
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.sectionHeaderTopPadding = 0;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 60;
    [self.tableView registerClass:[SCIPACategoryCell class] forCellReuseIdentifier:@"cat"];

    UIRefreshControl *rc = [UIRefreshControl new];
    [rc addTarget:self action:@selector(pullToRefreshProfile:) forControlEvents:UIControlEventValueChanged];
    self.tableView.refreshControl = rc;

    [self.view addSubview:self.tableView];
    [self buildTableHeader];
}

// Pull-to-refresh: re-fetch just the self-profile (/users/{pk}/info/) so the
// header reflects IG's truth on demand. No rescan, no data reset.
- (void)pullToRefreshProfile:(UIRefreshControl *)sender {
    NSString *pk = [SCIUtils currentUserPK];
    if (!pk.length) { [sender endRefreshing]; return; }
    __weak typeof(self) weakSelf = self;
    [SCIInstagramAPI sendRequestWithMethod:@"GET"
                                      path:[NSString stringWithFormat:@"users/%@/info/", pk]
                                      body:nil
                                completion:^(NSDictionary *resp, NSError *error) {
        NSDictionary *user = [resp[@"user"] isKindOfClass:[NSDictionary class]] ? resp[@"user"] : nil;
        if (user.count) {
            [SCIProfileAnalyzerStorage saveHeaderInfo:user forUserPK:pk];
            typeof(self) strongSelf = weakSelf;
            if (strongSelf.isViewLoaded && strongSelf.view.window) {
                [strongSelf paintHeaderFromUserInfo:user];
            }
        }
        [sender endRefreshing];
    }];
}

- (void)buildTableHeader {
    // tableHeaderView is frame-driven; let viewWillLayoutSubviews set width.
    self.headerContainer = [UIView new];
    self.headerContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    self.headerView = [[SCIPAHeaderView alloc] init];
    self.headerView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.headerContainer addSubview:self.headerView];

    [self.headerView.scanButton addTarget:self action:@selector(analyzeTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.headerView.cancelButton addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];

    [NSLayoutConstraint activateConstraints:@[
        [self.headerView.topAnchor constraintEqualToAnchor:self.headerContainer.topAnchor constant:12],
        [self.headerView.leadingAnchor constraintEqualToAnchor:self.headerContainer.leadingAnchor constant:16],
        [self.headerView.trailingAnchor constraintEqualToAnchor:self.headerContainer.trailingAnchor constant:-16],
        [self.headerView.bottomAnchor constraintEqualToAnchor:self.headerContainer.bottomAnchor constant:-4],
    ]];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    if (!self.headerContainer) return;
    CGFloat w = self.tableView.bounds.size.width;
    if (w < 1) return;

    // Resolve internal height against the tableView's width.
    self.headerContainer.frame = CGRectMake(0, 0, w, 1);
    [self.headerContainer setNeedsLayout];
    [self.headerContainer layoutIfNeeded];
    CGFloat h = [self.headerContainer systemLayoutSizeFittingSize:CGSizeMake(w, UILayoutFittingCompressedSize.height)
                                    withHorizontalFittingPriority:UILayoutPriorityRequired
                                          verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
    CGRect target = CGRectMake(0, 0, w, h);
    if (!CGRectEqualToRect(self.headerContainer.frame, target)) {
        self.headerContainer.frame = target;
        self.tableView.tableHeaderView = self.headerContainer;
    } else if (self.tableView.tableHeaderView != self.headerContainer) {
        self.tableView.tableHeaderView = self.headerContainer;
    }
}

#pragma mark - Header resolution (IG memory → our cache → network)

// Layered header lookup: IG fieldCache → on-disk cache → network (only when
// neither source has usable counts). Results get persisted so cold relaunch
// is offline.
- (void)loadHeaderLayered {
    NSString *pk = [SCIUtils currentUserPK];
    self.lastHeaderPK = pk;

    NSDictionary *live = [self liveSelfInfoFromSession];
    NSMutableDictionary *cached = [[SCIProfileAnalyzerStorage headerInfoForUserPK:pk] mutableCopy]
                                ?: [NSMutableDictionary dictionary];
    SCIProfileAnalyzerSnapshot *snap = self.report.current;

    // Hybrid reconciliation for following_count:
    //   * snapshot.followingCount captures in-app follow/unfollow mutations.
    //   * IG's fieldCache only refreshes when the user visits own profile.
    // We store the last fieldCache value we saw; when it moves, IG refreshed
    // and is authoritative — we align the snapshot to match. Otherwise the
    // snapshot (possibly just mutated) wins so unfollows show up live.
    NSNumber *liveFollowing = live[@"following_count"];
    NSNumber *lastSeenFollowing = cached[@"last_synced_following_count"];
    BOOL fieldCacheRefreshed = liveFollowing && (!lastSeenFollowing || ![liveFollowing isEqual:lastSeenFollowing]);
    if (fieldCacheRefreshed) {
        cached[@"following_count"] = liveFollowing;
        cached[@"last_synced_following_count"] = liveFollowing;
        if (snap && snap.followingCount != liveFollowing.integerValue) {
            snap.followingCount = liveFollowing.integerValue;
            [SCIProfileAnalyzerStorage updateCurrentSnapshot:snap forUserPK:pk];
        }
    } else if (snap && snap.followingCount > 0) {
        cached[@"following_count"] = @(snap.followingCount);
    } else if (liveFollowing) {
        cached[@"following_count"] = liveFollowing;
    }

    // Non-mutable-in-app fields: fieldCache wins when present.
    for (NSString *k in @[@"username", @"full_name", @"profile_pic_url",
                          @"profile_pic_id", @"follower_count", @"media_count"]) {
        if (live[k]) cached[k] = live[k];
    }
    // Fallbacks from snapshot if fieldCache lacks them entirely.
    if (snap && !cached[@"follower_count"] && snap.followerCount > 0) cached[@"follower_count"] = @(snap.followerCount);
    if (snap && !cached[@"media_count"]    && snap.mediaCount > 0)    cached[@"media_count"]    = @(snap.mediaCount);

    if (cached[@"username"] || [cached[@"follower_count"] integerValue] > 0) {
        [self paintHeaderFromUserInfo:cached];
    } else if (!snap) {
        self.headerView.fullNameLabel.text = SCILocalized(@"No scan yet");
        self.headerView.usernameLabel.text = @"";
        [self.headerView setStatsLabelsPosts:@"—" followers:@"—" following:@"—"];
    }

    BOOL haveCounts = [cached[@"follower_count"] integerValue] > 0
                   || [cached[@"following_count"] integerValue] > 0
                   || [cached[@"media_count"] integerValue] > 0;
    if (haveCounts) {
        [SCIProfileAnalyzerStorage saveHeaderInfo:cached forUserPK:pk];
    } else {
        // Defer to next runloop so the push transition can complete before
        // any completion-block layout mutations.
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakSelf.isViewLoaded && weakSelf.view.window) {
                [weakSelf fetchAndCacheHeader];
            } else {
                weakSelf.pendingHeaderFetch = YES;
            }
        });
    }
}

- (NSDictionary *)liveSelfInfoFromSession {
    id session = [SCIUtils activeUserSession];
    id igUser = nil;
    @try { if ([session respondsToSelector:@selector(user)]) igUser = [session valueForKey:@"user"]; } @catch (__unused id e) {}
    NSDictionary *fc = [self fieldCacheForUser:igUser];
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSString *k in @[@"username", @"full_name", @"profile_pic_url",
                          @"follower_count", @"following_count", @"media_count"]) {
        if (fc[k]) out[k] = fc[k];
    }
    return out;
}

- (void)fetchAndCacheHeader {
    NSString *pk = self.lastHeaderPK;
    if (!pk.length) return;
    __weak typeof(self) weakSelf = self;
    [SCIInstagramAPI sendRequestWithMethod:@"GET"
                                      path:[NSString stringWithFormat:@"users/%@/info/", pk]
                                      body:nil
                                completion:^(NSDictionary *resp, NSError *error) {
        NSDictionary *user = [resp[@"user"] isKindOfClass:[NSDictionary class]] ? resp[@"user"] : nil;
        if (!user.count) return;
        [SCIProfileAnalyzerStorage saveHeaderInfo:user forUserPK:pk];
        typeof(self) strongSelf = weakSelf;
        // Drop UI updates if the VC left the window between send + callback.
        if (!strongSelf.isViewLoaded || !strongSelf.view.window) return;
        [strongSelf paintHeaderFromUserInfo:user];
    }];
}

- (NSDictionary *)fieldCacheForUser:(id)user {
    if (!user) return @{};
    Ivar iv = NULL;
    for (Class c = [user class]; c && !iv; c = class_getSuperclass(c))
        iv = class_getInstanceVariable(c, "_fieldCache");
    if (!iv) return @{};
    id d = object_getIvar(user, iv);
    return [d isKindOfClass:[NSDictionary class]] ? d : @{};
}

- (NSString *)compactNumber:(NSInteger)n {
    if (n < 1000) return [NSString stringWithFormat:@"%ld", (long)n];
    if (n < 10000) return [NSString stringWithFormat:@"%.1fK", n / 1000.0];
    if (n < 1000000) return [NSString stringWithFormat:@"%ldK", (long)(n / 1000)];
    return [NSString stringWithFormat:@"%.1fM", n / 1000000.0];
}

#pragma mark - Data

- (void)loadCachedReport {
    NSString *pk = [SCIUtils currentUserPK];
    SCIProfileAnalyzerSnapshot *cur = [SCIProfileAnalyzerStorage currentSnapshotForUserPK:pk];
    self.report = [SCIProfileAnalyzerReport reportFromCurrent:cur previous:nil];
    [self rebuildCategories];
    [self refreshHeader];
    [self.tableView reloadData];
}

- (void)rebuildCategories {
    SCIProfileAnalyzerReport *r = self.report;
    NSArray<SCIPACategoryDescriptor *> *(^build)(void) = ^NSArray *{
        SCIPACategoryDescriptor *(^make)(SCIPACategory, NSString *, NSString *, NSString *, UIColor *, NSInteger, BOOL) =
        ^SCIPACategoryDescriptor *(SCIPACategory c, NSString *t, NSString *s, NSString *sym, UIColor *col, NSInteger count, BOOL needsPrev) {
            SCIPACategoryDescriptor *d = [SCIPACategoryDescriptor new];
            d.category = c; d.title = t; d.subtitle = s; d.symbol = sym; d.color = col;
            d.count = count; d.requiresPrevious = needsPrev;
            return d;
        };
        return @[
            make(SCIPACategoryMutual, SCILocalized(@"Mutuals"),
                 SCILocalized(@"You follow each other"),
                 @"person.2.fill", [UIColor systemBlueColor], r.mutualFollowers.count, NO),
            make(SCIPACategoryNotFollowingBack, SCILocalized(@"Not following you back"),
                 SCILocalized(@"You follow them, they don't follow back"),
                 @"person.fill.xmark", [UIColor systemOrangeColor], r.notFollowingYouBack.count, NO),
        ];
    };
    self.categories = build();
}

// Snapshot-backed paint: only scan-date + warning. Identity + stats + avatar
// are owned by loadHeaderLayered so fieldCache always wins.
- (void)refreshHeader {
    self.headerView.scanDateLabel.text = self.report.current
        ? [self scanDateText]
        : SCILocalized(@"Run your first analysis");
    [self refreshWarning];
}

- (NSString *)scanDateText {
    if (!self.report.current.scanDate) return @"";
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateStyle = NSDateFormatterMediumStyle;
    f.timeStyle = NSDateFormatterShortStyle;
    NSString *when = [f stringFromDate:self.report.current.scanDate];
    if (self.report.previous) return [NSString stringWithFormat:SCILocalized(@"Last scan: %@"), when];
    return [NSString stringWithFormat:SCILocalized(@"First scan: %@"), when];
}

- (void)refreshWarning {
    BOOL show = self.partialNotice.length > 0 && !self.running;
    self.headerView.warningLabel.hidden = !show;
    self.headerView.warningLabel.text = show ? self.partialNotice : @"";
    if (!self.running) [self syncRunButtons];
    [self.view setNeedsLayout];
}

- (void)syncRunButtons {
    SCIProfileAnalyzerService *svc = [SCIProfileAnalyzerService sharedService];
    UIButton *scan = self.headerView.scanButton;
    UIButton *cancel = self.headerView.cancelButton;
    scan.enabled = YES;
    scan.alpha = 1;
    if (!self.running) {
        cancel.hidden = YES;
        [scan setTitle:SCILocalized(@"Run analysis") forState:UIControlStateNormal];
        scan.backgroundColor = [SCIUtils SCIColor_Primary] ?: [UIColor systemBlueColor];
        self.headerView.progressLabel.hidden = YES;
        [self.headerView.avatar setShowProgress:NO];
        [self.view setNeedsLayout];
        return;
    }
    cancel.hidden = NO;
    self.headerView.progressLabel.hidden = NO;
    [self.headerView.avatar setShowProgress:YES];
    if (svc.isPaused) {
        [scan setTitle:SCILocalized(@"Resume") forState:UIControlStateNormal];
        scan.backgroundColor = [SCIUtils SCIColor_Primary] ?: [UIColor systemBlueColor];
    } else {
        [scan setTitle:SCILocalized(@"Pause") forState:UIControlStateNormal];
        scan.backgroundColor = [UIColor systemOrangeColor];
    }
    [self.view setNeedsLayout];
}

#pragma mark - Actions

- (void)analyzeTapped {
    SCIProfileAnalyzerService *svc = [SCIProfileAnalyzerService sharedService];
    if (self.running) {
        if (svc.isPaused) [svc resume];
        else [svc pause];
        [self syncRunButtons];
        if (svc.isPaused) self.headerView.progressLabel.text = SCILocalized(@"Paused");
        return;
    }
    self.running = YES;
    self.partialNotice = nil;
    self.headerView.warningLabel.hidden = YES;
    self.headerView.progressLabel.hidden = NO;
    self.headerView.progressLabel.text = SCILocalized(@"Starting…");
    [self.headerView.avatar setShowProgress:YES];
    self.headerView.avatar.progress = 0;
    [self syncRunButtons];
    [self.view setNeedsLayout];

    __weak typeof(self) weakSelf = self;
    [svc runForSelfWithHeaderInfo:^(NSDictionary *userInfo) {
        [weakSelf paintHeaderFromUserInfo:userInfo];
    } progress:^(NSString *status, double fraction) {
        if (!weakSelf.running) return;
        weakSelf.headerView.progressLabel.text = status;
        if (fraction >= 0) weakSelf.headerView.avatar.progress = fraction;
        [weakSelf syncRunButtons];
    } incremental:^(SCIProfileAnalyzerSnapshot *snapshot) {
        [weakSelf showPartialSnapshot:snapshot];
    } completion:^(SCIProfileAnalyzerSnapshot *snapshot, NSError *error) {
        [weakSelf onAnalysisFinished:snapshot error:error];
    }];
}

- (void)cancelTapped {
    if (!self.running) return;
    [[SCIProfileAnalyzerService sharedService] cancel];
}

- (void)showPartialSnapshot:(SCIProfileAnalyzerSnapshot *)snapshot {
    if (![snapshot isKindOfClass:[SCIProfileAnalyzerSnapshot class]]) return;
    self.report = [SCIProfileAnalyzerReport reportFromCurrent:snapshot previous:nil];
    [self rebuildCategories];
    if (self.isViewLoaded) [self.tableView reloadData];
}

- (void)paintHeaderFromUserInfo:(NSDictionary *)user {
    if (![user isKindOfClass:[NSDictionary class]]) return;
    NSString *username = user[@"username"];
    NSString *fullName = user[@"full_name"];
    NSString *picURL = user[@"profile_pic_url"];
    NSInteger followers = [user[@"follower_count"] integerValue];
    NSInteger following = [user[@"following_count"] integerValue];
    NSInteger posts = [user[@"media_count"] integerValue];
    self.headerView.fullNameLabel.text = fullName.length ? fullName : (username.length ? username : SCILocalized(@"No scan yet"));
    self.headerView.usernameLabel.text = username.length ? [NSString stringWithFormat:@"@%@", username] : @"";
    [self.headerView setStatsLabelsPosts:[self compactNumber:posts]
                              followers:[self compactNumber:followers]
                              following:[self compactNumber:following]];
    if (picURL.length) {
        __weak UIImageView *iv = self.headerView.avatar.imageView;
        [SCIImageCache loadImageFromURL:[NSURL URLWithString:picURL] completion:^(UIImage *img) {
            if (img) iv.image = img;
        }];
    }
}

- (void)onAnalysisFinished:(SCIProfileAnalyzerSnapshot *)snapshot error:(NSError *)error {
    self.running = NO;
    [self syncRunButtons];
    [self.view setNeedsLayout];

    if (snapshot) {
        NSString *pk = [SCIUtils currentUserPK];
        [SCIProfileAnalyzerStorage saveHeaderInfo:@{
            @"username": snapshot.selfUsername ?: @"",
            @"full_name": snapshot.selfFullName ?: @"",
            @"profile_pic_url": snapshot.selfProfilePicURL ?: @"",
            @"follower_count": @(snapshot.followerCount),
            @"following_count": @(snapshot.followingCount),
            @"media_count": @(snapshot.mediaCount),
        } forUserPK:pk];
        [self showPartialSnapshot:snapshot];
        [self refreshHeader];
        SCIProfileAnalyzerReport *done = self.report;
        NSString *counts = [NSString stringWithFormat:SCILocalized(@"%lu mutuals · %lu not following you back"),
                            (unsigned long)done.mutualFollowers.count,
                            (unsigned long)done.notFollowingYouBack.count];
        if (error) {
            self.partialNotice = error.localizedDescription.length ? error.localizedDescription : counts;
            [self refreshWarning];
            [SCIUtils showToastForDuration:2.4 title:SCILocalized(@"Analysis failed") subtitle:self.partialNotice];
        } else {
            self.partialNotice = nil;
            [self refreshWarning];
            [SCIUtils showToastForDuration:2.0 title:SCILocalized(@"Analysis complete") subtitle:counts];
        }
        return;
    }

    self.partialNotice = nil;
    [self loadCachedReport];
    if (error && error.code != SCIProfileAnalyzerErrorCancelled) {
        [self alertTitle:SCILocalized(@"Analysis failed") message:error.localizedDescription ?: @""];
    }
}

- (void)resetTapped {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:SCILocalized(@"Reset analyzer data?")
                                                              message:SCILocalized(@"Removes the saved following analysis for this account.")
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:SCILocalized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:SCILocalized(@"Reset") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *_) {
        [SCIProfileAnalyzerStorage resetForUserPK:[SCIUtils currentUserPK]];
        [self loadCachedReport];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)infoTapped {
    NSString *body = [@[
        SCILocalized(@"Profile Analyzer reads only who you follow. It does not download your followers."),
        SCILocalized(@"Someone you follow is a mutual when Instagram says they follow you back."),
        SCILocalized(@"Results stay on this device. The trash icon clears them."),
        SCILocalized(@"Long following lists are loaded slowly, with a pause between pages. A rate limit waits and then resumes."),
        SCILocalized(@"Follow-back checks are saved on this device. The next run only asks about new accounts."),
        SCILocalized(@"Pause and Cancel keep the accounts already checked on screen."),
    ] componentsJoinedByString:@"\n\n"];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:SCILocalized(@"About Profile Analyzer") message:body preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:SCILocalized(@"OK") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)alertTitle:(NSString *)title message:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:SCILocalized(@"OK") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return (NSInteger)self.categories.count;
    return 2;
}
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return SCILocalized(@"Categories");
    return @"";
}
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)section {
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 1) return [self actionCellForRow:indexPath.row tableView:tv];
    SCIPACategoryCell *cell = [tv dequeueReusableCellWithIdentifier:@"cat" forIndexPath:indexPath];
    SCIPACategoryDescriptor *d = self.categories[indexPath.row];
    BOOL waitingForPrev = d.requiresPrevious && !self.report.previous;
    BOOL hasReport = self.report.current != nil;
    BOOL disabled = waitingForPrev || !hasReport;

    cell.titleLabel.text = d.title;
    if (waitingForPrev) {
        cell.subtitleLabel.text = SCILocalized(@"Available after your next scan");
    } else if (self.running && d.count == 0) {
        cell.subtitleLabel.text = SCILocalized(@"Still checking who follows you back");
    } else {
        cell.subtitleLabel.text = d.subtitle;
    }
    cell.countLabel.text = (waitingForPrev || !hasReport) ? @"—" : [NSString stringWithFormat:@"%ld", (long)d.count];
    cell.iconBadge.backgroundColor = disabled ? [UIColor systemGray3Color] : d.color;
    cell.iconView.image = [UIImage systemImageNamed:d.symbol];
    cell.contentView.alpha = disabled ? 0.5 : 1.0;
    cell.selectionStyle = disabled ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tv deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1) {
        if (indexPath.row == 0) [self infoTapped];
        else [self resetTapped];
        return;
    }
    SCIPACategoryDescriptor *d = self.categories[indexPath.row];
    if (d.requiresPrevious && !self.report.previous) return;
    if (!self.report.current) return;
    [self.navigationController pushViewController:[self listVCForCategory:d] animated:YES];
}

- (UITableViewCell *)actionCellForRow:(NSInteger)row tableView:(UITableView *)tv {
    static NSString *rid = @"action";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:rid];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:rid];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.imageView.contentMode = UIViewContentModeCenter;
    if (row == 0) {
        cell.textLabel.text = SCILocalized(@"About Profile Analyzer");
        cell.textLabel.textColor = [SCIUtils SCIColor_Primary] ?: [UIColor systemBlueColor];
        cell.imageView.image = [UIImage systemImageNamed:@"info.circle"];
        cell.imageView.tintColor = cell.textLabel.textColor;
    } else {
        cell.textLabel.text = SCILocalized(@"Reset analyzer data");
        cell.textLabel.textColor = [UIColor systemRedColor];
        cell.imageView.image = [UIImage systemImageNamed:@"trash"];
        cell.imageView.tintColor = [UIColor systemRedColor];
    }
    return cell;
}

- (UIViewController *)listVCForCategory:(SCIPACategoryDescriptor *)d {
    SCIProfileAnalyzerReport *r = self.report;
    switch (d.category) {
        case SCIPACategoryMutual:
            return [[SCIProfileAnalyzerListViewController alloc] initWithTitle:d.title users:r.mutualFollowers kind:SCIPAListKindPlain];
        case SCIPACategoryNotFollowingBack:
            return [[SCIProfileAnalyzerListViewController alloc] initWithTitle:d.title users:r.notFollowingYouBack kind:SCIPAListKindUnfollow];
    }
    return nil;
}

@end
