#import "BrowserTabOverviewController.h"

#import "BrowserHomeView.h"
#import "BrowserTabViewModel.h"
#import "BrowserViewModel.h"

static CGFloat const kOverviewMaxContentWidth = 1560.0;
static CGFloat const kOverviewMinSideInset = 120.0;
static CGFloat const kOverviewHeaderTop = 70.0;
static CGFloat const kOverviewCollectionTop = 230.0;
static CGFloat const kOverviewBottomInset = 50.0;
static CGFloat const kTabCardWidth = 600.0;
static CGFloat const kTabCardThumbnailHeight = 338.0;
static CGFloat const kTabCardInfoTop = 24.0;
static CGFloat const kTabCardInfoHeight = 84.0;
static CGFloat const kTabCardHeight = kTabCardThumbnailHeight + kTabCardInfoTop + kTabCardInfoHeight;
static CGFloat const kTabCardSpacing = 56.0;
static CGFloat const kTabCardCornerRadius = 28.0;
static CGFloat const kTabCardFocusScale = 1.08;

static UIColor *BrowserOverviewAccentColor(void) {
    return [UIColor colorWithRed:0.23 green:0.57 blue:1.0 alpha:1.0];
}

static UIImage *BrowserOverviewSymbol(NSString *name, CGFloat pointSize, UIImageSymbolWeight weight) {
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:pointSize weight:weight];
    return [[UIImage systemImageNamed:name withConfiguration:configuration] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static NSString *BrowserOverviewDisplayAddress(NSString *URLString) {
    NSURL *URL = URLString.length > 0 ? [NSURL URLWithString:URLString] : nil;
    NSString *host = URL.host ?: @"";
    if ([host.lowercaseString hasPrefix:@"www."]) {
        host = [host substringFromIndex:4];
    }
    if (host.length == 0) {
        return URLString ?: @"";
    }
    NSString *path = [URL.path isEqualToString:@"/"] ? @"" : (URL.path ?: @"");
    return [host stringByAppendingString:path];
}

/// Small capsule with an SF Symbol and a label, used for badges and remote hints.
static UIView *BrowserOverviewChip(NSString *symbolName, NSString *text, UIColor *backgroundColor, UIColor *contentColor) {
    UIView *chip = [UIView new];
    chip.translatesAutoresizingMaskIntoConstraints = NO;
    chip.backgroundColor = backgroundColor;
    chip.layer.cornerRadius = 22.0;
    chip.userInteractionEnabled = NO;

    UIStackView *stack = [UIStackView new];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 10.0;
    [chip addSubview:stack];

    if (symbolName.length > 0) {
        UIImageView *iconView = [[UIImageView alloc] initWithImage:BrowserOverviewSymbol(symbolName, 20.0, UIImageSymbolWeightSemibold)];
        iconView.tintColor = contentColor;
        [stack addArrangedSubview:iconView];
    }
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = [UIFont systemFontOfSize:22.0 weight:UIFontWeightSemibold];
    label.textColor = contentColor;
    [stack addArrangedSubview:label];

    [NSLayoutConstraint activateConstraints:@[
        [chip.heightAnchor constraintEqualToConstant:44.0],
        [stack.leadingAnchor constraintEqualToAnchor:chip.leadingAnchor constant:18.0],
        [stack.trailingAnchor constraintEqualToAnchor:chip.trailingAnchor constant:-18.0],
        [stack.centerYAnchor constraintEqualToAnchor:chip.centerYAnchor],
    ]];
    return chip;
}

@class BrowserTabOverviewViewController;

@interface BrowserTabOverviewController ()

@property (nonatomic, weak) id<BrowserTabOverviewControllerHost> host;
@property (nonatomic) BrowserViewModel *viewModel;
@property (nonatomic, readwrite, getter=isVisible) BOOL visible;
@property (nonatomic) BOOL cursorModeBeforeShowing;
@property (nonatomic, weak) BrowserTabOverviewViewController *presentedOverviewViewController;

- (NSInteger)numberOfDisplayItems;
- (NSInteger)activeTabDisplayItemIndex;
- (nullable BrowserTabViewModel *)tabForDisplayItemIndex:(NSInteger)displayItemIndex;
- (void)handleSelectionForDisplayItemIndex:(NSInteger)displayItemIndex;
- (void)handleCloseRequestForDisplayItemIndex:(NSInteger)displayItemIndex;
- (void)handleAlternateAction;
- (void)reloadPresentedOverviewIfNeeded;
- (void)overviewViewControllerDidDisappear:(BrowserTabOverviewViewController *)viewController;

@end

#pragma mark - Card cell

@interface BrowserTabOverviewCollectionViewCell : UICollectionViewCell

- (void)configureAsAddCardWithLimitReached:(BOOL)limitReached maximumTabCount:(NSUInteger)maximumTabCount;
- (void)configureWithTab:(BrowserTabViewModel *)tab activeTab:(BOOL)activeTab canClose:(BOOL)canClose;

@end

@interface BrowserTabOverviewCollectionViewCell ()

@property (nonatomic) UIView *thumbnailContainerView;
@property (nonatomic) UIView *thumbnailClipView;
@property (nonatomic) CAGradientLayer *placeholderGradientLayer;
@property (nonatomic) UIImageView *placeholderIconView;
@property (nonatomic) UIImageView *thumbnailView;
@property (nonatomic) CAShapeLayer *dashedBorderLayer;
@property (nonatomic) UIView *currentBadgeView;
@property (nonatomic) UIView *closeHintView;
@property (nonatomic) UIView *infoView;
@property (nonatomic) BrowserSiteIconView *siteIconView;
@property (nonatomic) UIView *homeGlyphView;
@property (nonatomic) UILabel *titleLabel;
@property (nonatomic) UILabel *subtitleLabel;
@property (nonatomic) BOOL addCard;
@property (nonatomic) BOOL addCardDisabled;
@property (nonatomic) BOOL activeTab;
@property (nonatomic) BOOL canClose;

@end

@implementation BrowserTabOverviewCollectionViewCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.clipsToBounds = NO;
        self.contentView.clipsToBounds = NO;

        _thumbnailContainerView = [UIView new];
        _thumbnailContainerView.layer.shadowColor = UIColor.blackColor.CGColor;
        [self.contentView addSubview:_thumbnailContainerView];

        _thumbnailClipView = [UIView new];
        _thumbnailClipView.clipsToBounds = YES;
        _thumbnailClipView.layer.cornerRadius = kTabCardCornerRadius;
        [_thumbnailContainerView addSubview:_thumbnailClipView];

        _placeholderGradientLayer = [CAGradientLayer layer];
        _placeholderGradientLayer.colors = @[
            (id)[UIColor colorWithRed:0.17 green:0.18 blue:0.25 alpha:1.0].CGColor,
            (id)[UIColor colorWithRed:0.09 green:0.09 blue:0.13 alpha:1.0].CGColor,
        ];
        [_thumbnailClipView.layer addSublayer:_placeholderGradientLayer];

        _placeholderIconView = [UIImageView new];
        _placeholderIconView.contentMode = UIViewContentModeCenter;
        _placeholderIconView.tintColor = [UIColor colorWithWhite:1.0 alpha:0.45];
        [_thumbnailClipView addSubview:_placeholderIconView];

        _thumbnailView = [UIImageView new];
        _thumbnailView.contentMode = UIViewContentModeScaleToFill;
        [_thumbnailClipView addSubview:_thumbnailView];

        _dashedBorderLayer = [CAShapeLayer layer];
        _dashedBorderLayer.fillColor = UIColor.clearColor.CGColor;
        _dashedBorderLayer.lineWidth = 4.0;
        _dashedBorderLayer.lineDashPattern = @[@18, @12];
        [_thumbnailContainerView.layer addSublayer:_dashedBorderLayer];

        _currentBadgeView = BrowserOverviewChip(@"checkmark.circle.fill", @"Current", BrowserOverviewAccentColor(), UIColor.whiteColor);
        [_thumbnailContainerView addSubview:_currentBadgeView];

        _closeHintView = BrowserOverviewChip(@"playpause.fill", @"Close", [UIColor colorWithWhite:0.0 alpha:0.7], UIColor.whiteColor);
        [_thumbnailContainerView addSubview:_closeHintView];

        [NSLayoutConstraint activateConstraints:@[
            [_currentBadgeView.leadingAnchor constraintEqualToAnchor:_thumbnailContainerView.leadingAnchor constant:18.0],
            [_currentBadgeView.topAnchor constraintEqualToAnchor:_thumbnailContainerView.topAnchor constant:18.0],
            [_closeHintView.trailingAnchor constraintEqualToAnchor:_thumbnailContainerView.trailingAnchor constant:-18.0],
            [_closeHintView.topAnchor constraintEqualToAnchor:_thumbnailContainerView.topAnchor constant:18.0],
        ]];

        _infoView = [UIView new];
        [self.contentView addSubview:_infoView];

        _siteIconView = [BrowserSiteIconView new];
        [_infoView addSubview:_siteIconView];

        _homeGlyphView = [UIView new];
        _homeGlyphView.backgroundColor = BrowserOverviewAccentColor();
        _homeGlyphView.layer.cornerRadius = 13.0;
        UIImageView *houseView = [[UIImageView alloc] initWithImage:BrowserOverviewSymbol(@"house.fill", 24.0, UIImageSymbolWeightSemibold)];
        houseView.tintColor = UIColor.whiteColor;
        houseView.contentMode = UIViewContentModeCenter;
        houseView.frame = CGRectMake(0.0, 0.0, 54.0, 54.0);
        [_homeGlyphView addSubview:houseView];
        [_infoView addSubview:_homeGlyphView];

        _titleLabel = [UILabel new];
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [_infoView addSubview:_titleLabel];

        _subtitleLabel = [UILabel new];
        _subtitleLabel.font = [UIFont systemFontOfSize:24.0 weight:UIFontWeightRegular];
        _subtitleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [_infoView addSubview:_subtitleLabel];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.thumbnailView.image = nil;
}

- (void)configureAsAddCardWithLimitReached:(BOOL)limitReached maximumTabCount:(NSUInteger)maximumTabCount {
    self.addCard = YES;
    self.addCardDisabled = limitReached;
    self.activeTab = NO;
    self.canClose = NO;
    self.thumbnailView.image = nil;
    self.placeholderIconView.image = BrowserOverviewSymbol(@"plus", 84.0, UIImageSymbolWeightLight);
    self.siteIconView.hidden = YES;
    self.homeGlyphView.hidden = YES;
    self.titleLabel.text = @"New Tab";
    self.subtitleLabel.text = limitReached
        ? [NSString stringWithFormat:@"Limit of %lu tabs reached", (unsigned long)maximumTabCount]
        : @"Opens your Home page";
    self.accessibilityLabel = @"New Tab";
    [self setNeedsLayout];
    [self updateAppearance];
}

- (void)configureWithTab:(BrowserTabViewModel *)tab activeTab:(BOOL)activeTab canClose:(BOOL)canClose {
    self.addCard = NO;
    self.addCardDisabled = NO;
    self.activeTab = activeTab;
    self.canClose = canClose;
    self.thumbnailView.image = tab.snapshotImage;
    self.placeholderIconView.image = BrowserOverviewSymbol(tab.showingHome ? @"house" : @"globe", 72.0, UIImageSymbolWeightLight);

    BOOL showingHome = tab.showingHome || tab.URLString.length == 0;
    self.homeGlyphView.hidden = !showingHome;
    self.siteIconView.hidden = showingHome;
    if (showingHome) {
        self.titleLabel.text = @"Home";
        self.subtitleLabel.text = @"tvOS Browser";
    } else {
        NSString *title = tab.title.length > 0 && ![tab.title isEqualToString:@"New Tab"] ? tab.title : BrowserOverviewDisplayAddress(tab.URLString);
        self.titleLabel.text = title;
        self.subtitleLabel.text = BrowserOverviewDisplayAddress(tab.URLString);
        [self.siteIconView configureWithURLString:tab.URLString title:title];
    }
    self.accessibilityLabel = self.titleLabel.text;
    [self setNeedsLayout];
    [self updateAppearance];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.contentView.bounds);

    // bounds/center (not frame) so the focus transform stays valid.
    self.thumbnailContainerView.bounds = CGRectMake(0.0, 0.0, width, kTabCardThumbnailHeight);
    self.thumbnailContainerView.center = CGPointMake(width / 2.0, kTabCardThumbnailHeight / 2.0);
    self.thumbnailClipView.frame = self.thumbnailContainerView.bounds;
    self.thumbnailContainerView.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.thumbnailContainerView.bounds cornerRadius:kTabCardCornerRadius].CGPath;
    self.dashedBorderLayer.frame = self.thumbnailContainerView.bounds;
    self.dashedBorderLayer.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(self.thumbnailContainerView.bounds, 2.0, 2.0) cornerRadius:kTabCardCornerRadius - 2.0].CGPath;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.placeholderGradientLayer.frame = self.thumbnailClipView.bounds;
    [CATransaction commit];
    self.placeholderIconView.frame = self.thumbnailClipView.bounds;

    // Aspect-fill, anchored to the top of the page so headers stay visible.
    UIImage *image = self.thumbnailView.image;
    CGRect clipBounds = self.thumbnailClipView.bounds;
    if (image != nil && image.size.width > 0.0 && image.size.height > 0.0) {
        CGFloat scale = MAX(CGRectGetWidth(clipBounds) / image.size.width, CGRectGetHeight(clipBounds) / image.size.height);
        CGFloat imageWidth = image.size.width * scale;
        self.thumbnailView.frame = CGRectMake((CGRectGetWidth(clipBounds) - imageWidth) / 2.0, 0.0, imageWidth, image.size.height * scale);
    } else {
        self.thumbnailView.frame = CGRectZero;
    }

    [self layoutInfoView];
    [self applyLift];
}

- (void)layoutInfoView {
    CGFloat width = CGRectGetWidth(self.contentView.bounds);
    // Move the text down while focused so the enlarged thumbnail never covers it.
    CGFloat focusOffset = self.isFocused ? (kTabCardThumbnailHeight * (kTabCardFocusScale - 1.0) / 2.0) : 0.0;
    self.infoView.frame = CGRectMake(0.0, kTabCardThumbnailHeight + kTabCardInfoTop + focusOffset, width, kTabCardInfoHeight);

    CGFloat iconSide = 54.0;
    BOOL hasIcon = !self.siteIconView.hidden || !self.homeGlyphView.hidden;
    self.siteIconView.frame = CGRectMake(4.0, 4.0, iconSide, iconSide);
    self.homeGlyphView.frame = self.siteIconView.frame;
    CGFloat textX = hasIcon ? iconSide + 22.0 : 4.0;
    CGFloat textWidth = width - textX - 4.0;
    self.titleLabel.frame = CGRectMake(textX, -2.0, textWidth, 38.0);
    self.subtitleLabel.frame = CGRectMake(textX, 38.0, textWidth, 32.0);
}

- (void)applyLift {
    BOOL focused = self.isFocused;
    self.thumbnailContainerView.transform = focused ? CGAffineTransformMakeScale(kTabCardFocusScale, kTabCardFocusScale) : CGAffineTransformIdentity;
    self.thumbnailContainerView.layer.shadowOpacity = focused ? 0.6 : 0.3;
    self.thumbnailContainerView.layer.shadowRadius = focused ? 28.0 : 12.0;
    self.thumbnailContainerView.layer.shadowOffset = CGSizeMake(0.0, focused ? 20.0 : 8.0);
}

- (void)updateAppearance {
    BOOL focused = self.isFocused;

    if (self.addCard) {
        self.thumbnailClipView.layer.borderWidth = 0.0;
        self.placeholderGradientLayer.hidden = YES;
        self.thumbnailClipView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:focused ? 0.16 : 0.05];
        self.dashedBorderLayer.hidden = NO;
        self.dashedBorderLayer.strokeColor = [UIColor colorWithWhite:1.0 alpha:focused ? 0.9 : 0.3].CGColor;
        self.placeholderIconView.tintColor = [UIColor colorWithWhite:1.0 alpha:focused ? 1.0 : 0.6];
    } else {
        self.placeholderGradientLayer.hidden = NO;
        self.thumbnailClipView.backgroundColor = UIColor.blackColor;
        self.dashedBorderLayer.hidden = YES;
        // A white ring marks focus; the active tab gets a quieter accent ring.
        if (focused) {
            self.thumbnailClipView.layer.borderWidth = 6.0;
            self.thumbnailClipView.layer.borderColor = UIColor.whiteColor.CGColor;
        } else if (self.activeTab) {
            self.thumbnailClipView.layer.borderWidth = 4.0;
            self.thumbnailClipView.layer.borderColor = BrowserOverviewAccentColor().CGColor;
        } else {
            self.thumbnailClipView.layer.borderWidth = 1.0;
            self.thumbnailClipView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;
        }
        self.placeholderIconView.tintColor = [UIColor colorWithWhite:1.0 alpha:0.4];
    }

    self.placeholderIconView.hidden = !self.addCard && self.thumbnailView.image != nil;
    self.currentBadgeView.hidden = !self.activeTab;
    self.closeHintView.alpha = (focused && self.canClose) ? 1.0 : 0.0;

    self.titleLabel.font = [UIFont systemFontOfSize:30.0 weight:focused ? UIFontWeightBold : UIFontWeightSemibold];
    self.titleLabel.textColor = focused ? UIColor.whiteColor : [UIColor colorWithWhite:1.0 alpha:0.8];
    self.subtitleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:focused ? 0.65 : 0.45];
    self.contentView.alpha = self.addCardDisabled ? 0.5 : 1.0;

    [self layoutInfoView];
    [self applyLift];
}

- (void)didUpdateFocusInContext:(UIFocusUpdateContext *)context withAnimationCoordinator:(UIFocusAnimationCoordinator *)coordinator {
    [super didUpdateFocusInContext:context withAnimationCoordinator:coordinator];
    [coordinator addCoordinatedAnimations:^{
        [self updateAppearance];
    } completion:nil];
}

@end

#pragma mark - Overview view controller

@interface BrowserTabOverviewViewController : UIViewController <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout>

- (instancetype)initWithOverviewController:(BrowserTabOverviewController *)overviewController;
- (void)reload;
- (void)updateCardAtTabIndex:(NSInteger)tabIndex;
- (void)handleAlternateAction;

@end

@interface BrowserTabOverviewViewController ()

@property (nonatomic, weak) BrowserTabOverviewController *overviewController;
@property (nonatomic) CAGradientLayer *scrimLayer;
@property (nonatomic) UICollectionView *collectionView;
@property (nonatomic) UILabel *subtitleLabel;
@property (nonatomic) NSInteger preferredFocusItemIndex;
@property (nonatomic) CGSize lastCollectionSize;

@end

@implementation BrowserTabOverviewViewController

- (instancetype)initWithOverviewController:(BrowserTabOverviewController *)overviewController {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _overviewController = overviewController;
        _preferredFocusItemIndex = NSNotFound;
        self.modalPresentationStyle = UIModalPresentationOverCurrentContext;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    }
    return self;
}

- (CGFloat)sideInset {
    CGFloat width = CGRectGetWidth(self.view.bounds);
    return MAX(kOverviewMinSideInset, floor((width - kOverviewMaxContentWidth) / 2.0));
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    blurView.frame = self.view.bounds;
    blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:blurView];

    self.scrimLayer = [CAGradientLayer layer];
    self.scrimLayer.colors = @[
        (id)[UIColor colorWithRed:0.08 green:0.09 blue:0.13 alpha:0.70].CGColor,
        (id)[UIColor colorWithRed:0.03 green:0.03 blue:0.05 alpha:0.92].CGColor,
    ];
    [self.view.layer addSublayer:self.scrimLayer];

    UILabel *titleLabel = [UILabel new];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = @"Tabs";
    titleLabel.textColor = UIColor.whiteColor;
    titleLabel.font = [UIFont systemFontOfSize:64.0 weight:UIFontWeightHeavy];
    [self.view addSubview:titleLabel];

    UILabel *subtitleLabel = [UILabel new];
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    subtitleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    subtitleLabel.font = [UIFont systemFontOfSize:28.0 weight:UIFontWeightMedium];
    [self.view addSubview:subtitleLabel];
    self.subtitleLabel = subtitleLabel;

    UIStackView *hintsStack = [[UIStackView alloc] initWithArrangedSubviews:@[
        BrowserOverviewChip(@"hand.tap.fill", @"Open", [UIColor colorWithWhite:1.0 alpha:0.1], [UIColor colorWithWhite:1.0 alpha:0.8]),
        BrowserOverviewChip(@"playpause.fill", @"Close Tab", [UIColor colorWithWhite:1.0 alpha:0.1], [UIColor colorWithWhite:1.0 alpha:0.8]),
        BrowserOverviewChip(@"chevron.backward", @"Back", [UIColor colorWithWhite:1.0 alpha:0.1], [UIColor colorWithWhite:1.0 alpha:0.8]),
    ]];
    hintsStack.translatesAutoresizingMaskIntoConstraints = NO;
    hintsStack.axis = UILayoutConstraintAxisHorizontal;
    hintsStack.spacing = 14.0;
    [self.view addSubview:hintsStack];

    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
    layout.minimumLineSpacing = kTabCardSpacing;
    layout.minimumInteritemSpacing = kTabCardSpacing;
    layout.itemSize = CGSizeMake(kTabCardWidth, kTabCardHeight);

    UICollectionView *collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    collectionView.translatesAutoresizingMaskIntoConstraints = NO;
    collectionView.backgroundColor = UIColor.clearColor;
    collectionView.clipsToBounds = NO;
    collectionView.showsHorizontalScrollIndicator = NO;
    collectionView.showsVerticalScrollIndicator = NO;
    collectionView.remembersLastFocusedIndexPath = YES;
    collectionView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    collectionView.dataSource = self;
    collectionView.delegate = self;
    [collectionView registerClass:[BrowserTabOverviewCollectionViewCell class] forCellWithReuseIdentifier:@"TabCard"];
    [self.view addSubview:collectionView];
    self.collectionView = collectionView;

    CGFloat sideInset = [self sideInset];
    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:sideInset],
        [titleLabel.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:kOverviewHeaderTop],

        [subtitleLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:2.0],

        [hintsStack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-sideInset],
        [hintsStack.centerYAnchor constraintEqualToAnchor:titleLabel.centerYAnchor],

        [collectionView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [collectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [collectionView.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:kOverviewCollectionTop],
        [collectionView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-kOverviewBottomInset],
    ]];
    [self updateSubtitle];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.scrimLayer.frame = self.view.bounds;
    [CATransaction commit];
    if (!CGSizeEqualToSize(self.collectionView.bounds.size, self.lastCollectionSize)) {
        self.lastCollectionSize = self.collectionView.bounds.size;
        [self.collectionView.collectionViewLayout invalidateLayout];
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.overviewController overviewViewControllerDidDisappear:self];
}

- (void)updateSubtitle {
    NSUInteger tabCount = self.overviewController.viewModel.tabs.count;
    NSUInteger maximum = [BrowserViewModel maximumTabCount];
    self.subtitleLabel.text = [NSString stringWithFormat:@"%lu of %lu tabs open", (unsigned long)tabCount, (unsigned long)maximum];
}

- (void)reload {
    NSInteger itemCount = [self.overviewController numberOfDisplayItems];
    if (self.preferredFocusItemIndex == NSNotFound) {
        self.preferredFocusItemIndex = [self currentFocusedItemIndex];
    }
    if (self.preferredFocusItemIndex == NSNotFound) {
        self.preferredFocusItemIndex = [self.overviewController activeTabDisplayItemIndex];
    }
    if (itemCount > 0) {
        self.preferredFocusItemIndex = MIN(MAX(self.preferredFocusItemIndex, 0), itemCount - 1);
    }
    [self updateSubtitle];
    [self.collectionView.collectionViewLayout invalidateLayout];
    [self.collectionView reloadData];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setNeedsFocusUpdate];
        [self updateFocusIfNeeded];
    });
}

- (void)updateCardAtTabIndex:(NSInteger)tabIndex {
    NSInteger itemIndex = tabIndex;
    if (itemIndex < 0 || itemIndex >= self.overviewController.viewModel.tabs.count) {
        [self reload];
        return;
    }
    NSIndexPath *indexPath = [NSIndexPath indexPathForItem:itemIndex inSection:0];
    if ([[self.collectionView indexPathsForVisibleItems] containsObject:indexPath]) {
        [self.collectionView reloadItemsAtIndexPaths:@[indexPath]];
    } else {
        [self.collectionView reloadData];
    }
}

- (void)handleAlternateAction {
    NSInteger focusedItemIndex = [self currentFocusedItemIndex];
    if (focusedItemIndex == NSNotFound || focusedItemIndex >= self.overviewController.viewModel.tabs.count) {
        return;
    }
    self.preferredFocusItemIndex = focusedItemIndex;
    [self.overviewController handleCloseRequestForDisplayItemIndex:focusedItemIndex];
}

- (NSInteger)currentFocusedItemIndex {
    for (NSIndexPath *indexPath in self.collectionView.indexPathsForVisibleItems) {
        UICollectionViewCell *cell = [self.collectionView cellForItemAtIndexPath:indexPath];
        if (cell.isFocused) {
            return indexPath.item;
        }
    }
    return NSNotFound;
}

- (NSInteger)collectionView:(__unused UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return section == 0 ? [self.overviewController numberOfDisplayItems] : 0;
}

- (__kindof UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    BrowserTabOverviewCollectionViewCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"TabCard" forIndexPath:indexPath];
    NSUInteger tabCount = self.overviewController.viewModel.tabs.count;
    if (indexPath.item == tabCount) {
        NSUInteger maximum = [BrowserViewModel maximumTabCount];
        [cell configureAsAddCardWithLimitReached:tabCount >= maximum maximumTabCount:maximum];
        return cell;
    }

    BrowserTabViewModel *tab = [self.overviewController tabForDisplayItemIndex:indexPath.item];
    BOOL activeTab = indexPath.item == [self.overviewController activeTabDisplayItemIndex];
    [cell configureWithTab:tab activeTab:activeTab canClose:tabCount > 1];
    return cell;
}

- (void)collectionView:(__unused UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [self.overviewController handleSelectionForDisplayItemIndex:indexPath.item];
}

- (UIEdgeInsets)collectionView:(UICollectionView *)collectionView layout:(__unused UICollectionViewLayout *)layout insetForSectionAtIndex:(__unused NSInteger)section {
    CGFloat width = CGRectGetWidth(collectionView.bounds);
    CGFloat height = CGRectGetHeight(collectionView.bounds);
    NSInteger itemCount = [self.overviewController numberOfDisplayItems];
    CGFloat contentWidth = (itemCount * kTabCardWidth) + (MAX(itemCount - 1, 0) * kTabCardSpacing);
    CGFloat sideInset = [self sideInset];
    // Centre a short row of cards; otherwise align to the header and scroll.
    CGFloat horizontalInset = contentWidth + (sideInset * 2.0) <= width ? floor((width - contentWidth) / 2.0) : sideInset;
    CGFloat verticalInset = MAX(0.0, floor((height - kTabCardHeight) / 2.0) - 20.0);
    return UIEdgeInsetsMake(verticalInset, horizontalInset, verticalInset, horizontalInset);
}

- (NSIndexPath *)indexPathForPreferredFocusedViewInCollectionView:(UICollectionView *)collectionView {
    NSInteger itemCount = [self.overviewController numberOfDisplayItems];
    if (itemCount == 0) {
        return nil;
    }
    NSInteger preferredItemIndex = self.preferredFocusItemIndex;
    if (preferredItemIndex == NSNotFound) {
        preferredItemIndex = [self.overviewController activeTabDisplayItemIndex];
    }
    preferredItemIndex = MIN(MAX(preferredItemIndex, 0), itemCount - 1);
    return [NSIndexPath indexPathForItem:preferredItemIndex inSection:0];
}

- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {
    return @[self.collectionView];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    UIPress *press = presses.anyObject;
    if (press != nil && press.type == UIPressTypeMenu) {
        [self.overviewController dismiss];
        return;
    }
    if (press != nil && press.type == UIPressTypePlayPause) {
        [self handleAlternateAction];
        return;
    }
    [super pressesEnded:presses withEvent:event];
}

@end

@implementation BrowserTabOverviewController

- (instancetype)initWithHost:(id<BrowserTabOverviewControllerHost>)host
                   viewModel:(BrowserViewModel *)viewModel
                    rootView:(UIView *)rootView
                  topMenuView:(BrowserTopBarView *)topMenuView
                  cursorView:(UIImageView *)cursorView {
    (void)rootView;
    (void)topMenuView;
    (void)cursorView;
    self = [super init];
    if (self) {
        _host = host;
        _viewModel = viewModel;
    }
    return self;
}

- (NSInteger)numberOfDisplayItems {
    return self.viewModel.tabs.count + 1;
}

- (NSInteger)activeTabDisplayItemIndex {
    return self.viewModel.activeTabIndex == NSNotFound ? 0 : self.viewModel.activeTabIndex;
}

- (BrowserTabViewModel *)tabForDisplayItemIndex:(NSInteger)displayItemIndex {
    if (displayItemIndex < 0 || displayItemIndex >= self.viewModel.tabs.count) {
        return nil;
    }
    return self.viewModel.tabs[displayItemIndex];
}

- (void)show {
    if (self.visible) {
        [self reload];
        return;
    }

    self.cursorModeBeforeShowing = [self.host browserTabOverviewControllerCursorModeEnabled];
    self.visible = YES;
    [self.host browserTabOverviewControllerSetCursorModeEnabled:NO];

    BrowserTabOverviewViewController *viewController = [[BrowserTabOverviewViewController alloc] initWithOverviewController:self];
    self.presentedOverviewViewController = viewController;
    [self.host browserTabOverviewControllerPresentViewController:viewController];
}

- (void)dismiss {
    if (!self.visible) {
        return;
    }

    BrowserTabOverviewViewController *viewController = self.presentedOverviewViewController;
    if (viewController == nil) {
        [self overviewViewControllerDidDisappear:nil];
        return;
    }
    [viewController dismissViewControllerAnimated:YES completion:nil];
}

- (void)reload {
    [self reloadPresentedOverviewIfNeeded];
}

- (void)updateCardAtIndex:(NSInteger)tabIndex {
    [self.presentedOverviewViewController updateCardAtTabIndex:tabIndex];
}

- (BOOL)containsPoint:(CGPoint)viewPoint {
    (void)viewPoint;
    return NO;
}

- (BOOL)handleSelectionAtPoint:(CGPoint)viewPoint {
    (void)viewPoint;
    return NO;
}

- (void)handleSelectionForDisplayItemIndex:(NSInteger)displayItemIndex {
    if (displayItemIndex >= self.viewModel.tabs.count) {
        BrowserTabOverviewViewController *viewController = self.presentedOverviewViewController;
        if (viewController == nil) {
            [self.host browserTabOverviewControllerCreateNewTabLoadingHomePage:YES];
            return;
        }

        [viewController dismissViewControllerAnimated:YES completion:^{
            [self.host browserTabOverviewControllerCreateNewTabLoadingHomePage:YES];
        }];
        return;
    }

    [self.host browserTabOverviewControllerSwitchToTabAtIndex:displayItemIndex];
    [self dismiss];
}

- (void)handleCloseRequestForDisplayItemIndex:(NSInteger)displayItemIndex {
    NSInteger tabIndex = displayItemIndex;
    if (tabIndex < 0 || tabIndex >= self.viewModel.tabs.count || self.viewModel.tabs.count <= 1) {
        return;
    }

    [self.host browserTabOverviewControllerCloseTabAtIndex:tabIndex];
    [self reloadPresentedOverviewIfNeeded];
}

- (void)handleAlternateAction {
    [self.presentedOverviewViewController handleAlternateAction];
}

- (void)reloadPresentedOverviewIfNeeded {
    [self.presentedOverviewViewController reload];
}

- (void)overviewViewControllerDidDisappear:(BrowserTabOverviewViewController *)viewController {
    if (viewController != nil && viewController != self.presentedOverviewViewController) {
        return;
    }

    self.presentedOverviewViewController = nil;
    if (!self.visible) {
        return;
    }

    self.visible = NO;
    [self.host browserTabOverviewControllerSetCursorModeEnabled:self.cursorModeBeforeShowing];
}

@end
