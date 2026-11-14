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
#import "BrowserNativeVideoPlayerViewController.h"

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
/// The current Back/Menu press is handled by the app (not passed to tvOS, which would leave the app).
@property (nonatomic) BOOL handlingMenuPress;
@property (nonatomic) CFTimeInterval lastNavigationWakeTimestamp;
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
    [self.pageNavigator wakePageInWebView:self.webview completion:nil];
    // Press the highlighted element itself. (Clicking "whatever is at that spot" could hit the
    // video behind auto-hidden controls and open the full screen player instead.)
    NSString *outcome = [self.pageNavigator activateHighlightInWebView:self.webview force:NO];
    if ([outcome isEqualToString:@"none"]) {
        [self showToast:@"Click the edges of the remote's touch surface to pick a link"];
        return;
    }
    if ([outcome isEqualToString:@"text"] || [outcome isEqualToString:@"frame"]) {
        // Text fields get the on-screen keyboard prompt, which works from a page point; an embedded
        // player (iframe) gets the click handed to its frame at that point.
        NSValue *point = [self.pageNavigator activationPointInWebView:self.webview];
        if (point != nil) {
            [self.pageActionCoordinator handlePageSelectionAtDOMPoint:point.CGPointValue webView:self.webview];
        }
    } else if ([outcome isEqualToString:@"video"]) {
        // The highlight is the video itself: the full screen player if enabled, otherwise a click.
        NSValue *point = [self.pageNavigator activationPointInWebView:self.webview];
        BOOL handled = point != nil && [self.videoPlaybackCoordinator handleSelectPressForVideoAtDOMPoint:point.CGPointValue];
        if (!handled) {
            [self.pageNavigator activateHighlightInWebView:self.webview force:YES];
        }
    }
    // The item was opened: remove its highlight (a new page must not show the old ring).
    [self.pageNavigator releaseHighlightInWebView:self.webview];
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
            if (showingHome && [self.tabCoordinator returnFromHomeToPage]) {
                break;
            }
            if (!showingHome && self.webview.canGoBack) {
                [self.webview goBack];
            } else {
                [self.tabCoordinator returnToOpenerTab];
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
                                                                             message:@"Double press the touch area to switch between cursor & navigation mode.\nPress the touch area while in cursor mode to click.\nIn navigation mode, click the edges of the touch surface to move between links and buttons, swipe to scroll, and press Select to open.\nPress Back (Menu) to go to the previous page; with nothing left to go back to, it returns to the Apple TV Home screen.\nSingle tap the Play/Pause button to: Go Forward, Enter URL or Reload Page.\nDouble tap the Play/Pause to show the Advanced Menu with more options.\nUse the tabs icon in the top bar to open the tab overview."
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

/// Whether Back/Menu has something to go back to inside the app. When it does not,
/// the press is passed to tvOS, which returns to the Home screen like any Apple TV app.
- (BOOL)appHandlesMenuPress {
    if (self.presentedViewController != nil || self.topBarFocusActive || self.tabOverviewController.visible ||
        self.tabCoordinator.pageFullscreenActive) {
        return YES;
    }
    if (self.tabCoordinator.showingHome) {
        return self.tabCoordinator.activeTabHasPageBehindHome || [self.tabCoordinator canReturnToOpenerTab];
    }
    return self.webview.canGoBack || [self.tabCoordinator canReturnToOpenerTab];
}

- (void)browserRemoteInputControllerHandleMenuPress {
    if (self.presentedViewController != nil) {
        [self.presentedViewController dismissViewControllerAnimated:YES completion:nil];
    } else if (self.tabCoordinator.pageFullscreenActive) {
        [self exitPageFullscreen];
    } else if ([self.tabCoordinator returnFromHomeToPage]) {
        return;
    } else if (!self.tabCoordinator.showingHome && self.webview.canGoBack) {
        // Back through this tab's own history (including in-page history entries).
        [self.webview goBack];
    } else if ([self.tabCoordinator returnToOpenerTab]) {
        // First page of a tab opened from a link: close it and return to where it came from.
        return;
    }
}

- (void)browserRemoteInputControllerHandlePlayPausePress {
    UIAlertController *alertController = (UIAlertController *)self.presentedViewController;
    if (alertController != nil) {
        [self.presentedViewController dismissViewControllerAnimated:YES completion:nil];
    } else if (self.webview != nil && !self.tabCoordinator.showingHome) {
        // On a video page Play/Pause controls the video (and shows its controls), like Apple TV apps.
        // Pages without a large video keep the Quick Menu.
        __weak typeof(self) weakSelf = self;
        [self.pageNavigator togglePrimaryVideoInWebView:self.webview completion:^(BOOL handled) {
            if (!handled && weakSelf.presentedViewController == nil) {
                [weakSelf requestURLorSearchInput];
            }
        }];
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

- (void)browserRemoteInputControllerDidTouchSurfaceInNavigationMode {
    if (self.webview == nil || self.tabCoordinator.showingHome) {
        return;
    }
    CFTimeInterval now = CACurrentMediaTime();
    if (now - self.lastNavigationWakeTimestamp < 0.5) {
        return;
    }
    self.lastNavigationWakeTimestamp = now;
    [self.pageNavigator wakePageInWebView:self.webview completion:nil];
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
    NSLog(@"[Browser] new window request %@ navigationType=%ld from %@", request.URL.absoluteString, (long)navigationType, sourceURL.host);
    if ([[BrowserAdBlocker sharedBlocker] shouldBlockPopupRequest:request navigationType:navigationType sourceURL:sourceURL]) {
        return YES; // handled: the pop-up is dropped
    }
    if (self.viewModel.tabs.count >= [BrowserViewModel maximumTabCount]) {
        // All tabs are in use: open the link here rather than refusing it (links such as a
        // sports site's "Watch" buttons open in a new window and would otherwise do nothing).
        [self showToast:@"Tab limit reached · opened here"];
        [webView loadRequest:request];
        return YES;
    }
    return [self.tabCoordinator createNewTabWithRequest:request];
}

- (BOOL)webView:(id)webView shouldStartLoadWithRequest:(NSURLRequest *)request navigationType:(NSInteger)navigationType {
    BrowserAdBlocker *blocker = [BrowserAdBlocker sharedBlocker];
    BOOL mainFrame = request.mainDocumentURL == nil || [request.URL isEqual:request.mainDocumentURL];
    if (blocker.enabled && mainFrame && navigationType != 2 && navigationType != 3 &&
        ([blocker isBlockedURL:request.URL] || [blocker isSuspiciousAdDomainURL:request.URL]) &&
        ![webView isAppInitiatedRequest:request] &&
        ![[webView request].URL.host isEqualToString:request.URL.host]) {
        // A page script tried to send the tab to an ad site (click hijacking).
        NSLog(@"[Browser] Ad blocker: blocked redirect to %@", request.URL.host);
        [self showToast:@"Blocked a redirect to an ad site"];
        return NO;
    }
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

- (void)runNavigationBenchmarkIfRequested:(id)webView {
    // Launch with -BrowserNavBenchmark YES: 12 rapid arrow presses, timing each from press to result.
    static BOOL ranOnce = NO;
    if (ranOnce || ![[NSUserDefaults standardUserDefaults] boolForKey:@"BrowserNavBenchmark"] || webView != self.webview) {
        return;
    }
    ranOnce = YES;
    NSArray<NSNumber *> *pattern = @[@1, @1, @3, @3, @1, @2, @1, @1, @0, @3, @1, @0];
    NSArray<NSString *> *names = @[@"up", @"down", @"left", @"right"];
    __block NSUInteger index = 0;
    __block void (^next)(void);
    __block NSMutableArray<NSNumber *> *times = [NSMutableArray array];
    __weak typeof(self) weakSelf = self;
    next = ^{
        if (index >= pattern.count) {
            double total = 0, worst = 0;
            for (NSNumber *t in times) { total += t.doubleValue; worst = MAX(worst, t.doubleValue); }
            printf("[BBENCH] %lu presses: average %.0f ms, worst %.0f ms\n", (unsigned long)times.count, total / MAX(times.count, 1), worst);
            fflush(stdout);
            next = nil;
            return;
        }
        NSInteger direction = pattern[index].integerValue;
        index++;
        CFTimeInterval start = CACurrentMediaTime();
        [weakSelf.pageNavigator moveInDirection:(BrowserPageNavigationDirection)direction webView:weakSelf.webview completion:^(BrowserPageNavigationResult result) {
            double ms = (CACurrentMediaTime() - start) * 1000.0;
            [times addObject:@(ms)];
            [weakSelf.webview evaluateJavaScript:@"(function(){var e=window.__bnav&&window.__bnav.current; if(!e){return 'none';} var r=e.getBoundingClientRect(); var hit=document.elementFromPoint(r.left+r.width/2,r.top+r.height/2); return e.tagName+' '+JSON.stringify((e.innerText||e.getAttribute('aria-label')||'').trim().slice(0,28))+' '+Math.round(r.width)+'x'+Math.round(r.height)+' visibleAtCentre='+(!!hit&&(hit===e||e.contains(hit)||hit.contains(e)));})()" completionHandler:^(id description, __unused NSError *error) {
                printf("[BBENCH] %-5s %4.0f ms result=%ld -> %s\n", names[direction].UTF8String, ms, (long)result, [[description description] UTF8String]);
                fflush(stdout);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
            }];
        }];
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(24.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSString *dump = [weakSelf.webview stringByEvaluatingJavaScriptFromString:@"(function(){var els=document.querySelectorAll('button,a[href],video,[role=button]'); var out=[]; for(var i=0;i<els.length&&out.length<14;i++){var e=els[i]; var r=e.getBoundingClientRect(); var cs=getComputedStyle(e); out.push(e.tagName+' '+JSON.stringify((e.getAttribute('aria-label')||e.innerText||'').trim().slice(0,16))+' '+Math.round(r.left)+','+Math.round(r.top)+' '+Math.round(r.width)+'x'+Math.round(r.height)+' op='+cs.opacity+' vis='+cs.visibility+' disp='+cs.display+' pe='+cs.pointerEvents+' conn='+e.isConnected);} return 'count='+els.length+' video='+document.querySelectorAll('video').length+'\\n  '+out.join('\\n  ');})()"];
        printf("[BBENCH] page elements before pressing:\n  %s\n", dump.UTF8String ?: "(nil)");
        fflush(stdout);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
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
            NSString *ring = [self.webview stringByEvaluatingJavaScriptFromString:@"(function(){return (document.querySelector('[data-browser-focus-ring]') ? 'ring STILL SHOWN' : 'no ring') + ' at ' + location.href;})()"];
            printf("[BNAV] after select: %s\n", ring.UTF8String ?: "(page busy)");
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
    NSString *subtitleState = @"(function(){var v=document.querySelector('video'); var tt=[]; if(v&&v.textTracks){for(var i=0;i<v.textTracks.length;i++){var t=v.textTracks[i]; if(t.mode!=='disabled'){tt.push(t.label+'/'+t.language+':'+t.mode+':cues='+(t.cues?t.cues.length:'null')+':active='+(t.activeCues?t.activeCues.length:'null'));}}} var fsEl=document.querySelector('[data-browser-fullscreen]'); var overlays=[].filter.call(document.querySelectorAll('[class*=subtitle],[class*=caption],[class*=cue],[class*=Subtitle]'),function(e){return e.children.length<4&&e.innerText&&e.innerText.trim().length>0;}).map(function(e){var r=e.getBoundingClientRect(); var cs=getComputedStyle(e); var hit=document.elementFromPoint(r.left+r.width/2,r.top+r.height/2); return String(e.className).slice(0,50)+' text='+JSON.stringify(e.innerText.trim().slice(0,30))+' rect='+Math.round(r.left)+','+Math.round(r.top)+','+Math.round(r.width)+'x'+Math.round(r.height)+' vis='+cs.visibility+'/'+cs.display+'/'+cs.opacity+' covered='+(!!hit&&hit!==e&&!e.contains(hit))+' insideFS='+(fsEl?fsEl.contains(e):'n/a');}); var lp=document.querySelector('.lp-subtitle'); var lpBox=lp?lp.parentElement:null; var lpInfo=lpBox?('container vis='+getComputedStyle(lpBox).visibility+'/'+getComputedStyle(lpBox).display+'/'+getComputedStyle(lpBox).opacity):'no lp-subtitle element'; return JSON.stringify({videoClass:v?String(v.className):'', lp:lpInfo, activeTracks:tt, overlays:overlays.slice(0,4), fsElement:fsEl?(fsEl.tagName+'.'+String(fsEl.className).slice(0,50)):'none', displayingFS:v&&v.webkitDisplayingFullscreen, t:v&&v.currentTime.toFixed(1), paused:v&&v.paused});})()";
    NSString *subLogger = @"(function(){window.__subLog=[]; window.__subLast=''; clearInterval(window.__subTimer); window.__subTimer=setInterval(function(){var s=document.querySelector('.lp-subtitle, [class*=subtitle-text], [class*=captions-text], .vjs-text-track-display, .jw-captions, .plyr__captions'); var t=s?(s.innerText||'').trim():''; var fsEl=document.fullscreenElement; var key=t+'|'+(!!fsEl); if(key===window.__subLast){return;} window.__subLast=key; var info=''; if(s){var r=s.getBoundingClientRect(); var cs=getComputedStyle(s); var hit=t?document.elementFromPoint(r.left+r.width/2,r.top+r.height/2):null; info=' box='+Math.round(r.left)+','+Math.round(r.top)+','+Math.round(r.width)+'x'+Math.round(r.height)+' vis='+cs.visibility+'/'+cs.opacity+'/'+cs.display+(t?' topElement='+(hit?(hit===s||s.contains(hit)?'subtitle':hit.tagName+'.'+String(hit.className).slice(0,30)):'none'):'')+' insideFS='+(fsEl?fsEl.contains(s):'-');} var v=document.querySelector('video'); window.__subLog.push((v?v.currentTime.toFixed(1):'?')+'s fs='+(fsEl?fsEl.tagName+'.'+String(fsEl.className).slice(0,15):'none')+' text='+JSON.stringify(t.slice(0,34))+info);},250); return 'subtitle recorder on';})()";
    __unused NSString *ensureEnglish = @"(function(){var had=(window.__subLog||[]).some(function(l){return l.indexOf('text=\\\"\\\"')===-1;}); if(had){return 'subtitles already showing';} var b=document.querySelector('button[aria-label=Subtitles]'); if(!b){return 'no Subtitles button';} b.click(); var items=document.querySelectorAll('.menu-link'); for(var i=0;i<items.length;i++){if(/^English/.test((items[i].innerText||'').trim())){items[i].click(); break;}} setTimeout(function(){b.click();},400); return 'turned English on';})()";
    NSString *enterFullscreen = @"(function(){var b=document.querySelector('button[aria-label=Fullscreen], button[aria-label*=ullscreen], [class*=fullscreen] button, button[class*=fullscreen]'); if(!b){return 'no fullscreen button';} b.click(); return 'fullscreen button click() on '+(b.getAttribute('aria-label')||b.className);})()";
    NSString *allVideos = @"(function(){return [].map.call(document.querySelectorAll('video'),function(v){return String(v.currentSrc||v.src).slice(-60)+' rs='+v.readyState+' paused='+v.paused+' t='+v.currentTime.toFixed(1)+' muted='+v.muted+' err='+(v.error?v.error.code:'-')+' '+Math.round(v.getBoundingClientRect().width)+'x'+Math.round(v.getBoundingClientRect().height);}).join(' | ')+' || iframes='+[].map.call(document.querySelectorAll('iframe'),function(f){return (f.src||'(no src)').slice(0,60)+' '+Math.round(f.getBoundingClientRect().width)+'x'+Math.round(f.getBoundingClientRect().height);}).join(',')+' || url='+location.href;})()";
    NSArray *siteSteps = @[
        @[@0.0, @"click", @"^play$"],
        @[@10.0, @"videos", allVideos],
        @[@16.0, @"videos", allVideos],
        @[@17.0, @"start", @"(function(){var out=[]; var els=document.querySelectorAll('button,[role=button]'); for(var i=0;i<els.length;i++){var e=els[i]; var r=e.getBoundingClientRect(); if(r.width<4){continue;} var l=(e.getAttribute('aria-label')||e.getAttribute('title')||e.innerText||'').trim().replace(/\\s+/g,' ').slice(0,24); if(l){out.push(l);}} return 'player buttons: '+JSON.stringify(out.slice(0,30));})()"],
        @[@17.5, @"videos", @"(function(){var out=[]; var els=document.querySelectorAll('button,[role=button],[class*=control] *'); for(var i=0;i<els.length;i++){var e=els[i]; var d=((e.getAttribute('aria-label')||'')+' '+(e.getAttribute('title')||'')+' '+String(e.className||'')+' '+(e.getAttribute('data-tip')||'')+' '+(e.innerText||'').slice(0,20)).toLowerCase(); if(/full|screen|expand|sub|caption|\\bcc\\b|track|setting/.test(d)){var r=e.getBoundingClientRect(); out.push(e.tagName+' ['+d.replace(/\\s+/g,' ').trim().slice(0,70)+'] '+Math.round(r.left)+','+Math.round(r.top)+' '+Math.round(r.width)+'x'+Math.round(r.height));}} return 'fullscreen/subtitle-ish controls: '+out.slice(0,25).join(' ;; ');})()"],
        @[@18.0, @"fullscreen-retry", enterFullscreen],
        @[@21.0, @"videos", allVideos],
        @[@22.0, @"state", @"(function(){return 'fullscreenElement='+((document.fullscreenElement||{}).className||'none');})()"],
    ];
    NSArray *nativeSubtitleSteps = @[
        @[@0.0, @"start", @"(function(){var v=document.querySelector('video'); if(!v){return 'no video';} v.currentTime=225; var p=v.play(); if(p&&p.catch){p.catch(function(){});} return 'seeked to 225 + play';})()"],
        @[@3.0, @"click", @"^subtitles$"],
        @[@5.0, @"click", @"^off$"],
        @[@7.0, @"click", @"^english"],
        @[@9.0, @"click", @"^subtitles$"],
        @[@11.0, @"start", @"(function(){var s=window.__browserSubtitles; return s ? ('captured subtitle file: '+s.url.slice(0,70)+' ('+s.text.length+' chars)') : 'no subtitle file captured';})()"],
        @[@12.0, @"native-player", @""],
        @[@20.0, @"native-subs", @""],
        @[@23.0, @"native-subs", @""],
        @[@26.0, @"native-subs", @""],
        @[@29.0, @"native-subs", @""],
    ];
    NSString *subtitleProbe = @"(function(){var v=null,best=0; [].forEach.call(document.querySelectorAll('video'),function(x){var r=x.getBoundingClientRect(); if(r.width*r.height>best){best=r.width*r.height; v=x;}}); var tracks=[]; if(v&&v.textTracks){for(var i=0;i<v.textTracks.length;i++){var t=v.textTracks[i]; tracks.push((t.label||t.language||'?')+':'+t.mode+':'+(t.cues?t.cues.length:'-'));}} var cap=window.__browserSubtitles; var subEls=[].filter.call(document.querySelectorAll('[class*=subtitle],[class*=caption],[class*=Subtitle],[class*=cue]'),function(e){return e.innerText&&e.innerText.trim();}).map(function(e){return String(e.className).slice(0,30)+'='+JSON.stringify(e.innerText.trim().slice(0,30));}); var menu=[].filter.call(document.querySelectorAll('button,[role=menuitem],li'),function(e){return /subtit|caption|english|\\bcc\\b/i.test((e.getAttribute('aria-label')||'')+' '+(e.innerText||''));}).map(function(e){return (e.getAttribute('aria-label')||e.innerText||'').trim().slice(0,20);}); return 'video t='+(v?v.currentTime.toFixed(1):'-')+' paused='+(v?v.paused:'-')+' | tracks='+JSON.stringify(tracks.slice(0,6))+' ('+tracks.length+') | captured='+(cap?cap.url.slice(0,60)+' '+cap.text.length+'ch':'none')+' | on-screen='+JSON.stringify(subEls.slice(0,3))+' | subtitle controls='+JSON.stringify(menu.slice(0,8));})()";
    NSArray *movySteps = @[
        @[@0.0, @"click", @"^play$"],
        @[@9.0, @"start", @"(function(){var v=null,best=0; [].forEach.call(document.querySelectorAll('video'),function(x){var r=x.getBoundingClientRect(); if(r.width*r.height>best){best=r.width*r.height; v=x;}}); if(v&&v.paused){var p=v.play(); if(p&&p.catch){p.catch(function(){});}} return 'play main video';})()"],
        @[@15.0, @"videos", subtitleProbe],
        @[@25.0, @"videos", @"(function(){var c=window.__browserSubtitles; return c ? ('captured starts: '+JSON.stringify(c.text.slice(0,160))) : 'none';})()"],
    ];
    NSString *adReport = @"(function(){var hosts={}; performance.getEntriesByType('resource').forEach(function(e){try{var h=new URL(e.name).host; if(h.indexOf(location.host.replace(/^www\\./,''))===-1){hosts[h]=(hosts[h]||0)+1;}}catch(x){}}); var top=[].filter.call(document.querySelectorAll('html > *, body > *'),function(el){var cs=getComputedStyle(el); return (cs.position==='fixed'||cs.position==='absolute')&&(parseInt(cs.zIndex,10)||0)>=2147480000;}).map(function(el){return el.tagName+'.'+String(el.className).slice(0,20);}); var scam=document.body&&/Confirmation required|payment methods/i.test(document.documentElement.innerText||''); return 'overlay ads removed='+(window.__browserAdsRemoved||0)+' | max-layer overlays now='+JSON.stringify(top)+' | fake payment alert visible='+scam+' | third-party hosts loaded='+JSON.stringify(Object.keys(hosts));})()";
    NSString *injectFakeAd = @"(function(){var wrap=document.createElement('div'); wrap.style.cssText='position:fixed;inset:0;z-index:2147483647;'; var inner=document.createElement('div'); inner.className='notranslate'; var frame=document.createElement('iframe'); frame.setAttribute('sandbox','allow-same-origin allow-scripts allow-popups'); frame.style.cssText='width:468px;height:238px;border:0;'; inner.appendChild(frame); wrap.appendChild(inner); document.documentElement.appendChild(wrap); try{frame.contentDocument.body.innerHTML='<div>Confirmation required</div>';}catch(e){} return 'injected a simulated fake-alert overlay (unknown ad domain case)';})()";
    NSString *injectLegitDialog = @"(function(){var d=document.createElement('div'); d.id='legit-site-dialog'; d.style.cssText='position:fixed;left:40%;top:40%;width:400px;height:200px;z-index:9999;background:#222;color:#fff;'; d.textContent='Site dialog'; document.body.appendChild(d); return 'injected a normal site dialog (z-index 9999)';})()";
    NSArray *adSteps = @[
        @[@0.0, @"videos", adReport],
        @[@5.0, @"start", injectFakeAd],
        @[@5.2, @"start", injectLegitDialog],
        @[@7.0, @"videos", adReport],
        @[@7.5, @"start", @"(function(){return 'normal site dialog still present='+!!document.getElementById('legit-site-dialog');})()"],
    ];
    NSString *playState = @"(function(){var v=null,best=0; [].forEach.call(document.querySelectorAll('video'),function(x){var r=x.getBoundingClientRect(); if(r.width*r.height>best){best=r.width*r.height; v=x;}}); var cur=window.__bnav&&window.__bnav.current; return 'main video '+(v?(String(v.currentSrc).slice(-34)+' paused='+v.paused+' t='+v.currentTime.toFixed(1)):'none')+' | highlight='+(cur?(cur.tagName+' '+JSON.stringify((cur.getAttribute('aria-label')||cur.innerText||'').trim().slice(0,24))):'none');})()";
    NSArray *playClickSteps = @[
        @[@0.0, @"click", @"^play$"],
        @[@8.0, @"videos", playState],
        @[@8.5, @"presented-state", @""],
        @[@9.0, @"nav-to-play-control", @""],
        @[@14.0, @"videos", playState],
        @[@14.5, @"select-highlight", @""],
        @[@17.0, @"videos", playState],
        @[@17.5, @"presented-state", @""],
    ];
    NSArray *steps = [mode isEqualToString:@"playclick"] ? playClickSteps : [mode isEqualToString:@"ads"] ? adSteps : [mode isEqualToString:@"movy-subs"] ? movySteps : [mode isEqualToString:@"native-subtitles"] ? nativeSubtitleSteps : [mode isEqualToString:@"site"] ? siteSteps : [mode isEqualToString:@"subtitles2"] ? @[
        @[@0.0, @"start", @"(function(){var v=document.querySelector('video'); if(!v){return 'no video';} v.currentTime=225; var p=v.play(); if(p&&p.catch){p.catch(function(){});} return 'seeked to 225 + play';})()"],
        @[@1.0, @"start", subLogger],
        @[@3.0, @"click", @"^subtitles$"],
        @[@5.0, @"click", @"^off$"],
        @[@7.0, @"click", @"^english"],
        @[@9.0, @"click", @"^subtitles$"],
        @[@24.0, @"fullscreen-retry", enterFullscreen],
        @[@46.0, @"start", @"(function(){return 'LOG\\n'+(window.__subLog||[]).join('\\n');})()"],
    ] : [mode isEqualToString:@"subtitles"] ? @[
        @[@0.0, @"start", @"(function(){var v=document.querySelector('video'); if(v&&v.paused){var p=v.play(); if(p&&p.catch){p.catch(function(){});}} return 'play() called';})()"],
        @[@2.0, @"start", @"(function(){var v=document.querySelector('video'); if(!v){return 'no video';} v.currentTime=228; if(v.paused){v.muted=true; v.play(); return 'seeked to 228, retried muted';} return 'seeked to 228, playing';})()"],
        @[@3.0, @"start", @"(function(){var b=document.querySelector('button[aria-label=Subtitles]'); if(b){b.click();} return 'subtitles menu opened';})()"],
        @[@5.0, @"start", @"(function(){var items=document.querySelectorAll('.menu-link'); for(var i=0;i<items.length;i++){var t=(items[i].innerText||'').trim(); if(/^English/.test(t)){ if(/selected/.test(items[i].className)){return 'English already selected';} items[i].click(); return 'English selected now';}} return 'English item not found';})()"],
        @[@7.0, @"start", @"(function(){var b=document.querySelector('button[aria-label=Subtitles]'); if(b){b.click();} return 'subtitles menu toggled closed';})()"],
        @[@8.0, @"start", @"(function(){var sel=[].filter.call(document.querySelectorAll('.menu-link.selected'),function(e){return (e.innerText||'').trim();}).map(function(e){return e.innerText.trim().slice(0,20);}); return 'selected items: '+JSON.stringify(sel);})()"],
        @[@10.0, @"subs", subtitleState],
        @[@12.0, @"subs", subtitleState],
        @[@14.0, @"subs", subtitleState],
        @[@14.5, @"dump", @"(function(){function d(e){var out=[]; for(var k=0;k<7&&e;k++){out.push(e.tagName+'.'+String(e.className).replace(/\\s+/g,'.').slice(0,45)); e=e.parentElement;} return out.join(' < ');} var b=document.querySelector('button[aria-label=Fullscreen]'); var r=b.getBoundingClientRect(); var hit=document.elementFromPoint(r.left+r.width/2,r.top+r.height/2); var v=document.querySelector('video'); var vr=v.getBoundingClientRect(); var node=v.parentElement, best=v; for(var i=0;node&&node!==document.body&&i<4;i++,node=node.parentElement){var nr=node.getBoundingClientRect(); if(nr.width*nr.height>Math.max(1,vr.width*vr.height)*1.6){break;} best=node;} var sub=document.querySelector('.lp-subtitle'); return 'HIT@fullscreen: '+d(hit)+' || buttonIsHit='+(hit===b||b.contains(hit))+' || FS-CONTAINER(webkitEnterFullscreen): '+d(best)+' || SUBTITLE: '+(sub?d(sub):'none (between lines)')+' || subtitleInsideContainer='+(sub?best.contains(sub):'n/a')+' || VIDEO parent chain: '+d(v);})()"],
        @[@15.0, @"hover-fullscreen", @""],
        @[@16.0, @"start", @"(function(){var b=document.querySelector('button[aria-label=Fullscreen]'); if(!b){return 'no button';} b.click(); return 'Fullscreen button click() called';})()"],
        @[@18.0, @"subs", subtitleState],
        @[@19.5, @"subs", subtitleState],
        @[@21.0, @"subs", subtitleState],
        @[@22.5, @"subs", subtitleState],
        @[@24.0, @"subs", subtitleState],
        @[@25.5, @"subs", subtitleState],
        @[@27.0, @"subs", subtitleState],
        @[@28.5, @"subs", subtitleState],
    ] : [mode isEqualToString:@"native"] ? @[
        @[@0.0, @"click", @"^play$"],
        @[@0.5, @"start", @"(function(){var v=document.querySelector('video'); if(v&&v.paused){v.play();} return 'play() called';})()"],
        @[@6.0, @"state", videoState],
        @[@7.0, @"native-player", @""],
        @[@15.0, @"native-state", @""],
        @[@16.0, @"native-quality", @"480"],
        @[@22.0, @"native-state", @""],
        @[@26.0, @"native-state", @""],
        @[@27.0, @"native-quality", @"1080"],
        @[@33.0, @"native-state", @""],
        @[@37.0, @"native-state", @""],
        @[@38.0, @"native-quality", @"__restore__"],
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
    [self diagnosticsWhenVideoReady:0 run:^{
        [self diagnosticsScheduleSteps:steps mode:mode];
    }];
}

/// Polls until the page has a video that can play (or ~45s pass), then runs `block`.
- (void)diagnosticsWhenVideoReady:(NSUInteger)attempt run:(void (^)(void))block {
    NSString *ready = [self.webview stringByEvaluatingJavaScriptFromString:@"(function(){var v=document.querySelector('video'); return v && v.readyState >= 2 ? 'yes' : 'no';})()"];
    if ([ready isEqualToString:@"yes"] || attempt >= 45) {
        printf("[BQUAL] video ready after %lus\n", (unsigned long)attempt);
        fflush(stdout);
        block();
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self diagnosticsWhenVideoReady:attempt + 1 run:block];
    });
}

- (void)diagnosticsScheduleSteps:(NSArray *)steps mode:(NSString *)mode {
    for (NSArray *step in steps) {
        double baseDelay = 1.0;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((baseDelay + [step[0] doubleValue]) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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
            } else if ([step[1] isEqualToString:@"fullscreen-retry"]) {
                NSString *result = nil;
                for (NSUInteger attempt = 0; attempt < 4; attempt++) {
                    [self.pageNavigator wakePageInWebView:self.webview completion:nil];
                    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.6]];
                    result = [self.webview stringByEvaluatingJavaScriptFromString:step[2]];
                    if (result.length > 0 && ![result hasPrefix:@"no "]) {
                        break;
                    }
                }
                printf("[BQUAL] start %s\n", result.UTF8String ?: "(nil)");
                fflush(stdout);
            } else if ([step[1] isEqualToString:@"presented-state"]) {
                printf("[BQUAL] presented=%s\n", self.presentedViewController ? NSStringFromClass(self.presentedViewController.class).UTF8String : "(none)");
                fflush(stdout);
            } else if ([step[1] isEqualToString:@"nav-to-play-control"]) {
                [self.remoteInputController setCursorModeEnabled:NO];
                __block NSUInteger presses = 0;
                __block void (^pressDown)(void);
                __weak typeof(self) weakSelf = self;
                pressDown = ^{
                    [weakSelf.pageNavigator moveInDirection:(presses < 6 ? BrowserPageNavigationDirectionDown : BrowserPageNavigationDirectionLeft) webView:weakSelf.webview completion:^(BrowserPageNavigationResult result) {
                        NSString *label = [weakSelf.webview stringByEvaluatingJavaScriptFromString:@"(function(){var e=window.__bnav&&window.__bnav.current; return e?((e.getAttribute('aria-label')||e.innerText||e.tagName)+'').trim().slice(0,30):'';})()"];
                        printf("[BQUAL] nav press %lu -> %s\n", (unsigned long)presses + 1, label.UTF8String ?: "");
                        fflush(stdout);
                        presses++;
                        if (presses < 9 && ![label.lowercaseString hasPrefix:@"play"] && ![label.lowercaseString hasPrefix:@"pause"]) {
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), pressDown);
                        } else {
                            pressDown = nil;
                        }
                    }];
                };
                pressDown();
            } else if ([step[1] isEqualToString:@"select-highlight"]) {
                NSValue *point = [self.pageNavigator activationPointInWebView:self.webview];
                NSString *hit = point ? [self.webview stringByEvaluatingJavaScriptFromString:[NSString stringWithFormat:@"(function(){var h=document.elementFromPoint(%f,%f); return h?(h.tagName+'.'+String(h.className).slice(0,30)+' label='+((h.closest&&h.closest('button,[role=button]'))?(h.closest('button,[role=button]').getAttribute('aria-label')||''):'')):'none';})()", point.CGPointValue.x, point.CGPointValue.y]] : @"no point";
                printf("[BQUAL] Select on highlight: point=%s element there=%s\n", point ? NSStringFromCGPoint(point.CGPointValue).UTF8String : "nil", hit.UTF8String ?: "");
                fflush(stdout);
                [self activateHighlightedPageElement];
            } else if ([step[1] isEqualToString:@"native-subs"]) {
                UIViewController *player = self.presentedViewController;
                UILabel *label = [player respondsToSelector:NSSelectorFromString(@"subtitleLabel")] ? [player valueForKey:@"subtitleLabel"] : nil;
                NSArray *cues = [player respondsToSelector:NSSelectorFromString(@"subtitleCues")] ? [player valueForKey:@"subtitleCues"] : nil;
                double t = [player isKindOfClass:[AVPlayerViewController class]] ? CMTimeGetSeconds(((AVPlayerViewController *)player).player.currentTime) : -1;
                printf("[BQUAL] native player t=%.1f cues=%lu subtitle on screen: \"%s\"\n", t, (unsigned long)cues.count, [[label.text stringByReplacingOccurrencesOfString:@"\n" withString:@" / "] UTF8String] ?: "");
                fflush(stdout);
            } else if ([step[1] isEqualToString:@"videos"]) {
                printf("[BQUAL] videos %s\n", [self.webview stringByEvaluatingJavaScriptFromString:step[2]].UTF8String ?: "(nil)");
                fflush(stdout);
            } else if ([step[1] isEqualToString:@"wake"]) {
                [self.pageNavigator wakePageInWebView:self.webview completion:nil];
            } else if ([step[1] isEqualToString:@"dump"]) {
                NSString *result = [self.webview stringByEvaluatingJavaScriptFromString:step[2]];
                printf("[BQUAL] dump %s\n", [[result stringByReplacingOccurrencesOfString:@" || " withString:@"\n      "] UTF8String] ?: "(nil)");
                fflush(stdout);
            } else if ([step[1] isEqualToString:@"menu-press"]) {
                printf("[BQUAL] Menu press (fullscreen active=%d)\n", self.tabCoordinator.pageFullscreenActive);
                fflush(stdout);
                [self browserRemoteInputControllerHandleMenuPress];
            } else if ([step[1] isEqualToString:@"native-player"]) {
                printf("[BQUAL] TV output: nativeBounds=%s scale=%.1f\n", NSStringFromCGRect(UIScreen.mainScreen.nativeBounds).UTF8String, UIScreen.mainScreen.nativeScale);
                NSString *info = [self.webview stringByEvaluatingJavaScriptFromString:@"(function(){var v=null,best=0; [].forEach.call(document.querySelectorAll('video'),function(x){var r=x.getBoundingClientRect(); if(x.currentSrc&&r.width*r.height>best){best=r.width*r.height; v=x;}}); return v ? JSON.stringify({src:v.currentSrc, t:v.currentTime}) : '';})()"];
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
                if ([player isKindOfClass:[BrowserNativeVideoPlayerViewController class]]) {
                    printf("[BQUAL] native quality: %s\n", [(BrowserNativeVideoPlayerViewController *)player qualityStateDescription].UTF8String);
                }
                printf("[BQUAL] native player: presented=%s status=%ld rate=%.1f t=%.1f presentationSize=%s indicatedBitrate=%.0f observedBitrate=%.0f HDReligible=%d error=%s\n", player ? "yes" : "no", (long)player.player.currentItem.status, player.player.rate, CMTimeGetSeconds(player.player.currentTime), NSStringFromCGSize(player.player.currentItem.presentationSize).UTF8String, event.indicatedBitrate, event.observedBitrate, hdrEligible, player.player.currentItem.error.localizedDescription.UTF8String ?: "none");
                fflush(stdout);
            } else if ([step[1] isEqualToString:@"native-quality"]) {
                static NSString *originalQuality = nil;
                BrowserNativeVideoPlayerViewController *player = [self.presentedViewController isKindOfClass:[BrowserNativeVideoPlayerViewController class]] ? (BrowserNativeVideoPlayerViewController *)self.presentedViewController : nil;
                if (originalQuality == nil) {
                    originalQuality = [[NSUserDefaults standardUserDefaults] stringForKey:@"NativePlayerPreferredQuality"] ?: @"auto";
                }
                NSString *target = [step[2] isEqualToString:@"__restore__"] ? originalQuality : step[2];
                printf("[BQUAL] native quality before select %s: %s\n", target.UTF8String, player ? [player qualityStateDescription].UTF8String : "(no player)");
                [player selectQualityWithIdentifier:target];
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

- (void)runControlsWakeDiagnosticsIfRequested {
    // Launch with -BrowserControlsWakeDiagnostics YES on a video page (navigation mode).
    static BOOL ranOnce = NO;
    if (ranOnce || ![[NSUserDefaults standardUserDefaults] boolForKey:@"BrowserControlsWakeDiagnostics"]) {
        return;
    }
    ranOnce = YES;
    NSString *barState = @"(function(){var b=document.querySelector('button[aria-label=Fullscreen]'); var chain=[]; var e=b; for(var k=0;k<9&&e;k++){var cs=getComputedStyle(e); chain.push(e.tagName+'.'+String(e.className).replace(/\\s+/g,'.').slice(0,60)+'[op='+cs.opacity+',vis='+cs.visibility+',tf='+cs.transform+',pe='+cs.pointerEvents+',disp='+cs.display+']'); e=e.parentElement;} window.__bwakeChain=chain.join(' > '); var v=document.querySelector('video'); var bar=b; for(var i=0;i<4&&bar&&bar.parentElement;i++){bar=bar.parentElement;} var o=function(e){var x=1; while(e){x*=parseFloat(getComputedStyle(e).opacity); e=e.parentElement;} return x.toFixed(2);}; var cur=window.__bnav&&window.__bnav.current; return 'chain='+window.__bwakeChain+' || controlsOpacity='+(b?o(b):'n/a')+' video='+(v?(v.paused?'paused':'playing')+' t='+v.currentTime.toFixed(1):'none')+' highlight='+(cur?(cur.getAttribute('aria-label')||cur.tagName):'none');})()";
    void (^logState)(NSString *) = ^(NSString *label) {
        printf("[BWAKE] %s: %s\n", label.UTF8String, [self.webview stringByEvaluatingJavaScriptFromString:barState].UTF8String ?: "");
        fflush(stdout);
    };
    NSArray *steps = @[
        @[@5.0, ^{ [self.remoteInputController setCursorModeEnabled:NO]; [self browserRemoteInputControllerHandlePlayPausePress]; }],
        @[@6.0, ^{ logState(@"Play/Pause pressed, navigation mode"); }],
        @[@16.0, ^{ logState(@"after 10s idle"); }],
        @[@16.5, ^{ [self browserRemoteInputControllerDidTouchSurfaceInNavigationMode]; }],
        @[@17.0, ^{ logState(@"0.5s after touching the surface"); }],
        @[@27.0, ^{ logState(@"after 10s idle again"); }],
        @[@27.5, ^{ [self browserRemoteInputControllerHandleNavigationPress:UIPressTypeDownArrow]; }],
        @[@28.5, ^{ logState(@"1s after pressing down"); }],
        @[@29.0, ^{ [self browserRemoteInputControllerHandleNavigationPress:UIPressTypeRightArrow]; }],
        @[@30.0, ^{ logState(@"1s after pressing right"); }],
        @[@31.0, ^{ [self browserRemoteInputControllerHandlePlayPausePress]; }],
        @[@32.0, ^{ logState(@"1s after Play/Pause"); }],
        @[@33.0, ^{ [self browserRemoteInputControllerHandlePlayPausePress]; }],
        @[@34.0, ^{ logState(@"1s after Play/Pause again"); printf("[BWAKE] quick menu shown=%s\n", self.presentedViewController ? "yes" : "no"); }],
    ];
    for (NSArray *step in steps) {
        void (^block)(void) = step[1];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)([step[0] doubleValue] * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
    }
}

- (void)runBackDiagnosticsIfRequested {
    // Launch with -BrowserBackDiagnostics YES: checks what Back/Menu would do at each step.
    static BOOL ranOnce = NO;
    if (ranOnce || ![[NSUserDefaults standardUserDefaults] boolForKey:@"BrowserBackDiagnostics"]) {
        return;
    }
    ranOnce = YES;
    void (^report)(NSString *) = ^(NSString *label) {
        printf("[BBACK] %s: tabs=%lu active=%ld url=%s canGoBack=%d canReturnToOpener=%d appHandlesBack=%d\n", label.UTF8String,
               (unsigned long)self.viewModel.tabs.count, (long)self.viewModel.activeTabIndex,
               self.webview.request.URL.absoluteString.UTF8String ?: "(none)", self.webview.canGoBack,
               [self.tabCoordinator canReturnToOpenerTab], [self appHandlesMenuPress]);
        fflush(stdout);
    };
    NSArray *steps = @[
        @[@4.0, ^{ report(@"first page of the tab"); }],
        @[@5.0, ^{ [self loadRequestInActiveTab:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://example.org/"]]]; }],
        @[@10.0, ^{ report(@"after opening a second page"); }],
        @[@11.0, ^{ printf("[BBACK] pressing Back\n"); [self browserRemoteInputControllerHandleMenuPress]; }],
        @[@15.0, ^{ report(@"after Back"); }],
        @[@16.0, ^{ [self.tabCoordinator createNewTabWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://example.net/"]]]; }],
        @[@21.0, ^{ report(@"in a tab opened from the page"); }],
        @[@22.0, ^{ printf("[BBACK] pressing Back\n"); [self browserRemoteInputControllerHandleMenuPress]; }],
        @[@26.0, ^{ report(@"after Back in the opened tab"); }],
    ];
    for (NSArray *step in steps) {
        void (^block)(void) = step[1];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)([step[0] doubleValue] * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
    }
}

- (void)runClickDiagnosticsIfRequested {
    // Launch with -BrowserClickSelector '<css selector>': presses that element on the first page
    // (as the navigation highlight's Select does) and reports the tabs/pages that result.
    static BOOL ranOnce = NO;
    NSString *selector = [[NSUserDefaults standardUserDefaults] stringForKey:@"BrowserClickSelector"];
    if (ranOnce || selector.length == 0) {
        return;
    }
    ranOnce = YES;
    void (^report)(NSString *) = ^(NSString *label) {
        printf("[BCLICK] %s: tabs=%lu active=%ld url=%s\n", label.UTF8String, (unsigned long)self.viewModel.tabs.count,
               (long)self.viewModel.activeTabIndex, self.webview.request.URL.absoluteString.UTF8String ?: "(none)");
        fflush(stdout);
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        report(@"before click");
        NSData *json = [NSJSONSerialization dataWithJSONObject:@[selector] options:0 error:nil];
        NSString *quoted = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
        NSString *script = [NSString stringWithFormat:@"(function(){var el=document.querySelector(%@[0]); if(!el){return 'no element';} el.click(); return 'clicked '+el.tagName+' '+(el.href||'');})()", quoted];
        printf("[BCLICK] %s\n", [self.webview stringByEvaluatingJavaScriptFromString:script].UTF8String ?: "(null)");
        fflush(stdout);
    });
    for (NSNumber *delay in @[@8.0, @14.0, @25.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            report([NSString stringWithFormat:@"%.0fs", delay.doubleValue]);
        });
    }
}

- (void)runFrameDiagnosticsIfRequested {
    // Launch with -BrowserFrameDiagnostics YES (and optionally -BrowserFrameClickPoint 'x,y' in page
    // coordinates): Play/Pause and clicks for a player embedded in an iframe, printing [BFRAME] lines.
    static BOOL ranOnce = NO;
    if (ranOnce || ![[NSUserDefaults standardUserDefaults] boolForKey:@"BrowserFrameDiagnostics"]) {
        return;
    }
    ranOnce = YES;
    NSString *pointString = [[NSUserDefaults standardUserDefaults] stringForKey:@"BrowserFrameClickPoint"];
    NSArray<NSString *> *parts = [pointString componentsSeparatedByString:@","];
    CGPoint clickPoint = parts.count == 2 ? CGPointMake(parts[0].doubleValue, parts[1].doubleValue) : CGPointZero;
    void (^report)(NSString *) = ^(NSString *label) {
        printf("[BFRAME] %s: pageFullscreen=%d topBarHidden=%d presented=%s\n", label.UTF8String, self.tabCoordinator.pageFullscreenActive, self.topMenuView.hidden,
               self.presentedViewController ? NSStringFromClass(self.presentedViewController.class).UTF8String : "(none)");
        fflush(stdout);
    };
    void (^playPause)(NSString *) = ^(NSString *label) {
        [self.pageNavigator togglePrimaryVideoInWebView:self.webview completion:^(BOOL handled) {
            printf("[BFRAME] Play/Pause (%s) handled=%d\n", label.UTF8String, handled);
            fflush(stdout);
        }];
    };
    NSMutableArray *steps = [@[
        @[@12.0, ^{ playPause(@"expect unmute"); }],
        @[@17.0, ^{ playPause(@"expect pause"); }],
        @[@22.0, ^{ playPause(@"expect play"); }],
    ] mutableCopy];
    if (!CGPointEqualToPoint(clickPoint, CGPointZero)) {
        [steps addObjectsFromArray:@[
            @[@26.0, ^{ CGPoint hoverPoint = CGPointMake(clickPoint.x - 200, clickPoint.y - 200); [self.domInteractionService evaluateHoverStateJavaScriptAtPoint:hoverPoint webView:self.webview]; }],
            @[@26.8, ^{ CGPoint hoverPoint = CGPointMake(clickPoint.x - 199, clickPoint.y - 200); [self.domInteractionService evaluateHoverStateJavaScriptAtPoint:hoverPoint webView:self.webview]; }],
            @[@27.6, ^{ printf("[BFRAME] clicking %s\n", NSStringFromCGPoint(clickPoint).UTF8String); fflush(stdout); [self.pageActionCoordinator handlePageSelectionAtDOMPoint:clickPoint webView:self.webview]; }],
            @[@31.0, ^{ report(@"after click"); }],
            @[@33.0, ^{ printf("[BFRAME] pressing Menu\n"); fflush(stdout); [self browserRemoteInputControllerHandleMenuPress]; }],
            @[@36.0, ^{ report(@"after Menu"); }],
        ]];
    }
    for (NSArray *step in steps) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)([step[0] doubleValue] * NSEC_PER_SEC)), dispatch_get_main_queue(), step[1]);
    }
}

- (void)webViewDidFinishLoad:(id)webView {
    [self.tabCoordinator webViewDidFinishLoad:webView];
    [self runFrameDiagnosticsIfRequested];
    [self runClickDiagnosticsIfRequested];
    [self runBackDiagnosticsIfRequested];
    [self runControlsWakeDiagnosticsIfRequested];
    [self runNavigationDiagnosticsIfRequested:webView];
    [self runNavigationBenchmarkIfRequested:webView];
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

- (BOOL)pressesContainMenu:(NSSet<UIPress *> *)presses {
    for (UIPress *press in presses) {
        if (press.type == UIPressTypeMenu) {
            return YES;
        }
    }
    return NO;
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self.remoteInputController handlePressesBegan:presses withEvent:event];
    if ([self pressesContainMenu:presses]) {
        // tvOS leaves the app as soon as an unhandled Back/Menu press reaches UIKit (at press
        // *began*), so decide here whether the app handles it, and swallow it if so.
        self.handlingMenuPress = [self appHandlesMenuPress];
        if (self.handlingMenuPress) {
            return;
        }
    }
    [super pressesBegan:presses withEvent:event];
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    if ([self pressesContainMenu:presses] && self.handlingMenuPress) {
        self.handlingMenuPress = NO;
        return;
    }
    [super pressesCancelled:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    if ([self pressesContainMenu:presses]) {
        BOOL handled = self.handlingMenuPress;
        self.handlingMenuPress = NO;
        if (!handled) {
            // Nothing to go back to in the app: let tvOS go to the Home screen.
            [super pressesEnded:presses withEvent:event];
            return;
        }
        if (![self.remoteInputController handlePressesEnded:presses withEvent:event]) {
            [self browserRemoteInputControllerHandleMenuPress];
        }
        return;
    }
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
