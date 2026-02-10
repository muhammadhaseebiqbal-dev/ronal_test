import UIKit
import WebKit
import Capacitor
import os.log

/// Custom CAPBridgeViewController that:
///
///   1) Ensures WKWebView uses persistent data store (login persistence fix — Build 4)
///   2) Bridges cookies from HTTPCookieStorage → WKHTTPCookieStore before every navigation
///   3) Handles WebView content process termination gracefully (no blind reload)
///   4) Prevents unnecessary reloads on app resume
///   5) Provides diagnostics logging (cookie counts, store type, auth markers)
///   6) Injects client-side CSS+JS patches for remote Base44 app issues (Build 3)
///
/// Architecture: The WKWebView loads https://abideandanchor.app (remote Base44 platform).
/// We cannot modify the remote source code, so we inject JS+CSS via WKUserScript to
/// patch DOM/CSS issues at runtime.
class PatchedBridgeViewController: CAPBridgeViewController {

    private static let log = OSLog(subsystem: "com.abideandanchor.app", category: "WebView")
    private let serverDomain = "abideandanchor.app"
    private var hasPerformedInitialLoad = false
    private var isRecoveringFromTermination = false

    // MARK: – Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        injectPatches()
        setupLifecycleObservers()
        logDiagnostics(event: "coldBoot")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: – A) Ensure persistent data store

    /// Override to guarantee we use the default (persistent) WKWebsiteDataStore
    /// and sync cookies from HTTPCookieStorage BEFORE the WebView is created.
    override open func webViewConfiguration(for instanceConfiguration: InstanceConfiguration) -> WKWebViewConfiguration {
        let config = super.webViewConfiguration(for: instanceConfiguration)

        // CRITICAL: Ensure data store is persistent (default), never ephemeral
        if config.websiteDataStore.isPersistent {
            os_log(.info, log: Self.log, "✅ Data store: persistent (default)")
        } else {
            os_log(.error, log: Self.log, "⚠️ Data store was non-persistent — forcing default()")
            config.websiteDataStore = WKWebsiteDataStore.default()
        }

        return config
    }

    // MARK: – B) Cookie bridging

    /// Syncs ALL cookies from HTTPCookieStorage.shared into WKHTTPCookieStore.
    /// This bridges cookies set by SFSafariViewController (OAuth) into the WebView.
    /// Must run BEFORE loading server.url on cold boot and after process termination.
    private func syncCookiesToWebView(completion: (() -> Void)? = nil) {
        guard let webView = self.webView else {
            os_log(.error, log: Self.log, "syncCookies: webView is nil")
            completion?()
            return
        }

        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        let allCookies = HTTPCookieStorage.shared.cookies ?? []
        let domainCookies = allCookies.filter { cookie in
            cookie.domain.contains(serverDomain) || cookie.domain == ".\(serverDomain)"
        }

        os_log(.info, log: Self.log, "syncCookies: %d total, %d for domain",
               allCookies.count, domainCookies.count)

        if domainCookies.isEmpty {
            completion?()
            return
        }

        let group = DispatchGroup()
        for cookie in domainCookies {
            group.enter()
            cookieStore.setCookie(cookie) {
                group.leave()
            }
        }
        group.notify(queue: .main) {
            os_log(.info, log: Self.log, "syncCookies: done — %d cookies synced", domainCookies.count)
            completion?()
        }
    }

    // MARK: – C) Smart recovery from content process termination

    /// Called by Capacitor's bridge after the initial page load.
    /// We use this to sync cookies and mark the initial load as complete.
    override open func capacitorDidLoad() {
        super.capacitorDidLoad()
        // Sync cookies from HTTPCookieStorage → WKHTTPCookieStore before first navigation
        syncCookiesToWebView {
            os_log(.info, log: Self.log, "capacitorDidLoad: cookies synced before initial load")
        }
        hasPerformedInitialLoad = true
        logDiagnostics(event: "capacitorDidLoad")
    }

    // MARK: – D) Lifecycle observers — prevent harmful reloads on resume

    private func setupLifecycleObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        // Observe WebView content process termination via the webView's URL
        // When the content process terminates, the webView's URL becomes nil
        webView?.addObserver(self, forKeyPath: "URL", options: [.new, .old], context: nil)
    }

    @objc private func handleWillEnterForeground() {
        os_log(.info, log: Self.log, "willEnterForeground")
        logDiagnostics(event: "willEnterForeground")

        guard let webView = self.webView else {
            os_log(.error, log: Self.log, "willEnterForeground: webView is nil — cannot recover")
            return
        }

        // Check if the WebView content process was terminated while backgrounded.
        // If so, the webView's title/URL may be empty and the page is blank.
        if webView.url == nil || webView.title == nil || webView.title?.isEmpty == true {
            os_log(.info, log: Self.log, "willEnterForeground: WebView appears terminated — recovering")
            recoverFromProcessTermination()
        } else {
            os_log(.info, log: Self.log, "willEnterForeground: WebView alive at %{public}@",
                   webView.url?.host ?? "unknown")
            // Just sync cookies in case any new ones were set by Safari/other apps
            syncCookiesToWebView()
        }
    }

    @objc private func handleDidBecomeActive() {
        os_log(.info, log: Self.log, "didBecomeActive")
        // NO reload here — we only recover in willEnterForeground if needed
    }

    @objc private func handleDidEnterBackground() {
        os_log(.info, log: Self.log, "didEnterBackground")
        // Flush cookies to HTTPCookieStorage so they survive process termination
        flushWebViewCookies()
    }

    /// Flushes cookies FROM WKWebView's cookie store TO HTTPCookieStorage.shared
    /// so they survive content process termination.
    private func flushWebViewCookies() {
        guard let webView = self.webView else { return }
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        cookieStore.getAllCookies { cookies in
            let domainCookies = cookies.filter { $0.domain.contains(self.serverDomain) }
            for cookie in domainCookies {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
            os_log(.info, log: Self.log, "flushCookies: %d domain cookies flushed to HTTPCookieStorage",
                   domainCookies.count)
        }
    }

    /// Graceful recovery after WebView content process termination.
    /// Syncs cookies first, then reloads with the server URL.
    private func recoverFromProcessTermination() {
        guard !isRecoveringFromTermination else {
            os_log(.info, log: Self.log, "recoverFromProcessTermination: already recovering, skipping")
            return
        }
        isRecoveringFromTermination = true

        os_log(.info, log: Self.log, "recoverFromProcessTermination: syncing cookies then reloading")

        // 1. Sync cookies from HTTPCookieStorage → WKHTTPCookieStore
        syncCookiesToWebView { [weak self] in
            guard let self = self, let webView = self.webView else {
                self?.isRecoveringFromTermination = false
                return
            }

            // 2. Reload the server URL (not webView.reload() which may fail with no content)
            if let serverURL = URL(string: "https://\(self.serverDomain)") {
                os_log(.info, log: Self.log, "recoverFromProcessTermination: loading %{public}@", serverURL.absoluteString)
                webView.load(URLRequest(url: serverURL))
            } else {
                // Fallback: try reload
                webView.reload()
            }

            self.isRecoveringFromTermination = false
            self.logDiagnostics(event: "processTerminationRecovery")
        }
    }

    // MARK: – KVO for URL changes (process termination detection)

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "URL" {
            let oldURL = change?[.oldKey] as? URL
            let newURL = change?[.newKey] as? URL
            if oldURL != nil && newURL == nil && hasPerformedInitialLoad {
                os_log(.info, log: Self.log, "KVO: URL went nil — content process may have terminated")
                // The WebViewDelegationHandler's webViewWebContentProcessDidTerminate
                // will handle the reload. We just log here for diagnostics.
            }
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }

    // MARK: – E) Diagnostics logging

    /// Logs diagnostic information about the WebView state.
    /// Logs cookie NAMES only (never values) for the server domain.
    /// Visible in Xcode device console and Console.app.
    private func logDiagnostics(event: String) {
        guard let webView = self.webView else {
            os_log(.info, log: Self.log, "[DIAG:%{public}@] webView=nil", event)
            return
        }

        let dataStore = webView.configuration.websiteDataStore
        let storeType = dataStore.isPersistent ? "persistent" : "nonPersistent"
        let currentURL = webView.url?.absoluteString ?? "none"

        os_log(.info, log: Self.log,
               "[DIAG:%{public}@] webView=YES storeType=%{public}@ url=%{public}@",
               event, storeType, currentURL)

        // Log cookie names for the domain (never values)
        let httpCookies = HTTPCookieStorage.shared.cookies?.filter {
            $0.domain.contains(serverDomain)
        } ?? []
        let httpCookieNames = httpCookies.map { $0.name }.joined(separator: ", ")

        os_log(.info, log: Self.log,
               "[DIAG:%{public}@] HTTPCookieStorage: count=%d names=[%{public}@]",
               event, httpCookies.count, httpCookieNames)

        // Log WKHTTPCookieStore cookies (async)
        dataStore.httpCookieStore.getAllCookies { cookies in
            let domainCookies = cookies.filter { $0.domain.contains(self.serverDomain) }
            let wkCookieNames = domainCookies.map { $0.name }.joined(separator: ", ")

            os_log(.info, log: Self.log,
                   "[DIAG:%{public}@] WKCookieStore: count=%d names=[%{public}@]",
                   event, domainCookies.count, wkCookieNames)

            // Check for auth markers (presence only, never log values)
            let hasAuthCookie = domainCookies.contains { name in
                let n = name.name.lowercased()
                return n.contains("token") || n.contains("session") || n.contains("auth") || n.contains("sid")
            }
            os_log(.info, log: Self.log,
                   "[DIAG:%{public}@] authMarkerInCookies=%{public}@",
                   event, hasAuthCookie ? "YES" : "NO")
        }

        // Also check localStorage for auth tokens via JS (presence only)
        webView.evaluateJavaScript("""
            (function() {
                try {
                    var keys = ['base44_access_token', 'token', 'base44_auth_token'];
                    var found = keys.filter(function(k) { return !!localStorage.getItem(k); });
                    return JSON.stringify({ authKeysPresent: found, count: found.length });
                } catch(e) {
                    return JSON.stringify({ error: e.message });
                }
            })()
        """) { result, error in
            if let resultStr = result as? String {
                os_log(.info, log: Self.log,
                       "[DIAG:%{public}@] localStorage: %{public}@",
                       event, resultStr)
            } else if let error = error {
                os_log(.info, log: Self.log,
                       "[DIAG:%{public}@] localStorage check failed: %{public}@",
                       event, error.localizedDescription)
            }
        }
    }

    // MARK: – Script injection (Build 3 patches)

    private func injectPatches() {
        guard let webView = self.webView else { return }
        let controller = webView.configuration.userContentController

        let cssScript = WKUserScript(
            source: Self.cssInjection,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        controller.addUserScript(cssScript)

        let jsScript = WKUserScript(
            source: Self.jsInjection,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        controller.addUserScript(jsScript)
    }

    // MARK: – CSS Patch

    private static let cssInjection: String = """
    (function() {
      if (document.getElementById('aa-ios-patches')) return;
      var style = document.createElement('style');
      style.id = 'aa-ios-patches';
      style.textContent = `
        /* ── B7: Bottom nav — min tap-target 48px, no squash with 5 tabs ── */
        nav.fixed.bottom-0 .flex.items-center.justify-around > a,
        nav.fixed.bottom-0 .flex.items-center.justify-around > button {
          min-width: 48px !important;
          min-height: 44px !important;
          padding-left: 4px !important;
          padding-right: 4px !important;
          flex: 1 1 0% !important;
          box-sizing: border-box !important;
        }
        nav.fixed.bottom-0 .flex.items-center.justify-around > a svg.w-5,
        nav.fixed.bottom-0 .flex.items-center.justify-around > button svg.w-5 {
          width: 22px !important;
          height: 22px !important;
          flex-shrink: 0 !important;
        }
        nav.fixed.bottom-0 .flex.items-center.justify-around > a .text-xs,
        nav.fixed.bottom-0 .flex.items-center.justify-around > button .text-xs {
          font-size: 10px !important;
          line-height: 1.2 !important;
          white-space: nowrap !important;
          overflow: hidden !important;
          text-overflow: ellipsis !important;
          max-width: 64px !important;
        }

        /* ── Safe-area bottom padding for fixed nav ── */
        nav.fixed.bottom-0 {
          padding-bottom: max(env(safe-area-inset-bottom, 0px), 8px) !important;
        }

        /* ── Recovery fallback UI styling ── */
        .aa-error-fallback {
          display: flex;
          flex-direction: column;
          align-items: center;
          justify-content: center;
          min-height: 50vh;
          padding: 32px 24px;
          text-align: center;
          font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
          background: #fafaf9;
        }
        .aa-error-fallback h2 {
          font-size: 20px;
          font-weight: 700;
          color: #1e293b;
          margin: 0 0 8px 0;
        }
        .aa-error-fallback p {
          font-size: 14px;
          color: #64748b;
          margin: 0 0 20px 0;
          line-height: 1.5;
        }
        .aa-error-fallback .aa-btn {
          display: block;
          width: 200px;
          padding: 12px 24px;
          margin: 4px auto;
          border: none;
          border-radius: 10px;
          font-size: 15px;
          font-weight: 600;
          cursor: pointer;
          -webkit-tap-highlight-color: transparent;
        }
        .aa-error-fallback .aa-btn-primary {
          background: #c9a96e;
          color: #0b1f2a;
        }
        .aa-error-fallback .aa-btn-secondary {
          background: #e2e8f0;
          color: #334155;
        }

        /* ── Hide our injected back button when a native one exists ── */
        .aa-injected-back + * .aa-injected-back { display: none !important; }
      `;
      document.head.appendChild(style);
    })();
    """

    // MARK: – JS Patch

    private static let jsInjection: String = """
    (function() {
      'use strict';
      if (window.__aaPatched) return;
      window.__aaPatched = true;

      // ── 1. ERROR SCREEN DETECTION ──
      // The remote Base44 app has a React ErrorBoundary that renders:
      //   "Abide and Anchor failed to load"
      //   "Please refresh the page. If this persists, contact support."
      // We detect this screen and replace it with better recovery options.

      function detectAndFixErrorScreen() {
        var root = document.getElementById('root');
        if (!root) return;
        var text = root.innerText || '';
        // Detect the known error screen
        if (text.indexOf('failed to load') !== -1 ||
            text.indexOf('Failed to load') !== -1) {
          enhanceErrorScreen(root);
        }
      }

      function enhanceErrorScreen(root) {
        // Find and replace the error screen's reload button
        var buttons = root.querySelectorAll('button');
        var reloadBtn = null;
        buttons.forEach(function(btn) {
          var t = (btn.textContent || '').trim().toLowerCase();
          if (t.indexOf('refresh') !== -1 || t.indexOf('reload') !== -1 || t.indexOf('try again') !== -1) {
            reloadBtn = btn;
          }
        });
        // Add recovery buttons if not already present
        if (root.querySelector('.aa-error-fallback')) return;
        var container = reloadBtn ? reloadBtn.parentElement : root;
        var fallback = document.createElement('div');
        fallback.className = 'aa-error-fallback';
        fallback.innerHTML =
          '<p style="margin-top:12px;">You can go back or return to the home screen.</p>' +
          '<button class="aa-btn aa-btn-primary" onclick="window.history.back()">Go Back</button>' +
          '<button class="aa-btn aa-btn-secondary" onclick="window.location.href=\\'/\\'">Go Home</button>';
        container.appendChild(fallback);
      }

      // ── 2. BLANK SCREEN DETECTION ──
      // Prayer List and other pages can render to a blank white screen.
      // Periodically check if #root is empty and show recovery.

      function detectBlankScreen() {
        var root = document.getElementById('root');
        if (!root) return;
        // Don't check while the app is still loading
        if (root.children.length === 0) return;
        // Check for truly blank content (no visible text, no images)
        var text = (root.innerText || '').trim();
        var imgs = root.querySelectorAll('img, svg, canvas');
        var nav = root.querySelector('nav');
        // If there's a nav bar but no page content, the page failed to render
        if (nav && text.length < 20 && imgs.length < 2) {
          if (root.querySelector('.aa-error-fallback')) return;
          var main = root.querySelector('main') || nav.previousElementSibling || root;
          var fallback = document.createElement('div');
          fallback.className = 'aa-error-fallback';
          fallback.innerHTML =
            '<h2>Page didn\\u2019t load</h2>' +
            '<p>This page failed to render. Tap below to try again.</p>' +
            '<button class="aa-btn aa-btn-primary" onclick="window.location.reload()">Retry</button>' +
            '<button class="aa-btn aa-btn-secondary" onclick="window.history.back()">Go Back</button>';
          main.appendChild(fallback);
        }
      }

      // ── 3. GLOBAL ERROR HANDLERS ──
      // Catch non-React uncaught errors and unhandled rejections.

      window.addEventListener('error', function(event) {
        var msg = (event.error && event.error.message) || event.message || '';
        if (msg.indexOf('must be used within') !== -1 ||
            msg.indexOf('Cannot read properties of null') !== -1 ||
            msg.indexOf('Cannot read properties of undefined') !== -1) {
          event.preventDefault();
          setTimeout(detectAndFixErrorScreen, 500);
        }
      });

      window.addEventListener('unhandledrejection', function(event) {
        var msg = (event.reason && event.reason.message) || String(event.reason || '');
        if (msg.indexOf('must be used within') !== -1) {
          event.preventDefault();
          setTimeout(detectAndFixErrorScreen, 500);
        }
      });

      // ── 4. DUPLICATE BACK BUTTON FIX ──
      // Issue B5: Prayer Corner / About Abide show "Back" twice.
      // The Layout component renders a back button AND the page component
      // renders its own. We hide duplicates.

      function fixDuplicateBackButtons() {
        // Scan all containers that could hold back buttons
        var containers = document.querySelectorAll(
          'header, .pt-8, .sticky.top-0, [class*="sticky"][class*="top"]'
        );
        containers.forEach(function(container) {
          var backEls = [];
          var els = container.querySelectorAll('button, a');
          els.forEach(function(el) {
            if (el.closest('.aa-error-fallback')) return;
            if (el.closest('nav.fixed.bottom-0')) return;
            var text = (el.textContent || '').trim();
            if (/^(\\u2190\\s*)?Back$/i.test(text) || /^\\u2039\\s*Back$/i.test(text)) {
              backEls.push(el);
            }
          });
          // Keep first visible, hide rest
          var firstVisible = null;
          backEls.forEach(function(el) {
            if (el.style.display === 'none' || el.offsetParent === null) return;
            if (!firstVisible) {
              firstVisible = el;
            } else {
              el.style.display = 'none';
              el.setAttribute('data-aa-hidden', 'duplicate');
            }
          });
        });

        // Also scan globally for adjacent back buttons
        var root = document.getElementById('root');
        if (!root) return;
        var allBackBtns = [];
        root.querySelectorAll('button, a').forEach(function(el) {
          if (el.closest('.aa-error-fallback')) return;
          if (el.closest('nav.fixed.bottom-0')) return;
          var text = (el.textContent || '').trim();
          if (/^(\\u2190\\s*)?Back$/i.test(text)) {
            allBackBtns.push(el);
          }
        });
        // Group by proximity — if two back buttons are within 200px vertically, hide the second
        for (var i = 1; i < allBackBtns.length; i++) {
          if (allBackBtns[i].style.display === 'none') continue;
          var prev = allBackBtns[i - 1];
          if (prev.style.display === 'none') continue;
          var r1 = prev.getBoundingClientRect();
          var r2 = allBackBtns[i].getBoundingClientRect();
          if (Math.abs(r1.top - r2.top) < 200) {
            allBackBtns[i].style.display = 'none';
            allBackBtns[i].setAttribute('data-aa-hidden', 'proximity-duplicate');
          }
        }
      }

      // ── 5. MISSING BACK BUTTON FIX ──
      // Issue B6: Captain's Log (Journal) and More have no back button.
      // Inject one into the page header when missing.

      function fixMissingBackButtons() {
        var path = window.location.pathname.toLowerCase();
        // Only target specific routes that need back buttons
        var needsBack = path === '/journal' ||
                        path === '/more' ||
                        path.indexOf('/journal/') === 0 ||
                        path.indexOf('/more/') === 0;
        if (!needsBack) return;

        // Check if a back button already exists (visible)
        var root = document.getElementById('root');
        if (!root) return;
        var hasVisibleBack = false;
        root.querySelectorAll('button, a').forEach(function(el) {
          if (el.closest('nav.fixed.bottom-0')) return;
          if (el.closest('.aa-error-fallback')) return;
          if (el.style.display === 'none') return;
          var text = (el.textContent || '').trim();
          if (/^(\\u2190\\s*)?Back$/i.test(text)) {
            hasVisibleBack = true;
          }
        });
        if (hasVisibleBack) return;

        // Find the page header to attach to
        var header = root.querySelector('header') ||
                     root.querySelector('.pt-8') ||
                     root.querySelector('[class*="sticky"][class*="top"]');
        if (!header) return;
        if (header.querySelector('.aa-injected-back')) return;

        var backBtn = document.createElement('button');
        backBtn.className = 'aa-injected-back';
        backBtn.setAttribute('aria-label', 'Back');
        backBtn.style.cssText =
          'background:none;border:none;color:inherit;font-size:15px;font-weight:500;' +
          'padding:8px 12px;cursor:pointer;display:flex;align-items:center;gap:4px;' +
          'min-height:44px;min-width:44px;-webkit-tap-highlight-color:transparent;' +
          'margin-left:-8px;margin-bottom:8px;';
        backBtn.innerHTML =
          '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" ' +
          'stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
          '<polyline points="15 18 9 12 15 6"></polyline></svg>' +
          '<span style="font-size:15px;">Back</span>';
        backBtn.addEventListener('click', function(e) {
          e.preventDefault();
          window.history.back();
        });

        // Insert at the beginning of the header's first child container
        var target = header.querySelector('.max-w-2xl') ||
                     header.querySelector('.max-w-lg') ||
                     header.querySelector('div') ||
                     header;
        target.insertBefore(backBtn, target.firstChild);
      }

      // ── 6. CLEANUP STALE PATCHES ──
      // Remove injected elements when navigating away

      function cleanupStalePatches() {
        var injected = document.querySelectorAll('.aa-injected-back');
        injected.forEach(function(el) {
          var path = window.location.pathname.toLowerCase();
          var shouldHave = path === '/journal' || path === '/more' ||
                           path.indexOf('/journal/') === 0 || path.indexOf('/more/') === 0;
          if (!shouldHave) {
            el.remove();
          }
        });
        // Re-show any hidden-duplicate buttons (they may be correct on new page)
        document.querySelectorAll('[data-aa-hidden]').forEach(function(el) {
          el.style.display = '';
          el.removeAttribute('data-aa-hidden');
        });
        // Remove stale error fallbacks
        var root = document.getElementById('root');
        if (root) {
          var text = (root.innerText || '').trim();
          if (text.indexOf('failed to load') === -1 && text.length > 50) {
            root.querySelectorAll('.aa-error-fallback').forEach(function(el) {
              el.remove();
            });
          }
        }
      }

      // ── 7. ORCHESTRATOR ──

      var patchTimer = null;
      function runAllPatches() {
        if (patchTimer) return;
        patchTimer = setTimeout(function() {
          patchTimer = null;
          cleanupStalePatches();
          fixDuplicateBackButtons();
          fixMissingBackButtons();
          detectAndFixErrorScreen();
        }, 250);
      }

      // MutationObserver for DOM changes
      var observer = new MutationObserver(function(mutations) {
        for (var i = 0; i < mutations.length; i++) {
          if (mutations[i].addedNodes.length > 0 || mutations[i].removedNodes.length > 0) {
            runAllPatches();
            return;
          }
        }
      });

      function startObserving() {
        var root = document.getElementById('root');
        if (root) {
          observer.observe(root, { childList: true, subtree: true });
          runAllPatches();
        } else {
          setTimeout(startObserving, 100);
        }
      }

      // Periodic blank-screen check (every 3s for first 30s after navigation)
      var blankCheckCount = 0;
      function scheduleBlankChecks() {
        blankCheckCount = 0;
        var interval = setInterval(function() {
          blankCheckCount++;
          detectBlankScreen();
          if (blankCheckCount >= 10) clearInterval(interval);
        }, 3000);
      }

      // SPA navigation hooks (single patch for pushState/replaceState/popstate)
      window.addEventListener('popstate', function() {
        setTimeout(runAllPatches, 300);
        scheduleBlankChecks();
      });

      var origPush = history.pushState;
      var origReplace = history.replaceState;
      history.pushState = function() {
        var result = origPush.apply(this, arguments);
        setTimeout(runAllPatches, 300);
        scheduleBlankChecks();
        return result;
      };
      history.replaceState = function() {
        var result = origReplace.apply(this, arguments);
        setTimeout(runAllPatches, 300);
        scheduleBlankChecks();
        return result;
      };

      // Start
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', function() {
          startObserving();
          scheduleBlankChecks();
        });
      } else {
        startObserving();
        scheduleBlankChecks();
      }
    })();
    """
}
