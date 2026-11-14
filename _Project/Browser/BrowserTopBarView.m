#import "BrowserTopBarView.h"

#if __has_include(<UIKit/UIGlassEffect.h>)
#import <UIKit/UIGlassEffect.h>
#endif

static CGFloat const kTopBarHorizontalInset = 40.0;
static CGFloat const kTopBarVerticalInset = 8.0;
static CGFloat const kTopBarHeight = 86.0;
static CGFloat const kTopBarMaxWidth = 1760.0;
static CGFloat const kTopBarEdgePadding = 10.0;
static CGFloat const kTopBarButtonSize = 66.0;
static CGFloat const kTopBarButtonSpacing = 8.0;
static CGFloat const kTopBarClusterSpacing = 28.0;
static CGFloat const kTopBarAddressHeight = 62.0;
static CGFloat const kTopBarSymbolPointSize = 27.0;

static NSString * const kTopBarHomePlaceholder = @"Search or enter website address";

static UIColor *BrowserTopBarAccentColor(CGFloat alpha) {
    return [UIColor colorWithRed:0.23 green:0.57 blue:1.0 alpha:alpha];
}

static UIImage *BrowserTopBarSymbol(NSString *name, CGFloat pointSize) {
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:pointSize weight:UIImageSymbolWeightSemibold];
    return [[UIImage systemImageNamed:name withConfiguration:configuration] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

#pragma mark - Button

typedef NS_ENUM(NSInteger, BrowserTopBarButtonStyle) {
    BrowserTopBarButtonStyleIcon = 0,
    BrowserTopBarButtonStyleTabCount,
    BrowserTopBarButtonStyleAddress
};

@interface BrowserTopBarButton : UIButton

@property (nonatomic) BrowserTopBarAction topBarAction;
@property (nonatomic) BrowserTopBarButtonStyle style;
@property (nonatomic) BOOL focusable;
@property (nonatomic, getter=isDimmed) BOOL dimmed;
@property (nonatomic) UIView *backdropView;
@property (nonatomic) UIImageView *iconView;
@property (nonatomic) UILabel *textLabel;
@property (nonatomic) UIActivityIndicatorView *spinner;
@property (nonatomic) BOOL showsPlaceholder;
@property (nonatomic) UIView *progressClipView;
@property (nonatomic) UIView *progressFillView;
@property (nonatomic) double loadProgress;
@property (nonatomic) BOOL showsProgress;

- (void)setLoadProgress:(double)progress loading:(BOOL)loading animated:(BOOL)animated;

@end

@implementation BrowserTopBarButton

+ (instancetype)buttonWithStyle:(BrowserTopBarButtonStyle)style action:(BrowserTopBarAction)action {
    BrowserTopBarButton *button = [BrowserTopBarButton buttonWithType:UIButtonTypeCustom];
    button.style = style;
    button.topBarAction = action;
    [button commonSetup];
    return button;
}

- (void)commonSetup {
    self.backgroundColor = UIColor.clearColor;
    self.clipsToBounds = NO;
    self.accessibilityTraits = UIAccessibilityTraitButton;

    self.backdropView = [UIView new];
    self.backdropView.userInteractionEnabled = NO;
    [self addSubview:self.backdropView];

    self.iconView = [UIImageView new];
    self.iconView.userInteractionEnabled = NO;
    self.iconView.contentMode = UIViewContentModeCenter;
    [self.backdropView addSubview:self.iconView];

    if (self.style != BrowserTopBarButtonStyleIcon) {
        self.textLabel = [UILabel new];
        self.textLabel.userInteractionEnabled = NO;
        [self.backdropView addSubview:self.textLabel];
    }

    if (self.style == BrowserTopBarButtonStyleTabCount) {
        self.textLabel.font = [UIFont systemFontOfSize:19.0 weight:UIFontWeightBold];
        self.textLabel.textAlignment = NSTextAlignmentCenter;
        self.textLabel.layer.borderWidth = 3.0;
        self.textLabel.layer.cornerRadius = 9.0;
        self.textLabel.text = @"1";
    } else if (self.style == BrowserTopBarButtonStyleAddress) {
        self.textLabel.font = [UIFont systemFontOfSize:27.0 weight:UIFontWeightMedium];
        self.textLabel.textAlignment = NSTextAlignmentCenter;
        self.textLabel.lineBreakMode = NSLineBreakByTruncatingTail;

        self.progressClipView = [UIView new];
        self.progressClipView.userInteractionEnabled = NO;
        self.progressClipView.clipsToBounds = YES;
        [self.backdropView insertSubview:self.progressClipView atIndex:0];

        self.progressFillView = [UIView new];
        self.progressFillView.alpha = 0.0;
        [self.progressClipView addSubview:self.progressFillView];

        self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        self.spinner.hidesWhenStopped = YES;
        self.spinner.userInteractionEnabled = NO;
        [self.backdropView addSubview:self.spinner];
    }

    [self updateAppearanceFocused:NO];
}

- (BOOL)canBecomeFocused {
    return self.focusable && !self.hidden && self.alpha > 0.01;
}

- (UIFocusSoundIdentifier)soundIdentifierForFocusUpdateInContext:(__unused UIFocusUpdateContext *)context {
    return UIFocusSoundIdentifierDefault;
}

- (CGFloat)cornerRadius {
    return CGRectGetHeight(self.bounds) / 2.0;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // bounds/center (not frame) so the focus scale transform stays valid.
    self.backdropView.bounds = self.bounds;
    self.backdropView.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    self.backdropView.layer.cornerRadius = [self cornerRadius];

    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    switch (self.style) {
        case BrowserTopBarButtonStyleIcon:
            self.iconView.frame = self.backdropView.bounds;
            break;
        case BrowserTopBarButtonStyleTabCount:
            self.textLabel.frame = CGRectMake((width - 34.0) / 2.0, (height - 34.0) / 2.0, 34.0, 34.0);
            break;
        case BrowserTopBarButtonStyleAddress: {
            CGFloat sidePadding = 26.0;
            CGFloat accessorySide = 34.0;
            // Keep the text optically centred by reserving equal space on both sides.
            CGFloat reserved = sidePadding + accessorySide + 12.0;
            CGFloat textWidth = MAX(0.0, width - (reserved * 2.0));
            [self.textLabel sizeToFit];
            CGFloat labelWidth = MIN(CGRectGetWidth(self.textLabel.bounds), textWidth);
            CGFloat labelX = floor((width - labelWidth) / 2.0);
            self.textLabel.frame = CGRectMake(labelX, 0.0, labelWidth, height);
            BOOL iconVisible = self.iconView.image != nil;
            CGFloat iconX = iconVisible ? labelX - accessorySide - 8.0 : sidePadding;
            self.iconView.frame = CGRectMake(MAX(sidePadding, iconX), (height - accessorySide) / 2.0, accessorySide, accessorySide);
            self.spinner.frame = CGRectMake(width - sidePadding - accessorySide, (height - accessorySide) / 2.0, accessorySide, accessorySide);
            self.progressClipView.frame = self.backdropView.bounds;
            self.progressClipView.layer.cornerRadius = [self cornerRadius];
            [self layoutProgressFill];
            break;
        }
    }
    [self applyLiftForFocused:self.isFocused];
}

- (void)layoutProgressFill {
    CGRect bounds = self.progressClipView.bounds;
    self.progressFillView.frame = CGRectMake(0.0, 0.0, round(CGRectGetWidth(bounds) * self.loadProgress), CGRectGetHeight(bounds));
}

- (void)setLoadProgress:(double)progress loading:(BOOL)loading animated:(BOOL)animated {
    if (self.style != BrowserTopBarButtonStyleAddress) {
        return;
    }

    if (loading) {
        // Never show an empty bar: start visibly so the user sees something happen at once.
        double clamped = MAX(0.1, MIN(progress, 1.0));
        BOOL wasShowing = self.showsProgress;
        self.showsProgress = YES;
        if (!wasShowing) {
            [self.progressFillView.layer removeAllAnimations];
            self.loadProgress = 0.0;
            [self layoutProgressFill];
        }
        self.loadProgress = MAX(self.loadProgress, clamped);
        [UIView animateWithDuration:(animated ? 0.25 : 0.0)
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
                         animations:^{
            self.progressFillView.alpha = 1.0;
            [self layoutProgressFill];
        } completion:nil];
        [self.spinner startAnimating];
        return;
    }

    [self.spinner stopAnimating];
    if (!self.showsProgress) {
        return;
    }
    self.showsProgress = NO;
    if (!animated) {
        self.loadProgress = 0.0;
        self.progressFillView.alpha = 0.0;
        [self layoutProgressFill];
        return;
    }
    // Finish the sweep, then fade out.
    self.loadProgress = 1.0;
    [UIView animateWithDuration:0.2
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        [self layoutProgressFill];
    } completion:^(__unused BOOL finished) {
        if (self.showsProgress) {
            return;
        }
        [UIView animateWithDuration:0.3 animations:^{
            self.progressFillView.alpha = 0.0;
        } completion:^(__unused BOOL fadeFinished) {
            if (!self.showsProgress) {
                self.loadProgress = 0.0;
                [self layoutProgressFill];
            }
        }];
    }];
}

- (void)applyLiftForFocused:(BOOL)focused {
    CGFloat scale = 1.0;
    if (focused) {
        scale = self.style == BrowserTopBarButtonStyleAddress ? 1.03 : 1.1;
    }
    if (self.highlighted && focused) {
        scale -= 0.06;
    }
    self.backdropView.transform = CGAffineTransformMakeScale(scale, scale);
    self.backdropView.layer.shadowColor = UIColor.blackColor.CGColor;
    self.backdropView.layer.shadowOpacity = focused ? 0.35 : 0.0;
    self.backdropView.layer.shadowRadius = focused ? 14.0 : 0.0;
    self.backdropView.layer.shadowOffset = CGSizeMake(0.0, focused ? 8.0 : 0.0);
    self.backdropView.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.backdropView.bounds cornerRadius:[self cornerRadius]].CGPath;
}

- (void)updateAppearanceFocused:(BOOL)focused {
    UIColor *contentColor = focused ? [UIColor colorWithWhite:0.1 alpha:1.0] : [UIColor colorWithWhite:1.0 alpha:0.94];
    CGFloat contentAlpha = (self.dimmed && !focused) ? 0.32 : (self.dimmed ? 0.45 : 1.0);

    if (self.style == BrowserTopBarButtonStyleAddress) {
        self.backdropView.backgroundColor = focused ? UIColor.whiteColor : [UIColor colorWithWhite:1.0 alpha:0.12];
        UIColor *textColor = contentColor;
        if (self.showsPlaceholder) {
            textColor = focused ? [UIColor colorWithWhite:0.0 alpha:0.5] : [UIColor colorWithWhite:1.0 alpha:0.5];
        }
        self.textLabel.textColor = textColor;
        self.iconView.tintColor = focused ? [UIColor colorWithWhite:0.0 alpha:0.55] : [UIColor colorWithWhite:1.0 alpha:0.6];
        self.spinner.color = contentColor;
        self.progressFillView.backgroundColor = BrowserTopBarAccentColor(focused ? 0.28 : 0.45);
    } else {
        self.backdropView.backgroundColor = focused ? UIColor.whiteColor : UIColor.clearColor;
        self.iconView.tintColor = contentColor;
        self.iconView.alpha = contentAlpha;
        if (self.textLabel != nil) {
            self.textLabel.textColor = contentColor;
            self.textLabel.layer.borderColor = contentColor.CGColor;
        }
    }
    [self applyLiftForFocused:focused];
}

- (void)setDimmed:(BOOL)dimmed {
    _dimmed = dimmed;
    [self updateAppearanceFocused:self.isFocused];
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [UIView animateWithDuration:0.12 animations:^{
        [self applyLiftForFocused:self.isFocused];
    }];
}

- (void)didUpdateFocusInContext:(UIFocusUpdateContext *)context withAnimationCoordinator:(UIFocusAnimationCoordinator *)coordinator {
    [super didUpdateFocusInContext:context withAnimationCoordinator:coordinator];
    BOOL focused = context.nextFocusedView == self;
    [coordinator addCoordinatedAnimations:^{
        [self updateAppearanceFocused:focused];
    } completion:nil];
}

@end

#pragma mark - Top bar

@interface BrowserTopBarView ()

@property (nonatomic) UIView *chromeContainerView;
@property (nonatomic) UIVisualEffectView *chromeEffectView;
@property (nonatomic) BrowserTopBarButton *backButton;
@property (nonatomic) BrowserTopBarButton *forwardButton;
@property (nonatomic) BrowserTopBarButton *refreshButton;
@property (nonatomic) BrowserTopBarButton *addressButton;
@property (nonatomic) BrowserTopBarButton *homeButton;
@property (nonatomic) BrowserTopBarButton *tabsButton;
@property (nonatomic) BrowserTopBarButton *fullscreenButton;
@property (nonatomic) BrowserTopBarButton *menuButton;
@property (nonatomic) NSArray<BrowserTopBarButton *> *buttons;
@property (nonatomic, weak) BrowserTopBarButton *lastFocusedButton;
@property (nonatomic, readwrite, getter=isFocusModeActive) BOOL focusModeActive;

@end

@implementation BrowserTopBarView

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (instancetype)initWithEffect:(UIVisualEffect *)effect {
    self = [super initWithEffect:effect];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (void)awakeFromNib {
    [super awakeFromNib];

    // The storyboard still contains the legacy image views; the bar is built in code.
    for (UIView *subview in [self.contentView.subviews copy]) {
        if (subview != self.chromeContainerView) {
            [subview removeFromSuperview];
        }
    }
}

- (void)commonInit {
    self.effect = nil;
    self.backgroundColor = UIColor.clearColor;
    self.clipsToBounds = NO;
    self.userInteractionEnabled = YES;
    self.contentView.clipsToBounds = NO;

    self.chromeContainerView = [[UIView alloc] initWithFrame:CGRectZero];
    self.chromeContainerView.backgroundColor = UIColor.clearColor;
    self.chromeContainerView.clipsToBounds = NO;
    [self.contentView addSubview:self.chromeContainerView];

    self.chromeEffectView = [[UIVisualEffectView alloc] initWithEffect:nil];
    self.chromeEffectView.clipsToBounds = YES;
    [self.chromeContainerView addSubview:self.chromeEffectView];

    _backButton = [self iconButtonWithSymbol:@"chevron.left" action:BrowserTopBarActionBack label:@"Back"];
    _forwardButton = [self iconButtonWithSymbol:@"chevron.right" action:BrowserTopBarActionForward label:@"Forward"];
    _refreshButton = [self iconButtonWithSymbol:@"arrow.clockwise" action:BrowserTopBarActionRefresh label:@"Reload"];
    _homeButton = [self iconButtonWithSymbol:@"house" action:BrowserTopBarActionHome label:@"Home"];
    _fullscreenButton = [self iconButtonWithSymbol:@"arrow.up.left.and.arrow.down.right" action:BrowserTopBarActionFullscreen label:@"Hide Top Bar"];
    _menuButton = [self iconButtonWithSymbol:@"ellipsis" action:BrowserTopBarActionMenu label:@"Menu"];

    _tabsButton = [BrowserTopBarButton buttonWithStyle:BrowserTopBarButtonStyleTabCount action:BrowserTopBarActionTabs];
    _tabsButton.accessibilityLabel = @"Tabs";

    _addressButton = [BrowserTopBarButton buttonWithStyle:BrowserTopBarButtonStyleAddress action:BrowserTopBarActionURL];
    _addressButton.accessibilityLabel = @"Enter URL or Search";

    _buttons = @[_backButton, _forwardButton, _refreshButton, _addressButton, _homeButton, _tabsButton, _fullscreenButton, _menuButton];
    for (BrowserTopBarButton *button in _buttons) {
        [button addTarget:self action:@selector(handleButtonPrimaryAction:) forControlEvents:UIControlEventPrimaryActionTriggered];
        [self.chromeEffectView.contentView addSubview:button];
    }

    [self applyVisualStyle];
    [self setDisplayedURLString:nil];
}

- (BrowserTopBarButton *)iconButtonWithSymbol:(NSString *)symbolName action:(BrowserTopBarAction)action label:(NSString *)label {
    BrowserTopBarButton *button = [BrowserTopBarButton buttonWithStyle:BrowserTopBarButtonStyleIcon action:action];
    button.iconView.image = BrowserTopBarSymbol(symbolName, kTopBarSymbolPointSize);
    button.accessibilityLabel = label;
    return button;
}

- (UILabel *)URLLabel {
    return self.addressButton.textLabel;
}

- (UIActivityIndicatorView *)loadingSpinner {
    return self.addressButton.spinner;
}

- (void)applyVisualStyle {
#if __has_include(<UIKit/UIGlassEffect.h>)
    if (@available(tvOS 26.0, *)) {
        UIGlassEffect *glassEffect = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
        glassEffect.interactive = YES;
        glassEffect.tintColor = [UIColor colorWithWhite:0.0 alpha:0.25];
        self.chromeEffectView.effect = glassEffect;
        self.chromeContainerView.layer.shadowOpacity = 0.0;
        self.chromeContainerView.layer.borderWidth = 0.0;
        return;
    }
#endif

    self.chromeEffectView.effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    self.chromeContainerView.layer.shadowColor = UIColor.blackColor.CGColor;
    self.chromeContainerView.layer.shadowOpacity = 0.35;
    self.chromeContainerView.layer.shadowOffset = CGSizeMake(0.0, 10.0);
    self.chromeContainerView.layer.shadowRadius = 24.0;
    self.chromeContainerView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;
    self.chromeContainerView.layer.borderWidth = 1.0;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    self.contentView.frame = self.bounds;

    CGFloat width = MIN(CGRectGetWidth(self.bounds) - (kTopBarHorizontalInset * 2.0), kTopBarMaxWidth);
    width = MAX(width, 860.0);
    CGFloat originX = floor((CGRectGetWidth(self.bounds) - width) / 2.0);
    CGRect chromeFrame = CGRectMake(originX, kTopBarVerticalInset, width, kTopBarHeight);

    self.chromeContainerView.frame = chromeFrame;
    self.chromeContainerView.layer.cornerRadius = kTopBarHeight / 2.0;
    self.chromeContainerView.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.chromeContainerView.bounds
                                                                           cornerRadius:kTopBarHeight / 2.0].CGPath;
    self.chromeEffectView.frame = self.chromeContainerView.bounds;
    self.chromeEffectView.layer.cornerRadius = kTopBarHeight / 2.0;

    CGFloat buttonY = floor((kTopBarHeight - kTopBarButtonSize) / 2.0);
    CGFloat x = kTopBarEdgePadding;
    for (BrowserTopBarButton *button in @[self.backButton, self.forwardButton, self.refreshButton]) {
        button.frame = CGRectMake(x, buttonY, kTopBarButtonSize, kTopBarButtonSize);
        x += kTopBarButtonSize + kTopBarButtonSpacing;
    }
    CGFloat addressMinX = x - kTopBarButtonSpacing + kTopBarClusterSpacing;

    x = width - kTopBarEdgePadding - kTopBarButtonSize;
    for (BrowserTopBarButton *button in @[self.menuButton, self.fullscreenButton, self.tabsButton, self.homeButton]) {
        button.frame = CGRectMake(x, buttonY, kTopBarButtonSize, kTopBarButtonSize);
        x -= kTopBarButtonSize + kTopBarButtonSpacing;
    }
    CGFloat addressMaxX = CGRectGetMinX(self.homeButton.frame) - kTopBarClusterSpacing;

    self.addressButton.frame = CGRectMake(addressMinX,
                                          floor((kTopBarHeight - kTopBarAddressHeight) / 2.0),
                                          MAX(240.0, addressMaxX - addressMinX),
                                          kTopBarAddressHeight);
}

#pragma mark Content

- (void)setDisplayedURLString:(NSString *)URLString {
    BrowserTopBarButton *address = self.addressButton;
    NSURL *URL = URLString.length > 0 ? [NSURL URLWithString:URLString] : nil;
    if (URLString.length == 0) {
        address.showsPlaceholder = YES;
        address.textLabel.text = kTopBarHomePlaceholder;
        address.iconView.image = BrowserTopBarSymbol(@"magnifyingglass", 22.0);
    } else {
        address.showsPlaceholder = NO;
        NSString *host = URL.host ?: @"";
        if ([host.lowercaseString hasPrefix:@"www."]) {
            host = [host substringFromIndex:4];
        }
        NSString *path = URL.path ?: @"";
        if ([path isEqualToString:@"/"]) {
            path = @"";
        }
        address.textLabel.text = host.length > 0 ? [host stringByAppendingString:path] : URLString;
        BOOL secure = [URL.scheme.lowercaseString isEqualToString:@"https"];
        address.iconView.image = host.length > 0 ? BrowserTopBarSymbol(secure ? @"lock.fill" : @"globe", 20.0) : nil;
    }
    address.accessibilityValue = URLString.length > 0 ? URLString : kTopBarHomePlaceholder;
    [address updateAppearanceFocused:address.isFocused];
    [address setNeedsLayout];
}

- (void)setBackEnabled:(BOOL)backEnabled forwardEnabled:(BOOL)forwardEnabled {
    self.backButton.dimmed = !backEnabled;
    self.forwardButton.dimmed = !forwardEnabled;
}

- (void)setTabCount:(NSUInteger)tabCount {
    self.tabsButton.textLabel.text = tabCount > 99 ? @"∞" : [NSString stringWithFormat:@"%lu", (unsigned long)MAX(tabCount, 1)];
    self.tabsButton.accessibilityValue = [NSString stringWithFormat:@"%lu open", (unsigned long)tabCount];
}

- (void)setLoadProgress:(double)progress loading:(BOOL)loading animated:(BOOL)animated {
    [self.addressButton setLoadProgress:progress loading:loading animated:animated];
}

- (void)setHomeActive:(BOOL)homeActive {
    self.homeButton.iconView.image = BrowserTopBarSymbol(homeActive ? @"house.fill" : @"house", kTopBarSymbolPointSize);
}

#pragma mark Focus

- (CGRect)interactiveFrameForView:(UIView *)view {
    return [self convertRect:view.bounds fromView:view];
}

- (void)setFocusModeActive:(BOOL)focusModeActive {
    if (_focusModeActive == focusModeActive) {
        return;
    }
    _focusModeActive = focusModeActive;
    for (BrowserTopBarButton *button in self.buttons) {
        button.focusable = focusModeActive;
    }
}

- (UIView *)preferredFocusItem {
    if (!self.focusModeActive) {
        return nil;
    }
    return self.lastFocusedButton ?: self.addressButton;
}

- (void)handleButtonPrimaryAction:(BrowserTopBarButton *)button {
    [self.delegate browserTopBarView:self didTriggerAction:button.topBarAction];
}

- (void)didUpdateFocusInContext:(UIFocusUpdateContext *)context withAnimationCoordinator:(UIFocusAnimationCoordinator *)coordinator {
    [super didUpdateFocusInContext:context withAnimationCoordinator:coordinator];
    if ([context.nextFocusedView isKindOfClass:[BrowserTopBarButton class]]) {
        self.lastFocusedButton = (BrowserTopBarButton *)context.nextFocusedView;
    }
}

@end
