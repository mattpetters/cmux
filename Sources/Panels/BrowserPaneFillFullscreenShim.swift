import Foundation

/// JS Fullscreen-API shim that makes HTML5 fullscreen fill the WKWebView viewport
/// (i.e. the browser pane) instead of triggering native macOS display fullscreen.
///
/// Injected at document start, main frame only, when `browser.fullscreenFillsPane` is enabled.
///
/// **Limitations:**
/// - Cross-origin iframes (e.g. YouTube ad frames) cannot be shimmed — they will
///   either fall back to native fullscreen or fail silently. This is a fundamental
///   browser security boundary.
/// - The shim overrides `Element.prototype.requestFullscreen` and related APIs.
///   Sites that use private/internal WebKit fullscreen paths may bypass the shim.
/// - YouTube's player state management (icon toggling, keyboard shortcuts like `f`
///   and `Esc`) relies on `fullscreenchange` events and `document.fullscreenElement`.
///   The shim dispatches synthetic events to keep the player in sync, but edge cases
///   with Theater mode, Miniplayer, or PiP may require future refinement.
enum BrowserPaneFillFullscreenShim {
    static let scriptSource = """
    (() => {
      if (window.__cmuxPaneFillFullscreenInstalled) return;
      window.__cmuxPaneFillFullscreenInstalled = true;

      // ── State ──────────────────────────────────────────────────────────────
      let shimmedElement = null;
      let savedStyles = null;

      // ── Helpers ────────────────────────────────────────────────────────────
      const dispatch = (name) => {
        const ev = new Event(name, { bubbles: false });
        document.dispatchEvent(ev);
      };

      const saveStyles = (el) => ({
        position: el.style.position,
        inset: el.style.inset,
        top: el.style.top,
        left: el.style.left,
        width: el.style.width,
        height: el.style.height,
        zIndex: el.style.zIndex,
        backgroundColor: el.style.backgroundColor,
        margin: el.style.margin,
        padding: el.style.padding,
        border: el.style.border,
        borderRadius: el.style.borderRadius,
        transform: el.style.transform,
        maxWidth: el.style.maxWidth,
        maxHeight: el.style.maxHeight,
      });

      const restoreStyles = (el, saved) => {
        if (!saved) return;
        for (const key of Object.keys(saved)) {
          el.style[key] = saved[key];
        }
      };

      const applyFillStyles = (el) => {
        el.style.position = 'fixed';
        el.style.inset = '0';
        el.style.top = '0';
        el.style.left = '0';
        el.style.width = '100vw';
        el.style.height = '100vh';
        el.style.zIndex = '2147483647';
        el.style.backgroundColor = '#000';
        el.style.margin = '0';
        el.style.padding = '0';
        el.style.border = 'none';
        el.style.borderRadius = '0';
        el.style.transform = 'none';
        el.style.maxWidth = 'none';
        el.style.maxHeight = 'none';
      };

      // ── Enter fullscreen ───────────────────────────────────────────────────
      const enterFullscreen = function() {
        // Exit any existing shimmed fullscreen first
        if (shimmedElement && shimmedElement !== this) {
          exitFullscreen();
        }
        shimmedElement = this;
        savedStyles = saveStyles(this);
        applyFillStyles(this);

        // Dispatch after a microtask so listeners see the updated state
        queueMicrotask(() => {
          dispatch('fullscreenchange');
          dispatch('webkitfullscreenchange');
        });

        return Promise.resolve();
      };

      // ── Exit fullscreen ────────────────────────────────────────────────────
      const exitFullscreen = () => {
        if (!shimmedElement) return Promise.resolve();
        const el = shimmedElement;
        restoreStyles(el, savedStyles);
        shimmedElement = null;
        savedStyles = null;

        queueMicrotask(() => {
          dispatch('fullscreenchange');
          dispatch('webkitfullscreenchange');
        });

        return Promise.resolve();
      };

      // ── Override standard API ──────────────────────────────────────────────
      Element.prototype.requestFullscreen = enterFullscreen;

      Object.defineProperty(document, 'fullscreenElement', {
        get: () => shimmedElement,
        configurable: true,
      });

      Object.defineProperty(document, 'fullscreenEnabled', {
        get: () => true,
        configurable: true,
      });

      document.exitFullscreen = exitFullscreen;

      // ── Override webkit-prefixed API ───────────────────────────────────────
      Element.prototype.webkitRequestFullscreen = enterFullscreen;

      Object.defineProperty(document, 'webkitFullscreenElement', {
        get: () => shimmedElement,
        configurable: true,
      });

      Object.defineProperty(document, 'webkitIsFullScreen', {
        get: () => shimmedElement !== null,
        configurable: true,
      });

      document.webkitExitFullscreen = exitFullscreen;

      // ── Keyboard handling ──────────────────────────────────────────────────
      document.addEventListener('keydown', (e) => {
        if (!shimmedElement) return;

        // Escape exits shimmed fullscreen
        if (e.key === 'Escape' || e.keyCode === 27) {
          e.preventDefault();
          e.stopPropagation();
          exitFullscreen();
          return;
        }
      }, true);

      // ── Resize event ───────────────────────────────────────────────────────
      // YouTube and other players listen for resize to reflow controls.
      // The WebView viewport doesn't change (it's the pane), but dispatch
      // a resize when entering/exiting so players recalculate layout.
      const origEnter = enterFullscreen;
      const origExit = exitFullscreen;
    })();
    """
}
