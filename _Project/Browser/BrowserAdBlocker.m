#import "BrowserAdBlocker.h"

#import <objc/message.h>

NSNotificationName const BrowserAdBlockerDidBlockPopupNotification = @"BrowserAdBlockerDidBlockPopupNotification";

static NSString * const kAdBlockerEnabledDefaultsKey = @"AdBlockerEnabled";
/// Bump when the rules change so the compiled list is rebuilt.
static NSString * const kAdBlockerRuleListIdentifier = @"BrowserAdBlocker-v2";

/// Throwaway domain endings used by rotating ad/pop-under networks (they register new random
/// names daily, so they cannot be listed by name). Only third-party *scripts* on these endings
/// are blocked, so visiting such a site directly still works.
static NSArray<NSString *> *BrowserAdBlockerSuspiciousTLDs(void) {
    return @[@"cfd", @"cyou", @"qpon", @"sbs", @"icu", @"bond", @"quest", @"autos", @"boats", @"hair",
             @"monster", @"makeup", @"skin", @"homes", @"motorcycles", @"yachts", @"beauty", @"mom"];
}

/// Specific ad scripts on hosts that also serve useful files (blocked by path only).
static NSArray<NSString *> *BrowserAdBlockerPathFilters(void) {
    return @[
        @"^[^:]+://+www\\.vidy\\.st/scripts/",   // movy.sx pop-under / ad loader (users.vidy.st stays allowed)
    ];
}

/// Ad, pop-under and tracking hosts. Matching includes subdomains.
/// Deliberately conservative: CDNs, video hosts, login providers and tag
/// managers are left alone so sites keep working.
static NSArray<NSString *> *BrowserAdBlockerHosts(void) {
    return @[
        // Google ads & analytics
        @"doubleclick.net", @"googlesyndication.com", @"googleadservices.com", @"adservice.google.com",
        @"googletagservices.com", @"google-analytics.com", @"app-measurement.com",
        // Ad exchanges & networks
        @"adnxs.com", @"adsrvr.org", @"amazon-adsystem.com", @"criteo.com", @"criteo.net",
        @"taboola.com", @"outbrain.com", @"pubmatic.com", @"rubiconproject.com", @"openx.net",
        @"casalemedia.com", @"advertising.com", @"yieldmo.com", @"smartadserver.com", @"moatads.com",
        @"media.net", @"revcontent.com", @"mgid.com", @"adform.net", @"bidswitch.net",
        @"sharethrough.com", @"teads.tv", @"33across.com", @"indexww.com", @"contextweb.com",
        @"lijit.com", @"sovrn.com", @"zedo.com", @"adroll.com", @"adsafeprotected.com",
        @"serving-sys.com", @"springserve.com", @"spotxchange.com", @"yieldlove.com", @"adkernel.com",
        // Pop-under / pop-up / push networks common on streaming sites
        @"propellerads.com", @"propellerclick.com", @"popads.net", @"popcash.net", @"exoclick.com",
        @"exosrv.com", @"exdynsrv.com", @"juicyads.com", @"trafficjunky.net", @"trafficjunky.com",
        @"adsterra.com", @"adsterratech.com", @"hilltopads.net", @"hilltopads.com", @"clickadu.com",
        @"onclickads.net", @"onclkds.com", @"onclickperformance.com", @"a-ads.com", @"adcash.com",
        @"ad-maven.com", @"admaven.com", @"adskeeper.com", @"adskeeper.co.uk", @"trafficstars.com",
        @"tsyndicate.com", @"popmyads.com", @"richpush.co", @"pushame.com", @"evadav.com",
        @"galaksion.com", @"monetag.com", @"highperformanceformat.com", @"profitablegatecpm.com",
        @"admanmedia.com", @"adxpremium.services", @"bidvertiser.com", @"clickaine.com",
        @"pushnami.com", @"pushwhy.com", @"realsrv.com", @"magsrv.com", @"tsyndicate.net",
        @"syndication.realsrv.com", @"popunder.net", @"popadscdn.net", @"poptm.com",
        @"adspyglass.com", @"ero-advertising.com", @"plugrush.com", @"notifpush.com",
        // Seen on movy.sx (in-page push / fake alert networks)
        @"doomsarchaic.com", @"k1nm7c66rh4fgh.cfd", @"smockeddesmoid.qpon", @"sciageuncorks.cyou",
        @"gallaupcoil.cfd",
        // Trackers
        @"scorecardresearch.com", @"quantserve.com", @"hotjar.com", @"mouseflow.com",
        @"crazyegg.com", @"chartbeat.com", @"newrelic.com", @"nr-data.net", @"bluekai.com",
        @"demdex.net", @"krxd.net", @"exelator.com", @"rlcdn.com", @"agkn.com",
    ];
}

/// Hide common ad containers left behind once their content is blocked.
static NSString *BrowserAdBlockerCosmeticSelector(void) {
    return @"ins.adsbygoogle, .adsbygoogle, [id^='google_ads_iframe'], [id^='div-gpt-ad'], "
           "iframe[src*='doubleclick.net'], iframe[src*='googlesyndication.com'], iframe[src*='exoclick'], "
           "iframe[src*='popads'], iframe[src*='adsterra'], [data-ad-slot], [data-google-query-id], "
           ".ad-banner, .banner-ad, .ad-slot, .adsbox, [aria-label='Advertisement']";
}

static NSString *BrowserAdBlockerRegexEscapedHost(NSString *host) {
    return [host stringByReplacingOccurrencesOfString:@"." withString:@"\\."];
}

static NSString *BrowserAdBlockerRuleListJSON(void) {
    NSMutableArray *rules = [NSMutableArray array];
    for (NSString *host in BrowserAdBlockerHosts()) {
        // Same shape Safari content blockers use: scheme, optional subdomains, host, then : or /.
        NSString *filter = [NSString stringWithFormat:@"^[^:]+://+([^:/]+\\.)?%@[:/]", BrowserAdBlockerRegexEscapedHost(host)];
        [rules addObject:@{
            @"trigger": @{ @"url-filter": filter, @"load-type": @[@"third-party"] },
            @"action": @{ @"type": @"block" },
        }];
    }
    for (NSString *tld in BrowserAdBlockerSuspiciousTLDs()) {
        [rules addObject:@{
            @"trigger": @{ @"url-filter": [NSString stringWithFormat:@"^[^:]+://+[^:/]+\\.%@[:/]", tld],
                           @"load-type": @[@"third-party"],
                           @"resource-type": @[@"script", @"popup"] },
            @"action": @{ @"type": @"block" },
        }];
    }
    for (NSString *filter in BrowserAdBlockerPathFilters()) {
        [rules addObject:@{
            @"trigger": @{ @"url-filter": filter, @"load-type": @[@"third-party"] },
            @"action": @{ @"type": @"block" },
        }];
    }
    [rules addObject:@{
        @"trigger": @{ @"url-filter": @".*" },
        @"action": @{ @"type": @"css-display-none", @"selector": BrowserAdBlockerCosmeticSelector() },
    }];
    NSData *data = [NSJSONSerialization dataWithJSONObject:rules options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"[]";
}

static NSString *BrowserRegistrableDomain(NSString *host) {
    NSArray<NSString *> *labels = [host.lowercaseString componentsSeparatedByString:@"."];
    if (labels.count <= 2) {
        return host.lowercaseString;
    }
    // Two-part public suffixes such as co.uk / com.pk keep three labels.
    NSSet<NSString *> *secondLevel = [NSSet setWithArray:@[@"co", @"com", @"net", @"org", @"gov", @"edu", @"ac"]];
    NSUInteger keep = ([secondLevel containsObject:labels[labels.count - 2]] && labels.lastObject.length == 2) ? 3 : 2;
    return [[labels subarrayWithRange:NSMakeRange(labels.count - keep, keep)] componentsJoinedByString:@"."];
}

@interface BrowserAdBlocker ()

@property (nonatomic) NSHashTable *userContentControllers;
@property (nonatomic, strong, nullable) id compiledRuleList;
@property (nonatomic) BOOL compiling;
@property (nonatomic) NSSet<NSString *> *blockedHosts;

@end

@implementation BrowserAdBlocker

+ (BrowserAdBlocker *)sharedBlocker {
    static BrowserAdBlocker *blocker;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        blocker = [BrowserAdBlocker new];
    });
    return blocker;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _userContentControllers = [NSHashTable weakObjectsHashTable];
        _blockedHosts = [NSSet setWithArray:BrowserAdBlockerHosts()];
        [[NSUserDefaults standardUserDefaults] registerDefaults:@{ kAdBlockerEnabledDefaultsKey: @YES }];
    }
    return self;
}

- (BOOL)isEnabled {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kAdBlockerEnabledDefaultsKey];
}

- (void)setEnabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kAdBlockerEnabledDefaultsKey];
    for (id controller in self.userContentControllers.allObjects) {
        [self applyRulesToUserContentController:controller];
    }
    if (enabled) {
        [self compileRuleListIfNeeded];
    }
}

#pragma mark Content rules

- (void)attachToUserContentController:(id)userContentController {
    if (userContentController == nil) {
        return;
    }
    [self.userContentControllers addObject:userContentController];
    [self applyRulesToUserContentController:userContentController];
    [self compileRuleListIfNeeded];
}

- (void)applyRulesToUserContentController:(id)controller {
    id ruleList = self.compiledRuleList;
    if (ruleList == nil) {
        return;
    }
    SEL removeSelector = NSSelectorFromString(@"removeContentRuleList:");
    SEL addSelector = NSSelectorFromString(@"addContentRuleList:");
    if ([controller respondsToSelector:removeSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(controller, removeSelector, ruleList);
    }
    if (self.enabled && [controller respondsToSelector:addSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(controller, addSelector, ruleList);
    }
}

- (nullable id)ruleListStore {
    Class storeClass = NSClassFromString(@"WKContentRuleListStore");
    SEL storeWithURL = NSSelectorFromString(@"storeWithURL:");
    if (storeClass == Nil || ![storeClass respondsToSelector:storeWithURL]) {
        return nil;
    }
    // The default store lives under Library, which tvOS apps cannot write to.
    NSURL *cachesURL = [[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *storeURL = [cachesURL URLByAppendingPathComponent:@"BrowserContentRules" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:storeURL withIntermediateDirectories:YES attributes:nil error:nil];
    return ((id (*)(id, SEL, id))objc_msgSend)((id)storeClass, storeWithURL, storeURL);
}

- (void)compileRuleListIfNeeded {
    if (self.compiledRuleList != nil || self.compiling || !self.enabled) {
        return;
    }
    id store = [self ruleListStore];
    SEL lookUpSelector = NSSelectorFromString(@"lookUpContentRuleListForIdentifier:completionHandler:");
    SEL compileSelector = NSSelectorFromString(@"compileContentRuleListForIdentifier:encodedContentRuleList:completionHandler:");
    if (store == nil || ![store respondsToSelector:lookUpSelector] || ![store respondsToSelector:compileSelector]) {
        NSLog(@"[Browser] Ad blocker: content rule lists are not available on this WebKit");
        return;
    }

    self.compiling = YES;
    __weak typeof(self) weakSelf = self;
    void (^install)(id, NSError *, NSString *) = ^(id ruleList, NSError *error, NSString *source) {
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.compiling = NO;
            if (ruleList == nil) {
                NSLog(@"[Browser] Ad blocker: %@ failed: %@", source, error.localizedDescription);
                return;
            }
            NSLog(@"[Browser] Ad blocker: rules ready (%@, %lu hosts)", source, (unsigned long)weakSelf.blockedHosts.count);
            weakSelf.compiledRuleList = ruleList;
            for (id controller in weakSelf.userContentControllers.allObjects) {
                [weakSelf applyRulesToUserContentController:controller];
            }
        });
    };

    ((void (*)(id, SEL, id, id))objc_msgSend)(store, lookUpSelector, kAdBlockerRuleListIdentifier, ^(id existing, __unused NSError *lookUpError) {
        if (existing != nil) {
            install(existing, nil, @"cached");
            return;
        }
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(store, compileSelector, kAdBlockerRuleListIdentifier, BrowserAdBlockerRuleListJSON(), ^(id compiled, NSError *compileError) {
            install(compiled, compileError, @"compiled");
        });
    });
}

#pragma mark Overlay ads

+ (NSString *)overlayAdSweeperScript {
    return @"(function(){"
        "if (window.__browserAdSweeper) { return; }"
        "window.__browserAdSweeper = true;"
        "window.__browserAdsRemoved = window.__browserAdsRemoved || 0;"
        // Real site dialogs do not stack at the browser's maximum layer; injected ad layers do.
        "var TOP_LAYER = 2147480000;"
        "function isBrowserElement(el) { return el.hasAttribute && (el.hasAttribute('data-browser-focus-ring') || el.hasAttribute('data-browser-fullscreen')); }"
        "function adFrame(frame) {"
            "var src = (frame.getAttribute('src') || '').trim();"
            "if (!src || src === 'about:blank' || /^javascript:/i.test(src) || frame.hasAttribute('srcdoc')) { return true; }"
            "try { return new URL(src, location.href).host !== location.host; } catch (e) { return true; }"
        "}"
        "function isOverlayAd(el) {"
            "if (!el || el.nodeType !== 1 || isBrowserElement(el) || el === document.body) { return false; }"
            "var tag = el.tagName; if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'LINK' || tag === 'HEAD' || tag === 'META') { return false; }"
            "var cs = getComputedStyle(el);"
            "if (cs.position !== 'fixed' && cs.position !== 'absolute') { return false; }"
            "if ((parseInt(cs.zIndex, 10) || 0) < TOP_LAYER) { return false; }"
            "if (el.parentNode === document.documentElement || tag === 'A' || tag === 'IFRAME' && adFrame(el)) { return true; }"
            "var frames = el.querySelectorAll('iframe');"
            "for (var i = 0; i < frames.length; i++) { if (adFrame(frames[i])) { return true; } }"
            "return false;"
        "}"
        "function sweep() {"
            "var candidates = [];"
            "[document.documentElement, document.body].forEach(function(parent) { if (parent) { for (var i = 0; i < parent.children.length; i++) { candidates.push(parent.children[i]); } } });"
            "candidates.forEach(function(el) { if (isOverlayAd(el)) { el.remove(); window.__browserAdsRemoved++; } });"
        "}"
        "sweep();"
        "var observer = new MutationObserver(function() { sweep(); });"
        "observer.observe(document.documentElement, { childList: true });"
        "if (document.body) { observer.observe(document.body, { childList: true }); }"
        "document.addEventListener('DOMContentLoaded', function() { if (document.body) { observer.observe(document.body, { childList: true }); } sweep(); });"
        "setInterval(sweep, 1500);"
    "})();";
}

#pragma mark Hosts & pop-ups

- (BOOL)isSuspiciousAdDomainURL:(NSURL *)URL {
    NSString *host = URL.host.lowercaseString;
    NSString *tld = [host componentsSeparatedByString:@"."].lastObject;
    return tld.length > 0 && [BrowserAdBlockerSuspiciousTLDs() containsObject:tld];
}

- (BOOL)isBlockedURL:(NSURL *)URL {
    NSString *host = URL.host.lowercaseString;
    while (host.length > 0) {
        if ([self.blockedHosts containsObject:host]) {
            return YES;
        }
        NSRange dot = [host rangeOfString:@"."];
        if (dot.location == NSNotFound) {
            break;
        }
        host = [host substringFromIndex:dot.location + 1];
    }
    return NO;
}

- (BOOL)shouldBlockPopupRequest:(NSURLRequest *)request navigationType:(NSInteger)navigationType sourceURL:(NSURL *)sourceURL {
    if (!self.enabled || request.URL == nil) {
        return NO;
    }
    BOOL block = NO;
    if ([self isBlockedURL:request.URL] || [self isSuspiciousAdDomainURL:request.URL]) {
        block = YES;
    } else if (navigationType != 0) {
        // Opened by script rather than a link: pop-unders send you to another site.
        NSString *sourceDomain = sourceURL.host.length > 0 ? BrowserRegistrableDomain(sourceURL.host) : @"";
        NSString *targetDomain = request.URL.host.length > 0 ? BrowserRegistrableDomain(request.URL.host) : @"";
        block = sourceDomain.length > 0 && targetDomain.length > 0 && ![sourceDomain isEqualToString:targetDomain];
    }
    if (block) {
        NSLog(@"[Browser] Ad blocker: blocked pop-up to %@", request.URL.host);
        [[NSNotificationCenter defaultCenter] postNotificationName:BrowserAdBlockerDidBlockPopupNotification
                                                            object:self
                                                          userInfo:@{ @"host": request.URL.host ?: @"" }];
    }
    return block;
}

@end
