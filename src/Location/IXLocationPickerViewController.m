#import "IXLocationPickerViewController.h"
#import "IXLocationStore.h"
#import "IXLocationHooks.h"

#import <MapKit/MapKit.h>

@interface IXLocationPickerViewController () <MKMapViewDelegate, UISearchBarDelegate>
@property (nonatomic) MKMapView *mapView;
@property (nonatomic) UISearchBar *searchBar;
@property (nonatomic) UILabel *placeLabel;
@property (nonatomic) UISwitch *enableSwitch;
@property (nonatomic) UISwitch *timezoneSwitch;
@property (nonatomic) UISwitch *localeSwitch;
@property (nonatomic) MKPointAnnotation *pin;
@property (nonatomic) NSTimeZone *pendingZone;
@property (nonatomic) NSString *pendingLocale;
@end

@implementation IXLocationPickerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Fake location";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectZero];
    self.searchBar.placeholder = @"Search for a place";
    self.searchBar.delegate = self;
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;

    self.mapView = [[MKMapView alloc] initWithFrame:CGRectZero];
    self.mapView.delegate = self;
    self.mapView.translatesAutoresizingMaskIntoConstraints = NO;
    self.mapView.showsUserLocation = ![IXLocationStore isEnabled];
    UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handlePress:)];
    [self.mapView addGestureRecognizer:press];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    [self.mapView addGestureRecognizer:tap];

    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor secondarySystemBackgroundColor];
    card.layer.cornerRadius = 16;

    self.placeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.placeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.placeLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    self.placeLabel.numberOfLines = 2;
    self.placeLabel.text = [IXLocationStore placeName];

    self.enableSwitch = [self switchRow];
    self.enableSwitch.on = [IXLocationStore isEnabled];
    [self.enableSwitch addTarget:self action:@selector(enableChanged:) forControlEvents:UIControlEventValueChanged];
    self.timezoneSwitch = [self switchRow];
    self.timezoneSwitch.on = [[NSUserDefaults standardUserDefaults] boolForKey:IXLocationTimezoneEnabledKey];
    [self.timezoneSwitch addTarget:self action:@selector(timezoneChanged:) forControlEvents:UIControlEventValueChanged];
    self.localeSwitch = [self switchRow];
    self.localeSwitch.on = [[NSUserDefaults standardUserDefaults] boolForKey:IXLocationLocaleEnabledKey];
    [self.localeSwitch addTarget:self action:@selector(localeChanged:) forControlEvents:UIControlEventValueChanged];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.placeLabel,
        [self row:@"Use this location" control:self.enableSwitch],
        [self row:@"Match timezone" control:self.timezoneSwitch],
        [self row:@"Match locale (optional)" control:self.localeSwitch]
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];

    [self.view addSubview:self.searchBar];
    [self.view addSubview:self.mapView];
    [self.view addSubview:card];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.searchBar.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.searchBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.searchBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.mapView.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor],
        [self.mapView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.mapView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [card.topAnchor constraintEqualToAnchor:self.mapView.bottomAnchor constant:8],
        [card.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [card.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [card.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8],
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12],
        [self.mapView.heightAnchor constraintGreaterThanOrEqualToConstant:220]
    ]];

    if ([IXLocationStore hasSavedCoordinate]) {
        [self dropPinAt:[IXLocationStore coordinate] name:[IXLocationStore placeName] select:YES];
    } else {
        [self.mapView setRegion:MKCoordinateRegionMake(CLLocationCoordinate2DMake(20, 0), MKCoordinateSpanMake(80, 80)) animated:NO];
    }
}

- (UISwitch *)switchRow {
    UISwitch *control = [[UISwitch alloc] initWithFrame:CGRectZero];
    control.onTintColor = [UIColor colorWithRed:0.35 green:0.75 blue:1 alpha:1];
    return control;
}

- (UIStackView *)row:(NSString *)title control:(UISwitch *)control {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = title;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[label, control]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    return row;
}

- (void)dropPinAt:(CLLocationCoordinate2D)coordinate name:(NSString *)name select:(BOOL)select {
    if (self.pin) [self.mapView removeAnnotation:self.pin];
    MKPointAnnotation *pin = [[MKPointAnnotation alloc] init];
    pin.coordinate = coordinate;
    pin.title = name.length ? name : @"Fake location";
    self.pin = pin;
    [self.mapView addAnnotation:pin];
    [IXLocationStore saveCoordinate:coordinate name:(name.length ? name : @"Dropped pin") timeZone:nil localeIdentifier:nil];
    if (select) {
        [self.mapView setRegion:MKCoordinateRegionMake(coordinate, MKCoordinateSpanMake(0.2, 0.2)) animated:YES];
    }
    [self reverseGeocode:coordinate fallback:name];
}

- (void)reverseGeocode:(CLLocationCoordinate2D)coordinate fallback:(NSString *)fallback {
    self.placeLabel.text = fallback.length ? fallback : @"Looking up that place…";
    CLLocation *location = [[CLLocation alloc] initWithLatitude:coordinate.latitude longitude:coordinate.longitude];
    CLGeocoder *geocoder = [[CLGeocoder alloc] init];
    __weak typeof(self) weakSelf = self;
    [geocoder reverseGeocodeLocation:location completionHandler:^(NSArray<CLPlacemark *> *marks, NSError *error) {
        typeof(self) self = weakSelf;
        if (!self) return;
        CLPlacemark *mark = marks.firstObject;
        NSString *name = mark.name ?: mark.locality ?: mark.country ?: fallback;
        if (!name.length) {
            name = [NSString stringWithFormat:@"%.5f, %.5f", coordinate.latitude, coordinate.longitude];
        }
        self.placeLabel.text = name;
        self.pin.title = name;
        self.pendingZone = mark.timeZone;
        if (mark.ISOcountryCode.length) {
            self.pendingLocale = [NSString stringWithFormat:@"en_%@", mark.ISOcountryCode];
        }
        [IXLocationStore saveCoordinate:coordinate name:name timeZone:mark.timeZone localeIdentifier:self.pendingLocale];
    }];
}

- (void)handlePress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    CGPoint point = [gesture locationInView:self.mapView];
    [self dropPinAt:[self.mapView convertPoint:point toCoordinateFromView:self.mapView] name:nil select:NO];
}

- (void)handleTap:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded) return;
    CGPoint point = [gesture locationInView:self.mapView];
    [self dropPinAt:[self.mapView convertPoint:point toCoordinateFromView:self.mapView] name:nil select:NO];
}

- (void)enableChanged:(UISwitch *)sender {
    if (sender.on && ![IXLocationStore hasSavedCoordinate]) {
        sender.on = NO;
        self.placeLabel.text = @"Drop a pin or search before enabling.";
        return;
    }
    [IXLocationStore setEnabled:sender.on];
    if (sender.on) IXLocationHooksInstall();
    self.mapView.showsUserLocation = !sender.on;
}

- (void)timezoneChanged:(UISwitch *)sender {
    [IXLocationStore setSpoofTimeZone:sender.on];
}

- (void)localeChanged:(UISwitch *)sender {
    [IXLocationStore setSpoofLocale:sender.on];
    if (sender.on) {
        self.placeLabel.text = [NSString stringWithFormat:@"%@\nLocale spoofing can change dates and text. Turn it off if Instagram looks wrong.", [IXLocationStore placeName]];
    }
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    NSString *query = [searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!query.length) return;
    MKLocalSearchRequest *request = [[MKLocalSearchRequest alloc] init];
    request.naturalLanguageQuery = query;
    request.region = self.mapView.region;
    MKLocalSearch *search = [[MKLocalSearch alloc] initWithRequest:request];
    __weak typeof(self) weakSelf = self;
    [search startWithCompletionHandler:^(MKLocalSearchResponse *response, NSError *error) {
        MKMapItem *item = response.mapItems.firstObject;
        if (!item) {
            weakSelf.placeLabel.text = error.localizedDescription ?: @"No places matched that search.";
            return;
        }
        [weakSelf dropPinAt:item.placemark.coordinate name:item.name select:YES];
    }];
}

@end
