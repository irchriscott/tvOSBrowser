#import "BrowserPageNavigator.h"

#import "BrowserWebView.h"

/// Installs window.__bnav once per page. Kept free of ES2015+ syntax that older
/// tvOS WebKit builds might not parse.
static NSString *BrowserPageNavigatorLibrary(void) {
    return @"(function(){"
        "if (window.__bnav) { return; }"
        "var N = window.__bnav = { current: null, ring: null, lastRect: null, focused: null, siteStyled: false };"
        "var SELECTOR = \"a[href], button, input:not([type=hidden]), select, textarea, summary, video, [role=button], [role=link], [role=tab], [role=menuitem], [role=option], [role=checkbox], [role=switch], [onclick], [tabindex]:not([tabindex='-1']), [contenteditable=''], [contenteditable='true']\";"
        "function usable(el, r) {"
            "if (!r || r.width < 6 || r.height < 6) { return false; }"
            // Skip page-section-sized wrappers (a ring around the whole screen is useless); videos may be large.
            "if (el.tagName !== 'VIDEO' && r.width * r.height > innerWidth * innerHeight * 0.6) { return false; }"
            "if (el.disabled || el.getAttribute('aria-hidden') === 'true') { return false; }"
            "var cs = getComputedStyle(el);"
            "if (cs.visibility === 'hidden' || cs.display === 'none' || parseFloat(cs.opacity) < 0.05 || cs.pointerEvents === 'none') { return false; }"
            "return true;"
        "}"
        "function info(el) {"
            "var r = el.getBoundingClientRect();"
            "return { el: el, l: r.left, t: r.top, r: r.right, b: r.bottom, w: r.width, h: r.height, cx: (r.left + r.right) / 2, cy: (r.top + r.bottom) / 2, rect: r };"
        "}"
        "function inBand(c) { return c.b > -innerHeight * 0.5 && c.t < innerHeight * 1.5 && c.r > -innerWidth * 0.5 && c.l < innerWidth * 1.5; }"
        "function collect() {"
            "var out = []; var seen = [];"
            "var nodes = document.querySelectorAll(SELECTOR);"
            "for (var i = 0; i < nodes.length; i++) {"
                "var el = nodes[i]; var c = info(el);"
                "if (!inBand(c) || !usable(el, c.rect)) { continue; }"
                "out.push(c); seen.push(el);"
            "}"
            // Clickable cards that are plain elements with cursor:pointer: sample a grid of points.
            "var cols = 14, rows = 9;"
            "for (var y = 0; y < rows; y++) {"
                "for (var x = 0; x < cols; x++) {"
                    "var hit = document.elementFromPoint((x + 0.5) * innerWidth / cols, (y + 0.5) * innerHeight / rows);"
                    "var node = hit; var depth = 0; var clickable = null;"
                    "while (node && node !== document.body && depth < 6) {"
                        "if (seen.indexOf(node) !== -1) { clickable = null; break; }"
                        "if (!clickable && getComputedStyle(node).cursor === 'pointer') { clickable = node; }"
                        "node = node.parentElement; depth++;"
                    "}"
                    "if (!clickable || seen.indexOf(clickable) !== -1) { continue; }"
                    "var nested = false;"
                    "for (var k = 0; k < seen.length; k++) { if (clickable.contains(seen[k]) || seen[k].contains(clickable)) { nested = true; break; } }"
                    "if (nested) { continue; }"
                    "var cc = info(clickable);"
                    // Sampled (cursor:pointer) areas must be card-sized, not whole page sections.
                    "if (!usable(clickable, cc.rect) || cc.w * cc.h > innerWidth * innerHeight * 0.6) { continue; }"
                    "out.push(cc); seen.push(clickable);"
                "}"
            "}"
            "return out;"
        "}"
        "function sameRow(c, cur) {"
            "var overlap = Math.min(c.b, cur.b) - Math.max(c.t, cur.t);"
            "return overlap > Math.min(c.h, cur.h) * 0.3 || (c.cy >= cur.t && c.cy <= cur.b);"
        "}"
        // Left/right stay on the same row, like the tvOS focus engine; up/down may move anywhere below/above.
        "function qualifies(dir, c, cur) {"
            "if (dir === 'down') { return c.cy > cur.cy + 2 && c.t > cur.t + 2; }"
            "if (dir === 'up') { return c.cy < cur.cy - 2 && c.b < cur.b - 2; }"
            "if (dir === 'right') { return c.cx > cur.cx + 2 && c.l > cur.l + 2 && sameRow(c, cur); }"
            "return c.cx < cur.cx - 2 && c.r < cur.r - 2 && sameRow(c, cur);"
        "}"
        "function score(dir, c, cur) {"
            "var primary, gap, offset;"
            "if (dir === 'down' || dir === 'up') {"
                "primary = dir === 'down' ? Math.max(0, c.t - cur.b) : Math.max(0, cur.t - c.b);"
                "gap = Math.max(0, Math.max(c.l, cur.l) - Math.min(c.r, cur.r));"
                "offset = Math.abs(c.cx - cur.cx);"
            "} else {"
                "primary = dir === 'right' ? Math.max(0, c.l - cur.r) : Math.max(0, cur.l - c.r);"
                "gap = Math.max(0, Math.max(c.t, cur.t) - Math.min(c.b, cur.b));"
                "offset = Math.abs(c.cy - cur.cy);"
            "}"
            "return primary + gap * 3 + offset * 0.15;"
        "}"
        "function ensureRing() {"
            "if (N.ring && N.ring.parentNode) { return N.ring; }"
            "var ring = document.createElement('div');"
            "ring.setAttribute('data-browser-focus-ring', '');"
            // Single blue ring, only used when the site has no focus style of its own.
            "ring.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;box-sizing:border-box;border:4px solid rgb(59,145,255);border-radius:10px;box-shadow:0 8px 24px rgba(0,0,0,0.45);transition:left .15s ease,top .15s ease,width .15s ease,height .15s ease;';"
            "(document.body || document.documentElement).appendChild(ring);"
            "N.ring = ring;"
            "return ring;"
        "}"
        "function place() {"
            "if (!N.current || !N.ring) { return; }"
            "if (!document.contains(N.current)) { N.ring.style.opacity = '0'; return; }"
            "N.ring.style.opacity = '1';"
            "remember();"
            "var r = N.current.getBoundingClientRect(); var pad = 6;"
            "N.ring.style.left = (r.left - pad) + 'px'; N.ring.style.top = (r.top - pad) + 'px';"
            "N.ring.style.width = (r.width + pad * 2) + 'px'; N.ring.style.height = (r.height + pad * 2) + 'px';"
        "}"
        "function follow(ms) {"
            "var end = Date.now() + ms;"
            "(function step() { place(); if (Date.now() < end) { requestAnimationFrame(step); } })();"
        "}"
        "window.addEventListener('scroll', place, true);"
        "window.addEventListener('resize', place);"
        "function remember() {"
            "if (!N.current) { return; }"
            "var r = N.current.getBoundingClientRect();"
            "if (r.width > 0 && r.height > 0) { N.lastRect = { l: r.left, t: r.top, r: r.right, b: r.bottom, w: r.width, h: r.height, cx: (r.left + r.right) / 2, cy: (r.top + r.bottom) / 2, scrollY: scrollY }; }"
        "}"
        "function styleSignature(el) {"
            "var cs = getComputedStyle(el);"
            "return [cs.outlineStyle, cs.outlineWidth, cs.outlineColor, cs.boxShadow, cs.borderTopColor, cs.borderTopWidth, cs.backgroundColor, cs.color, cs.transform, cs.opacity, cs.textDecorationLine].join('|');"
        "}"
        "function isTextEntry(el) {"
            "if (el.isContentEditable) { return true; }"
            "var tag = el.tagName;"
            "if (tag === 'TEXTAREA' || tag === 'SELECT') { return true; }"
            "if (tag !== 'INPUT') { return false; }"
            "var type = (el.getAttribute('type') || 'text').toLowerCase();"
            "return ['button', 'submit', 'reset', 'checkbox', 'radio', 'image', 'range', 'color', 'file'].indexOf(type) === -1;"
        "}"
        "function releaseFocus() {"
            "if (N.focused && document.activeElement === N.focused) { try { N.focused.blur(); } catch (e) {} }"
            "N.focused = null;"
        "}"
        // Give the element real focus so the site's own :focus/:focus-visible style shows. Text fields
        // are skipped (focusing them could bring up the keyboard). Returns the style before focus.
        "function applySiteFocus(el) {"
            "releaseFocus();"
            "if (isTextEntry(el)) { return null; }"
            "var before = styleSignature(el);"
            "try { el.focus({ preventScroll: true }); } catch (e) { return null; }"
            "if (document.activeElement !== el) { return null; }"
            "N.focused = el;"
            "return before;"
        "}"
        "function updateRingVisibility(el, before) {"
            "if (N.current !== el || !N.ring) { return; }"
            "N.siteStyled = before !== null && styleSignature(el) !== before;"
            "N.ring.style.display = N.siteStyled ? 'none' : '';"
        "}"
        "function focusElement(el) {"
            "N.current = el;"
            "var before = applySiteFocus(el);"
            "var ring = ensureRing();"
            "var radius = parseFloat(getComputedStyle(el).borderRadius) || 0;"
            "ring.style.borderRadius = Math.max(10, radius + 6) + 'px';"
            "var r = el.getBoundingClientRect(); var margin = 80;"
            "if (r.top < margin || r.bottom > innerHeight - margin || r.left < 0 || r.right > innerWidth) {"
                "try { el.scrollIntoView({ block: r.height > innerHeight - margin * 2 ? 'start' : 'center', inline: 'nearest', behavior: 'smooth' }); } catch (e) { el.scrollIntoView(); }"
            "}"
            "place(); follow(700);"
            "updateRingVisibility(el, before);"
            // Focus styles often animate in: check again once a typical transition has finished.
            "if (before !== null) { setTimeout(function() { updateRingVisibility(el, before); }, 260); }"
        "}"
        "function scrollPage(dir) {"
            "var se = document.scrollingElement || document.documentElement;"
            "if (dir === 'up' && se.scrollTop <= 1) { return 'edge'; }"
            "if (dir === 'up' || dir === 'down') {"
                "var before = se.scrollTop;"
                "window.scrollBy({ top: (dir === 'down' ? 1 : -1) * innerHeight * 0.6, behavior: 'smooth' });"
                "follow(700);"
                "return (dir === 'down' && before + innerHeight >= se.scrollHeight - 2) ? 'none' : 'scrolled';"
            "}"
            "return 'none';"
        "}"
        "N.move = function(dir) {"
            "var cands = collect();"
            "var cur = (N.current && document.contains(N.current)) ? info(N.current) : null;"
            // The highlighted element was re-rendered away (carousels, lazy lists): continue from where it was.
            "if (!cur && N.current && N.lastRect) {"
                "var d = scrollY - N.lastRect.scrollY; var L = N.lastRect;"
                "cur = { el: null, l: L.l, r: L.r, w: L.w, h: L.h, cx: L.cx, t: L.t - d, b: L.b - d, cy: L.cy - d };"
            "}"
            "if (cur && (cur.w === 0 || cur.b < -innerHeight * 0.25 || cur.t > innerHeight * 1.25)) { cur = null; }"
            "if (!cur) {"
                "var visible = cands.filter(function(c) { return c.t >= 0 && c.b <= innerHeight && c.l >= 0 && c.r <= innerWidth; });"
                "if (!visible.length) { visible = cands.filter(function(c) { return c.b > 0 && c.t < innerHeight; }); }"
                "if (visible.length) {"
                    "visible.sort(function(a, b) { return Math.abs(a.t - b.t) < 12 ? a.l - b.l : a.t - b.t; });"
                    "focusElement((dir === 'up' ? visible[visible.length - 1] : visible[0]).el);"
                    "return 'moved';"
                "}"
                "return scrollPage(dir);"
            "}"
            "var best = null, bestScore = Infinity;"
            "for (var i = 0; i < cands.length; i++) {"
                "var c = cands[i];"
                "if (cur.el && (c.el === cur.el || c.el.contains(cur.el) || cur.el.contains(c.el))) { continue; }"
                "if (!qualifies(dir, c, cur)) { continue; }"
                "var s = score(dir, c, cur);"
                "if (s < bestScore) { bestScore = s; best = c; }"
            "}"
            "if (best) { focusElement(best.el); return 'moved'; }"
            "return scrollPage(dir);"
        "};"
        "N.point = function() {"
            "if (!N.current || !document.contains(N.current)) { return ''; }"
            "var r = N.current.getBoundingClientRect();"
            "if (r.bottom < 0 || r.top > innerHeight) { N.current.scrollIntoView({ block: 'center' }); r = N.current.getBoundingClientRect(); }"
            "var x = Math.min(Math.max(r.left + r.width / 2, 1), innerWidth - 1);"
            "var y = Math.min(Math.max(r.top + Math.min(r.height / 2, innerHeight / 2), 1), innerHeight - 1);"
            "return JSON.stringify({ x: x, y: y });"
        "};"
        "N.clear = function() {"
            "if (N.ring && N.ring.parentNode) { N.ring.parentNode.removeChild(N.ring); }"
            "releaseFocus();"
            "N.ring = null; N.current = null; N.lastRect = null; N.siteStyled = false;"
        "};"
    "})();";
}

static NSString *BrowserPageNavigationDirectionName(BrowserPageNavigationDirection direction) {
    switch (direction) {
        case BrowserPageNavigationDirectionUp: return @"up";
        case BrowserPageNavigationDirectionDown: return @"down";
        case BrowserPageNavigationDirectionLeft: return @"left";
        case BrowserPageNavigationDirectionRight: return @"right";
    }
    return @"down";
}

@implementation BrowserPageNavigator

- (void)moveInDirection:(BrowserPageNavigationDirection)direction
                webView:(BrowserWebView *)webView
             completion:(void (^)(BrowserPageNavigationResult))completion {
    NSString *script = [NSString stringWithFormat:@"%@ window.__bnav.move('%@');",
                        BrowserPageNavigatorLibrary(), BrowserPageNavigationDirectionName(direction)];
    // Asynchronous: arrow presses arrive inside UIKit event handling, where a
    // synchronous (run-loop pumping) evaluation would nest events.
    [webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        BrowserPageNavigationResult outcome = BrowserPageNavigationResultNone;
        NSString *value = [result isKindOfClass:[NSString class]] ? result : @"";
        if ([value isEqualToString:@"moved"]) {
            outcome = BrowserPageNavigationResultMoved;
        } else if ([value isEqualToString:@"scrolled"]) {
            outcome = BrowserPageNavigationResultScrolled;
        } else if ([value isEqualToString:@"edge"]) {
            outcome = BrowserPageNavigationResultTopEdge;
        }
        if (error != nil) {
            NSLog(@"[Browser] Page navigation failed: %@", error.localizedDescription);
        }
        if (completion != nil) {
            completion(outcome);
        }
    }];
}

- (NSValue *)activationPointInWebView:(BrowserWebView *)webView {
    NSString *script = [NSString stringWithFormat:@"%@ window.__bnav.point();", BrowserPageNavigatorLibrary()];
    NSString *result = [webView stringByEvaluatingJavaScriptFromString:script];
    NSData *data = [result dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *point = data.length > 0 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![point isKindOfClass:[NSDictionary class]] || point[@"x"] == nil || point[@"y"] == nil) {
        return nil;
    }
    return [NSValue valueWithCGPoint:CGPointMake([point[@"x"] doubleValue], [point[@"y"] doubleValue])];
}

- (void)clearInWebView:(BrowserWebView *)webView {
    [webView evaluateJavaScript:@"window.__bnav && window.__bnav.clear();" completionHandler:nil];
}

@end
