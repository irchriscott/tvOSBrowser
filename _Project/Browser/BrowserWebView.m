#import "BrowserWebView.h"

#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "BrowserAdBlocker.h"
#import "BrowserPageNavigator.h"

static NSString * const kBrowserWebViewClassName = @"WKWebView";
static NSString * const kBrowserWebViewConfigurationClassName = @"WKWebViewConfiguration";
static NSString * const kBrowserWebsiteDataStoreClassName = @"WKWebsiteDataStore";
static NSString * const kBrowserUserContentControllerClassName = @"WKUserContentController";
static NSString * const kBrowserUserScriptClassName = @"WKUserScript";

static void BrowserEnsureWebKitRuntimeLoaded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (NSClassFromString(kBrowserWebViewClassName) != Nil) {
            return;
        }

        NSArray<NSString *> *candidatePaths = @[
            @"/System/Library/Frameworks/WebKit.framework/WebKit",
            @"/System/Library/PrivateFrameworks/WebKit.framework/WebKit",
            @"/System/Library/StagedFrameworks/Safari/WebKit.framework/WebKit",
        ];

        for (NSString *candidatePath in candidatePaths) {
            if (dlopen(candidatePath.UTF8String, RTLD_NOW | RTLD_GLOBAL) != NULL && NSClassFromString(kBrowserWebViewClassName) != Nil) {
                break;
            }
        }
    });
}

static void BrowserPumpRunLoopUntilWithTimeout(BOOL *done, NSTimeInterval timeout) {
    // Bounded so a crashed or unresponsive web content process can't freeze the UI.
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!*done && [deadline timeIntervalSinceNow] > 0) {
        @autoreleasepool {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
    }
}

static void BrowserPumpRunLoopUntil(BOOL *done) {
    BrowserPumpRunLoopUntilWithTimeout(done, 2.0);
}

static NSString *BrowserStringFromJavaScriptResult(id result) {
    if (result == nil || result == [NSNull null]) {
        return nil;
    }
    if ([result isKindOfClass:[NSString class]]) {
        return result;
    }
    if ([result respondsToSelector:@selector(stringValue)]) {
        return [result stringValue];
    }
    return [result description];
}

static BOOL BrowserSelectorNameMatchesMediaFilter(NSString *selectorName) {
    static NSArray<NSString *> *keywords = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keywords = @[
            @"mediasource",
            @"managedmediasource",
            @"sourcebuffer",
            @"media",
            @"video",
            @"inline",
            @"autoplay",
            @"fullscreen",
            @"pictureinpicture",
            @"airplay",
            @"webm",
            @"vp9",
            @"av1",
            @"hls",
            @"mse",
            @"codec",
        ];
    });

    NSString *lowercaseSelectorName = selectorName.lowercaseString;
    for (NSString *keyword in keywords) {
        if ([lowercaseSelectorName containsString:keyword]) {
            return YES;
        }
    }
    return NO;
}

static NSArray<NSString *> *BrowserFilteredSelectorNamesForClass(Class klass) {
    if (klass == Nil) {
        return @[];
    }

    NSMutableOrderedSet<NSString *> *selectorNames = [NSMutableOrderedSet orderedSet];
    for (Class currentClass = klass; currentClass != Nil && currentClass != [NSObject class]; currentClass = class_getSuperclass(currentClass)) {
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(currentClass, &methodCount);
        for (unsigned int methodIndex = 0; methodIndex < methodCount; methodIndex += 1) {
            SEL selector = method_getName(methods[methodIndex]);
            NSString *selectorName = NSStringFromSelector(selector);
            if (selectorName.length > 0 && BrowserSelectorNameMatchesMediaFilter(selectorName)) {
                [selectorNames addObject:selectorName];
            }
        }
        free(methods);
    }

    return [selectorNames.array sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

static NSString *BrowserGetterNameFromSetterName(NSString *setterName) {
    if (![setterName hasPrefix:@"set"] || ![setterName hasSuffix:@":"] || setterName.length <= 4) {
        return nil;
    }

    NSString *propertyStem = [setterName substringWithRange:NSMakeRange(3, setterName.length - 4)];
    if (propertyStem.length == 0) {
        return nil;
    }

    NSString *firstCharacter = [[propertyStem substringToIndex:1] lowercaseString];
    if (propertyStem.length == 1) {
        return firstCharacter;
    }

    return [firstCharacter stringByAppendingString:[propertyStem substringFromIndex:1]];
}

static NSString *BrowserBooleanValueDescriptionForObjectAndSelector(id object, NSString *selectorName) {
    if (object == nil || selectorName.length == 0) {
        return nil;
    }

    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) {
        return nil;
    }

    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (signature == nil || signature.numberOfArguments != 2) {
        return nil;
    }

    const char *returnType = signature.methodReturnType;
    if (returnType == NULL) {
        return nil;
    }

    if (returnType[0] != 'B' && returnType[0] != 'c') {
        return nil;
    }

    BOOL value = ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
    return value ? @"YES" : @"NO";
}

static id BrowserObjectResultForGetter(id object, NSString *selectorName) {
    if (object == nil || selectorName.length == 0) {
        return nil;
    }

    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) {
        return nil;
    }

    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (signature == nil || signature.numberOfArguments != 2) {
        return nil;
    }

    const char *returnType = signature.methodReturnType;
    if (returnType == NULL || returnType[0] != '@') {
        return nil;
    }

    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSString *BrowserPreviewString(NSString *string, NSUInteger maxLength) {
    if (string.length <= maxLength) {
        return string;
    }
    return [[string substringToIndex:maxLength] stringByAppendingString:@"\n…"];
}

static NSString *BrowserStringValueForKnownSelectors(id object, NSArray<NSString *> *selectorNames) {
    for (NSString *selectorName in selectorNames) {
        id result = BrowserObjectResultForGetter(object, selectorName);
        if (result == nil || result == [NSNull null]) {
            continue;
        }
        NSString *stringResult = nil;
        if ([result isKindOfClass:[NSString class]]) {
            stringResult = result;
        } else if ([result respondsToSelector:@selector(stringValue)]) {
            stringResult = [result stringValue];
        } else {
            stringResult = [result description];
        }

        if (stringResult.length > 0) {
            return stringResult;
        }
    }
    return nil;
}

static NSArray<NSDictionary<NSString *, NSString *> *> *BrowserFeatureEntriesForPreferences(id preferences) {
    if (preferences == nil) {
        return @[];
    }

    NSArray<NSString *> *collectionSelectors = @[
        @"_experimentalFeatures",
        @"_internalDebugFeatures",
        @"_features",
    ];

    NSMutableArray<NSDictionary<NSString *, NSString *> *> *entries = [NSMutableArray array];
    for (NSString *collectionSelectorName in collectionSelectors) {
        id collection = BrowserObjectResultForGetter(preferences, collectionSelectorName);
        if (![collection conformsToProtocol:@protocol(NSFastEnumeration)]) {
            continue;
        }

        for (id feature in collection) {
            NSString *name = BrowserStringValueForKnownSelectors(feature, @[@"name", @"key", @"identifier", @"title", @"details"]);
            if (name.length == 0) {
                continue;
            }

            NSString *lowercaseName = name.lowercaseString;
            if (![lowercaseName containsString:@"media"] &&
                ![lowercaseName containsString:@"source"] &&
                ![lowercaseName containsString:@"vp9"] &&
                ![lowercaseName containsString:@"av1"] &&
                ![lowercaseName containsString:@"webm"] &&
                ![lowercaseName containsString:@"video"] &&
                ![lowercaseName containsString:@"mse"] &&
                ![lowercaseName containsString:@"managed"]) {
                continue;
            }

            NSString *enabledValue = BrowserBooleanValueDescriptionForObjectAndSelector(feature, @"enabled");
            if (enabledValue == nil) {
                enabledValue = BrowserBooleanValueDescriptionForObjectAndSelector(feature, @"isEnabled");
            }
            if (enabledValue == nil) {
                enabledValue = @"unknown";
            }

            NSString *key = BrowserStringValueForKnownSelectors(feature, @[@"key", @"identifier"]);
            NSString *source = [collectionSelectorName stringByReplacingOccurrencesOfString:@"_" withString:@""];
            [entries addObject:@{
                @"source": source ?: @"features",
                @"name": name,
                @"enabled": enabledValue,
                @"key": key ?: @"",
            }];
        }
    }

    return entries;
}

static void BrowserSetBooleanSelectorIfAvailable(id object, NSString *selectorName, BOOL value) {
    if (object == nil || selectorName.length == 0) {
        return;
    }

    SEL selector = NSSelectorFromString(selectorName);
    if ([object respondsToSelector:selector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(object, selector, value);
    }
}

static void BrowserConfigurePrivateMediaPreferences(id configuration) {
    if (configuration == nil) {
        return;
    }

    SEL preferencesSelector = NSSelectorFromString(@"preferences");
    if (![configuration respondsToSelector:preferencesSelector]) {
        return;
    }

    id preferences = ((id (*)(id, SEL))objc_msgSend)(configuration, preferencesSelector);
    if (preferences == nil) {
        return;
    }

    BrowserSetBooleanSelectorIfAvailable(preferences, @"_setMediaSourceEnabled:", YES);
    BrowserSetBooleanSelectorIfAvailable(preferences, @"_setManagedMediaSourceEnabled:", YES);
    BrowserSetBooleanSelectorIfAvailable(preferences, @"_setMediaCapabilityGrantsEnabled:", YES);
    BrowserSetBooleanSelectorIfAvailable(preferences, @"_setVideoQualityIncludesDisplayCompositingEnabled:", YES);
}

static NSString *BrowserYouTubeRequestCaptureScript(void) {
    return
    @"(function(){"
        "if (window.__browserYouTubeHookInstalled) { return; }"
        "window.__browserYouTubeHookInstalled = true;"
        "window.__browserYouTubeIntegrity = window.__browserYouTubeIntegrity || {};"
        "function assignIfPresent(key, value) {"
            "if (value === undefined || value === null) { return; }"
            "var stringValue = String(value || '');"
            "if (!stringValue) { return; }"
            "window.__browserYouTubeIntegrity[key] = stringValue;"
        "}"
        "function capturePayload(payload) {"
            "try {"
                "if (!payload || typeof payload !== 'object') { return; }"
                "if (payload.serviceIntegrityDimensions) {"
                    "assignIfPresent('poToken', payload.serviceIntegrityDimensions.poToken || payload.serviceIntegrityDimensions.po_token);"
                "}"
                "if (payload.context && payload.context.serviceIntegrityDimensions) {"
                    "assignIfPresent('poToken', payload.context.serviceIntegrityDimensions.poToken || payload.context.serviceIntegrityDimensions.po_token);"
                "}"
                "if (payload.context && payload.context.client) {"
                    "assignIfPresent('requestClientName', payload.context.client.clientName);"
                    "assignIfPresent('requestClientVersion', payload.context.client.clientVersion);"
                "}"
            "} catch (error) {}"
        "}"
        "function toHeaderObject(headers) {"
            "var result = {};"
            "try {"
                "if (!headers) { return result; }"
                "if (typeof Headers !== 'undefined' && headers instanceof Headers) {"
                    "headers.forEach(function(value, key) { result[String(key)] = String(value); });"
                    "return result;"
                "}"
                "if (Array.isArray(headers)) {"
                    "headers.forEach(function(entry) {"
                        "if (Array.isArray(entry) && entry.length >= 2) { result[String(entry[0])] = String(entry[1]); }"
                    "});"
                    "return result;"
                "}"
                "if (typeof headers === 'object') {"
                    "Object.keys(headers).forEach(function(key) { result[String(key)] = String(headers[key]); });"
                "}"
            "} catch (error) {}"
            "return result;"
        "}"
        "function rememberRequest(url, body, headers, transport) {"
            "try {"
                "var integrity = window.__browserYouTubeIntegrity;"
                "integrity.lastPlayerRequestURL = String(url || '');"
                "integrity.lastPlayerRequestBody = String(body || '');"
                "integrity.lastPlayerRequestHeaders = JSON.stringify(headers || {});"
                "integrity.lastPlayerRequestTransport = String(transport || '');"
                "if (!integrity.firstPlayerRequestURL) {"
                    "integrity.firstPlayerRequestURL = integrity.lastPlayerRequestURL;"
                    "integrity.firstPlayerRequestBody = integrity.lastPlayerRequestBody;"
                    "integrity.firstPlayerRequestHeaders = integrity.lastPlayerRequestHeaders;"
                    "integrity.firstPlayerRequestTransport = integrity.lastPlayerRequestTransport;"
                "}"
            "} catch (error) {}"
        "}"
        "function captureBodyStringAsync(source, bodyString, headers, transport) {"
            "try {"
                "if (bodyString && bodyString !== '[object ReadableStream]') {"
                    "rememberRequest(source.url || '', bodyString, headers || {}, transport || '');"
                    "try { capturePayload(JSON.parse(bodyString)); } catch (error) {}"
                    "return;"
                "}"
                "if (source && typeof source.clone === 'function' && typeof source.text === 'function') {"
                    "source.clone().text().then(function(text) {"
                        "rememberRequest(source.url || '', text || '', headers || {}, transport || '');"
                        "try { capturePayload(JSON.parse(text || '')); } catch (error) {}"
                    "}).catch(function(){});"
                "}"
            "} catch (error) {}"
        "}"
        "function captureRequest(input, init) {"
            "try {"
                "var url = '';"
                "if (typeof input === 'string') { url = input; }"
                "else if (input && typeof input.url === 'string') { url = input.url; }"
                "if (url.indexOf('/youtubei/v1/player') === -1) { return; }"
                "var body = (init && init.body) || (input && input.body) || null;"
                "var bodyString = '';"
                "if (typeof body === 'string') { bodyString = body; }"
                "else if (body && typeof body === 'object' && typeof body.toString === 'function') { bodyString = String(body); }"
                "var headers = toHeaderObject((init && init.headers) || (input && input.headers) || null);"
                "rememberRequest(url, bodyString, headers, 'fetch');"
                "captureBodyStringAsync((input && typeof input.clone === 'function') ? input : null, bodyString, headers, 'fetch');"
                "if (typeof bodyString !== 'string' || !bodyString || bodyString === '[object ReadableStream]') { return; }"
                "try { capturePayload(JSON.parse(bodyString)); } catch (error) {}"
            "} catch (error) {}"
        "}"
        "function captureXHRRequest(xhr, body) {"
            "try {"
                "var url = String((xhr && xhr.__browserYouTubeURL) || '');"
                "if (url.indexOf('/youtubei/v1/player') === -1) { return; }"
                "var bodyString = '';"
                "if (typeof body === 'string') { bodyString = body; }"
                "else if (body && typeof body === 'object' && typeof body.toString === 'function') { bodyString = String(body); }"
                "var headers = xhr && xhr.__browserYouTubeHeaders ? xhr.__browserYouTubeHeaders : {};"
                "rememberRequest(url, bodyString, headers, 'xhr');"
                "if (typeof bodyString !== 'string' || !bodyString) { return; }"
                "try { capturePayload(JSON.parse(bodyString)); } catch (error) {}"
            "try { capturePayload(JSON.parse(body)); } catch (error) {}"
            "} catch (error) {}"
        "}"
        "var cfg = (window.ytcfg && window.ytcfg.data_) || {};"
        "assignIfPresent('poToken', cfg.PO_TOKEN || cfg.po_token || cfg.POTOKEN);"
        "if (cfg.SERVICE_INTEGRITY_DIMENSIONS) {"
            "assignIfPresent('poToken', cfg.SERVICE_INTEGRITY_DIMENSIONS.poToken || cfg.SERVICE_INTEGRITY_DIMENSIONS.po_token);"
        "}"
        "if (cfg.WEB_PLAYER_CONTEXT_CONFIGS) {"
            "var watchConfig = cfg.WEB_PLAYER_CONTEXT_CONFIGS.WEB_PLAYER_CONTEXT_CONFIG_ID_KEVLAR_WATCH || {};"
            "if (watchConfig.serviceIntegrityDimensions) {"
                "assignIfPresent('poToken', watchConfig.serviceIntegrityDimensions.poToken || watchConfig.serviceIntegrityDimensions.po_token);"
            "}"
        "}"
        "if (window.fetch) {"
            "var originalFetch = window.fetch;"
            "window.fetch = function(input, init) {"
                "captureRequest(input, init);"
                "return originalFetch.apply(this, arguments);"
            "};"
        "}"
        "if (window.XMLHttpRequest && window.XMLHttpRequest.prototype) {"
            "var originalOpen = window.XMLHttpRequest.prototype.open;"
            "var originalSend = window.XMLHttpRequest.prototype.send;"
            "var originalSetRequestHeader = window.XMLHttpRequest.prototype.setRequestHeader;"
            "window.XMLHttpRequest.prototype.open = function(method, url) {"
                "this.__browserYouTubeURL = String(url || '');"
                "this.__browserYouTubeHeaders = {};"
                "return originalOpen.apply(this, arguments);"
            "};"
            "window.XMLHttpRequest.prototype.setRequestHeader = function(key, value) {"
                "try {"
                    "if (!this.__browserYouTubeHeaders) { this.__browserYouTubeHeaders = {}; }"
                    "this.__browserYouTubeHeaders[String(key)] = String(value);"
                "} catch (error) {}"
                "return originalSetRequestHeader.apply(this, arguments);"
            "};"
            "window.XMLHttpRequest.prototype.send = function(body) {"
                "captureXHRRequest(this, body);"
                "return originalSend.apply(this, arguments);"
            "};"
        "}"
    "})();";
}

static void BrowserInstallYouTubeCaptureUserScript(id configuration) {
    if (configuration == nil) {
        return;
    }

    Class userContentControllerClass = NSClassFromString(kBrowserUserContentControllerClassName);
    Class userScriptClass = NSClassFromString(kBrowserUserScriptClassName);
    if (userContentControllerClass == Nil || userScriptClass == Nil) {
        return;
    }

    SEL userContentControllerGetter = NSSelectorFromString(@"userContentController");
    SEL setUserContentControllerSelector = NSSelectorFromString(@"setUserContentController:");
    id userContentController = nil;
    if ([configuration respondsToSelector:userContentControllerGetter]) {
        userContentController = ((id (*)(id, SEL))objc_msgSend)(configuration, userContentControllerGetter);
    }

    if (userContentController == nil && [configuration respondsToSelector:setUserContentControllerSelector]) {
        userContentController = ((id (*)(id, SEL))objc_msgSend)((id)userContentControllerClass, @selector(new));
        ((void (*)(id, SEL, id))objc_msgSend)(configuration, setUserContentControllerSelector, userContentController);
    }

    SEL addUserScriptSelector = NSSelectorFromString(@"addUserScript:");
    SEL userScriptInitializer = NSSelectorFromString(@"initWithSource:injectionTime:forMainFrameOnly:");
    if (userContentController == nil ||
        ![userContentController respondsToSelector:addUserScriptSelector] ||
        ![userScriptClass instancesRespondToSelector:userScriptInitializer]) {
        return;
    }

    id userScript = ((id (*)(id, SEL))objc_msgSend)((id)userScriptClass, @selector(alloc));
    userScript = ((id (*)(id, SEL, id, NSInteger, BOOL))objc_msgSend)(userScript, userScriptInitializer, BrowserYouTubeRequestCaptureScript(), 0, NO);
    if (userScript != nil) {
        ((void (*)(id, SEL, id))objc_msgSend)(userContentController, addUserScriptSelector, userScript);
    }
}

#pragma mark - Website data storage

/// tvOS apps may not write to Library (outside Caches), so WebKit's default
/// persistent store cannot create its folders and silently keeps localStorage,
/// IndexedDB, service workers, etc. in memory only. Put all of it under
/// Caches instead. (tvOS can purge Caches when the device runs low on space,
/// so this is "persistent unless the system needs the room".)
static NSURL *BrowserWebsiteDataDirectoryURL(void) {
    NSURL *cachesURL = [[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    return [cachesURL URLByAppendingPathComponent:@"BrowserWebsiteData" isDirectory:YES];
}

static void BrowserSetURLIfAvailable(id target, NSString *selectorName, NSURL *URL) {
    SEL selector = NSSelectorFromString(selectorName);
    if (URL != nil && [target respondsToSelector:selector]) {
        [[NSFileManager defaultManager] createDirectoryAtURL:URL withIntermediateDirectories:YES attributes:nil error:nil];
        ((void (*)(id, SEL, id))objc_msgSend)(target, selector, URL);
    }
}

static id BrowserMakeCachesBackedDataStoreConfiguration(NSURL *rootURL) {
    Class configurationClass = NSClassFromString(@"_WKWebsiteDataStoreConfiguration");
    if (configurationClass == Nil) {
        return nil;
    }

    id configuration = nil;
    SEL initWithDirectory = NSSelectorFromString(@"initWithDirectory:");
    if ([configurationClass instancesRespondToSelector:initWithDirectory]) {
        // Newer WebKit: one root folder for every kind of site data.
        configuration = ((id (*)(id, SEL))objc_msgSend)((id)configurationClass, @selector(alloc));
        configuration = ((id (*)(id, SEL, id))objc_msgSend)(configuration, initWithDirectory, rootURL);
    }
    if (configuration == nil) {
        configuration = ((id (*)(id, SEL))objc_msgSend)((id)configurationClass, @selector(new));
    }

    // Set the individual folders as well, so nothing falls back to Library on
    // WebKit builds where the root folder does not cover every store.
    NSDictionary<NSString *, NSString *> *subdirectories = @{
        @"setGeneralStorageDirectory:": @"General",
        @"_setWebStorageDirectory:": @"LocalStorage",
        @"_setIndexedDBDatabaseDirectory:": @"IndexedDB",
        @"_setWebSQLDatabaseDirectory:": @"WebSQL",
        @"_setCacheStorageDirectory:": @"CacheStorage",
        @"_setServiceWorkerRegistrationDirectory:": @"ServiceWorkers",
        @"_setResourceLoadStatisticsDirectory:": @"ResourceLoadStatistics",
        @"_setResourceMonitorThrottlerDirectory:": @"ResourceMonitorThrottler",
        @"setNetworkCacheDirectory:": @"NetworkCache",
        @"setMediaCacheDirectory:": @"MediaCache",
        @"setMediaKeysStorageDirectory:": @"MediaKeys",
        @"setDeviceIdHashSaltsStorageDirectory:": @"DeviceIdHashSalts",
        @"setHSTSStorageDirectory:": @"HSTS",
        @"setAlternativeServicesStorageDirectory:": @"AlternativeServices",
        @"setSearchFieldHistoryDirectory:": @"SearchHistory",
        @"setApplicationCacheDirectory:": @"ApplicationCache",
    };
    [subdirectories enumerateKeysAndObjectsUsingBlock:^(NSString *selectorName, NSString *name, __unused BOOL *stop) {
        BrowserSetURLIfAvailable(configuration, selectorName, [rootURL URLByAppendingPathComponent:name isDirectory:YES]);
    }];
    return configuration;
}

/// One store for every tab (shared cookies, storage and network process).
static id BrowserSharedWebsiteDataStore(void) {
    static id dataStore;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        BrowserEnsureWebKitRuntimeLoaded();
        Class dataStoreClass = NSClassFromString(kBrowserWebsiteDataStoreClassName);
        if (dataStoreClass == Nil) {
            return;
        }

        NSURL *rootURL = BrowserWebsiteDataDirectoryURL();
        [[NSFileManager defaultManager] createDirectoryAtURL:rootURL withIntermediateDirectories:YES attributes:nil error:nil];
        id configuration = BrowserMakeCachesBackedDataStoreConfiguration(rootURL);
        SEL initWithConfiguration = NSSelectorFromString(@"_initWithConfiguration:");
        if (configuration != nil && [dataStoreClass instancesRespondToSelector:initWithConfiguration]) {
            id store = ((id (*)(id, SEL))objc_msgSend)((id)dataStoreClass, @selector(alloc));
            dataStore = ((id (*)(id, SEL, id))objc_msgSend)(store, initWithConfiguration, configuration);
        }
        if (dataStore != nil) {
            NSLog(@"[Browser] Website data stored in %@", rootURL.path);
            return;
        }

        SEL defaultDataStore = NSSelectorFromString(@"defaultDataStore");
        if ([dataStoreClass respondsToSelector:defaultDataStore]) {
            NSLog(@"[Browser] Custom website data store unavailable; using WebKit's default store");
            dataStore = ((id (*)(id, SEL))objc_msgSend)((id)dataStoreClass, defaultDataStore);
        }
    });
    return dataStore;
}

static void *BrowserWebViewProgressObservationContext = &BrowserWebViewProgressObservationContext;

#pragma mark - Cross-origin HLS fix

/// tvOS WebKit has no MediaSource, so players like hls.js fall back to handing
/// the .m3u8 straight to <video>. A plain <video> request carries no Origin
/// header, and many HLS hosts answer 404 without one (they expect hls.js'
/// CORS fetches). Loading the media in CORS mode (crossorigin="anonymous")
/// makes WebKit send Origin. If a server turns out not to allow CORS, the
/// element is retried once without it.
static NSString *BrowserCrossOriginHLSScript(void) {
    return @"(function(){"
        "if (window.__browserHLSCORSInstalled || !window.HTMLMediaElement) { return; }"
        "window.__browserHLSCORSInstalled = true;"
        "function needsCORS(element, value) {"
            "if (!element || element.hasAttribute('crossorigin') || element.__browserCORSRetried) { return false; }"
            "try {"
                "var url = new URL(String(value), document.baseURI);"
                "if (url.protocol !== 'https:' && url.protocol !== 'http:') { return false; }"
                "if (url.origin === location.origin) { return false; }"
                "return /\\.m3u8$/i.test(url.pathname) || /[?&](format|type)=m3u8/i.test(url.search);"
            "} catch (error) { return false; }"
        "}"
        "function prepare(element, value) {"
            "if (needsCORS(element, value)) {"
                "element.crossOrigin = 'anonymous';"
                "element.__browserAddedCORS = true;"
            "}"
        "}"
        "var descriptor = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');"
        "if (descriptor && descriptor.set) {"
            "Object.defineProperty(HTMLMediaElement.prototype, 'src', {"
                "configurable: true, enumerable: descriptor.enumerable, get: descriptor.get,"
                "set: function(value) { prepare(this, value); return descriptor.set.call(this, value); }"
            "});"
        "}"
        "var originalSetAttribute = Element.prototype.setAttribute;"
        "Element.prototype.setAttribute = function(name, value) {"
            "if (this instanceof HTMLMediaElement && String(name).toLowerCase() === 'src') { prepare(this, value); }"
            "else if (this instanceof HTMLSourceElement && String(name).toLowerCase() === 'src' && this.parentElement instanceof HTMLMediaElement) { prepare(this.parentElement, value); }"
            "return originalSetAttribute.apply(this, arguments);"
        "};"
        "document.addEventListener('error', function(event) {"
            "var element = event.target;"
            "if (!(element instanceof HTMLMediaElement) || !element.__browserAddedCORS || !element.error) { return; }"
            "element.__browserAddedCORS = false;"
            "element.__browserCORSRetried = true;"
            "element.removeAttribute('crossorigin');"
            "try { element.load(); } catch (error) {}"
        "}, true);"
        // Without MediaSource, players hand the stream to <video> only after the page has already
        // called play() on the empty element. Loading the new source cancels that pending play and
        // nothing calls play() again, so the video sat paused at 0:00. Remember that the page
        // wanted playback and resume once the new source can play, unless it was paused since.
        "var originalPlay = HTMLMediaElement.prototype.play, originalPause = HTMLMediaElement.prototype.pause;"
        "HTMLMediaElement.prototype.play = function() { this.__browserWantsPlay = Date.now(); return originalPlay.apply(this, arguments); };"
        "HTMLMediaElement.prototype.pause = function() {"
            "if (this.readyState >= 2 && this.currentSrc) { this.__browserWantsPlay = 0; this.__browserResume = false; }"
            "return originalPause.apply(this, arguments);"
        "};"
        "document.addEventListener('loadstart', function(event) {"
            "var element = event.target;"
            "if (!(element instanceof HTMLMediaElement)) { return; }"
            "element.__browserResume = !!(element.__browserWantsPlay && Date.now() - element.__browserWantsPlay < 20000) || element.autoplay;"
        "}, true);"
        "document.addEventListener('canplay', function(event) {"
            "var element = event.target;"
            "if (!(element instanceof HTMLMediaElement) || !element.__browserResume) { return; }"
            "element.__browserResume = false;"
            "setTimeout(function() {"
                "if (!element.paused || element.ended || !element.isConnected) { return; }"
                "try { var promise = originalPlay.call(element); if (promise && promise.catch) { promise.catch(function() {}); } } catch (error) {}"
            "}, 60);"
        "}, true);"
    "})();";
}

static void BrowserInstallCrossOriginHLSUserScript(id configuration) {
    Class userScriptClass = NSClassFromString(kBrowserUserScriptClassName);
    SEL userContentControllerGetter = NSSelectorFromString(@"userContentController");
    SEL userScriptInitializer = NSSelectorFromString(@"initWithSource:injectionTime:forMainFrameOnly:");
    if (configuration == nil || userScriptClass == Nil || ![configuration respondsToSelector:userContentControllerGetter] ||
        ![userScriptClass instancesRespondToSelector:userScriptInitializer]) {
        return;
    }
    id userContentController = ((id (*)(id, SEL))objc_msgSend)(configuration, userContentControllerGetter);
    id userScript = ((id (*)(id, SEL))objc_msgSend)((id)userScriptClass, @selector(alloc));
    // Document start, all frames: embedded players live in iframes too.
    userScript = ((id (*)(id, SEL, id, NSInteger, BOOL))objc_msgSend)(userScript, userScriptInitializer, BrowserCrossOriginHLSScript(), 0, NO);
    if (userContentController != nil && userScript != nil) {
        ((void (*)(id, SEL, id))objc_msgSend)(userContentController, NSSelectorFromString(@"addUserScript:"), userScript);
    }
}

#pragma mark - Subtitle capture (for the native full screen player)

/// Keeps the subtitles the page is using so the native full screen player can show them:
/// the last subtitle file the page downloaded (SRT/VTT, e.g. after choosing a language in a
/// site's player) and, for players using standard captions, the cues of the showing track.
static NSString *BrowserSubtitleCaptureScript(void) {
    return @"(function(){"
        "if (window.__browserSubtitleCapture) { return; }"
        "window.__browserSubtitleCapture = true;"
        // Timed text that is not subtitles - e.g. WebVTT thumbnail tracks for seek previews
        // ("thumbs/sprite-001.jpg#xywh=0,0,160,90") - must not be picked up.
        "function looksLikeSubtitles(text) {"
            "if (typeof text !== 'string' || text.length < 20 || text.length > 4000000) { return false; }"
            "var sample = text.slice(0, 6000);"
            "if (sample.indexOf('-->') === -1) { return false; }"
            "if (/#xywh=/i.test(sample) || /^[^\\s]+\\.(jpe?g|png|webp|gif)(#[^\\s]*)?\\s*$/im.test(sample)) { return false; }"
            "return true;"
        "}"
        "function isCandidate(url, type) { url = String(url || ''); return /\\.(srt|vtt|ass|ssa)(\\?|#|$)/i.test(url) || /\\/(subs?|subtitles?|captions?)\\//i.test(url) || /text\\/vtt|subrip|x-srt/i.test(type || ''); }"
        "function remember(url, text) { if (looksLikeSubtitles(text)) { window.__browserSubtitles = { url: String(url), text: text, at: Date.now() }; } }"
        "if (window.fetch) {"
            "var originalFetch = window.fetch;"
            "window.fetch = function(input) {"
                "var promise = originalFetch.apply(this, arguments);"
                "try {"
                    "var requested = input && input.url ? input.url : input;"
                    "promise.then(function(response) {"
                        "try { if (isCandidate(response.url || requested, response.headers.get('content-type'))) { response.clone().text().then(function(text) { remember(response.url || requested, text); }, function() {}); } } catch (e) {}"
                    "}, function() {});"
                "} catch (e) {}"
                "return promise;"
            "};"
        "}"
        "var originalOpen = XMLHttpRequest.prototype.open, originalSend = XMLHttpRequest.prototype.send;"
        "XMLHttpRequest.prototype.open = function(method, url) { this.__browserSubtitleURL = url; return originalOpen.apply(this, arguments); };"
        "XMLHttpRequest.prototype.send = function() {"
            "var xhr = this;"
            "try { xhr.addEventListener('load', function() { try { if ((xhr.responseType === '' || xhr.responseType === 'text') && isCandidate(xhr.responseURL || xhr.__browserSubtitleURL, xhr.getResponseHeader('content-type'))) { remember(xhr.responseURL || xhr.__browserSubtitleURL, xhr.responseText); } } catch (e) {} }); } catch (e) {}"
            "return originalSend.apply(this, arguments);"
        "};"
        "window.__browserSubtitlesForNativePlayer = function() {"
            "var videos = document.querySelectorAll('video'), video = null, best = 0;"
            "for (var i = 0; i < videos.length; i++) { var r = videos[i].getBoundingClientRect(); if (r.width * r.height > best) { best = r.width * r.height; video = videos[i]; } }"
            "if (video && video.textTracks) {"
                "for (var t = 0; t < video.textTracks.length; t++) {"
                    "var track = video.textTracks[t];"
                    "if (track.mode === 'showing' && track.cues && track.cues.length) {"
                        "var cues = [];"
                        "for (var c = 0; c < track.cues.length && c < 20000; c++) { var cue = track.cues[c]; cues.push([cue.startTime, cue.endTime, cue.text || '']); }"
                        "return JSON.stringify({ label: track.label || track.language || 'Subtitles', cues: cues });"
                    "}"
                "}"
            "}"
            "var captured = window.__browserSubtitles;"
            "if (captured) { var name = decodeURIComponent(String(captured.url).split('?')[0].split('/').pop() || ''); return JSON.stringify({ label: 'Website subtitles', source: name, text: captured.text }); }"
            "return '';"
        "};"
    "})();";
}

#pragma mark - Fullscreen API replacement

static NSString * const kBrowserFullscreenMessageHandlerName = @"browserFullscreen";

/// tvOS WebKit has no element fullscreen API (requestFullscreen & co. are missing)
/// and its native video fullscreen shows a black screen. Provide the standard API
/// by stretching the requested element over the whole page; the app hides its
/// top bar meanwhile. Site player controls, subtitles and menus keep working.
static NSString *BrowserFullscreenPolyfillScript(void) {
    return @"(function(){"
        "if (window.__browserFullscreenPolyfill) { return; }"
        "if (typeof Element.prototype.requestFullscreen === 'function' || typeof Element.prototype.webkitRequestFullscreen === 'function') { return; }"
        "window.__browserFullscreenPolyfill = true;"
        "var current = null;"
        // The top page tells the app (top bar, Menu to exit); a player inside an iframe asks its parent
        // page to stretch the iframe (see the frame bridge), which passes it on up to the top.
        "function notify(active) {"
            "if (window.top === window) { try { window.webkit.messageHandlers.browserFullscreen.postMessage({ active: active }); } catch (e) {} return; }"
            "try { window.parent.postMessage({ __bfbUp: 'fs', active: active }, '*'); } catch (e) {}"
        "}"
        "function ensureStyle() {"
            "if (document.getElementById('__browser-fullscreen-style')) { return; }"
            "var style = document.createElement('style'); style.id = '__browser-fullscreen-style';"
            "style.textContent = '[data-browser-fullscreen]{position:fixed!important;left:0!important;top:0!important;right:0!important;bottom:0!important;width:100vw!important;height:100vh!important;max-width:none!important;max-height:none!important;margin:0!important;padding:0!important;z-index:2147483646!important;background:#000!important;transform:none!important;border-radius:0!important;}'"
                "+ '[data-browser-fullscreen] video, video[data-browser-fullscreen]{width:100%!important;height:100%!important;max-height:none!important;object-fit:contain!important;}'"
                "+ 'html.__browser-fullscreen, html.__browser-fullscreen body{overflow:hidden!important;}';"
            "(document.head || document.documentElement).appendChild(style);"
        "}"
        "function fire(target, names) {"
            "setTimeout(function() {"
                "names.forEach(function(name) { try { target.dispatchEvent(new Event(name, { bubbles: true })); } catch (e) {} });"
                "try { window.dispatchEvent(new Event('resize')); } catch (e) {}"
            "}, 0);"
        "}"
        "function playerContainerFor(video) {"
            "var vr = video.getBoundingClientRect(); var node = video.parentElement; var best = video;"
            "for (var depth = 0; node && node !== document.body && depth < 4; depth++, node = node.parentElement) {"
                // display:contents wrappers draw no box, so they cannot be stretched over the screen.
                "if (getComputedStyle(node).display === 'contents') { break; }"
                "var r = node.getBoundingClientRect();"
                "if (r.width * r.height > Math.max(1, vr.width * vr.height) * 1.6) { break; }"
                "best = node;"
            "}"
            "return best;"
        "}"
        "function enter(element) {"
            "if (!element || element === document) { element = document.documentElement; }"
            "if (current === element) { return Promise.resolve(); }"
            "if (current) { leave(true); }"
            "ensureStyle();"
            "current = element;"
            "element.setAttribute('data-browser-fullscreen', '');"
            "document.documentElement.classList.add('__browser-fullscreen');"
            "notify(true);"
            "fire(element, ['fullscreenchange', 'webkitfullscreenchange']);"
            "return Promise.resolve();"
        "}"
        "function leave(silent) {"
            "if (!current) { return Promise.resolve(); }"
            "var element = current; current = null;"
            "element.removeAttribute('data-browser-fullscreen');"
            "if (element.tagName === 'IFRAME') { try { element.contentWindow.postMessage({ __bfb: 'fsexit' }, '*'); } catch (e) {} }"
            "document.documentElement.classList.remove('__browser-fullscreen');"
            "notify(false);"
            "if (!silent) { fire(element, ['fullscreenchange', 'webkitfullscreenchange']); }"
            "return Promise.resolve();"
        "}"
        "Element.prototype.requestFullscreen = function() { return enter(this); };"
        "Element.prototype.webkitRequestFullscreen = function() { enter(this); };"
        "Element.prototype.webkitRequestFullScreen = Element.prototype.webkitRequestFullscreen;"
        "Document.prototype.exitFullscreen = function() { return leave(false); };"
        "Document.prototype.webkitExitFullscreen = function() { leave(false); };"
        "Document.prototype.webkitCancelFullScreen = Document.prototype.webkitExitFullscreen;"
        "function getter(proto, name, fn) { try { Object.defineProperty(proto, name, { configurable: true, get: fn }); } catch (e) {} }"
        "['fullscreenElement', 'webkitFullscreenElement', 'webkitCurrentFullScreenElement'].forEach(function(name) { getter(Document.prototype, name, function() { return current; }); });"
        "['fullscreenEnabled', 'webkitFullscreenEnabled', 'webkitFullScreenEnabled'].forEach(function(name) { getter(Document.prototype, name, function() { return true; }); });"
        "['fullscreen', 'webkitIsFullScreen'].forEach(function(name) { getter(Document.prototype, name, function() { return !!current; }); });"
        // Hide the iOS-only video fullscreen (webkitEnterFullscreen & co.). On tvOS it is the black
        // native path, and players that see it take their iOS route, which switches off their own
        // subtitles/controls in favour of native captions. Without it they use the standard
        // requestFullscreen() above on their player, keeping their subtitles and controls.
        "['webkitEnterFullscreen', 'webkitEnterFullScreen', 'webkitExitFullscreen', 'webkitExitFullScreen'].forEach(function(name) {"
            "try { Object.defineProperty(HTMLVideoElement.prototype, name, { configurable: true, writable: true, value: undefined }); } catch (e) {}"
        "});"
        "getter(HTMLVideoElement.prototype, 'webkitSupportsFullscreen', function() { return false; });"
        "getter(HTMLVideoElement.prototype, 'webkitDisplayingFullscreen', function() { return false; });"
        "window.__browserExitFullscreen = function() { leave(false); };"
        "new MutationObserver(function() { if (current && !document.contains(current)) { leave(false); } }).observe(document.documentElement, { childList: true, subtree: true });"
    "})();";
}

#pragma mark - Frame bridge (players inside cross-site iframes)

/// Random per launch. Only the app knows it (it lives in a closure of the user script and in the
/// scripts the app evaluates), so pages cannot use the bridge to click inside frames they embed.
static NSString *BrowserFrameBridgeTokenValue(void) {
    static NSString *token;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        token = [[NSUUID UUID].UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""];
    });
    return token;
}

/// The app's clicks and hovers are dispatched by script in the top page, where a cross-site player
/// is just an <iframe> element, so its buttons (unmute, play, fullscreen, servers) never got them.
/// This script runs in every frame: the top page hands a click/hover/Play-Pause to the iframe under
/// the point, and each frame applies it to its own element there (or hands it on to a nested frame).
/// It also lets a player inside an iframe go fullscreen: the parent stretches that iframe, but only
/// right after the user clicked into it, so ad frames cannot take over the screen.
static NSString *BrowserFrameBridgeScript(void) {
    NSString *script = @"(function(){"
        "if (window.__browserFrameBridge) { return; }"
        "var TOKEN = '__TOKEN__';"
        "function localPoint(frame, x, y) {"
            "var r = frame.getBoundingClientRect(), cs = getComputedStyle(frame);"
            "return { x: x - r.left - (parseFloat(cs.borderLeftWidth) || 0) - (parseFloat(cs.paddingLeft) || 0),"
                     "y: y - r.top - (parseFloat(cs.borderTopWidth) || 0) - (parseFloat(cs.paddingTop) || 0) };"
        "}"
        "function sendDown(frame, kind, x, y) {"
            "if (!frame || !frame.contentWindow) { return false; }"
            "if (kind !== 'hover') { frame.__browserBridgeAt = Date.now(); }"
            "var p = localPoint(frame, x, y);"
            "try { frame.contentWindow.postMessage({ __bfb: kind, t: TOKEN, x: p.x, y: p.y }, '*'); return true; } catch (e) { return false; }"
        "}"
        "function fire(target, type, x, y, related) {"
            "var init = { bubbles: true, cancelable: true, composed: true, view: window, clientX: x, clientY: y, screenX: x, screenY: y, button: 0, buttons: /down/.test(type) ? 1 : 0, relatedTarget: related || null, pointerType: 'mouse', isPrimary: true };"
            "try { target.dispatchEvent(type.indexOf('pointer') === 0 && window.PointerEvent ? new PointerEvent(type, init) : new MouseEvent(type, init)); } catch (e) {}"
        "}"
        "var hoverTarget = null;"
        "function hover(el, x, y) {"
            "if (hoverTarget !== el) {"
                "if (hoverTarget && hoverTarget.isConnected) { fire(hoverTarget, 'pointerout', x, y, el); fire(hoverTarget, 'mouseout', x, y, el); }"
                "fire(el, 'pointerover', x, y, hoverTarget); fire(el, 'mouseover', x, y, hoverTarget); hoverTarget = el;"
            "}"
            "fire(el, 'pointermove', x, y); fire(el, 'mousemove', x, y);"
        "}"
        "function largest(selector) {"
            "var best = null, bestArea = innerWidth * innerHeight * 0.2;"
            "Array.prototype.forEach.call(document.querySelectorAll(selector), function(el) {"
                "var r = el.getBoundingClientRect();"
                "var w = Math.max(0, Math.min(r.right, innerWidth) - Math.max(r.left, 0)), h = Math.max(0, Math.min(r.bottom, innerHeight) - Math.max(r.top, 0));"
                "if (w * h >= bestArea) { bestArea = w * h; best = el; }"
            "});"
            "return best;"
        "}"
        "function centre(el) { var r = el.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; }"
        // Play/Pause on the remote: the frame's main video (a muted live stream is unmuted first,
        // since players start muted and their unmute button is tiny), else the main nested frame.
        "function toggle() {"
            "var v = largest('video');"
            "if (v) {"
                "var c = centre(v); var at = document.elementFromPoint(c.x, c.y) || v; hover(at, c.x, c.y);"
                "if (!v.paused && !v.ended && v.muted) { v.muted = false; if (!v.volume) { v.volume = 1; } return; }"
                "if (v.paused || v.ended) { var p = v.play(); if (p && p.catch) { p.catch(function() {}); } } else { v.pause(); }"
                "return;"
            "}"
            "var f = largest('iframe'); if (f) { var fc = centre(f); sendDown(f, 'toggle', fc.x, fc.y); }"
        "}"
        "function handle(kind, x, y) {"
            "if (kind === 'toggle') { toggle(); return; }"
            "var el = document.elementFromPoint(x, y);"
            "if (!el) { return; }"
            "if (el.tagName === 'IFRAME') { sendDown(el, kind, x, y); return; }"
            "hover(el, x, y);"
            "if (kind !== 'click') { return; }"
            "try { if (el.focus) { el.focus({ preventScroll: true }); } } catch (e) {}"
            "['pointerdown', 'mousedown', 'pointerup', 'mouseup'].forEach(function(type) { fire(el, type, x, y); });"
            "if (typeof el.click === 'function') { el.click(); } else { fire(el, 'click', x, y); }"
        "}"
        "function frameFor(source) {"
            "var frames = document.querySelectorAll('iframe');"
            "for (var i = 0; i < frames.length; i++) { if (frames[i].contentWindow === source) { return frames[i]; } }"
            "return null;"
        "}"
        "window.addEventListener('message', function(e) {"
            "var d = e.data; if (!d || typeof d !== 'object') { return; }"
            "if (d.__bfb && e.source === window.parent && e.source !== window) {"
                "if (d.__bfb === 'fsexit') { if (window.__browserExitFullscreen) { window.__browserExitFullscreen(); } return; }"
                "if (d.t !== TOKEN) { return; }"
                "handle(d.__bfb, +d.x || 0, +d.y || 0);"
                "return;"
            "}"
            "if (d.__bfbUp === 'fs') {"
                "var frame = frameFor(e.source); if (!frame) { return; }"
                "if (d.active) {"
                    "if (!frame.__browserBridgeAt || Date.now() - frame.__browserBridgeAt > 8000) { return; }"
                    "frame.__browserBridgeAt = Date.now();"
                    "if (frame.requestFullscreen) { frame.requestFullscreen(); }"
                "} else if (document.fullscreenElement === frame && document.exitFullscreen) { document.exitFullscreen(); }"
            "}"
        "});"
        "var api = {"
            "send: function(token, frame, kind, x, y) { return token === TOKEN && !!frame && frame.tagName === 'IFRAME' && sendDown(frame, kind, x, y); },"
            "toggleMainFrame: function(token) { if (token !== TOKEN) { return false; } var f = largest('iframe'); if (!f) { return false; } var c = centre(f); return sendDown(f, 'toggle', c.x, c.y); }"
        "};"
        "try { Object.defineProperty(window, '__browserFrameBridge', { value: Object.freeze(api), writable: false, configurable: false }); } catch (e) {}"
    "})();";
    return [script stringByReplacingOccurrencesOfString:@"__TOKEN__" withString:BrowserFrameBridgeTokenValue()];
}

/// WKUserContentController retains its message handlers; a weak proxy avoids a retain cycle.
@interface BrowserScriptMessageProxy : NSObject
@property (nonatomic, weak) id target;
@end

@implementation BrowserScriptMessageProxy

+ (void)initialize {
    Protocol *handlerProtocol = objc_getProtocol("WKScriptMessageHandler");
    if (handlerProtocol != NULL) {
        class_addProtocol(self, handlerProtocol);
    }
}

- (void)userContentController:(id)userContentController didReceiveScriptMessage:(id)message {
    (void)userContentController;
    SEL selector = NSSelectorFromString(@"handleScriptMessage:");
    if ([self.target respondsToSelector:selector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(self.target, selector, message);
    }
}

@end

#pragma mark - Media diagnostics (launch with -BrowserMediaDiagnostics YES)

static BOOL BrowserMediaDiagnosticsEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"BrowserMediaDiagnostics"];
}

static void BrowserDiagPrint(NSString *message) {
    // stdout so `devicectl device process launch --console` shows it.
    printf("[BDIAG] %s\n", message.UTF8String);
    fflush(stdout);
}

static NSString *BrowserMediaDiagnosticsHookScript(void) {
    return @"(function(){"
        "if (window.__bdiag) { return; }"
        "var D = window.__bdiag = { events: [], t0: Date.now() };"
        // Runs in every frame; sub-frames forward their lines to the top page, tagged with their host.
        "var isTop = window.top === window;"
        "function push(line) { D.events.push(line); if (D.events.length > 400) { D.events.shift(); } }"
        "function log(kind, msg) {"
            "var line = ((Date.now() - D.t0) / 1000).toFixed(1) + 's ' + kind + ' ' + String(msg).slice(0, 220);"
            "if (isTop) { push(line); return; }"
            "try { window.top.postMessage({ __bdiagLine: '[' + location.host + '] ' + line }, '*'); } catch (e) {}"
        "}"
        "if (isTop) { window.addEventListener('message', function(e) { if (e.data && e.data.__bdiagLine) { push(String(e.data.__bdiagLine)); } });"
            "setTimeout(function() { log('iframes', Array.prototype.map.call(document.querySelectorAll('iframe'), function(f) { var r = f.getBoundingClientRect(); return String(f.src).slice(0, 50) + ' @' + Math.round(r.left) + ',' + Math.round(r.top) + ' ' + Math.round(r.width) + 'x' + Math.round(r.height); }).join(' ;; ')); }, 9000); }"
        "else {"
            "log('frame', location.href.slice(0, 160));"
            "window.addEventListener('message', function(e) { var d = e.data; if (!d || !d.__bfb) { return; } var el = document.elementFromPoint(+d.x || 0, +d.y || 0); log('bridge', d.__bfb + ' @' + Math.round(d.x) + ',' + Math.round(d.y) + ' -> ' + (el ? el.tagName + '.' + String(el.className || '').slice(0, 50) + (el.closest && el.closest('a') ? ' href=' + String(el.closest('a').href).slice(0, 80) + ' target=' + el.closest('a').target + ' z=' + getComputedStyle(el.closest('a')).zIndex + ' pos=' + getComputedStyle(el.closest('a')).position + ' parent=' + el.closest('a').parentElement.tagName : '') : 'nothing')); });"
            "var reportControls = function() { var out = []; Array.prototype.forEach.call(document.querySelectorAll('button,[role=button],[class*=button],[class*=fullscreen],[class*=volume],[class*=mute]'), function(el) { var d = ((el.getAttribute('aria-label') || '') + ' ' + (el.getAttribute('title') || '') + ' ' + String(el.className || '') + ' ' + (el.getAttribute('data-fullscreen') !== null ? 'data-fullscreen' : '')).toLowerCase(); if (!/full|screen|mute|volume|sound/.test(d)) { return; } var r = el.getBoundingClientRect(); if (r.width * r.height === 0) { return; } out.push('[' + d.replace(/\\s+/g, ' ').trim().slice(0, 50) + '] ' + Math.round(r.left + r.width / 2) + ',' + Math.round(r.top + r.height / 2)); }); log('controls', innerWidth + 'x' + innerHeight + ' ' + out.slice(0, 12).join(' ;; ')); }; setTimeout(reportControls, 9000); setTimeout(reportControls, 27500);"
            "setInterval(function() { Array.prototype.forEach.call(document.querySelectorAll('video'), function(v) { log('video-state', 'src=' + String(v.currentSrc || v.src || '').slice(0, 90) + ' rs=' + v.readyState + ' paused=' + v.paused + ' muted=' + v.muted + ' vol=' + v.volume + ' t=' + (v.currentTime || 0).toFixed(1) + (v.error ? ' ERR=' + v.error.code : '')); }); }, 5000);"
        "}"
        "D.log = log;"
        "window.addEventListener('error', function(e) { log('js-error', (e.message || (e.target && e.target.src) || '') + ' @' + (e.filename || '') + ':' + (e.lineno || '')); }, true);"
        "window.addEventListener('unhandledrejection', function(e) { var r = e.reason; log('rejection', r && (r.stack || r.message) || r); });"
        "var origError = console.error; console.error = function() { try { log('console.error', Array.prototype.map.call(arguments, String).join(' ')); } catch (x) {} return origError.apply(console, arguments); };"
        "var origWarn = console.warn; console.warn = function() { try { log('console.warn', Array.prototype.map.call(arguments, String).join(' ')); } catch (x) {} return origWarn.apply(console, arguments); };"
        "['loadstart','loadedmetadata','loadeddata','canplay','canplaythrough','playing','waiting','stalled','error','emptied','abort','pause','play','seeking','ended'].forEach(function(name) {"
            "document.addEventListener(name, function(e) {"
                "var t = e.target; if (!t || t.tagName !== 'VIDEO') { return; }"
                "log('video:' + name, 'src=' + String(t.currentSrc || t.src || '').slice(0, 90) + ' rs=' + t.readyState + ' ns=' + t.networkState + ' t=' + (t.currentTime || 0).toFixed(1) + (t.error ? ' ERR=' + t.error.code + ' ' + (t.error.message || '') : ''));"
            "}, true);"
        "});"
        "function interesting(u) { return !/\\.(css|png|jpe?g|gif|svg|webp|woff2?)(\\?|$)|\\/_app\\/immutable\\//i.test(u); }"
        "if (window.fetch) {"
            "var origFetch = window.fetch;"
            "window.fetch = function(input, init) {"
                "var url = String(input && input.url || input); var start = Date.now();"
                "var p = origFetch.apply(this, arguments);"
                "if (interesting(url)) {"
                    "p.then(function(r) { log('fetch', r.status + ' ' + (Date.now() - start) + 'ms ' + url.slice(0, 140)); },"
                    "function(err) { log('fetch-FAIL', (Date.now() - start) + 'ms ' + url.slice(0, 140) + ' ' + err); });"
                "}"
                "return p;"
            "};"
        "}"
        "function describe(el) { return el ? (el.tagName + (el.id ? '#' + el.id : '') + '.' + String(el.className || '').slice(0, 40)) : 'null'; }"
        "[['Element', 'requestFullscreen'], ['Element', 'webkitRequestFullscreen'], ['Element', 'webkitRequestFullScreen'], ['HTMLVideoElement', 'webkitEnterFullscreen'], ['HTMLVideoElement', 'webkitEnterFullScreen'], ['Document', 'exitFullscreen'], ['Document', 'webkitExitFullscreen'], ['Document', 'webkitCancelFullScreen']].forEach(function(pair) {"
            "var proto = window[pair[0]] && window[pair[0]].prototype; var name = pair[1];"
            "if (!proto || typeof proto[name] !== 'function') { log('fullscreen-api', pair[0] + '.' + name + ' MISSING'); return; }"
            "var original = proto[name];"
            "proto[name] = function() { log('fullscreen-call', pair[0] + '.' + name + ' on ' + describe(this)); try { var r = original.apply(this, arguments); if (r && r.then) { r.then(function() { log('fullscreen-call', name + ' resolved'); }, function(e) { log('fullscreen-call', name + ' rejected ' + e); }); } return r; } catch (e) { log('fullscreen-call', name + ' threw ' + e); throw e; } };"
        "});"
        "['fullscreenchange', 'webkitfullscreenchange', 'fullscreenerror', 'webkitfullscreenerror'].forEach(function(name) { document.addEventListener(name, function() { log('fullscreen-event', name + ' element=' + describe(document.fullscreenElement || document.webkitFullscreenElement)); }, true); });"
        "['webkitbeginfullscreen', 'webkitendfullscreen', 'webkitpresentationmodechanged'].forEach(function(name) { document.addEventListener(name, function(e) { log('fullscreen-event', name + ' on ' + describe(e.target) + ' mode=' + (e.target && e.target.webkitPresentationMode)); }, true); });"
        "var origOpen = XMLHttpRequest.prototype.open;"
        "XMLHttpRequest.prototype.open = function(method, url) { this.__bdiagURL = String(url); this.__bdiagStart = Date.now(); return origOpen.apply(this, arguments); };"
        "var origSend = XMLHttpRequest.prototype.send;"
        "XMLHttpRequest.prototype.send = function() {"
            "var xhr = this;"
            "if (interesting(xhr.__bdiagURL || '')) {"
                "xhr.addEventListener('loadend', function() { log('xhr', xhr.status + ' ' + (Date.now() - xhr.__bdiagStart) + 'ms ' + String(xhr.__bdiagURL).slice(0, 140)); });"
            "}"
            "return origSend.apply(this, arguments);"
        "};"
    "})();";
}

static NSString *BrowserMediaDiagnosticsCapabilityScript(void) {
    return @"(function(){"
        "var D = window.__bdiag || {};"
        "var out = {};"
        "out.ua = navigator.userAgent;"
        "out.webAssembly = typeof WebAssembly;"
        "try { out.wasmValidate = WebAssembly.validate(new Uint8Array([0,97,115,109,1,0,0,0])); } catch (e) { out.wasmValidate = 'ERR ' + e; }"
        "out.mediaSource = typeof MediaSource;"
        "out.managedMediaSource = typeof ManagedMediaSource;"
        "var avc = 'video/mp4; codecs=\"avc1.640028,mp4a.40.2\"';"
        "try { out.mseAvc = window.MediaSource ? MediaSource.isTypeSupported(avc) : 'n/a'; } catch (e) { out.mseAvc = 'ERR ' + e; }"
        "try { out.mmsAvc = window.ManagedMediaSource ? ManagedMediaSource.isTypeSupported(avc) : 'n/a'; } catch (e) { out.mmsAvc = 'ERR ' + e; }"
        "out.nativeHLS = document.createElement('video').canPlayType('application/vnd.apple.mpegurl');"
        "var t = performance.now(); var acc = 0; for (var i = 0; i < 5000000; i++) { acc = (acc + i * 7) % 1000003; } out.loop5M_ms = Math.round(performance.now() - t);"
        "if (!D.wasmTestStarted && window.WebAssembly) {"
            "D.wasmTestStarted = true;"
            "var start = Date.now();"
            "fetch('https://api2.wing.st/crush.wasm').then(function(r) { return r.arrayBuffer(); }).then(function(b) {"
                "var fetched = Date.now(); D.log && D.log('wasm-test', 'fetched ' + b.byteLength + ' bytes in ' + (fetched - start) + 'ms');"
                "return WebAssembly.compile(b).then(function() { D.log && D.log('wasm-test', 'compiled in ' + (Date.now() - fetched) + 'ms'); });"
            "}).catch(function(e) { D.log && D.log('wasm-test', 'FAILED ' + e); });"
        "}"
        "(function() {"
            "function probe(label, src) { var s = document.createElement('script'); var t0 = Date.now(); s.src = src;"
                "s.onload = function() { D.log && D.log('adblock-test', label + ' LOADED in ' + (Date.now() - t0) + 'ms'); };"
                "s.onerror = function() { D.log && D.log('adblock-test', label + ' BLOCKED/failed in ' + (Date.now() - t0) + 'ms'); };"
                "(document.head || document.documentElement).appendChild(s); }"
            "probe('ad script (googlesyndication)', 'https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js');"
            "probe('control script (cdnjs)', 'https://cdnjs.cloudflare.com/ajax/libs/lodash.js/4.17.21/lodash.min.js');"
            "var slot = document.createElement('div'); slot.setAttribute('data-ad-slot', '1'); slot.textContent = 'ad'; document.body.appendChild(slot);"
            "setTimeout(function() { D.log && D.log('adblock-test', 'ad container display=' + getComputedStyle(slot).display); slot.remove(); }, 500);"
        "})();"
        "out.cookiePrevious = (document.cookie.match(/__bdiag_c=([^;]*)/) || [])[1] || null;"
        "document.cookie = '__bdiag_c=' + Date.now() + '; max-age=31536000; path=/; secure; samesite=lax';"
        "try { out.localStoragePrevious = localStorage.getItem('__bdiag_ls'); localStorage.setItem('__bdiag_ls', new Date().toISOString()); out.localStorageWrite = 'ok'; } catch (e) { out.localStorageWrite = 'ERR ' + e; }"
        "try {"
            "var req = indexedDB.open('__bdiag_db', 1);"
            "req.onupgradeneeded = function() { req.result.createObjectStore('kv'); };"
            "req.onerror = function() { D.log && D.log('idb', 'open FAILED ' + req.error); };"
            "req.onsuccess = function() {"
                "var db = req.result; var tx = db.transaction('kv', 'readwrite'); var store = tx.objectStore('kv');"
                "var get = store.get('stamp');"
                "get.onsuccess = function() { D.log && D.log('idb', 'previous=' + get.result); store.put(new Date().toISOString(), 'stamp'); };"
                "tx.oncomplete = function() { D.log && D.log('idb', 'write ok'); };"
                "tx.onerror = function() { D.log && D.log('idb', 'write FAILED ' + tx.error); };"
            "};"
        "} catch (e) { out.indexedDB = 'ERR ' + e; }"
        "return JSON.stringify(out);"
    "})()";
}

static NSString *BrowserMediaDiagnosticsReportScript(void) {
    return @"(function(){"
        "var D = window.__bdiag || { events: [] };"
        "var videos = Array.prototype.map.call(document.querySelectorAll('video'), function(v) {"
            "var b = []; try { for (var i = 0; i < v.buffered.length; i++) { b.push(v.buffered.start(i).toFixed(1) + '-' + v.buffered.end(i).toFixed(1)); } } catch (e) {}"
            "return { src: String(v.currentSrc || v.src || '').slice(0, 90), rs: v.readyState, ns: v.networkState, paused: v.paused, t: +(v.currentTime || 0).toFixed(1), dur: v.duration, err: v.error ? v.error.code + ' ' + (v.error.message || '') : null, trackElements: v.querySelectorAll('track').length, textTracks: v.textTracks ? v.textTracks.length : -1, buffered: b.join(','), muted: v.muted, autoplay: v.autoplay, crossOrigin: v.crossOrigin, corsRetried: !!v.__browserCORSRetried };"
        "});"
        "var events = (D.events || []).splice(0);"
        "return JSON.stringify({ url: location.href.slice(0, 80), videos: videos, iframes: document.querySelectorAll('iframe').length, events: events });"
    "})()";
}

static NSString *BrowserMediaDiagnosticsAutoPlayScript(void) {
    return @"(function(){"
        "var D = window.__bdiag || {}; var log = D.log || function(){};"
        "var v = document.querySelector('video'); if (!v) { return 'no video'; }"
        "var r = v.getBoundingClientRect(); var el = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);"
        "log('autoplay', 'clicking ' + (el ? el.tagName + '.' + String(el.className).slice(0, 40) : 'nothing') + ' then video.play()');"
        "try { if (el) { el.click(); } } catch (e) { log('autoplay', 'click error ' + e); }"
        "try { var p = v.play(); if (p && p.then) { p.then(function() { log('autoplay', 'play() resolved'); }, function(e) { log('autoplay', 'play() rejected ' + e); }); } } catch (e) { log('autoplay', 'play() threw ' + e); }"
        "return 'ok';"
    "})()";
}

static void BrowserDiagPrintMethods(NSString *className, NSArray<NSString *> *needles) {
    Class cls = NSClassFromString(className);
    if (cls == Nil) {
        BrowserDiagPrint([NSString stringWithFormat:@"class %@ MISSING", className]);
        return;
    }
    NSMutableArray<NSString *> *found = [NSMutableArray array];
    for (int pass = 0; pass < 2; pass++) {
        Class target = pass == 0 ? cls : object_getClass(cls);
        unsigned int count = 0;
        Method *methods = class_copyMethodList(target, &count);
        for (unsigned int i = 0; i < count; i++) {
            NSString *name = NSStringFromSelector(method_getName(methods[i]));
            for (NSString *needle in needles) {
                if ([name.lowercaseString containsString:needle]) {
                    [found addObject:[(pass == 0 ? @"-" : @"+") stringByAppendingString:name]];
                    break;
                }
            }
        }
        free(methods);
    }
    [found sortUsingSelector:@selector(compare:)];
    BrowserDiagPrint([NSString stringWithFormat:@"class %@ methods: %@", className, [found componentsJoinedByString:@" "]]);
}

static void BrowserInstallMediaDiagnosticsUserScript(id configuration) {
    if (!BrowserMediaDiagnosticsEnabled() || configuration == nil) {
        return;
    }
    static dispatch_once_t probeToken;
    dispatch_once(&probeToken, ^{
        BrowserDiagPrintMethods(@"_WKWebsiteDataStoreConfiguration", @[@"directory", @"storage", @"init", @"file", @"persistent"]);
        BrowserDiagPrintMethods(@"WKWebsiteDataStore", @[@"init", @"configuration", @"datastore", @"identifier"]);
    });
    Class userScriptClass = NSClassFromString(kBrowserUserScriptClassName);
    SEL userContentControllerGetter = NSSelectorFromString(@"userContentController");
    SEL userScriptInitializer = NSSelectorFromString(@"initWithSource:injectionTime:forMainFrameOnly:");
    if (userScriptClass == Nil || ![configuration respondsToSelector:userContentControllerGetter] ||
        ![userScriptClass instancesRespondToSelector:userScriptInitializer]) {
        return;
    }
    id userContentController = ((id (*)(id, SEL))objc_msgSend)(configuration, userContentControllerGetter);
    id userScript = ((id (*)(id, SEL))objc_msgSend)((id)userScriptClass, @selector(alloc));
    userScript = ((id (*)(id, SEL, id, NSInteger, BOOL))objc_msgSend)(userScript, userScriptInitializer, BrowserMediaDiagnosticsHookScript(), 0, NO);
    if (userContentController != nil && userScript != nil) {
        ((void (*)(id, SEL, id))objc_msgSend)(userContentController, NSSelectorFromString(@"addUserScript:"), userScript);
        BrowserDiagPrint(@"diagnostics hooks installed");
    }
}

@interface BrowserWebView ()

@property (nullable, nonatomic, strong) id runtimeWebView;
@property (nullable, nonatomic, strong) NSURLRequest *lastRequest;
@property (nullable, nonatomic, copy) NSString *lastTitle;
@property (nonatomic, copy) NSString *userAgent;
@property (nonatomic) BOOL loading;
@property (nonatomic, readwrite) double estimatedProgress;
@property (nonatomic) BOOL observingProgress;
@property (nonatomic) NSTimer *diagnosticsTimer;
@property (nonatomic, weak) id userContentController;
@property (nonatomic, copy) NSString *appInitiatedURLString;
@property (nonatomic) CFTimeInterval appInitiatedTimestamp;
@property (nonatomic) NSUInteger diagnosticsTicks;

@end

@implementation BrowserWebView

- (instancetype)initWithFrame:(CGRect)frame {
    return [self initWithUserAgent:nil allowsInlineMediaPlayback:YES];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self commonInitWithUserAgent:nil allowsInlineMediaPlayback:YES];
    }
    return self;
}

- (instancetype)initWithUserAgent:(NSString *)userAgent allowsInlineMediaPlayback:(BOOL)allowsInlineMediaPlayback {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        [self commonInitWithUserAgent:userAgent allowsInlineMediaPlayback:allowsInlineMediaPlayback];
    }
    return self;
}

- (void)commonInitWithUserAgent:(NSString *)userAgent allowsInlineMediaPlayback:(BOOL)allowsInlineMediaPlayback {
    BrowserEnsureWebKitRuntimeLoaded();

    self.backgroundColor = UIColor.blackColor;
    self.userAgent = userAgent;
    self.scalesPageToFit = NO;

    Class configurationClass = NSClassFromString(kBrowserWebViewConfigurationClassName);
    Class webViewClass = NSClassFromString(kBrowserWebViewClassName);
    if (configurationClass == Nil || webViewClass == Nil) {
        return;
    }

    id configuration = ((id (*)(id, SEL))objc_msgSend)((id)configurationClass, @selector(new));
    id websiteDataStore = BrowserSharedWebsiteDataStore();
    SEL setWebsiteDataStoreSelector = NSSelectorFromString(@"setWebsiteDataStore:");
    if (websiteDataStore != nil && [configuration respondsToSelector:setWebsiteDataStoreSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(configuration, setWebsiteDataStoreSelector, websiteDataStore);
    }
    SEL allowsInlineMediaPlaybackSelector = NSSelectorFromString(@"setAllowsInlineMediaPlayback:");
    if (configuration != nil && [configuration respondsToSelector:allowsInlineMediaPlaybackSelector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(configuration, allowsInlineMediaPlaybackSelector, allowsInlineMediaPlayback);
    }
    // tvOS WebKit defaults to requiring a user gesture for every video with sound. Players load
    // their source a few seconds after the Play click and then call play(), which is no longer
    // inside the gesture, so WebKit refused it and the video stayed paused at 0:00 (only the
    // native full screen player could play it). WKAudiovisualMediaTypeNone = 0 lets pages play.
    SEL mediaTypesRequiringUserActionSelector = NSSelectorFromString(@"setMediaTypesRequiringUserActionForPlayback:");
    if (configuration != nil && [configuration respondsToSelector:mediaTypesRequiringUserActionSelector]) {
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(configuration, mediaTypesRequiringUserActionSelector, 0);
    }
    BrowserConfigurePrivateMediaPreferences(configuration);
    BrowserInstallYouTubeCaptureUserScript(configuration);
    BrowserInstallCrossOriginHLSUserScript(configuration);
    SEL userContentControllerGetter = NSSelectorFromString(@"userContentController");
    if ([configuration respondsToSelector:userContentControllerGetter]) {
        id userContentController = ((id (*)(id, SEL))objc_msgSend)(configuration, userContentControllerGetter);
        self.userContentController = userContentController;
        [[BrowserAdBlocker sharedBlocker] attachToUserContentController:userContentController];

        Class userScriptClass = NSClassFromString(kBrowserUserScriptClassName);
        SEL userScriptInitializer = NSSelectorFromString(@"initWithSource:injectionTime:forMainFrameOnly:");
        if (userScriptClass != Nil && [userScriptClass instancesRespondToSelector:userScriptInitializer]) {
            id userScript = ((id (*)(id, SEL))objc_msgSend)((id)userScriptClass, @selector(alloc));
            // All frames: players embedded from other sites go fullscreen through their parent page.
            userScript = ((id (*)(id, SEL, id, NSInteger, BOOL))objc_msgSend)(userScript, userScriptInitializer, BrowserFullscreenPolyfillScript(), 0, NO);
            ((void (*)(id, SEL, id))objc_msgSend)(userContentController, NSSelectorFromString(@"addUserScript:"), userScript);
            id bridgeScript = ((id (*)(id, SEL))objc_msgSend)((id)userScriptClass, @selector(alloc));
            bridgeScript = ((id (*)(id, SEL, id, NSInteger, BOOL))objc_msgSend)(bridgeScript, userScriptInitializer, BrowserFrameBridgeScript(), 0, NO);
            ((void (*)(id, SEL, id))objc_msgSend)(userContentController, NSSelectorFromString(@"addUserScript:"), bridgeScript);
            // Remote navigation library, ready before the first arrow press (document end, main frame).
            id navigatorScript = ((id (*)(id, SEL))objc_msgSend)((id)userScriptClass, @selector(alloc));
            navigatorScript = ((id (*)(id, SEL, id, NSInteger, BOOL))objc_msgSend)(navigatorScript, userScriptInitializer, [BrowserPageNavigator libraryScript], 1, YES);
            ((void (*)(id, SEL, id))objc_msgSend)(userContentController, NSSelectorFromString(@"addUserScript:"), navigatorScript);
            id subtitleScript = ((id (*)(id, SEL))objc_msgSend)((id)userScriptClass, @selector(alloc));
            subtitleScript = ((id (*)(id, SEL, id, NSInteger, BOOL))objc_msgSend)(subtitleScript, userScriptInitializer, BrowserSubtitleCaptureScript(), 0, YES);
            ((void (*)(id, SEL, id))objc_msgSend)(userContentController, NSSelectorFromString(@"addUserScript:"), subtitleScript);
        }
        SEL addHandlerSelector = NSSelectorFromString(@"addScriptMessageHandler:name:");
        if ([userContentController respondsToSelector:addHandlerSelector]) {
            BrowserScriptMessageProxy *proxy = [BrowserScriptMessageProxy new];
            proxy.target = self;
            ((void (*)(id, SEL, id, id))objc_msgSend)(userContentController, addHandlerSelector, proxy, kBrowserFullscreenMessageHandlerName);
        }
    }
    BrowserInstallMediaDiagnosticsUserScript(configuration);

    id webViewObject = ((id (*)(id, SEL))objc_msgSend)((id)webViewClass, @selector(alloc));
    SEL initializer = NSSelectorFromString(@"initWithFrame:configuration:");
    webViewObject = ((id (*)(id, SEL, CGRect, id))objc_msgSend)(webViewObject, initializer, self.bounds, configuration);
    if (webViewObject == nil) {
        return;
    }

    self.runtimeWebView = webViewObject;
    UIView *runtimeView = (UIView *)webViewObject;
    runtimeView.frame = self.bounds;
    runtimeView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    runtimeView.backgroundColor = UIColor.blackColor;

    SEL navigationDelegateSelector = NSSelectorFromString(@"setNavigationDelegate:");
    if ([webViewObject respondsToSelector:navigationDelegateSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(webViewObject, navigationDelegateSelector, self);
    }

    SEL UIDelegateSelector = NSSelectorFromString(@"setUIDelegate:");
    if ([webViewObject respondsToSelector:UIDelegateSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(webViewObject, UIDelegateSelector, self);
    }

    [self addSubview:runtimeView];
    [self setUserAgent:userAgent];

    for (NSString *keyPath in @[@"estimatedProgress", @"loading"]) {
        [webViewObject addObserver:self forKeyPath:keyPath options:NSKeyValueObservingOptionNew context:BrowserWebViewProgressObservationContext];
    }
    self.observingProgress = YES;
}

- (void)handleScriptMessage:(id)message {
    NSString *name = [message respondsToSelector:@selector(name)] ? [message valueForKey:@"name"] : nil;
    id body = [message respondsToSelector:NSSelectorFromString(@"body")] ? [message valueForKey:@"body"] : nil;
    if ([name isEqualToString:kBrowserFullscreenMessageHandlerName] && [body isKindOfClass:[NSDictionary class]]) {
        BOOL active = [body[@"active"] boolValue];
        if ([self.delegate respondsToSelector:@selector(webView:didChangePageFullscreen:)]) {
            [self.delegate webView:self didChangePageFullscreen:active];
        }
    }
}

- (void)dealloc {
    SEL removeHandlerSelector = NSSelectorFromString(@"removeScriptMessageHandlerForName:");
    if ([self.userContentController respondsToSelector:removeHandlerSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(self.userContentController, removeHandlerSelector, kBrowserFullscreenMessageHandlerName);
    }
    if (self.observingProgress) {
        for (NSString *keyPath in @[@"estimatedProgress", @"loading"]) {
            [self.runtimeWebView removeObserver:self forKeyPath:keyPath context:BrowserWebViewProgressObservationContext];
        }
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey, id> *)change context:(void *)context {
    if (context != BrowserWebViewProgressObservationContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self reportLoadProgress];
        });
        return;
    }
    [self reportLoadProgress];
}

- (void)reportLoadProgress {
    id webView = self.runtimeWebView;
    if (webView == nil) {
        return;
    }
    double progress = [[webView valueForKey:@"estimatedProgress"] doubleValue];
    BOOL loading = [[webView valueForKey:@"loading"] boolValue];
    self.estimatedProgress = progress;
    self.loading = loading;
    if ([self.delegate respondsToSelector:@selector(webView:didChangeLoadProgress:loading:)]) {
        [self.delegate webView:self didChangeLoadProgress:progress loading:loading];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    ((UIView *)self.runtimeWebView).frame = self.bounds;
    [self applyPageScalingIfNeeded];
}

- (void)setUserInteractionEnabled:(BOOL)userInteractionEnabled {
    [super setUserInteractionEnabled:userInteractionEnabled];

    UIView *runtimeView = (UIView *)self.runtimeWebView;
    runtimeView.userInteractionEnabled = userInteractionEnabled;

    UIScrollView *scrollView = [self scrollView];
    scrollView.userInteractionEnabled = userInteractionEnabled;
}

- (UIScrollView *)scrollView {
    SEL selector = NSSelectorFromString(@"scrollView");
    if (self.runtimeWebView == nil || ![self.runtimeWebView respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector);
}

- (NSURL *)currentURL {
    SEL selector = NSSelectorFromString(@"URL");
    if (self.runtimeWebView == nil || ![self.runtimeWebView respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector);
}

- (NSURLRequest *)request {
    NSURL *currentURL = [self currentURL];
    if (currentURL != nil) {
        return [NSURLRequest requestWithURL:currentURL];
    }
    return self.lastRequest;
}

- (NSString *)title {
    SEL selector = NSSelectorFromString(@"title");
    if (self.runtimeWebView == nil || ![self.runtimeWebView respondsToSelector:selector]) {
        return self.lastTitle;
    }
    NSString *title = ((id (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector);
    return title ?: self.lastTitle;
}

- (BOOL)canGoBack {
    SEL selector = NSSelectorFromString(@"canGoBack");
    return self.runtimeWebView != nil && [self.runtimeWebView respondsToSelector:selector] ? ((BOOL (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector) : NO;
}

- (BOOL)canGoForward {
    SEL selector = NSSelectorFromString(@"canGoForward");
    return self.runtimeWebView != nil && [self.runtimeWebView respondsToSelector:selector] ? ((BOOL (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector) : NO;
}

- (void)loadRequest:(NSURLRequest *)request {
    self.appInitiatedURLString = request.URL.absoluteString;
    self.appInitiatedTimestamp = CACurrentMediaTime();
    if (request == nil || self.runtimeWebView == nil) {
        return;
    }
    self.lastRequest = request;
    SEL selector = NSSelectorFromString(@"loadRequest:");
    if ([self.runtimeWebView respondsToSelector:selector]) {
        ((id (*)(id, SEL, id))objc_msgSend)(self.runtimeWebView, selector, request);
    }
}

- (void)reload {
    SEL selector = NSSelectorFromString(@"reload");
    if (self.runtimeWebView != nil && [self.runtimeWebView respondsToSelector:selector]) {
        ((void (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector);
    }
}

- (void)goBack {
    SEL selector = NSSelectorFromString(@"goBack");
    if (self.runtimeWebView != nil && [self.runtimeWebView respondsToSelector:selector]) {
        ((id (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector);
    }
}

- (void)goForward {
    SEL selector = NSSelectorFromString(@"goForward");
    if (self.runtimeWebView != nil && [self.runtimeWebView respondsToSelector:selector]) {
        ((id (*)(id, SEL))objc_msgSend)(self.runtimeWebView, selector);
    }
}

- (NSString *)stringByEvaluatingJavaScriptFromString:(NSString *)script {
    if (script.length == 0 || self.runtimeWebView == nil) {
        return nil;
    }

    SEL selector = NSSelectorFromString(@"evaluateJavaScript:completionHandler:");
    if (![self.runtimeWebView respondsToSelector:selector]) {
        return nil;
    }

    __block id evaluationResult = nil;
    __block NSError *evaluationError = nil;
    __block BOOL finished = NO;
    ((void (*)(id, SEL, id, id))objc_msgSend)(self.runtimeWebView, selector, script, ^(id result, NSError *error) {
        evaluationResult = result;
        evaluationError = error;
        finished = YES;
    });
    BrowserPumpRunLoopUntil(&finished);

    if (evaluationError != nil) {
        return nil;
    }
    return BrowserStringFromJavaScriptResult(evaluationResult);
}

- (void)evaluateJavaScript:(NSString *)script completionHandler:(void (^)(id, NSError *))completionHandler {
    SEL selector = NSSelectorFromString(@"evaluateJavaScript:completionHandler:");
    if (script.length == 0 || ![self.runtimeWebView respondsToSelector:selector]) {
        if (completionHandler != nil) {
            completionHandler(nil, nil);
        }
        return;
    }
    ((void (*)(id, SEL, id, id))objc_msgSend)(self.runtimeWebView, selector, script, ^(id result, NSError *error) {
        if (completionHandler != nil) {
            completionHandler(result, error);
        }
    });
}

- (void)pauseAllMediaPlayback {
    if (self.runtimeWebView == nil) {
        return;
    }

    // Prefer WebKit's internal media pause APIs when available.
    SEL pauseWithCompletionHandlerSelector = NSSelectorFromString(@"pauseAllMediaPlaybackWithCompletionHandler:");
    if ([self.runtimeWebView respondsToSelector:pauseWithCompletionHandlerSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(self.runtimeWebView, pauseWithCompletionHandlerSelector, nil);
    } else {
        SEL pauseSelector = NSSelectorFromString(@"pauseAllMediaPlayback:");
        if ([self.runtimeWebView respondsToSelector:pauseSelector]) {
            ((void (*)(id, SEL, id))objc_msgSend)(self.runtimeWebView, pauseSelector, nil);
        } else {
            SEL privatePauseSelector = NSSelectorFromString(@"_pauseAllMediaPlayback");
            if ([self.runtimeWebView respondsToSelector:privatePauseSelector]) {
                ((void (*)(id, SEL))objc_msgSend)(self.runtimeWebView, privatePauseSelector);
            }
        }
    }

    // JS fallback for page media elements and common iframe-based players.
    NSString *pauseScript =
        @"(function(){"
            "function safe(fn){ try { fn(); } catch (error) {} }"
            "var media = document.querySelectorAll('video,audio');"
            "for (var i = 0; i < media.length; i++) {"
                "var element = media[i];"
                "safe(function(){ element.pause(); });"
                "safe(function(){ element.autoplay = false; });"
                "safe(function(){ element.removeAttribute('autoplay'); });"
            "}"
            "var iframePlayers = document.querySelectorAll('iframe');"
            "for (var j = 0; j < iframePlayers.length; j++) {"
                "var frame = iframePlayers[j];"
                "var src = String(frame.src || '').toLowerCase();"
                "if (!src) { continue; }"
                "safe(function(){"
                    "if (src.indexOf('youtube.com') !== -1 || src.indexOf('youtube-nocookie.com') !== -1) {"
                        "frame.contentWindow.postMessage(JSON.stringify({event:'command',func:'pauseVideo',args:''}), '*');"
                    "}"
                "});"
                "safe(function(){"
                    "if (src.indexOf('vimeo.com') !== -1) {"
                        "frame.contentWindow.postMessage(JSON.stringify({method:'pause'}), '*');"
                    "}"
                "});"
            "}"
        "})();";
    [self stringByEvaluatingJavaScriptFromString:pauseScript];
}

- (NSString *)runtimeMediaPreferenceReport {
    if (self.runtimeWebView == nil) {
        return @"Runtime web view unavailable.";
    }

    NSArray<NSDictionary<NSString *, NSString *> *> *objectSelectors = @[
        @{@"label": @"WKWebView", @"selector": @""},
        @{@"label": @"Configuration", @"selector": @"configuration"},
        @{@"label": @"Configuration._preferences", @"selector": @"configuration._preferences"},
        @{@"label": @"Configuration.preferences", @"selector": @"configuration.preferences"},
        @{@"label": @"Configuration.defaultWebpagePreferences", @"selector": @"configuration.defaultWebpagePreferences"},
        @{@"label": @"Configuration.websiteDataStore", @"selector": @"configuration.websiteDataStore"},
        @{@"label": @"WKWebView._configuration", @"selector": @"_configuration"},
        @{@"label": @"WKWebView._page", @"selector": @"_page"},
    ];

    NSMutableDictionary<NSValue *, NSString *> *seenObjects = [NSMutableDictionary dictionary];
    NSMutableString *report = [NSMutableString string];

    for (NSDictionary<NSString *, NSString *> *entry in objectSelectors) {
        NSString *label = entry[@"label"] ?: @"Object";
        NSString *selectorPath = entry[@"selector"] ?: @"";
        id currentObject = self.runtimeWebView;

        if (selectorPath.length > 0) {
            NSArray<NSString *> *components = [selectorPath componentsSeparatedByString:@"."];
            for (NSString *component in components) {
                currentObject = BrowserObjectResultForGetter(currentObject, component);
                if (currentObject == nil) {
                    break;
                }
            }
        }

        if (currentObject == nil) {
            [report appendFormat:@"[%@] unavailable\n\n", label];
            continue;
        }

        NSValue *objectKey = [NSValue valueWithNonretainedObject:currentObject];
        NSString *previousLabel = seenObjects[objectKey];
        if (previousLabel != nil) {
            [report appendFormat:@"[%@] same object as %@ (%@)\n\n", label, previousLabel, NSStringFromClass([currentObject class])];
            continue;
        }
        seenObjects[objectKey] = label;

        NSArray<NSString *> *selectorNames = BrowserFilteredSelectorNamesForClass([currentObject class]);
        NSMutableArray<NSString *> *booleanLines = [NSMutableArray array];
        for (NSString *selectorName in selectorNames) {
            NSString *getterName = nil;
            if ([selectorName hasPrefix:@"set"] && [selectorName hasSuffix:@":"]) {
                getterName = BrowserGetterNameFromSetterName(selectorName);
            } else {
                getterName = selectorName;
            }

            NSString *valueDescription = BrowserBooleanValueDescriptionForObjectAndSelector(currentObject, getterName);
            if (valueDescription != nil) {
                [booleanLines addObject:[NSString stringWithFormat:@"%@ = %@", getterName, valueDescription]];
            }
        }

        [report appendFormat:@"[%@] %@\n", label, NSStringFromClass([currentObject class])];
        if (booleanLines.count > 0) {
            [report appendString:@"Boolean getters:\n"];
            for (NSString *line in booleanLines) {
                [report appendFormat:@"- %@\n", line];
            }
        } else {
            [report appendString:@"Boolean getters:\n- none resolved\n"];
        }

        [report appendString:@"Matching selectors:\n"];
        if (selectorNames.count == 0) {
            [report appendString:@"- none\n\n"];
            continue;
        }

        for (NSString *selectorName in selectorNames) {
            [report appendFormat:@"- %@\n", selectorName];
        }

        if ([label isEqualToString:@"Configuration.preferences"]) {
            NSArray<NSDictionary<NSString *, NSString *> *> *featureEntries = BrowserFeatureEntriesForPreferences(currentObject);
            [report appendString:@"Feature entries:\n"];
            if (featureEntries.count == 0) {
                [report appendString:@"- none\n"];
            } else {
                for (NSDictionary<NSString *, NSString *> *featureEntry in featureEntries) {
                    NSString *featureSource = featureEntry[@"source"] ?: @"features";
                    NSString *featureName = featureEntry[@"name"] ?: @"Unknown";
                    NSString *featureEnabled = featureEntry[@"enabled"] ?: @"unknown";
                    NSString *featureKey = featureEntry[@"key"];
                    if (featureKey.length > 0) {
                        [report appendFormat:@"- [%@] %@ (%@) = %@\n", featureSource, featureName, featureKey, featureEnabled];
                    } else {
                        [report appendFormat:@"- [%@] %@ = %@\n", featureSource, featureName, featureEnabled];
                    }
                }
            }
        }
        [report appendString:@"\n"];
    }

    return BrowserPreviewString(report, 24000);
}

- (void)installYouTubeRequestCaptureHook {
    [self stringByEvaluatingJavaScriptFromString:BrowserYouTubeRequestCaptureScript()];
}

- (void)setUserAgent:(NSString *)userAgent {
    _userAgent = [userAgent copy];
    SEL selector = NSSelectorFromString(@"setCustomUserAgent:");
    if (self.runtimeWebView != nil && [self.runtimeWebView respondsToSelector:selector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(self.runtimeWebView, selector, _userAgent);
    }
}

- (void)setScalesPageToFit:(BOOL)scalesPageToFit {
    _scalesPageToFit = scalesPageToFit;
    [self applyPageScalingIfNeeded];
}

- (void)applyPageScalingIfNeeded {
    if (self.runtimeWebView == nil) {
        return;
    }

    UIScrollView *scrollView = [self scrollView];
    if (scrollView == nil || CGRectIsEmpty(scrollView.bounds)) {
        return;
    }

    CGFloat zoomValue = 1.0;
    if (self.scalesPageToFit) {
        CGFloat contentWidth = scrollView.contentSize.width;
        CGFloat boundsWidth = CGRectGetWidth(scrollView.bounds);
        if (contentWidth > 1.0 && boundsWidth > 1.0) {
            zoomValue = MIN(1.0, MAX(0.25, boundsWidth / contentWidth));
        }
    }

    SEL pageZoomSelector = NSSelectorFromString(@"setPageZoom:");
    if ([self.runtimeWebView respondsToSelector:pageZoomSelector]) {
        ((void (*)(id, SEL, double))objc_msgSend)(self.runtimeWebView, pageZoomSelector, zoomValue);
        return;
    }

    NSString *script = zoomValue == 1.0
        ? @"document.documentElement.style.zoom=''; document.body.style.zoom='';"
        : [NSString stringWithFormat:@"document.documentElement.style.zoom='%0.4f'; document.body.style.zoom='%0.4f';", zoomValue, zoomValue];
    [self stringByEvaluatingJavaScriptFromString:script];
}

- (void)webView:(id)webView didStartProvisionalNavigation:(id)navigation {
    self.loading = YES;
    if ([self.delegate respondsToSelector:@selector(webViewDidStartLoad:)]) {
        [self.delegate webViewDidStartLoad:self];
    }
}

- (void)evaluateDiagnosticsScript:(NSString *)script label:(NSString *)label {
    SEL selector = NSSelectorFromString(@"evaluateJavaScript:completionHandler:");
    if (![self.runtimeWebView respondsToSelector:selector]) {
        return;
    }
    // Asynchronous on purpose: no run-loop pumping.
    ((void (*)(id, SEL, id, id))objc_msgSend)(self.runtimeWebView, selector, script, ^(id result, NSError *error) {
        if (error != nil) {
            BrowserDiagPrint([NSString stringWithFormat:@"%@ ERROR %@", label, error.localizedDescription]);
        } else if (result != nil && result != [NSNull null]) {
            BrowserDiagPrint([NSString stringWithFormat:@"%@ %@", label, result]);
        }
    });
}

- (void)startMediaDiagnosticsIfNeeded {
    if (!BrowserMediaDiagnosticsEnabled() || self.window == nil) {
        return;
    }
    [self.diagnosticsTimer invalidate];
    self.diagnosticsTicks = 0;
    BrowserDiagPrint([NSString stringWithFormat:@"page finished: %@", self.request.URL.absoluteString]);
    [self evaluateDiagnosticsScript:BrowserMediaDiagnosticsCapabilityScript() label:@"capabilities"];
    __weak typeof(self) weakSelf = self;
    self.diagnosticsTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:YES block:^(NSTimer *timer) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf.diagnosticsTicks >= 60) {
            [timer invalidate];
            return;
        }
        strongSelf.diagnosticsTicks += 1;
        if (strongSelf.diagnosticsTicks == 3 && [[NSUserDefaults standardUserDefaults] boolForKey:@"BrowserMediaDiagnosticsAutoPlay"]) {
            [strongSelf evaluateDiagnosticsScript:BrowserMediaDiagnosticsAutoPlayScript() label:@"autoplay"];
        }
        [strongSelf evaluateDiagnosticsScript:BrowserMediaDiagnosticsReportScript()
                                        label:[NSString stringWithFormat:@"report t+%lus", (unsigned long)(strongSelf.diagnosticsTicks * 3)]];
    }];
}

- (BOOL)isAppInitiatedRequest:(NSURLRequest *)request {
    // The app's own load, or a server redirect right after it.
    if (request.URL == nil || self.appInitiatedURLString.length == 0) {
        return NO;
    }
    return [request.URL.absoluteString isEqualToString:self.appInitiatedURLString] ||
        (CACurrentMediaTime() - self.appInitiatedTimestamp) < 3.0;
}

/// WebKit (private): a content rule list acted on a load. Logged in diagnostics mode so sites the
/// ad blocker breaks can be traced to the exact request.
- (void)_webView:(id)webView contentRuleListWithIdentifier:(NSString *)identifier performedAction:(id)action forURL:(NSURL *)url {
    if (BrowserMediaDiagnosticsEnabled()) {
        BOOL blocked = [action respondsToSelector:NSSelectorFromString(@"blockedLoad")] && ((BOOL (*)(id, SEL))objc_msgSend)(action, NSSelectorFromString(@"blockedLoad"));
        BrowserDiagPrint([NSString stringWithFormat:@"adblock %@ %@", blocked ? @"BLOCKED" : @"css-hide", url.absoluteString.length > 200 ? [url.absoluteString substringToIndex:200] : url.absoluteString]);
    }
}

- (void)webView:(id)webView didFinishNavigation:(id)navigation {
    [self startMediaDiagnosticsIfNeeded];
    if ([BrowserAdBlocker sharedBlocker].enabled) {
        [self evaluateJavaScript:[BrowserAdBlocker overlayAdSweeperScript] completionHandler:nil];
    }
    self.loading = NO;
    self.lastTitle = [self title];
    self.lastRequest = [self request];
    [self installYouTubeRequestCaptureHook];
    [self applyPageScalingIfNeeded];
    if ([self.delegate respondsToSelector:@selector(webViewDidFinishLoad:)]) {
        [self.delegate webViewDidFinishLoad:self];
    }
}

- (void)webView:(id)webView didFailNavigation:(id)navigation withError:(NSError *)error {
    self.loading = NO;
    if ([self.delegate respondsToSelector:@selector(webView:didFailLoadWithError:)]) {
        [self.delegate webView:self didFailLoadWithError:error];
    }
}

- (void)webView:(id)webView didFailProvisionalNavigation:(id)navigation withError:(NSError *)error {
    self.loading = NO;
    if ([self.delegate respondsToSelector:@selector(webView:didFailLoadWithError:)]) {
        [self.delegate webView:self didFailLoadWithError:error];
    }
}

- (void)webViewWebContentProcessDidTerminate:(id)webView {
    self.loading = NO;
    self.estimatedProgress = 0.0;
    if ([self.delegate respondsToSelector:@selector(webView:didChangeLoadProgress:loading:)]) {
        [self.delegate webView:self didChangeLoadProgress:0.0 loading:NO];
    }
    if ([self.delegate respondsToSelector:@selector(webViewContentProcessDidTerminate:)]) {
        [self.delegate webViewContentProcessDidTerminate:self];
    }
}

- (NSURLRequest *)requestFromNavigationAction:(id)navigationAction {
    if (navigationAction == nil) {
        return nil;
    }
    SEL requestSelector = NSSelectorFromString(@"request");
    if (![navigationAction respondsToSelector:requestSelector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(navigationAction, requestSelector);
}

- (NSInteger)navigationTypeFromNavigationAction:(id)navigationAction {
    if (navigationAction == nil) {
        return 0;
    }
    SEL navigationTypeSelector = NSSelectorFromString(@"navigationType");
    if (![navigationAction respondsToSelector:navigationTypeSelector]) {
        return 0;
    }
    return ((NSInteger (*)(id, SEL))objc_msgSend)(navigationAction, navigationTypeSelector);
}

- (void)webView:(id)webView decidePolicyForNavigationAction:(id)navigationAction decisionHandler:(void (^)(NSInteger policy))decisionHandler {
    NSURLRequest *request = [self requestFromNavigationAction:navigationAction];
    NSInteger navigationType = [self navigationTypeFromNavigationAction:navigationAction];
    BOOL isMainFrameRequest = YES;

    SEL targetFrameSelector = NSSelectorFromString(@"targetFrame");
    if ([navigationAction respondsToSelector:targetFrameSelector]) {
        id targetFrame = ((id (*)(id, SEL))objc_msgSend)(navigationAction, targetFrameSelector);
        SEL mainFrameSelector = NSSelectorFromString(@"isMainFrame");
        if (targetFrame != nil && [targetFrame respondsToSelector:mainFrameSelector]) {
            isMainFrameRequest = ((BOOL (*)(id, SEL))objc_msgSend)(targetFrame, mainFrameSelector);
        }
    }

    BOOL shouldAllow = YES;
    if ([self.delegate respondsToSelector:@selector(webView:shouldStartLoadWithRequest:navigationType:)]) {
        shouldAllow = [self.delegate webView:self shouldStartLoadWithRequest:request navigationType:navigationType];
    }

    if (shouldAllow && isMainFrameRequest && request != nil) {
        self.lastRequest = request;
    }

    if (decisionHandler != nil) {
        decisionHandler(shouldAllow ? 1 : 0);
    }
}

- (id)webView:(id)webView
createWebViewWithConfiguration:(id)configuration
forNavigationAction:(id)navigationAction
windowFeatures:(id)windowFeatures {
    (void)webView;
    (void)configuration;
    (void)windowFeatures;

    NSURLRequest *request = [self requestFromNavigationAction:navigationAction];
    NSInteger navigationType = [self navigationTypeFromNavigationAction:navigationAction];

    BOOL delegateHandlesNewTabRequests = [self.delegate respondsToSelector:@selector(webView:shouldCreateNewTabWithRequest:navigationType:)];
    BOOL handledInTab = NO;
    if (delegateHandlesNewTabRequests) {
        handledInTab = [self.delegate webView:self shouldCreateNewTabWithRequest:request navigationType:navigationType];
    }

    if (!delegateHandlesNewTabRequests && !handledInTab && request != nil) {
        BOOL shouldAllow = YES;
        if ([self.delegate respondsToSelector:@selector(webView:shouldStartLoadWithRequest:navigationType:)]) {
            shouldAllow = [self.delegate webView:self shouldStartLoadWithRequest:request navigationType:navigationType];
        }
        if (shouldAllow) {
            [self loadRequest:request];
        }
    }

    return nil;
}

+ (NSString *)frameBridgeToken {
    return BrowserFrameBridgeTokenValue();
}

+ (id)defaultWebsiteDataStore {
    // The store every web view uses, so cookie save/restore and "clear data" act on it.
    return BrowserSharedWebsiteDataStore();
}

+ (id)defaultCookieStore {
    id dataStore = [self defaultWebsiteDataStore];
    SEL selector = NSSelectorFromString(@"httpCookieStore");
    if (dataStore == nil || ![dataStore respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(dataStore, selector);
}

/// Returns nil if the cookie store did not answer in time.
+ (nullable NSArray<NSHTTPCookie *> *)fetchAllCookies {
    id cookieStore = [self defaultCookieStore];
    SEL selector = NSSelectorFromString(@"getAllCookies:");
    if (cookieStore == nil || ![cookieStore respondsToSelector:selector]) {
        return NSHTTPCookieStorage.sharedHTTPCookieStorage.cookies ?: @[];
    }

    __block NSArray<NSHTTPCookie *> *cookies = nil;
    __block BOOL finished = NO;
    ((void (*)(id, SEL, id))objc_msgSend)(cookieStore, selector, ^(NSArray<NSHTTPCookie *> *fetchedCookies) {
        cookies = fetchedCookies;
        finished = YES;
    });
    BrowserPumpRunLoopUntilWithTimeout(&finished, 10.0);
    return finished ? (cookies ?: @[]) : nil;
}

+ (NSArray<NSHTTPCookie *> *)allCookies {
    return [self fetchAllCookies] ?: @[];
}

+ (NSData *)cookieDataRepresentation {
    NSArray<NSHTTPCookie *> *cookies = [self fetchAllCookies];
    if (cookies == nil) {
        // Don't overwrite the saved cookies with an empty list after a timeout.
        return nil;
    }
    NSError *error = nil;
    NSData *cookieData = [NSKeyedArchiver archivedDataWithRootObject:cookies requiringSecureCoding:NO error:&error];
    return error == nil ? cookieData : nil;
}

+ (void)restoreCookiesFromData:(NSData *)cookieData {
    if (cookieData.length == 0) {
        return;
    }

    NSError *error = nil;
    NSSet *allowedClasses = [NSSet setWithObjects:[NSArray class], [NSHTTPCookie class], nil];
    NSArray<NSHTTPCookie *> *cookies = [NSKeyedUnarchiver unarchivedObjectOfClasses:allowedClasses fromData:cookieData error:&error];
    if (![cookies isKindOfClass:[NSArray class]]) {
        return;
    }

    id cookieStore = [self defaultCookieStore];
    SEL selector = NSSelectorFromString(@"setCookie:completionHandler:");
    if (cookieStore == nil || ![cookieStore respondsToSelector:selector]) {
        for (NSHTTPCookie *cookie in cookies) {
            [NSHTTPCookieStorage.sharedHTTPCookieStorage setCookie:cookie];
        }
        return;
    }

    __block NSInteger remainingCount = cookies.count;
    __block BOOL finished = cookies.count == 0;
    for (NSHTTPCookie *cookie in cookies) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(cookieStore, selector, cookie, ^{
            remainingCount -= 1;
            finished = remainingCount == 0;
        });
    }
    BrowserPumpRunLoopUntilWithTimeout(&finished, 10.0);
}

+ (NSSet<NSString *> *)allWebsiteDataTypes {
    Class dataStoreClass = NSClassFromString(kBrowserWebsiteDataStoreClassName);
    SEL selector = NSSelectorFromString(@"allWebsiteDataTypes");
    if (dataStoreClass == Nil || ![dataStoreClass respondsToSelector:selector]) {
        return [NSSet set];
    }
    return ((id (*)(id, SEL))objc_msgSend)((id)dataStoreClass, selector);
}

+ (void)removeWebsiteDataTypes:(NSSet<NSString *> *)websiteDataTypes completion:(void (^)(void))completion {
    id dataStore = [self defaultWebsiteDataStore];
    SEL selector = NSSelectorFromString(@"removeDataOfTypes:modifiedSince:completionHandler:");
    if (dataStore == nil || ![dataStore respondsToSelector:selector]) {
        if (completion != nil) {
            completion();
        }
        return;
    }

    NSDate *beginningOfTime = [NSDate dateWithTimeIntervalSince1970:0];
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(dataStore, selector, websiteDataTypes, beginningOfTime, ^{
        if (completion != nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion();
            });
        }
    });
}

+ (void)clearCachedDataWithCompletion:(void (^)(void))completion {
    [[NSURLCache sharedURLCache] removeAllCachedResponses];

    NSMutableSet<NSString *> *websiteDataTypes = [[self allWebsiteDataTypes] mutableCopy];
    for (NSString *dataType in websiteDataTypes.allObjects) {
        if ([dataType.lowercaseString containsString:@"cookie"]) {
            [websiteDataTypes removeObject:dataType];
        }
    }

    [self removeWebsiteDataTypes:websiteDataTypes completion:completion];
}

+ (void)clearCookiesWithCompletion:(void (^)(void))completion {
    id cookieStore = [self defaultCookieStore];
    SEL getAllCookiesSelector = NSSelectorFromString(@"getAllCookies:");
    SEL deleteCookieSelector = NSSelectorFromString(@"deleteCookie:completionHandler:");
    if (cookieStore == nil || ![cookieStore respondsToSelector:getAllCookiesSelector] || ![cookieStore respondsToSelector:deleteCookieSelector]) {
        NSHTTPCookieStorage *storage = NSHTTPCookieStorage.sharedHTTPCookieStorage;
        for (NSHTTPCookie *cookie in storage.cookies) {
            [storage deleteCookie:cookie];
        }
        if (completion != nil) {
            completion();
        }
        return;
    }

    ((void (*)(id, SEL, id))objc_msgSend)(cookieStore, getAllCookiesSelector, ^(NSArray<NSHTTPCookie *> *cookies) {
        if (cookies.count == 0) {
            if (completion != nil) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion();
                });
            }
            return;
        }

        __block NSInteger remainingCount = cookies.count;
        for (NSHTTPCookie *cookie in cookies) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(cookieStore, deleteCookieSelector, cookie, ^{
                remainingCount -= 1;
                if (remainingCount == 0 && completion != nil) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        completion();
                    });
                }
            });
        }
    });
}

+ (void)resetWebsiteDataWithCompletion:(void (^)(void))completion {
    [[NSURLCache sharedURLCache] removeAllCachedResponses];
    [self removeWebsiteDataTypes:[self allWebsiteDataTypes] completion:completion];
}

@end
