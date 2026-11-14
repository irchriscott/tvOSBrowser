#import "BrowserTabCoordinator.h"

#import "BrowserHomeStore.h"
#import "BrowserHomeView.h"
#import "BrowserNavigationService.h"
#import "BrowserPreferencesStore.h"
#import "BrowserSessionStore.h"
#import "BrowserTabViewModel.h"
#import "BrowserTopBarView.h"
#import "BrowserViewModel.h"
#import "BrowserWebView.h"

static CGFloat const kThumbnailStagingOffset = 4096.0;
/// A second crash within this window stops automatic reloading (avoids a crash loop).
static NSTimeInterval const kRepeatedCrashInterval = 30.0;

@interface BrowserTabCoordinator () <BrowserHomeViewDelegate>

@property (nonatomic, weak) id<BrowserTabCoordinatorHost> host;
@property (nonatomic) BrowserViewModel *viewModel;
@property (nonatomic) BrowserPreferencesStore *preferencesStore;
@property (nonatomic) BrowserNavigationService *navigationService;
@property (nonatomic) BrowserSessionStore *sessionStore;
@property (nonatomic, weak) UIView *browserContainerView;
@property (nonatomic, weak) UIView *rootView;
@property (nonatomic, weak) BrowserTopBarView *topMenuView;
@property (nonatomic, weak) UIImageView *cursorView;
@property (nonatomic, weak) UIPanGestureRecognizer *manualScrollPanRecognizer;
@property (nonatomic, weak) id webViewDelegate;
@property (nonatomic) BOOL scrollViewAllowBounces;
@property (nonatomic) NSMutableDictionary<NSString *, BrowserWebView *> *webViewsByTabIdentifier;
@property (nonatomic) UIView *thumbnailStagingView;
@property (nonatomic, readwrite, nullable) BrowserWebView *activeWebView;
@property (nonatomic, readwrite, nullable) BrowserHomeView *homeView;
@property (nonatomic) BOOL hasNotifiedHomeVisibility;
@property (nonatomic) BOOL lastNotifiedHomeVisible;
@property (nonatomic) UIView *pageProgressView;
@property (nonatomic) UIView *pageProgressFillView;
@property (nonatomic) double pageProgressValue;
/// Tabs whose page process died and still need a reload.
@property (nonatomic) NSMutableSet<NSString *> *crashedTabIdentifiers;
/// Tabs that crashed repeatedly and wait for the user to reload.
@property (nonatomic) NSMutableSet<NSString *> *crashOverlayTabIdentifiers;
@property (nonatomic) NSMutableDictionary<NSString *, NSDate *> *lastCrashDates;
@property (nonatomic) UIView *crashOverlayView;
@property (nonatomic, readwrite) BOOL pageFullscreenActive;

@end

@implementation BrowserTabCoordinator

- (instancetype)initWithHost:(id<BrowserTabCoordinatorHost>)host
                   viewModel:(BrowserViewModel *)viewModel
            preferencesStore:(BrowserPreferencesStore *)preferencesStore
           navigationService:(BrowserNavigationService *)navigationService
                sessionStore:(BrowserSessionStore *)sessionStore
          browserContainerView:(UIView *)browserContainerView
                    rootView:(UIView *)rootView
                  topMenuView:(BrowserTopBarView *)topMenuView
                  cursorView:(UIImageView *)cursorView
     manualScrollPanRecognizer:(UIPanGestureRecognizer *)manualScrollPanRecognizer
             webViewDelegate:(id)webViewDelegate
         scrollViewAllowBounces:(BOOL)scrollViewAllowBounces {
    self = [super init];
    if (self) {
        _host = host;
        _viewModel = viewModel;
        _preferencesStore = preferencesStore;
        _navigationService = navigationService;
        _sessionStore = sessionStore;
        _browserContainerView = browserContainerView;
        _rootView = rootView;
        _topMenuView = topMenuView;
        _cursorView = cursorView;
        _manualScrollPanRecognizer = manualScrollPanRecognizer;
        _webViewDelegate = webViewDelegate;
        _scrollViewAllowBounces = scrollViewAllowBounces;
        _webViewsByTabIdentifier = [NSMutableDictionary dictionary];
        _crashedTabIdentifiers = [NSMutableSet set];
        _crashOverlayTabIdentifiers = [NSMutableSet set];
        _lastCrashDates = [NSMutableDictionary dictionary];
        [_preferencesStore ensureUserAgentConsistency];
        [self ensureThumbnailStagingView];
    }
    return self;
}

- (BrowserTabViewModel *)activeTab {
    return [self.viewModel activeTab];
}

- (BOOL)showingHome {
    return self.activeTab.showingHome;
}

#pragma mark - Home

- (BrowserHomeView *)homeView {
    if (_homeView == nil && self.browserContainerView != nil) {
        _homeView = [[BrowserHomeView alloc] initWithFrame:self.rootView.bounds];
        _homeView.delegate = self;
        _homeView.hidden = YES;
        [self.browserContainerView addSubview:_homeView];
    }
    return _homeView;
}

- (BOOL)activeTabHasPageBehindHome {
    BrowserTabViewModel *tab = self.activeTab;
    return self.activeWebView.request.URL.absoluteString.length > 0 || tab.URLString.length > 0;
}

- (void)updateHomeVisibility {
    BrowserTabViewModel *tab = self.activeTab;
    BOOL visible = tab != nil && tab.showingHome;

    if (visible) {
        BrowserHomeView *homeView = self.homeView;
        BOOL becameVisible = homeView.hidden;
        homeView.frame = self.rootView.bounds;
        homeView.contentTopInset = self.topMenuBrowserOffset;
        if (becameVisible) {
            [homeView reloadData];
            [self.activeWebView pauseAllMediaPlayback];
        }
        homeView.hidden = NO;
        [self.browserContainerView bringSubviewToFront:homeView];
    } else {
        _homeView.hidden = YES;
    }
    // Keep the page out of the focus engine and off screen while Home covers it.
    self.activeWebView.hidden = visible;
    [self refreshActiveTabUI];
    [self recoverActiveTabFromCrashIfNeeded];

    if (!self.hasNotifiedHomeVisibility || self.lastNotifiedHomeVisible != visible) {
        self.hasNotifiedHomeVisibility = YES;
        self.lastNotifiedHomeVisible = visible;
        [self.host browserTabCoordinatorHomeVisibilityChanged:visible];
    }
}

- (void)reloadHome {
    if (!self.showingHome) {
        return;
    }
    [self.homeView reloadData];
}

- (void)showHomeForTab:(BrowserTabViewModel *)tab {
    if (tab == nil) {
        return;
    }
    tab.showingHome = YES;
    if (tab == self.activeTab) {
        [self updateHomeVisibility];
    }
}

- (void)dismissHomeIfNeeded {
    BrowserTabViewModel *tab = self.activeTab;
    if (tab == nil || !tab.showingHome) {
        return;
    }
    tab.showingHome = NO;
    [self updateHomeVisibility];
}

- (BOOL)returnFromHomeToPage {
    BrowserTabViewModel *tab = self.activeTab;
    if (tab == nil || !tab.showingHome || ![self activeTabHasPageBehindHome]) {
        return NO;
    }
    [self dismissHomeIfNeeded];
    if (self.activeWebView.request == nil) {
        [self loadStoredContentForTab:tab webView:self.activeWebView fallbackToHomePage:NO];
    }
    [self persistSession];
    return YES;
}

- (void)openHomeItem:(BrowserHomeItem *)item inNewTab:(BOOL)inNewTab {
    NSURLRequest *request = [self.navigationService requestForURLString:item.URLString];
    if (request == nil) {
        return;
    }
    if (item.kind == BrowserHomeItemKindRecentlyClosed) {
        [BrowserHomeStore removeItem:item];
    }
    if (inNewTab) {
        [self createNewTabWithRequest:request];
        return;
    }
    [self dismissHomeIfNeeded];
    [self.activeWebView loadRequest:request];
    [self persistSession];
}

#pragma mark BrowserHomeViewDelegate

- (void)homeView:(__unused BrowserHomeView *)homeView didSelectItem:(BrowserHomeItem *)item {
    [self.host browserTabCoordinatorDidConsumeSelectPress];
    [self openHomeItem:item inNewTab:NO];
}

- (void)homeViewDidSelectSearch:(__unused BrowserHomeView *)homeView {
    [self.host browserTabCoordinatorDidConsumeSelectPress];
    [self.host browserTabCoordinatorShowAddressEntry];
}

- (void)homeView:(__unused BrowserHomeView *)homeView didRequestOptionsForItem:(BrowserHomeItem *)item {
    [self.host browserTabCoordinatorDidConsumeSelectPress];

    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:item.title
                                                                             message:item.URLString
                                                                      preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [alertController addAction:[UIAlertAction actionWithTitle:@"Open"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        [weakSelf openHomeItem:item inNewTab:NO];
    }]];
    [alertController addAction:[UIAlertAction actionWithTitle:@"Open in New Tab"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        [weakSelf openHomeItem:item inNewTab:YES];
    }]];

    if (item.kind == BrowserHomeItemKindPinned) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Remove from Pinned"
                                                            style:UIAlertActionStyleDestructive
                                                          handler:^(__unused UIAlertAction *action) {
            [BrowserHomeStore removeItem:item];
            [weakSelf reloadHome];
        }]];
    } else {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Pin to Home"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            [BrowserHomeStore pinItem:item];
            [weakSelf reloadHome];
        }]];
        [alertController addAction:[UIAlertAction actionWithTitle:@"Remove from Recently Closed"
                                                            style:UIAlertActionStyleDestructive
                                                          handler:^(__unused UIAlertAction *action) {
            [BrowserHomeStore removeItem:item];
            [weakSelf reloadHome];
        }]];
        [alertController addAction:[UIAlertAction actionWithTitle:@"Clear All Recently Closed"
                                                            style:UIAlertActionStyleDestructive
                                                          handler:^(__unused UIAlertAction *action) {
            [BrowserHomeStore clearRecentlyClosed];
            [weakSelf reloadHome];
        }]];
    }
    [alertController addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self.host browserTabCoordinatorPresentViewController:alertController];
}

- (NSString *)requestURL {
    return self.activeTab.requestURL;
}

- (void)setRequestURL:(NSString *)requestURL {
    self.activeTab.requestURL = requestURL ?: @"";
}

- (NSString *)previousURL {
    return self.activeTab.previousURL;
}

- (void)setPreviousURL:(NSString *)previousURL {
    self.activeTab.previousURL = previousURL ?: @"";
}

- (BOOL)topNavigationVisible {
    return self.viewModel.topNavigationBarVisible;
}

- (CGFloat)topMenuBrowserOffset {
    return self.topNavigationVisible ? self.topMenuView.frame.size.height : 0.0;
}

- (void)setTopNavigationVisible:(BOOL)visible {
    self.viewModel.topNavigationBarVisible = visible;
    self.topMenuView.hidden = !visible;
    [self updateTopNavAndWebView];
    [self updateLoadIndicatorsAnimated:NO];
}

- (void)updateTopNavAndWebView {
    if (_homeView != nil) {
        _homeView.frame = self.rootView.bounds;
        _homeView.contentTopInset = self.topMenuBrowserOffset;
    }
    if (self.activeWebView == nil) {
        return;
    }
    if (self.pageFullscreenActive) {
        self.activeWebView.frame = self.rootView.bounds;
    } else if (self.topNavigationVisible) {
        self.activeWebView.frame = CGRectMake(self.rootView.bounds.origin.x,
                                              self.rootView.bounds.origin.y + self.topMenuBrowserOffset,
                                              self.rootView.bounds.size.width,
                                              self.rootView.bounds.size.height - self.topMenuBrowserOffset);
    } else {
        self.activeWebView.frame = self.rootView.bounds;
    }
    if (_crashOverlayView != nil) {
        _crashOverlayView.frame = self.activeWebView.frame;
    }
}

- (CGSize)thumbnailViewportSize {
    CGFloat width = CGRectGetWidth(self.rootView.bounds);
    CGFloat height = CGRectGetHeight(self.rootView.bounds) - self.topMenuBrowserOffset;
    return CGSizeMake(MAX(width, 1.0), MAX(height, 1.0));
}

- (void)ensureThumbnailStagingView {
    if (self.thumbnailStagingView != nil || self.rootView == nil) {
        return;
    }

    CGSize viewportSize = [self thumbnailViewportSize];
    UIView *stagingView = [[UIView alloc] initWithFrame:CGRectMake(kThumbnailStagingOffset,
                                                                   0.0,
                                                                   viewportSize.width,
                                                                   viewportSize.height)];
    stagingView.backgroundColor = UIColor.clearColor;
    stagingView.userInteractionEnabled = NO;
    stagingView.clipsToBounds = YES;
    [self.rootView addSubview:stagingView];
    self.thumbnailStagingView = stagingView;
}

- (void)updateThumbnailStagingViewFrame {
    [self ensureThumbnailStagingView];
    if (self.thumbnailStagingView == nil) {
        return;
    }

    CGSize viewportSize = [self thumbnailViewportSize];
    self.thumbnailStagingView.frame = CGRectMake(kThumbnailStagingOffset,
                                                 0.0,
                                                 viewportSize.width,
                                                 viewportSize.height);
}

- (void)prepareWebViewLayoutForSnapshot:(BrowserWebView *)webView {
    if (webView == nil) {
        return;
    }

    if (webView.superview == self.thumbnailStagingView) {
        webView.frame = self.thumbnailStagingView.bounds;
    }
    [webView setNeedsLayout];
    [webView layoutIfNeeded];

    UIScrollView *scrollView = webView.scrollView;
    [scrollView setNeedsLayout];
    [scrollView layoutIfNeeded];
    [self.rootView setNeedsLayout];
    [self.rootView layoutIfNeeded];
}

- (void)parkWebViewForThumbnailing:(BrowserWebView *)webView {
    if (webView == nil) {
        return;
    }

    [self updateThumbnailStagingViewFrame];
    webView.hidden = NO;
    webView.userInteractionEnabled = NO;
    UIScrollView *scrollView = webView.scrollView;
    scrollView.scrollEnabled = NO;
    scrollView.bounces = self.scrollViewAllowBounces;
    if (webView.superview != self.thumbnailStagingView) {
        [webView removeFromSuperview];
        [self.thumbnailStagingView addSubview:webView];
    }
    webView.frame = self.thumbnailStagingView.bounds;
}

- (BOOL)isWebViewStaged:(BrowserWebView *)webView {
    return webView != nil && webView.superview == self.thumbnailStagingView;
}

- (BrowserWebView *)createConfiguredWebView {
    BrowserWebView *webView = [[BrowserWebView alloc] initWithUserAgent:self.preferencesStore.userAgent
                                            allowsInlineMediaPlayback:YES];
    webView.translatesAutoresizingMaskIntoConstraints = NO;
    webView.clipsToBounds = NO;
    webView.delegate = self.webViewDelegate;
    webView.layoutMargins = UIEdgeInsetsZero;
    webView.opaque = NO;
    webView.backgroundColor = UIColor.blackColor;

    UIScrollView *scrollView = webView.scrollView;
    scrollView.layoutMargins = UIEdgeInsetsZero;
    scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    scrollView.contentOffset = CGPointZero;
    scrollView.contentInset = UIEdgeInsetsZero;
    scrollView.clipsToBounds = NO;
    scrollView.backgroundColor = UIColor.blackColor;
    scrollView.bounces = self.scrollViewAllowBounces;
    [scrollView.panGestureRecognizer addTarget:self action:@selector(handleWebViewPanGesture:)];
    scrollView.scrollEnabled = NO;

    BOOL shouldScalePagesToFit = self.preferencesStore.scalePagesToFit;
    webView.scalesPageToFit = shouldScalePagesToFit;
    webView.contentMode = shouldScalePagesToFit ? UIViewContentModeScaleAspectFit : UIViewContentModeScaleToFill;
    webView.userInteractionEnabled = NO;
    return webView;
}

#pragma mark - Page fullscreen

- (void)setPageFullscreen:(BOOL)fullscreen forWebView:(id)webView {
    if (webView != nil && webView != self.activeWebView) {
        return;
    }
    if (self.pageFullscreenActive == fullscreen) {
        return;
    }
    self.pageFullscreenActive = fullscreen;
    self.topMenuView.hidden = fullscreen || !self.topNavigationVisible;
    [self updateTopNavAndWebView];
    [self updateLoadIndicatorsAnimated:NO];
}

#pragma mark - Page process crashes

- (void)forgetCrashStateForTabIdentifier:(NSString *)identifier {
    if (identifier == nil) {
        return;
    }
    [self.crashedTabIdentifiers removeObject:identifier];
    [self.crashOverlayTabIdentifiers removeObject:identifier];
    [self.lastCrashDates removeObjectForKey:identifier];
}

- (void)webViewContentProcessDidTerminate:(id)webView {
    BrowserTabViewModel *tab = [self tabForWebView:webView];
    if (tab == nil) {
        return;
    }

    NSDate *now = [NSDate date];
    NSDate *previousCrash = self.lastCrashDates[tab.identifier];
    self.lastCrashDates[tab.identifier] = now;
    [self.crashedTabIdentifiers addObject:tab.identifier];
    // Re-apply the last saved position once the page comes back.
    tab.needsScrollRestore = tab.hasSavedScrollOffset;

    BOOL repeatedCrash = previousCrash != nil && [now timeIntervalSinceDate:previousCrash] < kRepeatedCrashInterval;
    NSLog(@"[Browser] Web content process terminated for tab %@ (%@)%@", tab.identifier, tab.URLString, repeatedCrash ? @" - repeated, waiting for user" : @"");
    if (repeatedCrash) {
        [self.crashOverlayTabIdentifiers addObject:tab.identifier];
    }

    if (tab == self.activeTab) {
        [self recoverActiveTabFromCrashIfNeeded];
    }
    // Background tabs (or a tab under Home) reload when they are shown again.
}

- (void)recoverActiveTabFromCrashIfNeeded {
    BrowserTabViewModel *tab = self.activeTab;
    [self updateCrashOverlay];
    if (tab == nil || tab.showingHome ||
        ![self.crashedTabIdentifiers containsObject:tab.identifier] ||
        [self.crashOverlayTabIdentifiers containsObject:tab.identifier]) {
        return;
    }

    // Deferred so a navigation the caller is about to start (e.g. opening a
    // Home tile) wins instead of being replaced by this reload.
    BrowserWebView *webView = self.activeWebView;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (tab != self.activeTab || tab.showingHome || webView != self.activeWebView || webView.isLoading ||
            ![self.crashedTabIdentifiers containsObject:tab.identifier]) {
            return;
        }
        [self reloadCrashedTab:tab webView:webView];
    });
}

- (void)reloadCrashedTab:(BrowserTabViewModel *)tab webView:(BrowserWebView *)webView {
    [self.crashedTabIdentifiers removeObject:tab.identifier];
    [self.crashOverlayTabIdentifiers removeObject:tab.identifier];
    [self updateCrashOverlay];
    if (webView.request.URL != nil) {
        [webView reload];
    } else {
        [self loadStoredContentForTab:tab webView:webView fallbackToHomePage:NO];
    }
}

- (BOOL)reloadCrashedActiveTabIfNeeded {
    BrowserTabViewModel *tab = self.activeTab;
    if (tab == nil || tab.showingHome || ![self.crashOverlayTabIdentifiers containsObject:tab.identifier]) {
        return NO;
    }
    [self reloadCrashedTab:tab webView:self.activeWebView];
    return YES;
}

- (UIView *)makeCrashOverlayView {
    UIView *overlay = [UIView new];
    overlay.backgroundColor = [UIColor colorWithRed:0.07 green:0.07 blue:0.10 alpha:1.0];
    overlay.userInteractionEnabled = NO;

    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:84.0 weight:UIImageSymbolWeightLight];
    UIImageView *iconView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"exclamationmark.triangle" withConfiguration:configuration]];
    iconView.tintColor = [UIColor colorWithWhite:1.0 alpha:0.6];

    UILabel *titleLabel = [UILabel new];
    titleLabel.text = @"This page stopped responding";
    titleLabel.font = [UIFont systemFontOfSize:48.0 weight:UIFontWeightBold];
    titleLabel.textColor = UIColor.whiteColor;

    UILabel *messageLabel = [UILabel new];
    messageLabel.text = @"It crashed more than once, possibly because it uses more memory than Apple TV allows.\nPress Select or the reload button to try again.";
    messageLabel.numberOfLines = 0;
    messageLabel.textAlignment = NSTextAlignmentCenter;
    messageLabel.font = [UIFont systemFontOfSize:28.0 weight:UIFontWeightRegular];
    messageLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.6];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[iconView, titleLabel, messageLabel]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 24.0;
    [overlay addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [stack.widthAnchor constraintLessThanOrEqualToConstant:1200.0],
    ]];
    return overlay;
}

- (void)updateCrashOverlay {
    BrowserTabViewModel *tab = self.activeTab;
    BOOL visible = tab != nil && !tab.showingHome && [self.crashOverlayTabIdentifiers containsObject:tab.identifier];
    if (!visible) {
        self.crashOverlayView.hidden = YES;
        return;
    }
    if (self.crashOverlayView == nil) {
        self.crashOverlayView = [self makeCrashOverlayView];
        [self.browserContainerView addSubview:self.crashOverlayView];
    }
    self.crashOverlayView.frame = self.activeWebView.frame;
    self.crashOverlayView.hidden = NO;
    [self.browserContainerView bringSubviewToFront:self.crashOverlayView];
}

#pragma mark - Load progress

- (void)webView:(id)webView didChangeLoadProgress:(__unused double)progress loading:(__unused BOOL)loading {
    if ([self tabForWebView:webView] == self.activeTab) {
        [self updateLoadIndicatorsAnimated:YES];
    }
}

- (void)updateLoadIndicatorsAnimated:(BOOL)animated {
    BrowserTabViewModel *tab = self.activeTab;
    BrowserWebView *webView = self.activeWebView;
    BOOL loading = tab != nil && !tab.showingHome && webView.isLoading;
    double progress = webView.estimatedProgress;
    [self.topMenuView setLoadProgress:progress loading:loading animated:animated];
    [self updatePageProgressViewWithProgress:progress loading:loading && !self.topNavigationVisible];
}

/// Slim progress line along the top of the screen, used while the top bar is hidden.
- (void)ensurePageProgressView {
    if (self.pageProgressView != nil || self.rootView == nil) {
        return;
    }
    UIView *trackView = [UIView new];
    trackView.userInteractionEnabled = NO;
    trackView.clipsToBounds = YES;
    trackView.hidden = YES;
    trackView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.35];

    UIView *fillView = [UIView new];
    fillView.backgroundColor = [UIColor colorWithRed:0.23 green:0.57 blue:1.0 alpha:1.0];
    [trackView addSubview:fillView];

    if (self.browserContainerView.superview == self.rootView) {
        [self.rootView insertSubview:trackView aboveSubview:self.browserContainerView];
    } else {
        [self.rootView addSubview:trackView];
    }
    self.pageProgressView = trackView;
    self.pageProgressFillView = fillView;
}

- (void)updatePageProgressViewWithProgress:(double)progress loading:(BOOL)loading {
    if (!loading && (self.pageProgressView == nil || self.pageProgressView.hidden)) {
        return;
    }
    [self ensurePageProgressView];
    UIView *trackView = self.pageProgressView;
    CGFloat width = CGRectGetWidth(self.rootView.bounds);
    trackView.frame = CGRectMake(0.0, 0.0, width, 6.0);

    if (loading) {
        BOOL wasHidden = trackView.hidden;
        if (wasHidden) {
            [trackView.layer removeAllAnimations];
            [self.pageProgressFillView.layer removeAllAnimations];
            self.pageProgressValue = 0.0;
            self.pageProgressFillView.frame = CGRectMake(0.0, 0.0, 0.0, 6.0);
            trackView.alpha = 1.0;
            trackView.hidden = NO;
        }
        self.pageProgressValue = MAX(self.pageProgressValue, MAX(0.1, MIN(progress, 1.0)));
        [UIView animateWithDuration:0.25 delay:0.0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
            self.pageProgressFillView.frame = CGRectMake(0.0, 0.0, round(width * self.pageProgressValue), 6.0);
        } completion:nil];
        [self.rootView bringSubviewToFront:self.cursorView];
        return;
    }

    if (self.topNavigationVisible) {
        // The address field shows progress now; drop the line immediately.
        trackView.hidden = YES;
        return;
    }
    self.pageProgressValue = 0.0;
    [UIView animateWithDuration:0.2 animations:^{
        self.pageProgressFillView.frame = CGRectMake(0.0, 0.0, width, 6.0);
    } completion:^(__unused BOOL finished) {
        [UIView animateWithDuration:0.3 animations:^{
            trackView.alpha = 0.0;
        } completion:^(__unused BOOL fadeFinished) {
            if (self.pageProgressValue == 0.0) {
                trackView.hidden = YES;
                trackView.alpha = 1.0;
            }
        }];
    }];
}

- (void)refreshActiveTabUI {
    [self.topMenuView setTabCount:self.viewModel.tabs.count];
    [self updateLoadIndicatorsAnimated:YES];
    BrowserTabViewModel *tab = self.activeTab;
    if (tab == nil) {
        [self.topMenuView setDisplayedURLString:nil];
        [self.topMenuView setBackEnabled:NO forwardEnabled:NO];
        return;
    }

    if (tab.showingHome) {
        [self.topMenuView setHomeActive:YES];
        [self.topMenuView setDisplayedURLString:nil];
        [self.topMenuView setBackEnabled:[self activeTabHasPageBehindHome] forwardEnabled:NO];
        return;
    }

    NSURLRequest *request = self.activeWebView.request;
    NSString *currentURL = tab.URLString.length > 0 ? tab.URLString : request.URL.absoluteString;
    [self.topMenuView setHomeActive:NO];
    [self.topMenuView setDisplayedURLString:currentURL];
    [self.topMenuView setBackEnabled:self.activeWebView.canGoBack forwardEnabled:self.activeWebView.canGoForward];

    if (request != nil) {
        [self.host browserTabCoordinatorUpdateTextFontSize];
    }
}

- (BOOL)restoreBrowserSession {
    return [self.sessionStore restoreSessionIntoViewModel:self.viewModel];
}

- (void)restoreInitialStateOrCreateFirstTab {
    [BrowserHomeStore seedDefaultPinnedSitesIfNeeded];
    self.topMenuView.hidden = !self.viewModel.topNavigationBarVisible;
    if (![self restoreBrowserSession]) {
        [self createNewTabLoadingHomePage:NO];
        return;
    }
    [self initWebView];
    [self refreshActiveTabUI];
}

- (void)webViewDidAppear {
    NSURLRequest *savedReopenRequest = [self.sessionStore consumeSavedURLToReopenRequestWithNavigationService:self.navigationService];
    if (savedReopenRequest != nil) {
        [self dismissHomeIfNeeded];
        [self.activeWebView loadRequest:savedReopenRequest];
    } else if (self.showingHome) {
        [self updateHomeVisibility];
    } else if (self.activeWebView.request == nil) {
        [self loadStoredContentForTab:self.activeTab webView:self.activeWebView fallbackToHomePage:YES];
    }
}

- (void)loadHomePage {
    BrowserTabViewModel *tab = self.activeTab;
    if (tab == nil) {
        return;
    }
    [self captureSnapshotForTab:tab];
    [self showHomeForTab:tab];
    [self reloadHome];
    [self persistSession];
}

- (void)initWebView {
    self.topMenuView.hidden = !self.viewModel.topNavigationBarVisible;

    BrowserTabViewModel *tab = [self.viewModel ensureActiveTab];
    if (tab == nil) {
        return;
    }

    BrowserWebView *webView = self.webViewsByTabIdentifier[tab.identifier];
    if (webView == nil) {
        webView = [self createConfiguredWebView];
        self.webViewsByTabIdentifier[tab.identifier] = webView;
    }
    self.activeWebView = webView;
    [self attachActiveWebView];
}

- (void)attachActiveWebView {
    BrowserTabViewModel *tab = self.activeTab;
    if (tab == nil) {
        return;
    }

    BrowserWebView *activeWebView = self.webViewsByTabIdentifier[tab.identifier];
    if (activeWebView == nil) {
        return;
    }

    [self updateThumbnailStagingViewFrame];
    for (BrowserTabViewModel *candidate in self.viewModel.tabs) {
        BrowserWebView *candidateWebView = self.webViewsByTabIdentifier[candidate.identifier];
        if (candidateWebView == nil || candidateWebView == activeWebView) {
            continue;
        }
        [self parkWebViewForThumbnailing:candidateWebView];
    }

    [self setPageFullscreen:NO forWebView:nil];
    self.activeWebView = activeWebView;
    [self.activeWebView removeFromSuperview];
    [self.browserContainerView addSubview:self.activeWebView];
    [self updateTopNavAndWebView];

    UIScrollView *scrollView = self.activeWebView.scrollView;
    [scrollView setNeedsLayout];
    [scrollView layoutIfNeeded];
    [self.rootView setNeedsLayout];
    [self.rootView layoutIfNeeded];
    scrollView.bounces = self.scrollViewAllowBounces;

    BOOL scrollModeActive = ![self.host browserTabCoordinatorIsCursorModeEnabled] &&
        ![self.host browserTabCoordinatorIsTabOverviewVisible];
    // The app scrolls pages itself (manual pan + inertia); WebKit never gets remote touches.
    scrollView.scrollEnabled = NO;
    self.activeWebView.userInteractionEnabled = NO;
    self.manualScrollPanRecognizer.enabled = scrollModeActive;

    [self refreshActiveTabUI];
    [self updateHomeVisibility];
}

- (void)updateStoredScrollOffsetForTab:(BrowserTabViewModel *)tab {
    // While a restore is pending (or the page crashed) the live offset is meaningless; keep the saved one.
    if (tab == nil || tab.needsScrollRestore || [self.crashedTabIdentifiers containsObject:tab.identifier]) {
        return;
    }

    BrowserWebView *webView = self.webViewsByTabIdentifier[tab.identifier];
    if (webView == nil) {
        return;
    }

    UIScrollView *scrollView = webView.scrollView;
    tab.savedScrollOffset = scrollView.contentOffset;
    tab.hasSavedScrollOffset = YES;
}

- (void)persistSession {
    for (BrowserTabViewModel *tab in self.viewModel.tabs) {
        [self updateStoredScrollOffsetForTab:tab];
    }
    [self.sessionStore saveSessionForViewModel:self.viewModel];
}

- (void)loadStoredContentForTab:(BrowserTabViewModel *)tab
                        webView:(BrowserWebView *)webView
             fallbackToHomePage:(BOOL)fallbackToHomePage {
    if (tab == nil || tab.showingHome || webView == nil) {
        return;
    }

    NSString *URLString = tab.URLString.length > 0 ? tab.URLString : tab.requestURL;
    NSURLRequest *request = URLString.length > 0 ? [self.navigationService requestForURLString:URLString] : nil;
    if (request != nil) {
        [webView loadRequest:request];
    } else if (fallbackToHomePage) {
        [self showHomeForTab:tab];
    }
}

- (void)restoreSavedScrollOffsetForTab:(BrowserTabViewModel *)tab webView:(BrowserWebView *)webView {
    if (tab == nil || !tab.needsScrollRestore || !tab.hasSavedScrollOffset) {
        return;
    }

    UIScrollView *scrollView = webView.scrollView;
    CGPoint savedScrollOffset = tab.savedScrollOffset;
    dispatch_async(dispatch_get_main_queue(), ^{
        [scrollView layoutIfNeeded];
        CGFloat maxOffsetX = MAX(0.0, scrollView.contentSize.width - CGRectGetWidth(scrollView.bounds));
        CGFloat maxOffsetY = MAX(0.0, scrollView.contentSize.height - CGRectGetHeight(scrollView.bounds));
        CGPoint clampedScrollOffset = CGPointMake(MIN(MAX(savedScrollOffset.x, 0.0), maxOffsetX),
                                                  MIN(MAX(savedScrollOffset.y, 0.0), maxOffsetY));
        [scrollView setContentOffset:clampedScrollOffset animated:NO];
        tab.savedScrollOffset = clampedScrollOffset;
        tab.hasSavedScrollOffset = YES;
        [self captureSnapshotForTab:tab];
        [self persistSession];
    });
    tab.needsScrollRestore = NO;
}

- (void)captureSnapshotForTab:(BrowserTabViewModel *)tab {
    if (tab == nil) {
        return;
    }

    if (!tab.needsScrollRestore) {
        [self updateStoredScrollOffsetForTab:tab];
    }

    if (tab.showingHome) {
        // The page behind Home is not what the user sees; keep the Home snapshot instead.
        if (tab == self.activeTab && _homeView != nil && !_homeView.hidden) {
            UIImage *homeSnapshot = [_homeView snapshotImage];
            if (homeSnapshot != nil) {
                tab.snapshotImage = homeSnapshot;
            }
        }
        return;
    }

    BrowserWebView *webView = self.webViewsByTabIdentifier[tab.identifier];
    if (webView == nil || CGRectIsEmpty(webView.bounds) || [self.crashedTabIdentifiers containsObject:tab.identifier]) {
        // A crashed page renders black; keep the last good thumbnail.
        return;
    }

    [self prepareWebViewLayoutForSnapshot:webView];
    UIGraphicsBeginImageContextWithOptions(webView.bounds.size, YES, 0.0);
    [webView drawViewHierarchyInRect:webView.bounds afterScreenUpdates:NO];
    UIImage *snapshotImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    if (snapshotImage != nil) {
        tab.snapshotImage = snapshotImage;
    }
}

- (void)captureSnapshotForCurrentTab {
    [self captureSnapshotForTab:self.activeTab];
}

- (void)prepareTabOverviewThumbnails {
    [self updateThumbnailStagingViewFrame];

    for (BrowserTabViewModel *tab in self.viewModel.tabs) {
        BrowserWebView *webView = self.webViewsByTabIdentifier[tab.identifier];
        if (tab == self.activeTab) {
            [self captureSnapshotForTab:tab];
            continue;
        }

        if (webView == nil) {
            webView = [self createConfiguredWebView];
            self.webViewsByTabIdentifier[tab.identifier] = webView;
        }

        [self parkWebViewForThumbnailing:webView];
        if (webView.request == nil) {
            [self loadStoredContentForTab:tab webView:webView fallbackToHomePage:NO];
            continue;
        }

        [self captureSnapshotForTab:tab];
    }
}

- (void)showMaxTabsAlert {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Maximum Tabs Reached"
                                                                             message:@"This build keeps up to five tabs open at once."
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    [alertController addAction:[UIAlertAction actionWithTitle:@"Dismiss"
                                                        style:UIAlertActionStyleCancel
                                                      handler:nil]];
    [self.host browserTabCoordinatorPresentViewController:alertController];
}

- (void)createNewTabLoadingHomePage:(BOOL)loadHomePage {
    BrowserTabViewModel *tab = [self.viewModel addTab];
    if (tab == nil) {
        [self showMaxTabsAlert];
        return;
    }

    (void)tab;
    [self initWebView];
    [self refreshActiveTabUI];
    [self.rootView bringSubviewToFront:self.cursorView];

    if (loadHomePage) {
        [self loadHomePage];
    }
    [self persistSession];
}

- (BOOL)createNewTabWithRequest:(NSURLRequest *)request {
    if (request == nil || request.URL == nil) {
        return NO;
    }

    [self captureSnapshotForTab:self.activeTab];
    BrowserTabViewModel *tab = [self.viewModel addTab];
    if (tab == nil) {
        [self showMaxTabsAlert];
        return NO;
    }
    tab.showingHome = NO;

    [self initWebView];
    [self refreshActiveTabUI];
    [self.rootView bringSubviewToFront:self.cursorView];
    [self.activeWebView loadRequest:request];
    [self persistSession];
    return YES;
}

- (void)switchToTabAtIndex:(NSInteger)tabIndex {
    if (tabIndex < 0 || tabIndex >= self.viewModel.tabs.count) {
        return;
    }

    BrowserTabViewModel *currentTab = self.activeTab;
    [self captureSnapshotForTab:currentTab];

    [self.viewModel switchToTabAtIndex:tabIndex];
    [self initWebView];
    [self.rootView bringSubviewToFront:self.cursorView];
    if (self.activeWebView.request == nil) {
        [self loadStoredContentForTab:self.activeTab webView:self.activeWebView fallbackToHomePage:YES];
    }
    [self persistSession];
}

- (void)closeTabAtIndex:(NSInteger)tabIndex {
    if (tabIndex < 0 || tabIndex >= self.viewModel.tabs.count) {
        return;
    }

    BOOL closingActiveTab = tabIndex == self.viewModel.activeTabIndex;
    BrowserTabViewModel *tab = self.viewModel.tabs[tabIndex];
    NSString *closedURL = tab.URLString.length > 0 ? tab.URLString : tab.requestURL;
    NSString *closedTitle = [tab.title isEqualToString:@"New Tab"] ? nil : tab.title;
    [BrowserHomeStore recordClosedTabWithURLString:closedURL title:closedTitle];
    [self.webViewsByTabIdentifier[tab.identifier] removeFromSuperview];
    [self.webViewsByTabIdentifier removeObjectForKey:tab.identifier];
    [self forgetCrashStateForTabIdentifier:tab.identifier];
    [self.viewModel removeTabAtIndex:tabIndex];

    if (self.viewModel.tabs.count == 0) {
        [self createNewTabLoadingHomePage:YES];
        return;
    }

    if (closingActiveTab) {
        [self initWebView];
        if (self.activeWebView.request == nil) {
            [self loadStoredContentForTab:self.activeTab webView:self.activeWebView fallbackToHomePage:YES];
        }
    }

    [self refreshActiveTabUI];
    [self reloadHome];
    [self persistSession];
}

- (void)recreateActiveWebViewPreservingCurrentURL {
    BrowserTabViewModel *tab = self.activeTab;
    if (tab == nil) {
        return;
    }

    NSString *currentURL = self.activeWebView.request.URL.absoluteString;
    [self.webViewsByTabIdentifier[tab.identifier] removeFromSuperview];
    [self.webViewsByTabIdentifier removeObjectForKey:tab.identifier];
    tab.requestURL = currentURL ?: @"";
    tab.previousURL = @"";
    tab.URLString = currentURL ?: @"";
    [self initWebView];

    if (currentURL.length > 0) {
        NSURLRequest *request = [self.navigationService requestForURLString:currentURL];
        if (request != nil) {
            [self.activeWebView loadRequest:request];
        }
    } else {
        [self loadHomePage];
    }
    [self persistSession];
}

- (void)handleWebViewPanGesture:(UIPanGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer.state != UIGestureRecognizerStateEnded &&
        gestureRecognizer.state != UIGestureRecognizerStateCancelled &&
        gestureRecognizer.state != UIGestureRecognizerStateFailed) {
        return;
    }

    UIView *gestureView = gestureRecognizer.view;
    if (![gestureView isKindOfClass:[UIScrollView class]]) {
        return;
    }

    UIScrollView *scrollView = (UIScrollView *)gestureView;
    if (scrollView != self.activeWebView.scrollView) {
        return;
    }

    [self persistSession];
}

- (BOOL)isPrimaryDocumentRequest:(NSURLRequest *)request {
    NSURL *requestURL = request.URL;
    NSURL *mainDocumentURL = request.mainDocumentURL;
    if (requestURL == nil) {
        return NO;
    }
    if (mainDocumentURL == nil) {
        return YES;
    }
    return [requestURL isEqual:mainDocumentURL];
}

- (BrowserTabViewModel *)tabForWebView:(id)webView {
    for (BrowserTabViewModel *tab in self.viewModel.tabs) {
        if (self.webViewsByTabIdentifier[tab.identifier] == webView) {
            return tab;
        }
    }
    return nil;
}

- (void)prepareTabForRequest:(NSURLRequest *)request webView:(id)webView {
    BrowserTabViewModel *tab = [self tabForWebView:webView];
    if (tab == nil || ![self isPrimaryDocumentRequest:request]) {
        return;
    }
    NSString *requestURL = request.URL.absoluteString ?: @"";
    if (tab == self.activeTab && self.pageFullscreenActive) {
        // A new page never inherits the previous page's fullscreen state.
        [self setPageFullscreen:NO forWebView:nil];
    }
    if (tab.URLString.length > 0 && ![tab.URLString isEqualToString:requestURL]) {
        tab.savedScrollOffset = CGPointZero;
        tab.hasSavedScrollOffset = NO;
        tab.needsScrollRestore = NO;
    }
    tab.requestURL = requestURL;
}

- (void)webViewDidStartLoad:(id)webView {
    BrowserTabViewModel *tab = [self tabForWebView:webView];
    if (tab == nil) {
        return;
    }

    tab.previousURL = tab.requestURL;
    [self.crashedTabIdentifiers removeObject:tab.identifier];
    if ([self.crashOverlayTabIdentifiers containsObject:tab.identifier]) {
        [self.crashOverlayTabIdentifiers removeObject:tab.identifier];
        [self updateCrashOverlay];
    }
    if (tab == self.activeTab) {
        [self updateLoadIndicatorsAnimated:YES];
    }
}

- (void)webViewDidFinishLoad:(id)webView {
    BrowserTabViewModel *tab = [self tabForWebView:webView];
    if (tab == nil) {
        return;
    }

    NSString *theTitle = [webView stringByEvaluatingJavaScriptFromString:@"document.title"];
    NSURLRequest *request = [webView request];
    NSString *currentURL = request.URL.absoluteString ?: @"";
    [self.navigationService updateTab:tab withPageTitle:theTitle currentURLString:currentURL];

    if (tab == self.activeTab) {
        [self refreshActiveTabUI];
    }
    if ((tab != self.activeTab && [self isWebViewStaged:webView]) || tab.showingHome) {
        [webView pauseAllMediaPlayback];
    }
    [self restoreSavedScrollOffsetForTab:tab webView:webView];
    if (!tab.needsScrollRestore) {
        [self captureSnapshotForTab:tab];
        [self persistSession];
    }
}

@end
