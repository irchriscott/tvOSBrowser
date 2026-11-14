//
//  ViewController.m
//  Browser
//
//  Created by Steven Troughton-Smith on 20/09/2015.
//  Improved by Jip van Akker on 14/10/2015 through 10/01/2019
//

#import <AVKit/AVKit.h>

#import "BrowserAdBlocker.h"
#import "BrowserMenuCoordinator.h"
#import "BrowserPageNavigator.h"
#import "BrowserDOMInteractionService.h"
#import "BrowserHomeView.h"
#import "BrowserNavigationService.h"
#import "BrowserPageActionCoordinator.h"
#import "BrowserPreferencesStore.h"
#import "BrowserRemoteInputController.h"
#import "BrowserSessionStore.h"
#import "BrowserTabViewModel.h"
#import "BrowserTabCoordinator.h"
#import "BrowserTabOverviewController.h"
#import "BrowserVideoPlaybackCoordinator.h"
#import "BrowserViewModel.h"
#import "ViewController.h"

static NSString * const kBrowserGlobalSelectPressEndedNotification = @"BrowserGlobalSelectPressEndedNotification";

static UIColor *kTextColor(void) {
    if (@available(tvOS 13, *)) {
        return UIColor.labelColor;
    } else {
        return UIColor.blackColor;
    }
}

@interface ViewController () <BrowserMenuCoordinatorHost, BrowserPageActionCoordinatorHost, BrowserRemoteInputControllerHost, BrowserTabCoordinatorHost, BrowserTabOverviewControllerHost, BrowserTopBarViewDelegate, BrowserVideoPlaybackCoordinatorHost>

@property (nonatomic) BrowserDOMInteractionService *domInteractionService;
@property (nonatomic) BrowserMenuCoordinator *menuCoordinator;
@property (nonatomic) BrowserNavigationService *navigationService;
@property (nonatomic) BrowserPageActionCoordinator *pageActionCoordinator;
@property (nonatomic) BrowserPreferencesStore *preferencesStore;
@property (nonatomic) BrowserRemoteInputController *remoteInputController;
@property (nonatomic) BrowserSessionStore *sessionStore;
@property (nonatomic) BrowserTabCoordinator *tabCoordinator;
@property (nonatomic) BrowserTabOverviewController *tabOverviewController;
@property (nonatomic) BrowserVideoPlaybackCoordinator *videoPlaybackCoordinator;
@property (nonatomic) BrowserViewModel *viewModel;
@property (nonatomic) BOOL displayedHintsOnLaunch;
@property (nonatomic) BOOL scrollViewAllowBounces;
@property (nonatomic, getter=isTopBarFocusActive) BOOL topBarFocusActive;
@property (nonatomic) BrowserPageNavigator *pageNavigator;
@property (nonatomic) UIVisualEffectView *toastView;
@property (nonatomic) UILabel *toastLabel;
@property (nonatomic) BOOL homeWasVisible;
/// Cursor/scroll mode to return to on web pages; Home always runs without the cursor.
@property (nonatomic) BOOL cursorModeBeforeHome;

@end

@implementation ViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.definesPresentationContext = YES;
    self.scrollViewAllowBounces = YES;
    self.cursorModeBeforeHome = YES;

    self.preferencesStore = [BrowserPreferencesStore new];
    [self.preferencesStore ensureUserAgentConsistency];

    self.viewModel = [BrowserViewModel new];
    self.viewModel.topNavigationBarVisible = self.preferencesStore.topNavigationBarVisible;
    self.viewModel.textFontSize = self.preferencesStore.textFontSize;
    self.viewModel.fullscreenVideoPlaybackEnabled = self.preferencesStore.fullscreenVideoPlaybackEnabled;

    self.domInteractionService = [BrowserDOMInteractionService new];
    self.pageNavigator = [BrowserPageNavigator new];
    self.navigationService = [[BrowserNavigationService alloc] initWithPreferencesStore:self.preferencesStore];
    self.sessionStore = [BrowserSessionStore new];
    self.menuCoordinator = [[BrowserMenuCoordinator alloc] initWithHost:self preferencesStore:self.preferencesStore];
    self.remoteInputController = [[BrowserRemoteInputController alloc] initWithHost:self rootView:self.view];
    [self.view addSubview:self.remoteInputController.cursorView];
    self.videoPlaybackCoordinator = [[BrowserVideoPlaybackCoordinator alloc] initWithHost:self
                                                                      domInteractionService:self.domInteractionService];
    self.tabCoordinator = [[BrowserTabCoordinator alloc] initWithHost:self
                                                             viewModel:self.viewModel
                                                      preferencesStore:self.preferencesStore
                                                     navigationService:self.navigationService
                                                          sessionStore:self.sessionStore
                                                    browserContainerView:self.browserContainerView
                                                              rootView:self.view
                                                            topMenuView:self.topMenuView
                                                            cursorView:self.remoteInputController.cursorView
                                               manualScrollPanRecognizer:self.remoteInputController.manualScrollPanRecognizer
                                                           webViewDelegate:self
                                                       scrollViewAllowBounces:self.scrollViewAllowBounces];
    self.tabOverviewController = [[BrowserTabOverviewController alloc] initWithHost:self
                                                                            viewModel:self.viewModel
                                                                             rootView:self.view
                                                                           topMenuView:self.topMenuView
                                                                           cursorView:self.remoteInputController.cursorView];
    self.pageActionCoordinator = [[BrowserPageActionCoordinator alloc] initWithHost:self
                                                               domInteractionService:self.domInteractionService
                                                                   navigationService:self.navigationService
                                                            videoPlaybackCoordinator:self.videoPlaybackCoordinator];

    self.topMenuView.delegate = self;
    self.topMenuView.loadingSpinner.hidesWhenStopped = YES;
    self.remoteInputController.cursorView.hidden = NO;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleApplicationWillResignActive:)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleApplicationDidEnterBackground:)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleApplicationWillTerminate:)
                                                 name:UIApplicationWillTerminateNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handlePopupBlockedNotification:)
                                                 name:BrowserAdBlockerDidBlockPopupNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleGlobalSelectPressEndedNotification:)
                                                 name:kBrowserGlobalSelectPressEndedNotification
                                               object:nil];

    [self.tabCoordinator restoreInitialStateOrCreateFirstTab];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.tabCoordinator webViewDidAppear];
    if (!self.preferencesStore.dontShowHintsOnLaunch && !self.displayedHintsOnLaunch) {
        [self showHintsAlert];
    }
    self.displayedHintsOnLaunch = YES;
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Notifications

- (void)handleApplicationWillResignActive:(NSNotification *)notification {
    (void)notification;
    [self.tabCoordinator persistSession];
}

- (void)handleApplicationDidEnterBackground:(NSNotification *)notification {
    (void)notification;
    [self.tabCoordinator persistSession];
}

- (void)handleApplicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.tabCoordinator persistSession];
}

- (void)handlePopupBlockedNotification:(NSNotification *)notification {
    (void)notification;
    [self showToast:@"Blocked a pop-up"];
}

- (void)handleGlobalSelectPressEndedNotification:(NSNotification *)notification {
    (void)notification;
    if (self.tabCoordinator.showingHome) {
        return;
    }
    [self.remoteInputController handleGlobalSelectPressEndedNotification];
}

#pragma mark - Helpers

/// Short message near the bottom of the screen (mode changes, blocked pop-ups).
- (void)showToast:(NSString *)message {
    if (self.toastView == nil) {
        UIVisualEffectView *toastView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
        toastView.userInteractionEnabled = NO;
        toastView.clipsToBounds = YES;
        toastView.alpha = 0.0;
        UILabel *label = [UILabel new];
        label.textColor = UIColor.whiteColor;
        label.font = [UIFont systemFontOfSize:28.0 weight:UIFontWeightSemibold];
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 2;
        [toastView.contentView addSubview:label];
        [self.view addSubview:toastView];
        self.toastView = toastView;
        self.toastLabel = label;
    }

    self.toastLabel.text = message;
    CGSize maxSize = CGSizeMake(MIN(1300.0, CGRectGetWidth(self.view.bounds) - 160.0), 200.0);
    CGSize textSize = [self.toastLabel sizeThatFits:maxSize];
    textSize.width = MIN(ceil(textSize.width), maxSize.width);
    CGSize toastSize = CGSizeMake(textSize.width + 72.0, ceil(textSize.height) + 36.0);
    self.toastView.frame = CGRectMake(floor((CGRectGetWidth(self.view.bounds) - toastSize.width) / 2.0),
                                      CGRectGetHeight(self.view.bounds) - toastSize.height - 90.0,
                                      toastSize.width,
                                      toastSize.height);
    self.toastView.layer.cornerRadius = MIN(toastSize.height / 2.0, 36.0);
    self.toastLabel.frame = CGRectInset(self.toastView.bounds, 36.0, 18.0);
    [self.view bringSubviewToFront:self.toastView];
    [self.view bringSubviewToFront:self.remoteInputController.cursorView];

    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideToast) object:nil];
    [UIView animateWithDuration:0.2 animations:^{
        self.toastView.alpha = 1.0;
    }];
    [self performSelector:@selector(hideToast) withObject:nil afterDelay:2.6];
}

- (void)hideToast {
    [UIView animateWithDuration:0.35 animations:^{
        self.toastView.alpha = 0.0;
    }];
}

/// Navigation mode: Select opens whatever the page highlight is on.
- (void)activateHighlightedPageElement {
    if (self.webview == nil || self.tabCoordinator.showingHome) {
        return;
    }
    NSValue *point = [self.pageNavigator activationPointInWebView:self.webview];
    if (point == nil) {
        [self showToast:@"Click the edges of the remote's touch surface to pick a link"];
        return;
    }
    [self.pageActionCoordinator handlePageSelectionAtDOMPoint:point.CGPointValue webView:self.webview];
}

- (BrowserWebView *)webview {
    return self.tabCoordinator.activeWebView;
}

- (CGPoint)browserDOMPointForCursor {
    return [self.domInteractionService DOMPointForCursorOrigin:self.remoteInputController.cursorView.frame.origin
                                                        inView:self.view
                                                       webView:self.webview];
}

- (void)loadHomePage {
    [self.tabCoordinator loadHomePage];
}

- (void)loadRequestInActiveTab:(NSURLRequest *)request {
    if (request == nil) {
        return;
    }
    [self.tabCoordinator dismissHomeIfNeeded];
    [self.webview loadRequest:request];
}

- (void)browserTabCoordinatorHomeVisibilityChanged:(BOOL)visible {
    if (visible && !self.homeWasVisible) {
        // While the tab overview is up it has already parked the cursor; keep the saved preference.
        if (!self.tabOverviewController.visible) {
            self.cursorModeBeforeHome = self.remoteInputController.cursorModeEnabled;
        }
        [self.remoteInputController setCursorModeEnabled:NO];
    } else if (!visible && self.homeWasVisible) {
        [self.remoteInputController setCursorModeEnabled:self.cursorModeBeforeHome];
    }
    self.homeWasVisible = visible;
    [self updateTopBarFocusability];
    [self setNeedsFocusUpdate];
    [self updateFocusIfNeeded];
}

- (void)browserTabCoordinatorShowAddressEntry {
    [self showInputURLorSearchGoogle];
}

- (void)browserTabCoordinatorDidConsumeSelectPress {
    [self.remoteInputController suppressGlobalSelectPress];
}

/// On Home the top bar is part of normal focus navigation (swipe up from the
/// tiles); on web pages it only takes focus while top-bar focus mode is active.
- (BOOL)isHomeTopBarFocusAvailable {
    return self.tabCoordinator.showingHome &&
        self.viewModel.topNavigationBarVisible &&
        !self.topMenuView.hidden;
}

- (void)updateTopBarFocusability {
    [self.topMenuView setFocusModeActive:self.topBarFocusActive || [self isHomeTopBarFocusAvailable]];
}

- (void)showAdvancedMenu {
    [self deactivateTopBarFocusMode];
    [self.menuCoordinator showAdvancedMenu];
}

- (BOOL)canActivateTopBarFocusMode {
    return self.presentedViewController == nil &&
        !self.tabOverviewController.visible &&
        self.viewModel.topNavigationBarVisible &&
        !self.topMenuView.hidden;
}

- (void)activateTopBarFocusMode {
    if (![self canActivateTopBarFocusMode]) {
        return;
    }
    if (self.topBarFocusActive) {
        return;
    }

    self.topBarFocusActive = YES;
    [self updateTopBarFocusability];
    [self.remoteInputController refreshInteractionState];
    [self setNeedsFocusUpdate];
    [self updateFocusIfNeeded];
}

- (void)deactivateTopBarFocusMode {
    if (!self.topBarFocusActive) {
        return;
    }

    self.topBarFocusActive = NO;
    [self updateTopBarFocusability];
    [self.remoteInputController refreshInteractionState];
    [self setNeedsFocusUpdate];
    [self updateFocusIfNeeded];
}

- (void)performTopBarAction:(BrowserTopBarAction)action {
    [self.remoteInputController suppressGlobalSelectPress];
    [self deactivateTopBarFocusMode];

    BOOL showingHome = self.tabCoordinator.showingHome;
    switch (action) {
        case BrowserTopBarActionBack:
            if (showingHome) {
                [self.tabCoordinator returnFromHomeToPage];
            } else if (self.webview.canGoBack) {
                [self.webview goBack];
            }
            break;
        case BrowserTopBarActionRefresh:
            if (showingHome) {
                [self.tabCoordinator reloadHome];
            } else {
                [self.webview reload];
            }
            break;
        case BrowserTopBarActionForward:
            if (self.webview.canGoForward) {
                [self.tabCoordinator dismissHomeIfNeeded];
                [self.webview goForward];
            }
            break;
        case BrowserTopBarActionHome:
            [self loadHomePage];
            break;
        case BrowserTopBarActionTabs:
            [self browserShowTabOverview];
            break;
        case BrowserTopBarActionURL:
            [self showInputURLorSearchGoogle];
            break;
        case BrowserTopBarActionFullscreen:
            if (self.viewModel.topNavigationBarVisible) {
                UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Hide Top Navigation bar?"
                                                                                         message:@"You can still open the side menu by double-tapping the Play/Pause button."
                                                                                  preferredStyle:UIAlertControllerStyleAlert];
                [alertController addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
                [alertController addAction:[UIAlertAction actionWithTitle:@"Hide Bar"
                                                                    style:UIAlertActionStyleDestructive
                                                                  handler:^(__unused UIAlertAction *action) {
                    [self browserHideTopNav];
                }]];
                [self browserPresentViewController:alertController];
            } else {
                [self browserShowTopNav];
            }
            break;
        case BrowserTopBarActionMenu:
            [self showAdvancedMenu];
            break;
    }
}

- (void)updateTextFontSize {
    if (self.webview == nil) {
        return;
    }

    NSString *jsString = [[NSString alloc] initWithFormat:
                          @"(function(){"
                           "var value='%lu%%';"
                           "var multiplier=%lu/100;"
                           "if (document.documentElement && document.documentElement.style) {"
                               "document.documentElement.style.setProperty('-webkit-text-size-adjust', value, 'important');"
                               "document.documentElement.style.setProperty('text-size-adjust', value, 'important');"
                           "}"
                           "if (document.body && document.body.style) {"
                               "document.body.style.setProperty('-webkit-text-size-adjust', value, 'important');"
                               "document.body.style.setProperty('text-size-adjust', value, 'important');"
                           "}"
                           "if (!document.body || !window.getComputedStyle) { return value; }"
                           "var elements = document.querySelectorAll('body, body *');"
                           "for (var i = 0; i < elements.length; i++) {"
                               "var element = elements[i];"
                               "if (!element || !element.tagName) { continue; }"
                               "var tagName = element.tagName.toLowerCase();"
                               "if (tagName === 'script' || tagName === 'style' || tagName === 'noscript') { continue; }"
                               "var originalSize = element.getAttribute('data-browser-original-font-size');"
                               "if (!originalSize) {"
                                   "var computedSize = window.getComputedStyle(element).fontSize || '';"
                                   "if (computedSize.indexOf('px') == -1) { continue; }"
                                   "var parsedSize = parseFloat(computedSize);"
                                   "if (!isFinite(parsedSize) || parsedSize <= 0) { continue; }"
                                   "originalSize = String(parsedSize);"
                                   "element.setAttribute('data-browser-original-font-size', originalSize);"
                               "}"
                               "var baseSize = parseFloat(originalSize);"
                               "if (!isFinite(baseSize) || baseSize <= 0) { continue; }"
                               "element.style.setProperty('font-size', (baseSize * multiplier) + 'px', 'important');"
                           "}"
                           "return value;"
                          "})()",
                          (unsigned long)self.viewModel.textFontSize,
                          (unsigned long)self.viewModel.textFontSize];
    [self.webview stringByEvaluatingJavaScriptFromString:jsString];
}

- (void)showInputURLorSearchGoogle {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Enter URL or Search Terms"
                                                                             message:@""
                                                                      preferredStyle:UIAlertControllerStyleAlert];

    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.keyboardType = UIKeyboardTypeURL;
        textField.placeholder = @"Enter URL or Search Terms";
        textField.textColor = kTextColor();
        [textField setReturnKeyType:UIReturnKeyDone];
    }];

    __weak typeof(self) weakSelf = self;
    [alertController addAction:[UIAlertAction actionWithTitle:@"Search Google"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        UITextField *textField = alertController.textFields.firstObject;
        NSURLRequest *searchRequest = [weakSelf.navigationService googleSearchRequestForQuery:textField.text];
        if (searchRequest != nil) {
            [weakSelf loadRequestInActiveTab:searchRequest];
        } else {
            [weakSelf requestURLorSearchInput];
        }
    }]];
    [alertController addAction:[UIAlertAction actionWithTitle:@"Go To Website"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        UITextField *textField = alertController.textFields.firstObject;
        if (textField.text.length == 0) {
            [weakSelf requestURLorSearchInput];
            return;
        }
        NSURLRequest *navigationRequest = [weakSelf.navigationService requestForEnteredAddressString:textField.text];
        if (navigationRequest != nil) {
            [weakSelf loadRequestInActiveTab:navigationRequest];
        } else {
            [weakSelf requestURLorSearchInput];
        }
    }]];
    [alertController addAction:[UIAlertAction actionWithTitle:nil style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alertController animated:YES completion:nil];

    UITextField *textField = alertController.textFields.firstObject;
    if (self.webview.request == nil || self.webview.request.URL.absoluteString.length > 0) {
        [textField becomeFirstResponder];
    }
}

- (void)requestURLorSearchInput {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Quick Menu"
                                                                             message:@""
                                                                      preferredStyle:UIAlertControllerStyleAlert];

    BOOL showingHome = self.tabCoordinator.showingHome;
    if (!showingHome && self.webview.canGoForward) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Go Forward"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            [self.webview goForward];
        }]];
    }

    [alertController addAction:[UIAlertAction actionWithTitle:@"Input URL or Search with Google"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        [self showInputURLorSearchGoogle];
    }]];

    if (!showingHome && self.webview.request != nil && self.webview.request.URL.absoluteString.length > 0) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Reload Page"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            self.tabCoordinator.previousURL = @"";
            [self.webview reload];
        }]];
    }

    [alertController addAction:[UIAlertAction actionWithTitle:nil style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alertController animated:YES completion:nil];
}

- (void)showHintsAlert {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Usage Guide"
                                                                             message:@"Double press the touch area to switch between cursor & navigation mode.\nPress the touch area while in cursor mode to click.\nIn navigation mode, click the edges of the touch surface to move between links and buttons, swipe to scroll, and press Select to open.\nSingle tap to Menu button to Go Back, or Exit on root page.\nSingle tap the Play/Pause button to: Go Forward, Enter URL or Reload Page.\nDouble tap the Play/Pause to show the Advanced Menu with more options.\nUse the tabs icon in the top bar to open the tab overview."
                                                                      preferredStyle:UIAlertControllerStyleAlert];

    __weak typeof(self) weakSelf = self;
    if (self.preferencesStore.dontShowHintsOnLaunch) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Always Show On Launch"
                                                            style:UIAlertActionStyleDestructive
                                                          handler:^(__unused UIAlertAction *action) {
            weakSelf.preferencesStore.dontShowHintsOnLaunch = NO;
        }]];
    } else {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Don't Show This Again"
                                                            style:UIAlertActionStyleDestructive
                                                          handler:^(__unused UIAlertAction *action) {
            weakSelf.preferencesStore.dontShowHintsOnLaunch = YES;
        }]];
    }
    [alertController addAction:[UIAlertAction actionWithTitle:@"Dismiss"
                                                        style:UIAlertActionStyleCancel
                                                      handler:nil]];
    [self presentViewController:alertController animated:YES completion:nil];
}

- (void)browserHandlePrimaryAction {
    if ([self.tabCoordinator reloadCrashedActiveTabIfNeeded]) {
        return;
    }
    if (!self.remoteInputController.cursorModeEnabled) {
        [self activateHighlightedPageElement];
        return;
    }
    if (self.webview == nil) {
        return;
    }

    CGPoint point = [self.view convertPoint:self.remoteInputController.cursorView.frame.origin toView:self.webview];
    if (point.y < 0) {
        [self activateTopBarFocusMode];
        return;
    }

    CGPoint domPoint = [self browserDOMPointForCursor];
    [self.pageActionCoordinator handlePageSelectionAtDOMPoint:domPoint webView:self.webview];
}

- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {
    if (self.topBarFocusActive) {
        UIView *preferredFocusItem = [self.topMenuView preferredFocusItem];
        if (preferredFocusItem != nil) {
            return @[preferredFocusItem];
        }
    }
    if (self.tabCoordinator.showingHome) {
        BrowserHomeView *homeView = self.tabCoordinator.homeView;
        if (homeView != nil && !homeView.hidden) {
            return @[homeView];
        }
    }
    return [super preferredFocusEnvironments];
}

#pragma mark - BrowserTopBarViewDelegate

- (void)browserTopBarView:(__unused BrowserTopBarView *)topBarView didTriggerAction:(BrowserTopBarAction)action {
    [self performTopBarAction:action];
}

#pragma mark - BrowserMenuCoordinatorHost

- (BrowserWebView *)browserWebView {
    return self.webview;
}

- (NSString *)browserPreviousURL {
    return self.tabCoordinator.previousURL;
}

- (void)setBrowserPreviousURL:(NSString *)browserPreviousURL {
    self.tabCoordinator.previousURL = browserPreviousURL ?: @"";
}

- (NSUInteger)browserTextFontSize {
    return self.viewModel.textFontSize;
}

- (void)setBrowserTextFontSize:(NSUInteger)browserTextFontSize {
    self.viewModel.textFontSize = browserTextFontSize;
    self.preferencesStore.textFontSize = self.viewModel.textFontSize;
}

- (BOOL)browserTopMenuShowing {
    return self.viewModel.topNavigationBarVisible;
}

- (BOOL)browserFullscreenVideoPlaybackEnabled {
    return self.viewModel.fullscreenVideoPlaybackEnabled;
}

- (void)setBrowserFullscreenVideoPlaybackEnabled:(BOOL)browserFullscreenVideoPlaybackEnabled {
    self.viewModel.fullscreenVideoPlaybackEnabled = browserFullscreenVideoPlaybackEnabled;
    self.preferencesStore.fullscreenVideoPlaybackEnabled = browserFullscreenVideoPlaybackEnabled;
}

- (void)browserPresentViewController:(UIViewController *)viewController {
    [self deactivateTopBarFocusMode];
    [self presentViewController:viewController animated:YES completion:nil];
}

- (void)browserLoadHomePage {
    [self loadHomePage];
}

- (void)browserLoadRequest:(NSURLRequest *)request {
    [self loadRequestInActiveTab:request];
}

- (void)browserShowHints {
    [self showHintsAlert];
}

- (void)browserShowTabOverview {
    [self deactivateTopBarFocusMode];
    [self.tabCoordinator prepareTabOverviewThumbnails];
    [self.tabOverviewController show];
}

- (void)browserCreateNewTabLoadingHomePage:(BOOL)loadHomePage {
    [self.tabCoordinator createNewTabLoadingHomePage:loadHomePage];
}

- (void)browserHideTopNav {
    [self deactivateTopBarFocusMode];
    self.viewModel.topNavigationBarVisible = NO;
    self.preferencesStore.topNavigationBarVisible = NO;
    [self.tabCoordinator setTopNavigationVisible:NO];
    [self updateTopBarFocusability];
}

- (void)browserShowTopNav {
    self.viewModel.topNavigationBarVisible = YES;
    self.preferencesStore.topNavigationBarVisible = YES;
    [self.tabCoordinator setTopNavigationVisible:YES];
    [self updateTopBarFocusability];
}

- (void)browserUpdateTextFontSize {
    [self updateTextFontSize];
}

- (void)browserCaptureSnapshotForCurrentTab {
    [self.tabCoordinator captureSnapshotForCurrentTab];
}

- (void)browserRecreateActiveWebViewPreservingCurrentURL {
    [self.tabCoordinator recreateActiveWebViewPreservingCurrentURL];
}

- (void)browserBringCursorToFront {
    [self.view bringSubviewToFront:self.remoteInputController.cursorView];
}

- (void)browserPlayVideoUnderCursorIfAvailable {
    [self.videoPlaybackCoordinator playVideoUnderCursorIfAvailable];
}

#pragma mark - BrowserVideoPlaybackCoordinatorHost

- (BOOL)browserIsCursorModeEnabled {
    return self.remoteInputController.cursorModeEnabled;
}

- (CGPoint)browserDOMCursorPoint {
    return [self browserDOMPointForCursor];
}

- (UIViewController *)browserPresentedViewController {
    return self.presentedViewController;
}

- (NSString *)browserCurrentPageTitle {
    return self.webview.title;
}

#pragma mark - BrowserTabCoordinatorHost

- (void)browserTabCoordinatorPresentViewController:(UIViewController *)viewController {
    [self browserPresentViewController:viewController];
}

- (void)browserTabCoordinatorUpdateTextFontSize {
    [self updateTextFontSize];
}

- (BOOL)browserTabCoordinatorIsCursorModeEnabled {
    return self.remoteInputController.cursorModeEnabled;
}

- (BOOL)browserTabCoordinatorIsTabOverviewVisible {
    return self.tabOverviewController.visible;
}

#pragma mark - BrowserTabOverviewControllerHost

- (BOOL)browserTabOverviewControllerCursorModeEnabled {
    if (self.tabCoordinator.showingHome) {
        return self.cursorModeBeforeHome;
    }
    return self.remoteInputController.cursorModeEnabled;
}

- (void)browserTabOverviewControllerSetCursorModeEnabled:(BOOL)enabled {
    if (self.tabCoordinator.showingHome) {
        // Home never uses the cursor. When the overview is closing (no longer
        // visible) it hands back the web preference; keep that for the next page.
        if (!self.tabOverviewController.visible) {
            self.cursorModeBeforeHome = enabled;
        }
        [self.remoteInputController setCursorModeEnabled:NO];
        [self setNeedsFocusUpdate];
        return;
    }
    [self.remoteInputController setCursorModeEnabled:enabled];
}

- (void)browserTabOverviewControllerPresentViewController:(UIViewController *)viewController {
    [self presentViewController:viewController animated:YES completion:nil];
}

- (void)browserTabOverviewControllerCreateNewTabLoadingHomePage:(BOOL)loadHomePage {
    [self.tabCoordinator createNewTabLoadingHomePage:loadHomePage];
}

- (void)browserTabOverviewControllerSwitchToTabAtIndex:(NSInteger)tabIndex {
    [self.tabCoordinator switchToTabAtIndex:tabIndex];
}

- (void)browserTabOverviewControllerCloseTabAtIndex:(NSInteger)tabIndex {
    [self.tabCoordinator closeTabAtIndex:tabIndex];
}

#pragma mark - BrowserPageActionCoordinatorHost

- (void)browserPageActionCoordinatorPresentViewController:(UIViewController *)viewController {
    [self browserPresentViewController:viewController];
}

- (BOOL)browserPageActionCoordinatorCreateNewTabWithRequest:(NSURLRequest *)request {
    return [self.tabCoordinator createNewTabWithRequest:request];
}

#pragma mark - BrowserRemoteInputControllerHost

- (UIScrollView *)browserRemoteInputControllerActiveScrollView {
    if (self.tabCoordinator.showingHome) {
        return nil;
    }
    return self.webview.scrollView;
}

- (UIViewController *)browserRemoteInputControllerPresentedViewController {
    return self.presentedViewController;
}

- (BOOL)browserRemoteInputControllerTopBarFocusActive {
    return self.topBarFocusActive;
}

- (BOOL)browserRemoteInputControllerCanActivateTopBarFocus {
    return [self canActivateTopBarFocusMode];
}

- (void)browserRemoteInputControllerActivateTopBarFocus {
    [self activateTopBarFocusMode];
}

- (void)browserRemoteInputControllerDeactivateTopBarFocus {
    [self deactivateTopBarFocusMode];
}

- (BOOL)browserRemoteInputControllerTabOverviewVisible {
    return self.tabOverviewController.visible;
}

- (BOOL)browserRemoteInputControllerTabOverviewContainsPoint:(CGPoint)point {
    return [self.tabOverviewController containsPoint:point];
}

- (BOOL)browserRemoteInputControllerHandleTabOverviewSelectionAtPoint:(CGPoint)point {
    return [self.tabOverviewController handleSelectionAtPoint:point];
}

- (void)browserRemoteInputControllerDismissTabOverview {
    [self.tabOverviewController dismiss];
}

- (void)browserRemoteInputControllerHandleTabOverviewAlternateAction {
    [self.tabOverviewController handleAlternateAction];
}

- (void)browserRemoteInputControllerHandlePrimaryAction {
    [self browserHandlePrimaryAction];
}

- (void)browserRemoteInputControllerHandleMenuPress {
    UIAlertController *alertController = (UIAlertController *)self.presentedViewController;
    if (alertController != nil) {
        [self.presentedViewController dismissViewControllerAnimated:YES completion:nil];
    } else if (self.tabCoordinator.pageFullscreenActive) {
        [self exitPageFullscreen];
    } else if ([self.tabCoordinator returnFromHomeToPage]) {
        return;
    } else if (!self.tabCoordinator.showingHome && self.webview.canGoBack) {
        [self.webview goBack];
    } else {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Exit App?"
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Exit"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(__unused UIAlertAction *action) {
            exit(EXIT_SUCCESS);
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Dismiss" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (void)browserRemoteInputControllerHandlePlayPausePress {
    UIAlertController *alertController = (UIAlertController *)self.presentedViewController;
    if (alertController != nil) {
        [self.presentedViewController dismissViewControllerAnimated:YES completion:nil];
    } else {
        [self requestURLorSearchInput];
    }
}

- (void)browserRemoteInputControllerHandleAdvancedMenuPress {
    [self showAdvancedMenu];
}

- (NSString *)browserRemoteInputControllerHoverStateAtCursorPoint:(CGPoint)point {
    if (self.webview.request == nil) {
        return @"false";
    }
    CGPoint webPoint = [self.view convertPoint:point toView:self.webview];
    if (webPoint.y < 0) {
        return @"false";
    }
    CGPoint domPoint = [self browserDOMPointForCursor];
    return [self.pageActionCoordinator hoverStateAtDOMPoint:domPoint webView:self.webview];
}

- (void)browserRemoteInputControllerSetWebInteractionEnabled:(BOOL)enabled {
    self.webview.userInteractionEnabled = enabled;
}

- (void)browserRemoteInputControllerPersistSession {
    [self.tabCoordinator persistSession];
}

- (void)browserRemoteInputControllerHandleNavigationPress:(UIPressType)pressType {
    if (self.webview == nil || self.tabCoordinator.showingHome) {
        return;
    }
    BrowserPageNavigationDirection direction = BrowserPageNavigationDirectionDown;
    switch (pressType) {
        case UIPressTypeUpArrow: direction = BrowserPageNavigationDirectionUp; break;
        case UIPressTypeLeftArrow: direction = BrowserPageNavigationDirectionLeft; break;
        case UIPressTypeRightArrow: direction = BrowserPageNavigationDirectionRight; break;
        default: break;
    }
    __weak typeof(self) weakSelf = self;
    [self.pageNavigator moveInDirection:direction webView:self.webview completion:^(BrowserPageNavigationResult result) {
        if (result == BrowserPageNavigationResultTopEdge && direction == BrowserPageNavigationDirectionUp) {
            [weakSelf activateTopBarFocusMode];
        }
    }];
}

- (void)browserRemoteInputControllerDidToggleCursorMode:(BOOL)cursorModeEnabled {
    if (cursorModeEnabled) {
        [self.pageNavigator clearInWebView:self.webview];
        [self showToast:@"Cursor mode"];
    } else {
        [self showToast:@"Navigation mode · click the remote's edges to move, Select to open"];
    }
}

#pragma mark - BrowserWebViewDelegate

- (BOOL)webView:(id)webView shouldCreateNewTabWithRequest:(NSURLRequest *)request navigationType:(NSInteger)navigationType {
    NSURL *sourceURL = [webView request].URL;
    if ([[BrowserAdBlocker sharedBlocker] shouldBlockPopupRequest:request navigationType:navigationType sourceURL:sourceURL]) {
        return YES; // handled: the pop-up is dropped
    }
    return [self.tabCoordinator createNewTabWithRequest:request];
}

- (BOOL)webView:(id)webView shouldStartLoadWithRequest:(NSURLRequest *)request navigationType:(NSInteger)navigationType {
    (void)navigationType;
    [self.tabCoordinator prepareTabForRequest:request webView:webView];
    return YES;
}

- (void)webViewDidStartLoad:(id)webView {
    [self.tabCoordinator webViewDidStartLoad:webView];
}

- (void)webView:(id)webView didChangeLoadProgress:(double)progress loading:(BOOL)loading {
    [self.tabCoordinator webView:webView didChangeLoadProgress:progress loading:loading];
}

- (void)webView:(id)webView didChangePageFullscreen:(BOOL)fullscreen {
    if (webView != self.webview) {
        return;
    }
    [self deactivateTopBarFocusMode];
    [self.tabCoordinator setPageFullscreen:fullscreen forWebView:webView];
    if (fullscreen) {
        [self showToast:@"Full screen · press Menu to exit"];
    }
}

- (void)exitPageFullscreen {
    [self.webview evaluateJavaScript:@"window.__browserExitFullscreen && window.__browserExitFullscreen();" completionHandler:nil];
    [self.tabCoordinator setPageFullscreen:NO forWebView:nil];
}

- (void)webViewContentProcessDidTerminate:(id)webView {
    [self.tabCoordinator webViewContentProcessDidTerminate:webView];
}

- (void)runNavigationDiagnosticsIfRequested:(id)webView {
    // Launch with -BrowserNavDiagnostics YES: simulates remote arrow presses and logs the highlighted element.
    static BOOL ranOnce = NO;
    if (ranOnce || ![[NSUserDefaults standardUserDefaults] boolForKey:@"BrowserNavDiagnostics"] || webView != self.webview) {
        return;
    }
    ranOnce = YES;
    NSArray<NSNumber *> *steps = @[@(BrowserPageNavigationDirectionDown), @(BrowserPageNavigationDirectionDown),
                                   @(BrowserPageNavigationDirectionRight), @(BrowserPageNavigationDirectionRight),
                                   @(BrowserPageNavigationDirectionDown), @(BrowserPageNavigationDirectionRight),
                                   @(BrowserPageNavigationDirectionLeft), @(BrowserPageNavigationDirectionUp)];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(14.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // Select test: open the highlighted element, then report where the tab went.
        printf("[BNAV] select on highlighted element (page %s)\n", self.webview.request.URL.absoluteString.UTF8String);
        fflush(stdout);
        [self activateHighlightedPageElement];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            printf("[BNAV] after select: tab is at %s\n", self.webview.request.URL.absoluteString.UTF8String);
            fflush(stdout);
        });
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(16.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // Pop-up test: a script-opened window to another site should be refused by the ad blocker.
        [self.webview evaluateJavaScript:@"(function(){var w=window.open('https://www.example.org/','_blank'); return w ? 'window object returned' : 'no window';})()"
                       completionHandler:^(id result, NSError *error) {
            printf("[BNAV] popup test: %s %s\n", [[result description] UTF8String], error ? error.localizedDescription.UTF8String : "");
            fflush(stdout);
        }];
    });
    NSArray<NSString *> *names = @[@"up", @"down", @"left", @"right"];
    [steps enumerateObjectsUsingBlock:^(NSNumber *step, NSUInteger index, __unused BOOL *stop) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((4.0 + index * 1.2) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            BrowserWebView *currentWebView = self.webview;
            CFTimeInterval start = CACurrentMediaTime();
            [self.pageNavigator moveInDirection:(BrowserPageNavigationDirection)step.integerValue webView:currentWebView completion:^(BrowserPageNavigationResult result) {
                double elapsed = (CACurrentMediaTime() - start) * 1000.0;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [currentWebView evaluateJavaScript:@"(function(){var e=window.__bnav&&window.__bnav.current; if(!e){return 'none';} var r=e.getBoundingClientRect(); return e.tagName+' \"'+(e.innerText||e.getAttribute('aria-label')||e.getAttribute('href')||'').trim().replace(/\\s+/g,' ').slice(0,50)+'\" at '+Math.round(r.left)+','+Math.round(r.top)+' '+Math.round(r.width)+'x'+Math.round(r.height)+' scrollY='+Math.round(scrollY)+' highlight='+(window.__bnav.siteStyled?'site focus style':'blue ring');})()"
                                 completionHandler:^(id description, __unused NSError *error) {
                    printf("[BNAV] press %s -> result %ld in %.0fms: %s\n", names[step.integerValue].UTF8String, (long)result, elapsed, [[description description] UTF8String]);
                    fflush(stdout);
                }];
                });
            }];
        });
    }];
}

/// Clicks the first visible element whose text/label matches `pattern`, through the same path a remote Select uses.
- (NSString *)diagnosticsClickElementMatching:(NSString *)pattern {
    NSString *script = [NSString stringWithFormat:@"(function(){var re=new RegExp(%@,'i'); var buttons=document.querySelectorAll('button,[role=button]'); for(var j=0;j<buttons.length;j++){var b=buttons[j]; var br=b.getBoundingClientRect(); var bl=(b.getAttribute('aria-label')||b.getAttribute('title')||'').trim(); if(br.width>4&&br.height>4&&bl&&re.test(bl)){return JSON.stringify({x:br.left+br.width/2,y:br.top+br.height/2,t:bl,tag:b.tagName});}} var els=document.querySelectorAll('button,[role=button],[role=menuitem],[role=menuitemradio],[role=option],li,a,label,div,span'); var best=null; for(var i=0;i<els.length;i++){var e=els[i]; var r=e.getBoundingClientRect(); if(r.width<4||r.height<4||r.bottom<0||r.top>innerHeight){continue;} var cs=getComputedStyle(e); if(cs.visibility==='hidden'||cs.display==='none'||parseFloat(cs.opacity)<0.1){continue;} var t=(e.getAttribute('aria-label')||e.getAttribute('title')||e.innerText||'').trim().replace(/\\s+/g,' '); if(t.length>40||!re.test(t)){continue;} if(!best||r.width*r.height<best.a){best={a:r.width*r.height,x:r.left+r.width/2,y:r.top+r.height/2,t:t,tag:e.tagName};}} return best?JSON.stringify(best):'';})()", [self diagnosticsJSONString:pattern]];
    NSString *json = [self.webview stringByEvaluatingJavaScriptFromString:script];
    NSDictionary *target = json.length > 0 ? [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
    if (![target isKindOfClass:[NSDictionary class]]) {
        return [NSString stringWithFormat:@"nothing matching /%@/", pattern];
    }
    [self.pageActionCoordinator handlePageSelectionAtDOMPoint:CGPointMake([target[@"x"] doubleValue], [target[@"y"] doubleValue]) webView:self.webview];
    return [NSString stringWithFormat:@"clicked %@ '%@'", target[@"tag"], target[@"t"]];
}

- (NSString *)diagnosticsJSONString:(NSString *)string {
    NSData *data = [NSJSONSerialization dataWithJSONObject:@[string] options:0 error:nil];
    NSString *array = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [array substringWithRange:NSMakeRange(1, array.length - 2)];
}

- (void)diagnosticsLog:(NSString *)label script:(NSString *)script {
    NSString *result = script.length > 0 ? [self.webview stringByEvaluatingJavaScriptFromString:script] : @"";
    printf("[BQUAL] %s %s\n", label.UTF8String, (result ?: @"").UTF8String);
    fflush(stdout);
}

- (void)runPlayerQualityAndFullscreenDiagnostics {
    NSString *videoState = @"(function(){var v=document.querySelector('video'); if(!v){return 'no video';} return 'src='+String(v.currentSrc).slice(-40)+' size='+v.videoWidth+'x'+v.videoHeight+' rs='+v.readyState+' paused='+v.paused+' t='+v.currentTime.toFixed(1)+' fsElement='+((document.fullscreenElement||document.webkitFullscreenElement||{}).tagName||'none')+' presentation='+v.webkitPresentationMode+' rect='+Math.round(v.getBoundingClientRect().width)+'x'+Math.round(v.getBoundingClientRect().height);})()";
    NSString *menuText = @"(function(){var out=[]; var els=document.querySelectorAll('[role=menu] *,[role=dialog] *,[class*=menu] *,[class*=settings] *,[class*=popover] *,[class*=panel] *'); for(var i=0;i<els.length;i++){var e=els[i]; if(e.children.length){continue;} var r=e.getBoundingClientRect(); if(r.width<2||r.height<2){continue;} var t=(e.innerText||'').trim(); if(t&&out.indexOf(t)===-1){out.push(t);}} return JSON.stringify(out.slice(0,40));})()";
    NSString *mode = [[NSUserDefaults standardUserDefaults] stringForKey:@"BrowserPlayerTestMode"] ?: @"fullscreen";
    NSArray *steps = [mode isEqualToString:@"native"] ? @[
        @[@0.0, @"start", @"(function(){var v=document.querySelector('video'); if(v){v.play();} return 'play() called';})()"],
        @[@6.0, @"state", videoState],
        @[@7.0, @"native-player", @""],
        @[@15.0, @"native-state", @""],
        @[@23.0, @"native-state", @""],
        @[@31.0, @"native-state", @""],
    ] : @[
        @[@0.0, @"start", @"(function(){var v=document.querySelector('video'); if(v){v.play();} return 'play() called';})()"],
        @[@6.0, @"state", videoState],
        @[@7.0, @"hover-fullscreen", @""],
        @[@8.0, @"click", @"^fullscreen$"],
        @[@11.0, @"state", videoState],
        @[@14.0, @"state", videoState],
        @[@15.0, @"menu-press", @""],
        @[@17.0, @"state", videoState],
    ];
    for (NSArray *step in steps) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((10.0 + [step[0] doubleValue]) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if ([step[1] isEqualToString:@"click"]) {
                printf("[BQUAL] %s\n", [self diagnosticsClickElementMatching:step[2]].UTF8String);
                fflush(stdout);
            } else if ([step[1] isEqualToString:@"hover-fullscreen"]) {
                NSString *where = [self.webview stringByEvaluatingJavaScriptFromString:@"(function(){var b=document.querySelector('button[aria-label=Fullscreen]'); if(!b){return '';} var r=b.getBoundingClientRect(); return (r.left+r.width/2)+','+(r.top+r.height/2)+','+getComputedStyle(b).opacity+','+getComputedStyle(b.parentElement).opacity;})()"];
                NSArray *parts = [where componentsSeparatedByString:@","];
                if (parts.count >= 2) {
                    [self.domInteractionService evaluateHoverStateJavaScriptAtPoint:CGPointMake([parts[0] doubleValue], [parts[1] doubleValue]) webView:self.webview];
                }
                NSString *after = [self.webview stringByEvaluatingJavaScriptFromString:@"(function(){var b=document.querySelector('button[aria-label=Fullscreen]'); return b ? getComputedStyle(b).opacity+','+getComputedStyle(b.parentElement).opacity : '';})()"];
                printf("[BQUAL] cursor moved over Fullscreen button (x,y,opacity,barOpacity before=%s; after=%s)\n", where.UTF8String ?: "", after.UTF8String ?: "");
                fflush(stdout);
            } else if ([step[1] isEqualToString:@"menu-press"]) {
                printf("[BQUAL] Menu press (fullscreen active=%d)\n", self.tabCoordinator.pageFullscreenActive);
                fflush(stdout);
                [self browserRemoteInputControllerHandleMenuPress];
            } else if ([step[1] isEqualToString:@"native-player"]) {
                printf("[BQUAL] TV output: nativeBounds=%s scale=%.1f\n", NSStringFromCGRect(UIScreen.mainScreen.nativeBounds).UTF8String, UIScreen.mainScreen.nativeScale);
                NSString *info = [self.webview stringByEvaluatingJavaScriptFromString:@"(function(){var v=document.querySelector('video'); return v ? JSON.stringify({src:v.currentSrc, t:v.currentTime}) : '';})()"];
                NSDictionary *video = info.length > 0 ? [NSJSONSerialization JSONObjectWithData:[info dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
                printf("[BQUAL] opening native player at t=%.1f quality pref=%s\n", [video[@"t"] doubleValue], [[[NSUserDefaults standardUserDefaults] stringForKey:@"NativePlayerPreferredQuality"] ?: @"auto" UTF8String]);
                fflush(stdout);
                if (video[@"src"] != nil) {
                    [self.videoPlaybackCoordinator presentNativeVideoPlayerForURL:[NSURL URLWithString:video[@"src"]] title:@"Test" startTime:[video[@"t"] doubleValue]];
                }
            } else if ([step[1] isEqualToString:@"native-state"]) {
                AVPlayerViewController *player = [self.presentedViewController isKindOfClass:[AVPlayerViewController class]] ? (AVPlayerViewController *)self.presentedViewController : nil;
                AVPlayerItemAccessLogEvent *event = player.player.currentItem.accessLog.events.lastObject;
                BOOL hdrEligible = NO;
                if (@available(tvOS 13.4, *)) {
                    hdrEligible = AVPlayer.eligibleForHDRPlayback;
                }
                printf("[BQUAL] native player: presented=%s status=%ld rate=%.1f t=%.1f presentationSize=%s indicatedBitrate=%.0f observedBitrate=%.0f HDReligible=%d error=%s\n", player ? "yes" : "no", (long)player.player.currentItem.status, player.player.rate, CMTimeGetSeconds(player.player.currentTime), NSStringFromCGSize(player.player.currentItem.presentationSize).UTF8String, event.indicatedBitrate, event.observedBitrate, hdrEligible, player.player.currentItem.error.localizedDescription.UTF8String ?: "none");
                fflush(stdout);
            } else if ([step[1] isEqualToString:@"native-close"]) {
                [self.presentedViewController dismissViewControllerAnimated:YES completion:nil];
            } else {
                [self diagnosticsLog:step[1] script:step[2]];
            }
            if ([step[1] isEqualToString:@"state"]) {
                printf("[BQUAL] presented=%s webViewFrame=%s topBarHidden=%d\n", self.presentedViewController ? NSStringFromClass(self.presentedViewController.class).UTF8String : "(none)", NSStringFromCGRect(self.webview.frame).UTF8String, self.topMenuView.hidden);
                fflush(stdout);
            }
        });
    }
}

- (void)runPlayerControlsDiagnosticsIfRequested:(id)webView {
    // Launch with -BrowserPlayerControlsDiagnostics YES on a video page: presses the player's
    // settings/subtitles/servers buttons the way a remote Select would and logs what happens.
    static BOOL ranOnce = NO;
    if (ranOnce || ![[NSUserDefaults standardUserDefaults] boolForKey:@"BrowserPlayerControlsDiagnostics"] || webView != self.webview) {
        return;
    }
    ranOnce = YES;
    printf("[BCTRL] full screen player enabled: %s\n", self.viewModel.fullscreenVideoPlaybackEnabled ? "YES" : "NO");
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"BrowserPlayerQualityDiagnostics"]) {
        [self runPlayerQualityAndFullscreenDiagnostics];
        return;
    }
    NSString *listScript = @"(function(){var v=document.querySelector('video'); if(!v){return '[]';} var out=[]; var els=document.querySelectorAll('button,[role=button]'); for(var i=0;i<els.length;i++){var e=els[i]; var r=e.getBoundingClientRect(); if(r.width<4||r.height<4){continue;} var label=(e.getAttribute('aria-label')||e.getAttribute('title')||e.innerText||'').trim().replace(/\\s+/g,' ').slice(0,30); out.push({label:label,x:Math.round(r.left+r.width/2),y:Math.round(r.top+r.height/2)});} return JSON.stringify(out);})()";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(7.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSString *json = [self.webview stringByEvaluatingJavaScriptFromString:listScript];
        for (NSUInteger attempt = 0; (json.length == 0 || [json isEqualToString:@"[]"]) && attempt < 12; attempt++) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
            json = [self.webview stringByEvaluatingJavaScriptFromString:listScript];
        }
        printf("[BCTRL] player buttons: %s\n", json.UTF8String ?: "(none)");
        fflush(stdout);
        NSData *jsonData = [json dataUsingEncoding:NSUTF8StringEncoding];
        NSArray *buttons = jsonData != nil ? [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil] : nil;
        if (![buttons isKindOfClass:[NSArray class]]) {
            return;
        }
        NSDictionary *target = nil;
        for (NSDictionary *button in buttons) {
            NSString *label = [button[@"label"] lowercaseString];
            if ([label containsString:@"setting"] || [label containsString:@"subtitle"] || [label containsString:@"caption"] || [label containsString:@"server"]) {
                target = button;
                break;
            }
        }
        if (target == nil) {
            printf("[BCTRL] no settings/subtitles/servers button found\n");
            fflush(stdout);
            return;
        }
        printf("[BCTRL] pressing '%s' at %s,%s\n", [target[@"label"] UTF8String], [[target[@"x"] description] UTF8String], [[target[@"y"] description] UTF8String]);
        fflush(stdout);
        [self.pageActionCoordinator handlePageSelectionAtDOMPoint:CGPointMake([target[@"x"] doubleValue], [target[@"y"] doubleValue]) webView:self.webview];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSString *state = [self.webview stringByEvaluatingJavaScriptFromString:@"(function(){var v=document.querySelector('video'); var menus=[].filter.call(document.querySelectorAll('[role=menu],[role=dialog],[class*=menu],[class*=settings],[class*=panel]'),function(e){var r=e.getBoundingClientRect(); return r.width>40&&r.height>40&&getComputedStyle(e).visibility!=='hidden';}).length; return 'video paused='+(v&&v.paused)+' visibleMenus='+menus;})()"];
            printf("[BCTRL] after press: presented=%s page: %s\n", self.presentedViewController ? NSStringFromClass(self.presentedViewController.class).UTF8String : "(none)", state.UTF8String);
            fflush(stdout);
        });
    });
}

- (void)webViewDidFinishLoad:(id)webView {
    [self.tabCoordinator webViewDidFinishLoad:webView];
    [self runNavigationDiagnosticsIfRequested:webView];
    [self runPlayerControlsDiagnosticsIfRequested:webView];
    if (self.tabOverviewController.visible) {
        BrowserTabViewModel *tab = [self.tabCoordinator tabForWebView:webView];
        NSInteger tabIndex = tab != nil ? [self.viewModel.tabs indexOfObject:tab] : NSNotFound;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.tabOverviewController.visible) {
                return;
            }
            if (tabIndex != NSNotFound) {
                [self.tabOverviewController updateCardAtIndex:tabIndex];
            } else {
                [self.tabOverviewController reload];
            }
        });
    }
}

- (void)webView:(id)webView didFailLoadWithError:(NSError *)error {
    BrowserTabViewModel *tab = [self.tabCoordinator tabForWebView:webView];
    if (tab == nil) {
        return;
    }

    NSURL *failingURL = error.userInfo[NSURLErrorFailingURLErrorKey];
    NSURLRequest *currentRequest = [webView request];
    NSString *currentRequestURLString = currentRequest.URL.absoluteString ?: @"";
    if (failingURL != nil &&
        currentRequestURLString.length > 0 &&
        ![failingURL.absoluteString isEqualToString:currentRequestURLString]) {
        return;
    }

    if (tab != self.tabCoordinator.activeTab || tab.showingHome) {
        return;
    }
    if ([self.navigationService shouldIgnoreLoadError:error]) {
        return;
    }
    if ([[BrowserAdBlocker sharedBlocker] isBlockedURL:failingURL]) {
        return; // blocked by the ad blocker on purpose
    }

    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Could Not Load Webpage"
                                                                             message:error.localizedDescription
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    if (tab.requestURL.length > 1) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Google This Page"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            NSURLRequest *searchRequest = [weakSelf.navigationService googleSearchRequestForFailedRequestURLString:tab.requestURL];
            [weakSelf loadRequestInActiveTab:searchRequest];
        }]];
    }
    if (self.webview.request != nil && self.webview.request.URL.absoluteString.length > 0) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Reload Page"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            weakSelf.tabCoordinator.previousURL = @"";
            [weakSelf.webview reload];
        }]];
    } else {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Enter a URL or Search"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            [weakSelf requestURLorSearchInput];
        }]];
    }
    [alertController addAction:[UIAlertAction actionWithTitle:nil style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alertController animated:YES completion:nil];
}

#pragma mark - Presses / Touches

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self.remoteInputController handlePressesBegan:presses withEvent:event];
    [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    // Home is focus-driven: let the focus engine own Select and the arrows there,
    // instead of the cursor/scroll handling (which would also open top-bar focus mode).
    if (self.tabCoordinator.showingHome && !self.topBarFocusActive && self.presentedViewController == nil) {
        for (UIPress *press in presses) {
            if (press.type == UIPressTypeSelect || press.type == UIPressTypeUpArrow || press.type == UIPressTypeDownArrow || press.type == UIPressTypeLeftArrow || press.type == UIPressTypeRightArrow) {
                [super pressesEnded:presses withEvent:event];
                return;
            }
        }
    }
    if ([self.remoteInputController handlePressesEnded:presses withEvent:event]) {
        return;
    }
    [super pressesEnded:presses withEvent:event];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if ([self.remoteInputController handleTouchesBegan:touches withEvent:event]) {
        return;
    }
    [super touchesBegan:touches withEvent:event];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if ([self.remoteInputController handleTouchesMoved:touches withEvent:event]) {
        return;
    }
    [super touchesMoved:touches withEvent:event];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
    [self.remoteInputController handleTouchesEnded];
    [super touchesEnded:touches withEvent:event];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
    [self.remoteInputController handleTouchesEnded];
    [super touchesCancelled:touches withEvent:event];
}

@end
