# Feasibility Plan: "fill-the-pane" YouTube fullscreen in cmux browser panes

## Executive Summary

**Verdict: FEASIBLE with caveats**

This feature can be implemented using a JavaScript Fullscreen API shim approach. The cmux codebase already has the necessary infrastructure (WKUserScript injection, settings catalog, schema system) to support this. The main challenge is YouTube's complex player state management and iframe-based ad delivery.

---

## 1. Is it doable?

**Yes, but with significant edge cases.**

WKWebView on macOS supports the HTML5 Fullscreen API, and cmux already enables it via `configuration.preferences.isElementFullscreenEnabled = true` (BrowserPanel.swift:3947). The WebView's `fullscreenState` property is already observed (BrowserPanel.swift:4864).

The core technical approach—intercepting `requestFullscreen()` and making the element fill the viewport instead of triggering native fullscreen—is sound. Since the WKWebView already fills the pane, "fill the viewport" equals "fill the pane."

**Key constraint:** We cannot intercept the native fullscreen presentation itself (AppKit's `NSWindow` fullscreen transition). We must prevent it from being triggered by shimming the JavaScript API before the page calls it.

---

## 2. Approaches & Tradeoffs

### Approach A: JS Fullscreen-API Shim via `WKUserScript`

**Mechanism:**
Inject a user script at document start that overrides:
- `Element.prototype.requestFullscreen` / `webkitRequestFullscreen`
- `Document.prototype.exitFullscreen` / `webkitExitFullscreen`
- `document.fullscreenElement` / `webkitFullscreenElement`
- `document.fullscreenEnabled`
- `fullscreenchange` / `webkitfullscreenchange` events

The shim intercepts `requestFullscreen()` calls, applies CSS to stretch the target element (`position: fixed; inset: 0; z-index: 2147483647;`), updates the shimmed `fullscreenElement` property, and dispatches synthetic `fullscreenchange` events.

**Pros:**
- No private API usage
- Works across all HTML5 video sites (YouTube, Vimeo, plain `<video>`)
- Leverages existing cmux infrastructure (`WKUserScript` injection at `.atDocumentStart`)
- No AppKit/AppStore compliance risk

**Cons:**
- **YouTube player state management:** YouTube's player keys off `document.fullscreenElement` and `resize` events. If the shim doesn't perfectly emulate the Fullscreen API contract (including `fullscreenElement` being the actual video container, not just any ancestor), the player may:
  - Show incorrect UI (e.g., exit-fullscreen icon when not actually fullscreen)
  - Fail to resize the video element
  - Break keyboard shortcuts (`f` key, `Esc`)
- **iframe & cross-origin issues:** YouTube ads are delivered via cross-origin iframes. The shim cannot inject into cross-origin frames (`forMainFrameOnly: true` would be required), so:
  - Ad fullscreen requests will fail or fall back to native fullscreen
  - Picture-in-Picture from ad iframes may behave unexpectedly
- **`allowfullscreen` attribute:** The shim must ensure the iframe containing the video has `allowfullscreen` set, or the page will refuse to call `requestFullscreen()`
- **Esc key handling:** The shim must intercept `keydown` for `Escape` and call `exitFullscreen()`, but only when the shimmed fullscreen is active (not when a modal or other UI element is open)
- **MutationObserver complexity:** YouTube's player dynamically restructures the DOM. The shim must track the "fullscreen element" even if it's moved or replaced.

**YouTube-specific risks:**
1. YouTube uses a custom `<video>` wrapper (`html5-video-player`) that calls `requestFullscreen()` on the container, not the `<video>` element. The shim must handle this.
2. YouTube's `f` key shortcut calls `document.fullscreenElement.exitFullscreen()` or `document.exitFullscreen()`. The shim must support both.
3. YouTube's fullscreen button icon state (enter vs. exit) is driven by `fullscreenchange` events. The shim must dispatch these with the correct `target`.
4. YouTube's "Theater mode" and "Miniplayer" modes interact with fullscreen state. The shim must not break these transitions.

**Implementation sketch:**
```javascript
// Injected at document start
(() => {
  const shimmedFullscreenElement = { value: null, writable: true };
  const listeners = new Set();
  
  Object.defineProperty(document, 'fullscreenElement', {
    get: () => shimmedFullscreenElement.value,
    configurable: true
  });
  
  Object.defineProperty(document, 'webkitFullscreenElement', {
    get: () => shimmedFullscreenElement.value,
    configurable: true
  });
  
  Element.prototype.requestFullscreen = function() {
    // Apply CSS to fill viewport
    this.style.position = 'fixed';
    this.style.inset = '0';
    this.style.zIndex = '2147483647';
    this.style.backgroundColor = '#000';
    
    shimmedFullscreenElement.value = this;
    
    // Dispatch synthetic event
    const event = new Event('fullscreenchange', { bubbles: false });
    document.dispatchEvent(event);
    document.dispatchEvent(new Event('webkitfullscreenchange', { bubbles: false }));
    
    return Promise.resolve();
  };
  
  document.exitFullscreen = function() {
    if (!shimmedFullscreenElement.value) return Promise.resolve();
    
    const el = shimmedFullscreenElement.value;
    el.style.position = '';
    el.style.inset = '';
    el.style.zIndex = '';
    el.style.backgroundColor = '';
    
    shimmedFullscreenElement.value = null;
    
    document.dispatchEvent(new Event('fullscreenchange', { bubbles: false }));
    document.dispatchEvent(new Event('webkitfullscreenchange', { bubbles: false }));
    
    return Promise.resolve();
  };
  
  // Intercept Esc key
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && shimmedFullscreenElement.value) {
      e.preventDefault();
      document.exitFullscreen();
    }
  }, true);
})();
```

**Assessment:** This is the most practical approach, but requires extensive testing with YouTube's player to ensure UI state, keyboard shortcuts, and transitions work correctly. Expect 2-3 iterations to handle edge cases.

---

### Approach B: Native Element-Fullscreen Path

**Mechanism:**
Attempt to constrain the native fullscreen presentation to the pane's `NSView` bounds using AppKit APIs.

**Investigation:**
- `WKPreferences.isElementFullscreenEnabled` is already `true` (BrowserPanel.swift:3947)
- `WKWebView.fullscreenState` is observed (BrowserPanel.swift:4864)
- `CmuxWebView.cmuxIsElementFullscreenActiveOrTransitioning` checks `fullscreenState` (CmuxWebView.swift:30)

**Problem:** WKWebView's fullscreen presentation is handled by WebKit's internal code, which calls `[NSWindow toggleFullScreen:]` or similar AppKit APIs. There is no public API to constrain the fullscreen window to a subview's bounds. The fullscreen window is created by WebKit and managed by the system.

**Private API exploration (unverified):**
- `_WKFullscreenDelegate` (private) may allow intercepting fullscreen requests, but:
  - Not documented
  - App Store rejection risk
  - May not allow constraining bounds
- `NSWindow` fullscreen transition is not easily interceptable without method swizzling (fragile, private API)

**Assessment:** **Not viable.** The native fullscreen path is not controllable at the level needed. Even with private APIs, constraining the fullscreen window to a pane would require significant AppKit hacking with no guarantee of success.

---

### Approach C: Hybrid (JS Shim + Native Fallback)

**Mechanism:**
Use the JS shim for most cases, but detect when the shim fails (e.g., cross-origin iframe) and fall back to native fullscreen.

**Problem:** Detecting "shim failure" is non-trivial. If the iframe's `requestFullscreen()` call is blocked by cross-origin policy, the shim never sees it. The native fullscreen would trigger anyway, defeating the purpose.

**Assessment:** Adds complexity without solving the core cross-origin iframe problem. Not recommended.

---

## 3. Recommended Approach

**Approach A: JS Fullscreen-API Shim**

**Why:**
- No private API risk
- Leverages existing cmux infrastructure
- Works for the primary use case (YouTube main player)
- Can be incrementally improved as edge cases are discovered

**Main risks:**
1. **YouTube player state bugs:** The shim may not perfectly emulate the Fullscreen API contract, causing UI glitches or broken shortcuts. Mitigation: extensive manual testing with YouTube, Vimeo, and plain `<video>` pages.
2. **Cross-origin iframe ads:** Ad fullscreen will not work. Mitigation: document this limitation; consider a "native fullscreen for ads" fallback if the user reports issues.
3. **Future YouTube changes:** YouTube may change its player implementation, breaking the shim. Mitigation: design the shim to be minimal and non-invasive; avoid YouTube-specific hacks.

**Unknowns:**
- Does YouTube's player check `document.fullscreenElement === videoContainer` or just `document.fullscreenElement !== null`? (Needs testing)
- Does YouTube's `f` key shortcut call `document.exitFullscreen()` or `document.fullscreenElement.exitFullscreen()`? (Needs testing)
- Will the shim break YouTube's "Theater mode" or "Miniplayer" transitions? (Needs testing)

---

## 4. Where in the cmux codebase this would be implemented

### 4.1 WKWebView setup and user script injection

**File:** `Sources/Panels/BrowserPanel.swift`

**Function:** `static func configureWebViewConfiguration(_:websiteDataStore:processPool:)` (line 3928)

**Current user scripts:**
- Line 3951: `BrowserFileSystemAccessBridge.scriptSource` (`.atDocumentStart`, `forMainFrameOnly: true`)
- Line 3962: `telemetryHookBootstrapScriptSource` (`.atDocumentStart`, `forMainFrameOnly: true`)
- Line 3969: `RemoteLoopbackRuntimeBridge.runtimeBridgeScriptSource` (`.atDocumentStart`, `forMainFrameOnly: false`)
- Line 3979: `addressBarFocusTrackingBootstrapScript` (`.atDocumentStart`, `forMainFrameOnly: true`)
- Line 3988: `CmuxWebView.pasteAsPlainTextFocusTrackingBootstrapScriptSource` (`.atDocumentStart`, `forMainFrameOnly: true`)

**Where to add the shim:**
Add a new user script after line 3994 (or before, depending on ordering requirements):
```swift
if PaneFillFullscreenSettings.isEnabled() {
    configuration.userContentController.addUserScript(
        WKUserScript(
            source: Self.paneFillFullscreenShimScriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true // Cross-origin iframes cannot be shimmed
        )
    )
}
```

**Script source location:**
Define `paneFillFullscreenShimScriptSource` as a static property on `BrowserPanel` (similar to `telemetryHookBootstrapScriptSource`), or in a separate file like `Sources/Panels/BrowserPaneFillFullscreenShim.swift`.

### 4.2 Fullscreen state observer

**File:** `Sources/Panels/BrowserPanel.swift`

**Location:** Line 4864, where `fullscreenState` is already observed.

**Current code:**
```swift
let fullscreenObserver = webView.observe(\.fullscreenState, options: [.initial, .new]) { [weak self] webView, _ in
    let fullscreenState = webView.fullscreenState
    // ... existing logic ...
}
```

**What to add:**
If the shim is active, `fullscreenState` should remain `.notInFullscreen` (since the shim prevents native fullscreen). No changes needed here, but add logging to verify:
```swift
#if DEBUG
if PaneFillFullscreenSettings.isEnabled() && fullscreenState != .notInFullscreen {
    cmuxDebugLog("WARNING: pane-fill fullscreen shim did not prevent native fullscreen")
}
#endif
```

### 4.3 CmuxWebView fullscreen helpers

**File:** `Sources/Panels/CmuxWebView.swift`

**Location:** Lines 30-45 (`cmuxIsElementFullscreenActiveOrTransitioning`, `cmuxIsManagedByExternalFullscreenWindow`)

**What to add:**
No changes needed, but consider adding a helper to check if the shim is active:
```swift
var cmuxIsPaneFillFullscreenActive: Bool {
    // Query the shimmed state via evaluateJavaScript (async)
    // Or track via a message handler
}
```

### 4.4 Settings wiring

**File:** `Packages/CmuxSettings/Sources/CmuxSettings/Keys/BrowserSettingsKeys.swift` (unverified path)

**What to add:**
A new settings key for `browser.fullscreenFillsPane`:
```swift
public let fullscreenFillsPane: SettingKey<Bool>
```

**File:** `Packages/CmuxSettingsUI/Sources/CmuxSettingsUI/Sections/BrowserSection.swift` (verified)

**What to add:**
A toggle in the Browser settings UI:
```swift
SettingsToggle(
    "Fill pane on fullscreen",
    isOn: $fullscreenFillsPane,
    help: "When enabled, clicking fullscreen on a video expands it to fill the browser pane instead of the entire screen."
)
```

---

## 5. Settings wiring

### 5.1 `cmux.json` key

**Proposed key:** `browser.fullscreenFillsPane`

**Type:** `boolean`

**Default:** `false` (preserve existing behavior)

**Schema location:** `web/data/cmux.schema.json`, line 898 (`"browser"` object)

**Schema addition:**
```json
"fullscreenFillsPane": {
  "type": "boolean",
  "default": false,
  "description": "When enabled, clicking fullscreen on a video expands it to fill the browser pane instead of the entire screen."
}
```

### 5.2 Settings catalog

**File:** `Packages/CmuxSettings/Sources/CmuxSettings/Keys/BrowserSettingsKeys.swift` (unverified)

**What to add:**
```swift
public struct BrowserSettingsKeys {
    // ... existing keys ...
    public let fullscreenFillsPane: SettingKey<Bool>
    
    public init() {
        // ... existing init ...
        self.fullscreenFillsPane = SettingKey(
            path: ["browser", "fullscreenFillsPane"],
            defaultValue: false,
            description: "Fill pane on fullscreen"
        )
    }
}
```

### 5.3 Settings UI

**File:** `Packages/CmuxSettingsUI/Sources/CmuxSettingsUI/Sections/BrowserSection.swift` (verified)

**What to add:**
A toggle in the Browser settings section, likely after the "Browser Theme" or "Memory Saver" settings:
```swift
SettingsToggle(
    String(localized: "settings.browser.fullscreenFillsPane", defaultValue: "Fill pane on fullscreen"),
    isOn: Binding(
        get: { catalog.browser.fullscreenFillsPane.value },
        set: { catalog.browser.fullscreenFillsPane.value = $0 }
    ),
    help: String(localized: "settings.browser.fullscreenFillsPane.help", defaultValue: "When enabled, clicking fullscreen on a video expands it to fill the browser pane instead of the entire screen.")
)
```

---

## 6. Validation plan

### 6.1 Test sites

1. **YouTube watch page** (primary use case)
   - URL: `https://www.youtube.com/watch?v=dQw4w9WgXcQ`
   - Test: Click fullscreen button, press `f` key, press `Esc`, check UI state (icon, video size, controls)
   - Expected: Video fills pane, UI state is correct, shortcuts work

2. **Plain `<video>` test page**
   - URL: `https://www.w3schools.com/html/html5_video.asp` (or a local test page)
   - Test: Click fullscreen button, check video fills pane
   - Expected: Video fills pane, no UI glitches

3. **Vimeo**
   - URL: `https://vimeo.com/showcase/10798859`
   - Test: Click fullscreen button, check video fills pane
   - Expected: Video fills pane, UI state is correct

4. **YouTube with ads** (edge case)
   - URL: Any YouTube video with pre-roll ads
   - Test: Click fullscreen during ad playback
   - Expected: Ad may go to native fullscreen (known limitation) or fail gracefully

### 6.2 Known failure modes

1. **YouTube UI state desync:** The fullscreen icon may show "exit" when not actually fullscreen, or vice versa. Mitigation: test and iterate on the shim's event dispatching.

2. **Keyboard shortcuts broken:** `f` key or `Esc` may not work. Mitigation: ensure the shim intercepts these keys and calls `exitFullscreen()`.

3. **Cross-origin iframe ads:** Ad fullscreen will not work. Mitigation: document this limitation.

4. **Picture-in-Picture:** PiP from a shimmed fullscreen video may behave unexpectedly. Mitigation: test and document.

5. **YouTube "Theater mode" / "Miniplayer":** These modes may interact with fullscreen state in unexpected ways. Mitigation: test transitions.

6. **Performance:** The shim adds DOM manipulation and event listeners. Mitigation: profile and optimize if needed.

### 6.3 Manual testing checklist

- [ ] YouTube: Click fullscreen button → video fills pane
- [ ] YouTube: Press `f` key → video fills pane
- [ ] YouTube: Press `Esc` → video exits fullscreen
- [ ] YouTube: Fullscreen icon state is correct (enter vs. exit)
- [ ] YouTube: Video controls are visible and functional in fullscreen
- [ ] YouTube: "Theater mode" transition works
- [ ] YouTube: "Miniplayer" transition works
- [ ] Plain `<video>`: Click fullscreen → video fills pane
- [ ] Vimeo: Click fullscreen → video fills pane
- [ ] YouTube with ad: Ad fullscreen behavior is acceptable (may go native)
- [ ] Setting toggle: Disabling `browser.fullscreenFillsPane` restores native fullscreen

---

## 7. Open Questions

1. **Does YouTube's player check `document.fullscreenElement === videoContainer` or just `document.fullscreenElement !== null`?**
   - If the former, the shim must ensure `fullscreenElement` is the exact container element, not a wrapper.
   - Needs testing.

2. **Does YouTube's `f` key shortcut call `document.exitFullscreen()` or `document.fullscreenElement.exitFullscreen()`?**
   - The shim must support both.
   - Needs testing.

3. **Will the shim break YouTube's "Theater mode" or "Miniplayer" transitions?**
   - These modes may rely on `fullscreenchange` events or `fullscreenElement` state.
   - Needs testing.

4. **Should the shim be injected into all frames (`forMainFrameOnly: false`) or just the main frame?**
   - Cross-origin iframes cannot be shimmed, but same-origin iframes (e.g., YouTube's own UI) could benefit.
   - Tradeoff: injecting into all frames increases complexity and may cause CAPTCHA issues (see BrowserPanel.swift:3959 comment).
   - Recommendation: start with `forMainFrameOnly: true` and expand if needed.

5. **How should the shim handle `requestFullscreen()` calls on non-video elements (e.g., a game or interactive canvas)?**
   - The shim could apply to all elements, or be restricted to `<video>` and known video containers.
   - Recommendation: apply to all elements for generality, but test with non-video use cases.

6. **Should there be a per-site allowlist/denylist for the shim?**
   - Some sites may break with the shim; users may want to disable it for specific domains.
   - Recommendation: defer to a future iteration; start with a global toggle.

7. **How should the shim interact with the existing `fullscreenState` observer (BrowserPanel.swift:4864)?**
   - If the shim is active, `fullscreenState` should remain `.notInFullscreen`.
   - Should the observer be disabled or modified when the shim is active?
   - Recommendation: leave the observer as-is; add logging to detect unexpected native fullscreen.

8. **Should the shim dispatch `fullscreenerror` events if `requestFullscreen()` is called on an invalid element?**
   - The Fullscreen API spec requires this, but the shim may not need to be fully spec-compliant.
   - Recommendation: defer to a future iteration; start with a minimal shim.

---

## 8. Implementation estimate

**Phase 1: Minimal shim (1-2 days)**
- Write the JS shim script
- Add settings key and UI toggle
- Test with YouTube, plain `<video>`, Vimeo

**Phase 2: Edge cases and polish (2-3 days)**
- Fix YouTube UI state desync
- Handle keyboard shortcuts
- Test with ads, PiP, Theater mode, Miniplayer

**Phase 3: Documentation and rollout (0.5 day)**
- Update CHANGELOG
- Add help text to settings UI
- Monitor for user reports

**Total: 3.5-5.5 days**

---

## 9. Conclusion

The "fill-the-pane" fullscreen feature is feasible using a JavaScript Fullscreen API shim. The main risk is YouTube's complex player state management, which will require iterative testing and refinement. The cmux codebase already has the necessary infrastructure, so implementation is straightforward once the shim is validated.

**Recommendation:** Proceed with Approach A (JS shim), starting with a minimal implementation and iterating based on testing.

---

DONE: plan.md written
