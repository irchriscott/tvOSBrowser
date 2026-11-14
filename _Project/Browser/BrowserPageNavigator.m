#import "BrowserPageNavigator.h"

#import "BrowserWebView.h"

/// Installs window.__bnav once per page. Kept free of ES2015+ syntax that older
/// tvOS WebKit builds might not parse.
static NSString *BrowserPageNavigatorLibrary(void) {
    // Generated from the navigator script: cached candidates, visibility checks, tvOS-like movement.
    return @
        "(function(){\n"
        "if (window.__bnav) { return; }\n"
        "var N = window.__bnav = { current: null, ring: null, lastRect: null, lastURL: null, focused: null, siteStyled: false };\n"
        "var SELECTOR = \"a[href], button, input:not([type=hidden]), select, textarea, summary, video, iframe, [role=button], [role=link], [role=tab], [role=menuitem], [role=menuitemradio], [role=option], [role=checkbox], [role=switch], [onclick], [tabindex]:not([tabindex='-1']), [contenteditable=''], [contenteditable='true']\";\n"
        "\n"
        "/* ---- Candidate cache: rebuilt only when the page changes ---- */\n"
        "var dirty = true, cachedElements = [], styleOK = null;\n"
        "function markDirty() { dirty = true; }\n"
        "try {\n"
        "  new MutationObserver(markDirty).observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['class', 'style', 'hidden', 'aria-hidden', 'disabled', 'href', 'role', 'tabindex'] });\n"
        "} catch (e) {}\n"
        "\n"
        "function sizeOK(r) {\n"
        "  if (!r || r.width < 6 || r.height < 6) { return false; }\n"
        "  if (Math.min(r.width, r.height) < 14 && r.width * r.height < 400) { return false; }  /* carousel dots etc. */\n"
        "  return true;\n"
        "}\n"
        "function styleUsable(el) {\n"
        "  if (styleOK && styleOK.has(el)) { return styleOK.get(el); }\n"
        "  var ok = true;\n"
        "  if (el.disabled || el.getAttribute('aria-hidden') === 'true') { ok = false; }\n"
        "  else {\n"
        "    var cs = getComputedStyle(el);\n"
        "    /* pointer-events and visibility are inherited, so this also covers hidden/closed parents. */\n"
        "    if (cs.visibility === 'hidden' || cs.display === 'none' || cs.pointerEvents === 'none') { ok = false; }\n"
        "    else {\n"
        "      /* Effective opacity: closed menus and auto-hidden controls are faded out through a parent.\n"
        "         (Player controls become targets again once a remote press has brought them back.) */\n"
        "      var opacity = 1;\n"
        "      for (var node = el, d = 0; node && node.nodeType === 1 && d < 12; node = node.parentElement, d++) {\n"
        "        opacity *= parseFloat(getComputedStyle(node).opacity);\n"
        "        if (opacity < 0.1) { ok = false; break; }\n"
        "      }\n"
        "    }\n"
        "  }\n"
        "  if (styleOK) { styleOK.set(el, ok); }\n"
        "  return ok;\n"
        "}\n"
        "function inBand(r) { return r.bottom > -innerHeight * 0.6 && r.top < innerHeight * 1.6 && r.right > -innerWidth * 0.5 && r.left < innerWidth * 1.5; }\n"
        "function info(el, r) {\n"
        "  r = r || el.getBoundingClientRect();\n"
        "  return { el: el, l: r.left, t: r.top, r: r.right, b: r.bottom, w: r.width, h: r.height, cx: (r.left + r.right) / 2, cy: (r.top + r.bottom) / 2 };\n"
        "}\n"
        "function rebuild() {\n"
        "  styleOK = typeof WeakMap === 'function' ? new WeakMap() : null;\n"
        "  var list = Array.prototype.slice.call(document.querySelectorAll(SELECTOR));\n"
        "  /* Clickable cards that are plain elements with cursor:pointer: sample a grid over the screen. */\n"
        "  var cols = 12, rows = 8, extra = [];\n"
        "  for (var y = 0; y < rows; y++) {\n"
        "    for (var x = 0; x < cols; x++) {\n"
        "      var hit = document.elementFromPoint((x + 0.5) * innerWidth / cols, (y + 0.5) * innerHeight / rows);\n"
        "      var node = hit, depth = 0, clickable = null;\n"
        "      while (node && node !== document.body && node !== document.documentElement && depth < 6) {\n"
        "        if (node.matches && node.matches(SELECTOR)) { clickable = null; break; }\n"
        "        if (!clickable && getComputedStyle(node).cursor === 'pointer') { clickable = node; }\n"
        "        node = node.parentElement; depth++;\n"
        "      }\n"
        "      /* Skip wrappers of real links (e.g. drag-scrollable carousel rows): the cards inside are the targets. */\n"
        "      if (clickable && extra.indexOf(clickable) === -1 && !clickable.hasAttribute('data-browser-focus-ring') && !clickable.querySelector(SELECTOR)) { extra.push(clickable); }\n"
        "    }\n"
        "  }\n"
        "  for (var i = 0; i < extra.length; i++) {\n"
        "    var nested = false;\n"
        "    for (var k = 0; k < extra.length && !nested; k++) { if (k !== i && extra[k].contains(extra[i])) { nested = true; } }\n"
        "    if (!nested) { list.push(extra[i]); }\n"
        "  }\n"
        "  cachedElements = list;\n"
        "  dirty = false;\n"
        "}\n"
        "function candidates() {\n"
        "  if (dirty) { rebuild(); }\n"
        "  var area = innerWidth * innerHeight, out = [];\n"
        "  for (var i = 0; i < cachedElements.length; i++) {\n"
        "    var el = cachedElements[i];\n"
        "    if (!el.isConnected) { continue; }\n"
        "    var r = el.getBoundingClientRect();\n"
        "    if (!sizeOK(r) || !inBand(r)) { continue; }\n"
        "    if (el.tagName !== 'VIDEO' && el.tagName !== 'IFRAME' && r.width * r.height > area * 0.6) { continue; }  /* page sections, not targets */\n"
        "    if (!styleUsable(el)) { continue; }\n"
        "    out.push(info(el, r));\n"
        "  }\n"
        "  return out;\n"
        "}\n"
        "\n"
        "/* ---- Visibility: is the element actually what the viewer sees at that spot? ---- */\n"
        "function visibleAt(el, x, y) {\n"
        "  if (x < 0 || y < 0 || x >= innerWidth || y >= innerHeight) { return null; }  /* off screen: unknown */\n"
        "  /* Hit-testing never finds pointer-events:none elements (e.g. auto-hidden player controls): unknown. */\n"
        "  if (getComputedStyle(el).pointerEvents === 'none') { return null; }\n"
        "  var hit = document.elementFromPoint(x, y);\n"
        "  if (!hit || hit.hasAttribute('data-browser-focus-ring')) { return true; }\n"
        "  return hit === el || el.contains(hit) || hit.contains(el);\n"
        "}\n"
        "function notCovered(c) {\n"
        "  var v = visibleAt(c.el, c.cx, c.cy);\n"
        "  if (v !== false) { return true; }\n"
        "  /* Centre covered (badge, overlay label...): try a few other points inside it. */\n"
        "  var pts = [[c.l + c.w * 0.25, c.t + c.h * 0.5], [c.l + c.w * 0.75, c.t + c.h * 0.5], [c.l + c.w * 0.5, c.t + c.h * 0.25], [c.l + c.w * 0.5, c.t + c.h * 0.75]];\n"
        "  for (var i = 0; i < pts.length; i++) { if (visibleAt(c.el, pts[i][0], pts[i][1]) === true) { return true; } }\n"
        "  return false;\n"
        "}\n"
        "function inFixedLayer(el) {\n"
        "  for (var node = el, d = 0; node && node !== document.body && d < 8; node = node.parentElement, d++) {\n"
        "    var p = getComputedStyle(node).position;\n"
        "    if (p === 'fixed' || p === 'sticky') { return true; }\n"
        "  }\n"
        "  return false;\n"
        "}\n"
        "\n"
        "/* ---- Direction scoring (tvOS-like: left/right stay on the row) ---- */\n"
        "function sameRow(c, cur) {\n"
        "  var overlap = Math.min(c.b, cur.b) - Math.max(c.t, cur.t);\n"
        "  return overlap > Math.min(c.h, cur.h) * 0.3 || (c.cy >= cur.t && c.cy <= cur.b);\n"
        "}\n"
        "function qualifies(dir, c, cur) {\n"
        "  if (dir === 'down') { return c.cy > cur.cy + 2 && c.t > cur.t + 2; }\n"
        "  if (dir === 'up') { return c.cy < cur.cy - 2 && c.b < cur.b - 2; }\n"
        "  if (dir === 'right') { return c.cx > cur.cx + 2 && c.l > cur.l + 2 && sameRow(c, cur); }\n"
        "  return c.cx < cur.cx - 2 && c.r < cur.r - 2 && sameRow(c, cur);\n"
        "}\n"
        "function score(dir, c, cur) {\n"
        "  var primary, gap, offset;\n"
        "  if (dir === 'down' || dir === 'up') {\n"
        "    primary = dir === 'down' ? Math.max(0, c.t - cur.b) : Math.max(0, cur.t - c.b);\n"
        "    gap = Math.max(0, Math.max(c.l, cur.l) - Math.min(c.r, cur.r));\n"
        "    offset = Math.abs(c.cx - cur.cx);\n"
        "  } else {\n"
        "    primary = dir === 'right' ? Math.max(0, c.l - cur.r) : Math.max(0, cur.l - c.r);\n"
        "    gap = Math.max(0, Math.max(c.t, cur.t) - Math.min(c.b, cur.b));\n"
        "    offset = Math.abs(c.cy - cur.cy);\n"
        "  }\n"
        "  return primary + gap * 3 + offset * 0.15;\n"
        "}\n"
        "\n"
        "/* ---- Highlight ring ---- */\n"
        "function ensureRing() {\n"
        "  if (N.ring && N.ring.parentNode) { return N.ring; }\n"
        "  var ring = document.createElement('div');\n"
        "  ring.setAttribute('data-browser-focus-ring', '');\n"
        "  ring.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;box-sizing:border-box;border:4px solid rgb(41,151,255);border-radius:12px;transition:left .09s ease-out,top .09s ease-out,width .09s ease-out,height .09s ease-out;';\n"
        "  (document.body || document.documentElement).appendChild(ring);\n"
        "  N.ring = ring;\n"
        "  return ring;\n"
        "}\n"
        "function remember() {\n"
        "  if (!N.current) { return; }\n"
        "  var r = N.current.getBoundingClientRect();\n"
        "  if (r.width > 0 && r.height > 0) {\n"
        "    N.lastRect = { l: r.left, t: r.top, r: r.right, b: r.bottom, w: r.width, h: r.height, cx: (r.left + r.right) / 2, cy: (r.top + r.bottom) / 2, scrollY: scrollY };\n"
        "    N.lastURL = location.href;\n"
        "  }\n"
        "}\n"
        "var placing = false;\n"
        "function place() {\n"
        "  if (!N.current || !N.ring) { return; }\n"
        "  var r = N.current.getBoundingClientRect();\n"
        "  if (!N.current.isConnected || r.width === 0 || r.height === 0) { N.ring.style.opacity = '0'; return; }\n"
        "  N.ring.style.opacity = '1';\n"
        "  remember();\n"
        "  var pad = 6;\n"
        "  N.ring.style.left = (r.left - pad) + 'px'; N.ring.style.top = (r.top - pad) + 'px';\n"
        "  N.ring.style.width = (r.width + pad * 2) + 'px'; N.ring.style.height = (r.height + pad * 2) + 'px';\n"
        "}\n"
        "function schedulePlace() {\n"
        "  if (placing) { return; }\n"
        "  placing = true;\n"
        "  requestAnimationFrame(function() { placing = false; place(); });\n"
        "}\n"
        "function follow(ms) {\n"
        "  var end = Date.now() + ms;\n"
        "  (function step() { place(); if (Date.now() < end) { requestAnimationFrame(step); } })();\n"
        "}\n"
        "window.addEventListener('scroll', schedulePlace, true);\n"
        "window.addEventListener('resize', schedulePlace);\n"
        "\n"
        "/* ---- Site focus styles: use them only when clearly visible ---- */\n"
        "function focusSignature(el) {\n"
        "  var cs = getComputedStyle(el);\n"
        "  var outline = (cs.outlineStyle !== 'none' && parseFloat(cs.outlineWidth) >= 2) ? cs.outlineStyle + cs.outlineWidth + cs.outlineColor : '';\n"
        "  var shadow = cs.boxShadow && cs.boxShadow !== 'none' ? cs.boxShadow : '';\n"
        "  var border = parseFloat(cs.borderTopWidth) >= 2 ? cs.borderTopColor + cs.borderTopWidth : '';\n"
        "  return [outline, shadow, border].join('|');\n"
        "}\n"
        "function isTextEntry(el) {\n"
        "  if (el.isContentEditable) { return true; }\n"
        "  var tag = el.tagName;\n"
        "  if (tag === 'TEXTAREA' || tag === 'SELECT') { return true; }\n"
        "  if (tag !== 'INPUT') { return false; }\n"
        "  var type = (el.getAttribute('type') || 'text').toLowerCase();\n"
        "  return ['button', 'submit', 'reset', 'checkbox', 'radio', 'image', 'range', 'color', 'file'].indexOf(type) === -1;\n"
        "}\n"
        "function releaseFocus() {\n"
        "  if (N.focused && document.activeElement === N.focused) { try { N.focused.blur(); } catch (e) {} }\n"
        "  N.focused = null;\n"
        "}\n"
        "function applySiteFocus(el) {\n"
        "  releaseFocus();\n"
        "  if (isTextEntry(el)) { return null; }\n"
        "  var before = focusSignature(el);\n"
        "  try { el.focus({ preventScroll: true }); } catch (e) { return null; }\n"
        "  if (document.activeElement !== el) { return null; }\n"
        "  N.focused = el;\n"
        "  return before;\n"
        "}\n"
        "function updateRingVisibility(el, before) {\n"
        "  if (N.current !== el || !N.ring) { return; }\n"
        "  N.siteStyled = before !== null && focusSignature(el) !== before;\n"
        "  N.ring.style.display = N.siteStyled ? 'none' : '';\n"
        "}\n"
        "\n"
        "/* ---- Scrolling: only as far as needed ---- */\n"
        "function reveal(el) {\n"
        "  var r = el.getBoundingClientRect();\n"
        "  if (r.left < 0 || r.right > innerWidth) {\n"
        "    try { el.scrollIntoView({ block: 'nearest', inline: 'nearest', behavior: 'auto' }); } catch (e) { el.scrollIntoView(false); }\n"
        "    r = el.getBoundingClientRect();\n"
        "  }\n"
        "  var top = 110, bottom = innerHeight - 70, delta = 0;\n"
        "  if (r.height > bottom - top) { delta = r.top - top; }\n"
        "  else if (r.top < top) { delta = r.top - top; }\n"
        "  else if (r.bottom > bottom) { delta = r.bottom - bottom; }\n"
        "  if (Math.abs(delta) < 1) { return; }\n"
        "  var before = scrollY;\n"
        "  window.scrollBy({ top: delta, behavior: Math.abs(delta) < innerHeight * 0.8 ? 'smooth' : 'auto' });\n"
        "  /* Inner scroll containers: if the window did not move, let the browser scroll the right container. */\n"
        "  setTimeout(function() {\n"
        "    if (Math.abs(scrollY - before) < 1) {\n"
        "      var rr = el.getBoundingClientRect();\n"
        "      if (rr.top < top || rr.bottom > bottom) { try { el.scrollIntoView({ block: 'nearest', inline: 'nearest' }); } catch (e) {} }\n"
        "    }\n"
        "  }, 30);\n"
        "}\n"
        "\n"
        "function focusElement(el) {\n"
        "  N.current = el;\n"
        "  var before = applySiteFocus(el);\n"
        "  var ring = ensureRing();\n"
        "  var radius = parseFloat(getComputedStyle(el).borderRadius) || 0;\n"
        "  ring.style.borderRadius = Math.max(12, radius + 6) + 'px';\n"
        "  reveal(el);\n"
        "  place(); follow(450);\n"
        "  updateRingVisibility(el, before);\n"
        "  if (before !== null) { setTimeout(function() { updateRingVisibility(el, before); }, 220); }\n"
        "}\n"
        "function scrollPage(dir) {\n"
        "  var se = document.scrollingElement || document.documentElement;\n"
        "  if (dir === 'up' && se.scrollTop <= 1) { return 'edge'; }\n"
        "  if (dir === 'up' || dir === 'down') {\n"
        "    var before = se.scrollTop;\n"
        "    window.scrollBy({ top: (dir === 'down' ? 1 : -1) * innerHeight * 0.6, behavior: 'smooth' });\n"
        "    markDirty();\n"
        "    return (dir === 'down' && before + innerHeight >= se.scrollHeight - 2) ? 'none' : 'scrolled';\n"
        "  }\n"
        "  return 'none';\n"
        "}\n"
        "function currentInfo() {\n"
        "  if (N.current && N.current.isConnected) {\n"
        "    var r = N.current.getBoundingClientRect();\n"
        "    if (r.width > 0 && r.height > 0) { return info(N.current, r); }\n"
        "  }\n"
        "  /* The highlighted element vanished or collapsed (carousel, lazy list): continue from where it was. */\n"
        "  if (N.lastRect && N.lastURL === location.href) {\n"
        "    var d = scrollY - N.lastRect.scrollY, L = N.lastRect;\n"
        "    return { el: null, l: L.l, r: L.r, w: L.w, h: L.h, cx: L.cx, t: L.t - d, b: L.b - d, cy: L.cy - d };\n"
        "  }\n"
        "  return null;\n"
        "}\n"
        "\n"
        "N.move = function(dir) {\n"
        "  var cands = candidates();\n"
        "  var cur = currentInfo();\n"
        "  if (cur && (cur.b < -innerHeight * 0.25 || cur.t > innerHeight * 1.25)) { cur = null; }\n"
        "  if (!cur) {\n"
        "    var onScreen = cands.filter(function(c) { return c.t >= 0 && c.b <= innerHeight && c.l >= 0 && c.r <= innerWidth && notCovered(c); });\n"
        "    if (!onScreen.length) { onScreen = cands.filter(function(c) { return c.b > 0 && c.t < innerHeight; }); }\n"
        "    /* Start in the page content (not the site's fixed header) when possible. */\n"
        "    var content = onScreen.filter(function(c) { return !inFixedLayer(c.el); });\n"
        "    var pool = content.length ? content : onScreen;\n"
        "    if (pool.length) {\n"
        "      pool.sort(function(a, b) { return Math.abs(a.t - b.t) < 12 ? a.l - b.l : a.t - b.t; });\n"
        "      focusElement((dir === 'up' ? pool[pool.length - 1] : pool[0]).el);\n"
        "      return 'moved';\n"
        "    }\n"
        "    return scrollPage(dir);\n"
        "  }\n"
        "  var ranked = [];\n"
        "  for (var i = 0; i < cands.length; i++) {\n"
        "    var c = cands[i];\n"
        "    if (cur.el && (c.el === cur.el || c.el.contains(cur.el) || cur.el.contains(c.el))) { continue; }\n"
        "    if (!qualifies(dir, c, cur)) { continue; }\n"
        "    ranked.push({ c: c, s: score(dir, c, cur) });\n"
        "  }\n"
        "  ranked.sort(function(a, b) { return a.s - b.s; });\n"
        "  /* Best candidate the viewer can actually see (skip ones hidden under overlays/menus). */\n"
        "  for (var j = 0; j < ranked.length && j < 8; j++) {\n"
        "    if (notCovered(ranked[j].c)) { focusElement(ranked[j].c.el); return 'moved'; }\n"
        "  }\n"
        "  return scrollPage(dir);\n"
        "};\n"
        "N.point = function() {\n"
        "  if (!N.current || !N.current.isConnected) { return ''; }\n"
        "  var r = N.current.getBoundingClientRect();\n"
        "  if (r.bottom < 0 || r.top > innerHeight || r.right < 0 || r.left > innerWidth) {\n"
        "    N.current.scrollIntoView({ block: 'center', inline: 'nearest' });\n"
        "    r = N.current.getBoundingClientRect();\n"
        "  }\n"
        "  /* Click a point where the element itself is what is on screen. */\n"
        "  var c = info(N.current, r);\n"
        "  var pts = [[c.cx, c.t + Math.min(c.h / 2, innerHeight / 2)], [c.l + c.w * 0.25, c.cy], [c.l + c.w * 0.75, c.cy], [c.cx, c.t + c.h * 0.25], [c.cx, c.t + c.h * 0.75]];\n"
        "  for (var i = 0; i < pts.length; i++) {\n"
        "    var x = Math.min(Math.max(pts[i][0], 1), innerWidth - 1), y = Math.min(Math.max(pts[i][1], 1), innerHeight - 1);\n"
        "    if (visibleAt(N.current, x, y) === true) { return JSON.stringify({ x: x, y: y }); }\n"
        "  }\n"
        "  return JSON.stringify({ x: Math.min(Math.max(pts[0][0], 1), innerWidth - 1), y: Math.min(Math.max(pts[0][1], 1), innerHeight - 1) });\n"
        "};\n"
        "/* Select: press the highlighted element itself (never whatever happens to be at that screen spot). */\n"
        "N.activate = function(force) {\n"
        "  var el = N.current;\n"
        "  if (!el || !el.isConnected) { return 'none'; }\n"
        "  if (isTextEntry(el)) { return 'text'; }\n"
        "  if (el.tagName === 'VIDEO' && !force) { return 'video'; }\n"
        "  if (el.tagName === 'IFRAME') { return 'frame'; }  /* embedded player: the app hands the click to the frame */\n"
        "  var r = el.getBoundingClientRect();\n"
        "  var x = r.left + r.width / 2, y = r.top + r.height / 2;\n"
        "  function fire(type) {\n"
        "    try {\n"
        "      var init = { bubbles: true, cancelable: true, composed: true, view: window, clientX: x, clientY: y, screenX: x, screenY: y, button: 0, buttons: type.indexOf('down') !== -1 ? 1 : 0, pointerType: 'mouse', isPrimary: true };\n"
        "      el.dispatchEvent(type.indexOf('pointer') === 0 && window.PointerEvent ? new PointerEvent(type, init) : new MouseEvent(type, init));\n"
        "    } catch (e) {}\n"
        "  }\n"
        "  ['pointerover', 'mouseover', 'pointerdown', 'mousedown', 'pointerup', 'mouseup'].forEach(fire);\n"
        "  if (typeof el.click === 'function') { el.click(); } else { fire('click'); }\n"
        "  return 'clicked';\n"
        "};\n"
        "N.release = function() {\n"
        "  remember();\n"
        "  releaseFocus();\n"
        "  if (N.ring && N.ring.parentNode) { N.ring.parentNode.removeChild(N.ring); }\n"
        "  N.ring = null; N.current = null; N.siteStyled = false;\n"
        "  markDirty();\n"
        "};\n"
        "N.clear = function() {\n"
        "  releaseFocus();\n"
        "  if (N.ring && N.ring.parentNode) { N.ring.parentNode.removeChild(N.ring); }\n"
        "  N.ring = null; N.current = null; N.lastRect = null; N.siteStyled = false;\n"
        "  markDirty();\n"
        "};\n"
        "/* In-page navigation (single-page apps): a new page starts without a highlight. */\n"
        "(function() {\n"
        "  function reset() { if (N.lastURL !== location.href) { N.clear(); } }\n"
        "  ['pushState', 'replaceState'].forEach(function(name) {\n"
        "    var original = history[name];\n"
        "    if (typeof original !== 'function') { return; }\n"
        "    history[name] = function() { var result = original.apply(this, arguments); setTimeout(reset, 0); return result; };\n"
        "  });\n"
        "  window.addEventListener('popstate', reset);\n"
        "  window.addEventListener('hashchange', reset);\n"
        "})();\n"
        "})();\n";
}

/// Shared by wake and play/pause: the largest visible video covering at least a quarter of
/// the viewport, and a function that sends mouse movement where the user is "looking".
static NSString *BrowserPageVideoHelpers(void) {
    return [[NSString stringWithFormat:@"var __bToken = '%@';", [BrowserWebView frameBridgeToken]] stringByAppendingString:@"function __bPrimaryVideo() {"
            "var best = null, bestArea = innerWidth * innerHeight * 0.25;"
            "var videos = document.querySelectorAll('video');"
            "for (var i = 0; i < videos.length; i++) {"
                "var r = videos[i].getBoundingClientRect();"
                "var w = Math.max(0, Math.min(r.right, innerWidth) - Math.max(r.left, 0));"
                "var h = Math.max(0, Math.min(r.bottom, innerHeight) - Math.max(r.top, 0));"
                "if (w * h >= bestArea) { bestArea = w * h; best = videos[i]; }"
            "}"
            "return best;"
        "}"
        "function __bWake(video) {"
            "var x, y; var nav = window.__bnav;"
            "var current = nav && nav.current && document.contains(nav.current) ? nav.current.getBoundingClientRect() : null;"
            "if (current && current.bottom > 0 && current.top < innerHeight) { x = current.left + current.width / 2; y = current.top + current.height / 2; }"
            "else if (video) { var vr = video.getBoundingClientRect(); x = vr.left + vr.width / 2; y = vr.top + vr.height / 2; }"
            "else { x = innerWidth / 2; y = innerHeight / 2; }"
            // Wiggle by a pixel so sites that ignore repeated identical positions still react.
            "window.__bWakeFlip = !window.__bWakeFlip; x += window.__bWakeFlip ? 1 : 0;"
            "var target = document.elementFromPoint(Math.min(Math.max(x, 0), innerWidth - 1), Math.min(Math.max(y, 0), innerHeight - 1)) || video || document.body;"
            "var init = { bubbles: true, cancelable: true, composed: true, view: window, clientX: x, clientY: y, screenX: x, screenY: y, pointerType: 'mouse', isPrimary: true };"
            "['pointerover', 'mouseover', 'pointermove', 'mousemove'].forEach(function(type) {"
                "try { target.dispatchEvent(type.indexOf('pointer') === 0 && window.PointerEvent ? new PointerEvent(type, init) : new MouseEvent(type, init)); } catch (e) {}"
            "});"
            "if (video && video !== target) { try { video.dispatchEvent(new MouseEvent('mousemove', init)); } catch (e) {} }"
            // A player embedded from another site: move the mouse inside its frame.
            "if (target && target.tagName === 'IFRAME' && window.__browserFrameBridge) { window.__browserFrameBridge.send(__bToken, target, 'hover', x, y); }"
        "}"];
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

@interface BrowserPageNavigator ()
@property (nonatomic) CFTimeInterval lastWakeTimestamp;
@end

@implementation BrowserPageNavigator

+ (NSString *)libraryScript {
    return BrowserPageNavigatorLibrary();
}

/// Runs a call against window.__bnav, installing the library first only if the page lacks it.
- (void)evaluateNavigatorCall:(NSString *)call webView:(BrowserWebView *)webView completion:(void (^)(id result))completion {
    NSString *guarded = [NSString stringWithFormat:@"window.__bnav ? (%@) : '__bnav_missing__'", call];
    [webView evaluateJavaScript:guarded completionHandler:^(id result, NSError *error) {
        if ([result isKindOfClass:[NSString class]] && [result isEqualToString:@"__bnav_missing__"]) {
            NSString *full = [NSString stringWithFormat:@"%@\n(%@)", BrowserPageNavigatorLibrary(), call];
            [webView evaluateJavaScript:full completionHandler:^(id fullResult, __unused NSError *fullError) {
                if (completion != nil) { completion(fullResult); }
            }];
            return;
        }
        if (error != nil) {
            NSLog(@"[Browser] Page navigation script failed: %@", error.localizedDescription);
        }
        if (completion != nil) { completion(result); }
    }];
}

- (void)wakePageInWebView:(BrowserWebView *)webView completion:(void (^)(BOOL))completion {
    NSString *script = [NSString stringWithFormat:@"(function(){%@ var v = __bPrimaryVideo(); __bWake(v); return v ? 'video' : 'none';})()", BrowserPageVideoHelpers()];
    [webView evaluateJavaScript:script completionHandler:^(id result, __unused NSError *error) {
        if (completion != nil) {
            completion([result isKindOfClass:[NSString class]] && [result isEqualToString:@"video"]);
        }
    }];
}

- (void)togglePrimaryVideoInWebView:(BrowserWebView *)webView completion:(void (^)(BOOL))completion {
    // No video in the page itself: the player may be embedded from another site (an iframe).
    // A playing but muted video (players start muted) is unmuted first.
    NSString *script = [NSString stringWithFormat:@"(function(){%@ var v = __bPrimaryVideo();"
                        "if (!v) { return window.__browserFrameBridge && window.__browserFrameBridge.toggleMainFrame(__bToken) ? 'frame' : 'none'; } __bWake(v);"
                        "if (!v.paused && !v.ended && v.muted) { v.muted = false; if (!v.volume) { v.volume = 1; } return 'unmuted'; }"
                        "if (v.paused || v.ended) { var p = v.play(); if (p && p.catch) { p.catch(function() {}); } return 'playing'; }"
                        "v.pause(); return 'paused';})()", BrowserPageVideoHelpers()];
    [webView evaluateJavaScript:script completionHandler:^(id result, __unused NSError *error) {
        if (completion != nil) {
            completion([result isKindOfClass:[NSString class]] && ![result isEqualToString:@"none"]);
        }
    }];
}

- (void)moveInDirection:(BrowserPageNavigationDirection)direction
                webView:(BrowserWebView *)webView
             completion:(void (^)(BrowserPageNavigationResult))completion {
    __weak typeof(self) weakSelf = self;
    __weak BrowserWebView *weakWebView = webView;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - self.lastWakeTimestamp < 1.5) {
        // The page was woken moments ago (controls are showing): move straight away.
        [self performMoveInDirection:direction webView:webView completion:completion];
        return;
    }
    self.lastWakeTimestamp = now;
    [self wakePageInWebView:webView completion:^(BOOL videoOnScreen) {
        // Player controls fade back in after the wake-up; give them a moment so the move
        // can land on them instead of skipping them as invisible.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((videoOnScreen ? 0.18 : 0.0) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            BrowserWebView *strongWebView = weakWebView;
            if (strongWebView != nil) {
                [weakSelf performMoveInDirection:direction webView:strongWebView completion:completion];
            }
        });
    }];
}

- (void)performMoveInDirection:(BrowserPageNavigationDirection)direction
                       webView:(BrowserWebView *)webView
                    completion:(void (^)(BrowserPageNavigationResult))completion {
    NSString *call = [NSString stringWithFormat:@"window.__bnav.move('%@')", BrowserPageNavigationDirectionName(direction)];
    // Asynchronous: arrow presses arrive inside UIKit event handling, where a
    // synchronous (run-loop pumping) evaluation would nest events.
    [self evaluateNavigatorCall:call webView:webView completion:^(id result) {
        BrowserPageNavigationResult outcome = BrowserPageNavigationResultNone;
        NSString *value = [result isKindOfClass:[NSString class]] ? result : @"";
        if ([value isEqualToString:@"moved"]) {
            outcome = BrowserPageNavigationResultMoved;
        } else if ([value isEqualToString:@"scrolled"]) {
            outcome = BrowserPageNavigationResultScrolled;
        } else if ([value isEqualToString:@"edge"]) {
            outcome = BrowserPageNavigationResultTopEdge;
        }
        if (completion != nil) {
            completion(outcome);
        }
    }];
}

- (NSValue *)activationPointInWebView:(BrowserWebView *)webView {
    NSString *result = [webView stringByEvaluatingJavaScriptFromString:@"window.__bnav ? window.__bnav.point() : ''"];
    NSData *data = [result dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *point = data.length > 0 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![point isKindOfClass:[NSDictionary class]] || point[@"x"] == nil || point[@"y"] == nil) {
        return nil;
    }
    return [NSValue valueWithCGPoint:CGPointMake([point[@"x"] doubleValue], [point[@"y"] doubleValue])];
}

- (NSString *)activateHighlightInWebView:(BrowserWebView *)webView force:(BOOL)force {
    NSString *script = [NSString stringWithFormat:@"window.__bnav ? window.__bnav.activate(%@) : 'none'", force ? @"true" : @"false"];
    NSString *result = [webView stringByEvaluatingJavaScriptFromString:script];
    return result.length > 0 ? result : @"none";
}

- (void)releaseHighlightInWebView:(BrowserWebView *)webView {
    [webView evaluateJavaScript:@"window.__bnav && window.__bnav.release();" completionHandler:nil];
}

- (void)clearInWebView:(BrowserWebView *)webView {
    [webView evaluateJavaScript:@"window.__bnav && window.__bnav.clear();" completionHandler:nil];
}

@end
