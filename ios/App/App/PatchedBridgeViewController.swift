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
///   7) Hides Google sign-in completely — Email/Password only for iOS (Build 6)
///   8) In-app diagnostics overlay triggered by 5-tap on version label (Build 6)
///
/// Architecture: The WKWebView loads https://abideandanchor.app (remote Base44 platform).
/// We cannot modify the remote source code, so we inject JS+CSS via WKUserScript to
/// patch DOM/CSS issues at runtime.
///
/// NOTE (Build 6): Google sign-in is hidden on iOS. Roland confirmed Email/Password only.
/// No Base44 subscription, so no Google OAuth flow needed.
class PatchedBridgeViewController: CAPBridgeViewController, WKScriptMessageHandler {

    private static let log = OSLog(subsystem: "com.abideandanchor.app", category: "WebView")
    private let serverDomain = "abideandanchor.app"
    private var hasPerformedInitialLoad = false
    private var isRecoveringFromTermination = false

    // MARK: – F) Script message handler (diagnostics copy)

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "aaCopyDiagnostics" {
            guard let text = message.body as? String else { return }
            UIPasteboard.general.string = text
            os_log(.info, log: Self.log, "[DIAG:copy] Diagnostics copied to clipboard (%d chars)", text.count)
        }

        if message.name == "aaLogout" {
            os_log(.info, log: Self.log, "[LOGOUT] Native logout triggered — clearing all auth state")
            performFullLogout()
        }
    }

    // MARK: – Full Logout (clears all auth state so a different account can log in)

    /// Clears cookies, WKWebView website data, and navigates to login screen.
    /// Called from JS via aaLogout message handler.
    private func performFullLogout() {
        guard let webView = self.webView else {
            os_log(.error, log: Self.log, "[LOGOUT] webView is nil — cannot logout")
            return
        }

        // 1. Clear ALL cookies for our domain from HTTPCookieStorage
        if let cookies = HTTPCookieStorage.shared.cookies {
            let domainCookies = cookies.filter { $0.domain.contains(serverDomain) || $0.domain == ".\(serverDomain)" }
            for cookie in domainCookies {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
            os_log(.info, log: Self.log, "[LOGOUT] Cleared %d cookies from HTTPCookieStorage", domainCookies.count)
        }

        // 2. Clear ALL cookies from WKHTTPCookieStore
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        cookieStore.getAllCookies { cookies in
            let domainCookies = cookies.filter { $0.domain.contains(self.serverDomain) }
            for cookie in domainCookies {
                cookieStore.delete(cookie) {}
            }
            os_log(.info, log: Self.log, "[LOGOUT] Cleared %d cookies from WKHTTPCookieStore", domainCookies.count)
        }

        // 3. Clear WKWebView website data (localStorage, sessionStorage, cookies, cache)
        let dataStore = webView.configuration.websiteDataStore

        dataStore.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let domainRecords = records.filter { record in
                record.displayName.contains(self.serverDomain) || record.displayName.contains("abideandanchor")
            }
            dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: domainRecords) {
                os_log(.info, log: Self.log, "[LOGOUT] Cleared %d WKWebsiteDataStore records", domainRecords.count)

                // 4. Navigate to login page
                DispatchQueue.main.async {
                    if let loginURL = URL(string: "https://\(self.serverDomain)/login") {
                        os_log(.info, log: Self.log, "[LOGOUT] Navigating to %{public}@", loginURL.absoluteString)
                        webView.load(URLRequest(url: loginURL))
                    }
                }
            }
        }

        logDiagnostics(event: "logout")
    }

    // MARK: – Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        injectPatches()
        injectNativeDiagnostics()
        setupLifecycleObservers()
        logDiagnostics(event: "coldBoot")
    }

    // MARK: – G) Native diagnostics injection

    /// Re-injects device/build info into JS after foreground resume.
    /// The WKUserScript at .atDocumentStart handles cold boot; this handles resume.
    private func injectNativeDiagnostics() {
        guard let webView = self.webView else { return }

        let js = buildNativeDiagJS()
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                os_log(.error, log: Self.log, "[DIAG:nativeInject] failed: %{public}@", error.localizedDescription)
            }
        }
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
            os_log(.info, log: Self.log, "[DIAG:webViewCreated] dataStore=persistent")
        } else {
            os_log(.error, log: Self.log, "[DIAG:webViewCreated] dataStore=nonPersistent — forcing default()")
            config.websiteDataStore = WKWebsiteDataStore.default()
        }

        return config
    }

    // MARK: – B) Cookie bridging

    /// Syncs ALL cookies from HTTPCookieStorage.shared into WKHTTPCookieStore.
    /// This bridges cookies for the WebView on cold boot and after process termination.
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
        os_log(.info, log: Self.log, "[DIAG:willEnterForeground]")
        logDiagnostics(event: "willEnterForeground")
        injectNativeDiagnostics() // refresh native data in JS after resume

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

        // Device + build info
        let device = UIDevice.current
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"

        os_log(.info, log: Self.log,
               "[DIAG:%{public}@] device=%{public}@ iOS=%{public}@ app=%{public}@(%{public}@) store=%{public}@ url=%{public}@",
               event, machine, device.systemVersion, appVersion, buildNumber, storeType, currentURL)

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

            // Auth markers (presence only, never log values)
            let hasAuthCookie = domainCookies.contains { name in
                let n = name.name.lowercased()
                return n.contains("token") || n.contains("session") || n.contains("auth") || n.contains("sid")
            }
            os_log(.info, log: Self.log,
                   "[DIAG:authMarkers] event=%{public}@ cookieAuth=%{public}@",
                   event, hasAuthCookie ? "YES" : "NO")
        }

        // Check localStorage for auth tokens via JS (presence only)
        webView.evaluateJavaScript("""
            (function() {
                try {
                    var keys = ['base44_access_token', 'base44_refresh_token', 'token', 'base44_auth_token', 'access_token', 'refresh_token'];
                    var found = keys.filter(function(k) { return !!localStorage.getItem(k); });
                    var capToken = !!localStorage.getItem('CapacitorStorage.aa_token');
                    return JSON.stringify({ authKeysPresent: found, count: found.length, capToken: capToken });
                } catch(e) {
                    return JSON.stringify({ error: e.message });
                }
            })()
        """) { result, error in
            if let resultStr = result as? String {
                os_log(.info, log: Self.log,
                       "[DIAG:authMarkers] localStorage: %{public}@",
                       resultStr)
            } else if let error = error {
                os_log(.info, log: Self.log,
                       "[DIAG:authMarkers] localStorage check failed: %{public}@",
                       error.localizedDescription)
            }
        }
    }

    // MARK: – Script injection (Build 3 patches)

    private func injectPatches() {
        guard let webView = self.webView else { return }
        let controller = webView.configuration.userContentController

        // Register native message handlers
        controller.add(self, name: "aaCopyDiagnostics")
        controller.add(self, name: "aaLogout")

        // Inject native diagnostics data at DOCUMENT START so it's available
        // before any other scripts run (fixes "unknown" race condition)
        let nativeDiagScript = WKUserScript(
            source: buildNativeDiagJS(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        controller.addUserScript(nativeDiagScript)

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

    /// Builds the JS string that sets window.__aaNativeDiag with device/build info.
    /// Used both as a WKUserScript (document start) and via evaluateJavaScript (resume).
    private func buildNativeDiagJS() -> String {
        let device = UIDevice.current
        let systemVersion = device.systemVersion
        let model = device.model

        var systemInfo = utsname()
        uname(&systemInfo)
        let machineStr = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"

        let storeType: String
        if let webView = self.webView {
            storeType = webView.configuration.websiteDataStore.isPersistent ? "persistent" : "nonPersistent"
        } else {
            storeType = "unknown"
        }

        let deviceName = device.name.replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\\", with: "\\\\")

        return """
        window.__aaNativeDiag = {
          deviceModel: '\(machineStr)',
          deviceType: '\(model)',
          iOSVersion: '\(systemVersion)',
          deviceName: '\(deviceName)',
          appVersion: '\(appVersion)',
          buildNumber: '\(buildNumber)',
          dataStoreType: '\(storeType)'
        };
        """
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

        /* ── B8: Force ALL back buttons to top-left, well below safe area + header ── */
        .aa-injected-back,
        .aa-back-topleft {
          position: fixed !important;
          top: calc(env(safe-area-inset-top, 44px) + 52px) !important;
          left: 12px !important;
          z-index: 9999 !important;
          margin: 0 !important;
        }
        /* Ensure parent containers of back buttons are positioned */
        header,
        .sticky.top-0,
        [class*="sticky"][class*="top-0"],
        .pt-8 {
          position: relative !important;
        }

        /* ── B9: Prayer Wall responsiveness ── */
        /* Prevent squished grid/cards on smaller iPhone screens */
        [class*="prayer-wall"] .grid,
        [class*="prayer_wall"] .grid,
        [class*="PrayerWall"] .grid,
        main .grid {
          grid-template-columns: 1fr !important;
          gap: 12px !important;
        }
        @media (min-width: 640px) {
          [class*="prayer-wall"] .grid,
          [class*="prayer_wall"] .grid,
          [class*="PrayerWall"] .grid,
          main .grid {
            grid-template-columns: repeat(2, 1fr) !important;
          }
        }
        /* Ensure cards/items in prayer wall are not squashed */
        [class*="prayer-wall"] .grid > *,
        [class*="prayer_wall"] .grid > *,
        main .grid > div {
          min-width: 0 !important;
          overflow-wrap: break-word !important;
          word-break: break-word !important;
        }
        /* Fix prayer wall scrollable content */
        [class*="prayer-wall"],
        [class*="prayer_wall"],
        [class*="PrayerWall"] {
          overflow-x: hidden !important;
          max-width: 100vw !important;
          box-sizing: border-box !important;
        }
        /* Ensure prayer pages have proper padding for fixed back button */
        main {
          padding-top: max(calc(env(safe-area-inset-top, 44px) + 8px), 52px) !important;
        }

        /* ── B11: Log Out button on More/Settings page ── */
        #aa-logout-section {
          margin: 24px 16px 40px 16px;
          padding: 0;
        }
        #aa-logout-btn {
          display: flex;
          align-items: center;
          justify-content: center;
          gap: 8px;
          width: 100%;
          padding: 14px 20px;
          background: transparent;
          border: 1.5px solid #dc2626;
          border-radius: 12px;
          color: #dc2626;
          font-size: 16px;
          font-weight: 600;
          font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
          cursor: pointer;
          -webkit-tap-highlight-color: transparent;
          transition: background 0.15s, color 0.15s;
          min-height: 48px;
          box-sizing: border-box;
        }
        #aa-logout-btn:active {
          background: #dc2626;
          color: #ffffff;
        }
        #aa-logout-confirm-overlay {
          position: fixed;
          top: 0; left: 0; right: 0; bottom: 0;
          background: rgba(0,0,0,0.6);
          z-index: 99998;
          display: flex;
          align-items: center;
          justify-content: center;
          padding: 24px;
        }
        #aa-logout-confirm-card {
          background: #ffffff;
          border-radius: 16px;
          padding: 28px 24px;
          max-width: 320px;
          width: 100%;
          text-align: center;
          box-shadow: 0 8px 32px rgba(0,0,0,0.2);
          font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
        }
        #aa-logout-confirm-card h3 {
          margin: 0 0 8px 0;
          font-size: 18px;
          font-weight: 700;
          color: #1e293b;
        }
        #aa-logout-confirm-card p {
          margin: 0 0 20px 0;
          font-size: 14px;
          color: #64748b;
          line-height: 1.5;
        }
        .aa-logout-confirm-btn {
          display: block;
          width: 100%;
          padding: 13px;
          border: none;
          border-radius: 10px;
          font-size: 16px;
          font-weight: 600;
          cursor: pointer;
          -webkit-tap-highlight-color: transparent;
          margin-bottom: 8px;
        }
        .aa-logout-confirm-yes {
          background: #dc2626;
          color: #ffffff;
        }
        .aa-logout-confirm-cancel {
          background: #f1f5f9;
          color: #334155;
        }

        /* ── B10: Diagnostics overlay ── */
        .aa-diag-overlay {
          position: fixed;
          top: 0; left: 0; right: 0; bottom: 0;
          background: rgba(0,0,0,0.85);
          z-index: 99999;
          overflow-y: auto;
          -webkit-overflow-scrolling: touch;
          font-family: -apple-system, BlinkMacSystemFont, 'SF Mono', Menlo, monospace;
          color: #e8e8e8;
          padding: env(safe-area-inset-top, 20px) 16px env(safe-area-inset-bottom, 20px) 16px;
        }
        .aa-diag-overlay h2 {
          font-size: 18px; font-weight: 700; margin: 0 0 12px 0; color: #c9a96e;
        }
        .aa-diag-overlay pre {
          font-size: 11px; line-height: 1.5; white-space: pre-wrap; word-break: break-all;
          background: #1a1a2e; border-radius: 8px; padding: 12px; margin: 8px 0 16px 0;
        }
        .aa-diag-overlay .aa-diag-btn {
          display: block; width: 100%; padding: 14px; margin: 6px 0;
          border: none; border-radius: 10px; font-size: 16px; font-weight: 600;
          cursor: pointer; -webkit-tap-highlight-color: transparent;
          text-align: center;
        }
        .aa-diag-copy { background: #c9a96e; color: #0b1f2a; }
        .aa-diag-close { background: #333; color: #e8e8e8; }
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

      // ── 0. GOOGLE SIGN-IN: HIDDEN ON iOS (Build 6) ──
      // Roland confirmed: Email/Password only for iOS. No Base44 subscription for Google.
      // Google buttons are completely hidden. No loops, no account picker, no native auth.

      function interceptGoogleAuth() {
        var root = document.getElementById('root');
        if (!root) return;

        var path = window.location.pathname.toLowerCase();
        var hash = (window.location.hash || '').toLowerCase();
        // Only on login/auth pages
        if (path.indexOf('/login') === -1 && path.indexOf('/auth') === -1 &&
            path !== '/' && path.indexOf('/signup') === -1 &&
            hash.indexOf('/login') === -1 && hash.indexOf('/auth') === -1 &&
            hash.indexOf('/signup') === -1) return;

        var elements = root.querySelectorAll('button, a, [role="button"]');
        elements.forEach(function(el) {
          if (el.getAttribute('data-aa-google-hidden')) return;
          var text = (el.textContent || '').trim().toLowerCase();
          var ariaLabel = (el.getAttribute('aria-label') || '').toLowerCase();
          var className = (el.className || '').toLowerCase();
          var imgAlt = '';
          var img = el.querySelector('img');
          if (img) imgAlt = (img.getAttribute('alt') || '').toLowerCase();

          var isGoogle = text.indexOf('google') !== -1 ||
                         ariaLabel.indexOf('google') !== -1 ||
                         className.indexOf('google') !== -1 ||
                         imgAlt.indexOf('google') !== -1;
          if (!isGoogle) {
            var svgs = el.querySelectorAll('svg');
            svgs.forEach(function(svg) {
              if ((svg.getAttribute('aria-label') || '').toLowerCase().indexOf('google') !== -1) {
                isGoogle = true;
              }
            });
          }

          if (!isGoogle) return;

          // Hide Google button completely
          el.setAttribute('data-aa-google-hidden', 'true');
          el.style.display = 'none';

          // Hide any "or" dividers near the Google button (check siblings + parent)
          var prev = el.previousElementSibling;
          var next = el.nextElementSibling;
          var parent = el.parentElement;
          [prev, next].forEach(function(sib) {
            if (!sib) return;
            var sibText = (sib.textContent || '').trim().toLowerCase();
            if (sibText === 'or' || sibText === '— or —' || sibText === '- or -' ||
                sibText === 'or continue with' || /^-+\\s*or\\s*-+$/.test(sibText) ||
                /^—+\\s*or\\s*—+$/.test(sibText)) {
              sib.style.display = 'none';
              sib.setAttribute('data-aa-or-hidden', 'true');
            }
          });
          // Also check the parent's siblings (if Google is wrapped in a container)
          if (parent) {
            var parentPrev = parent.previousElementSibling;
            var parentNext = parent.nextElementSibling;
            [parentPrev, parentNext].forEach(function(sib) {
              if (!sib) return;
              var sibText = (sib.textContent || '').trim().toLowerCase();
              if (sibText === 'or' || sibText === '— or —' || sibText === '- or -' ||
                  /^-+\\s*or\\s*-+$/.test(sibText) || /^—+\\s*or\\s*—+$/.test(sibText)) {
                sib.style.display = 'none';
                sib.setAttribute('data-aa-or-hidden', 'true');
              }
            });
            // Hide parent if it only contained the Google button
            var visibleChildren = 0;
            for (var i = 0; i < parent.children.length; i++) {
              if (parent.children[i].style.display !== 'none') visibleChildren++;
            }
            if (visibleChildren === 0 && parent.children.length > 0) {
              parent.style.display = 'none';
            }
          }
        });

        // Broad sweep: hide any standalone "or" divider elements on login pages
        // that sit between (now-hidden) Google buttons and email forms.
        // Matches: divs/spans with class containing 'divider', 'separator', 'or-divider',
        // or elements whose only text content is "or" (with optional dashes/em-dashes).
        var allEls = root.querySelectorAll('div, span, p, hr');
        allEls.forEach(function(el) {
          if (el.getAttribute('data-aa-or-hidden')) return;
          if (el.style.display === 'none') return;
          var t = (el.textContent || '').trim().toLowerCase();
          var cls = (el.className || '').toLowerCase();
          // Text-only "or" dividers
          var isOrText = (t === 'or' || t === '— or —' || t === '- or -' ||
                         /^-{1,3}\\s*or\\s*-{1,3}$/.test(t) ||
                         /^—{1,3}\\s*or\\s*—{1,3}$/.test(t));
          // CSS class-based dividers near hidden Google buttons
          var isDividerClass = cls.indexOf('divider') !== -1 || cls.indexOf('separator') !== -1;
          if (isOrText || (isDividerClass && t.indexOf('or') !== -1 && t.length < 20)) {
            el.style.display = 'none';
            el.setAttribute('data-aa-or-hidden', 'true');
          }
        });
      }

      // ── 1. ERROR SCREEN DETECTION ──

      function isPrayerFlowRoute() {
        var path = window.location.pathname.toLowerCase();
        var hash = (window.location.hash || '').toLowerCase();
        return path.indexOf('/prayer') !== -1 || path.indexOf('/request') !== -1 ||
               path.indexOf('/builder') !== -1 || path.indexOf('/wall') !== -1 ||
               hash.indexOf('/prayer') !== -1 || hash.indexOf('/request') !== -1 ||
               hash.indexOf('/builder') !== -1 || hash.indexOf('/wall') !== -1;
      }

      function detectAndFixErrorScreen() {
        if (isPrayerFlowRoute()) return;
        var root = document.getElementById('root');
        if (!root) return;
        var text = root.innerText || '';
        if (text.indexOf('failed to load') !== -1 ||
            text.indexOf('Failed to load') !== -1) {
          enhanceErrorScreen(root);
        }
      }

      function enhanceErrorScreen(root) {
        var buttons = root.querySelectorAll('button');
        var reloadBtn = null;
        buttons.forEach(function(btn) {
          var t = (btn.textContent || '').trim().toLowerCase();
          if (t.indexOf('refresh') !== -1 || t.indexOf('reload') !== -1 || t.indexOf('try again') !== -1) {
            reloadBtn = btn;
          }
        });
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

      // ── 2. BLANK SCREEN DETECTION (ultra-conservative) ──
      // Only triggers if root has NO meaningful content for 5+ consecutive checks (15s+).
      // Never triggers on prayer/builder/request/wall routes (let Base44 handle those).

      var blankConsecutiveHits = 0;
      var prayerBlankHits = 0;

      function hasLoadingIndicators(root) {
        return !!root.querySelector(
          '[class*="animate-spin"], [class*="animate-pulse"], [class*="loading"], ' +
          '[class*="skeleton"], [class*="spinner"], .aa-error-fallback'
        );
      }

      function detectBlankScreen() {
        var root = document.getElementById('root');
        if (!root) return;
        if (root.children.length === 0) return;

        // Never inject error overlays on prayer-related routes
        if (isPrayerFlowRoute()) {
          blankConsecutiveHits = 0;
          return;
        }

        // Skip if loading indicators are present
        if (hasLoadingIndicators(root)) return;

        var text = (root.innerText || '').trim();
        var imgs = root.querySelectorAll('img, svg, canvas');
        var nav = root.querySelector('nav');

        // Only trigger if almost nothing rendered: text < 10 chars AND fewer than 2 images
        if (nav && text.length < 10 && imgs.length < 2) {
          blankConsecutiveHits++;
          if (blankConsecutiveHits < 5) return;
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
        } else {
          blankConsecutiveHits = 0;
        }
      }

      // ── 2b. PRAYER CORNER ROUTE MONITORING ──
      // No recovery overlays on prayer routes; only a silent one-time reload if route is truly blank.
      function monitorPrayerRoutes() {
        if (!isPrayerFlowRoute()) {
          prayerBlankHits = 0;
          return;
        }

        var root = document.getElementById('root');
        if (!root || root.children.length === 0) return;
        if (hasLoadingIndicators(root)) return;

        var text = (root.innerText || '').trim().toLowerCase();
        var visualElements = root.querySelectorAll('img, svg, canvas, button, a').length;
        var looksBlank = text.length < 12 && visualElements < 2;
        var hasFailureText = text.indexOf('failed to load') !== -1;

        if (!looksBlank && !hasFailureText) {
          prayerBlankHits = 0;
          return;
        }

        prayerBlankHits++;
        if (prayerBlankHits < 5) return; // 15s grace period

        // One silent self-heal reload per route key to avoid loops.
        var routeKey = (window.location.pathname || '') + '|' + (window.location.hash || '');
        var reloadKey = 'aa-prayer-reload:' + routeKey;
        if (sessionStorage.getItem(reloadKey) === '1') return;
        sessionStorage.setItem(reloadKey, '1');
        window.location.reload();
      }

      // ── 3. GLOBAL ERROR HANDLERS ──

      // Track SelectTrigger crash recovery
      var selectTriggerRetryCount = 0;
      var lastSelectTriggerRetryTime = 0;

      function isSelectCrashRoute() {
        var path = window.location.pathname.toLowerCase();
        var hash = (window.location.hash || '').toLowerCase();
        return path.indexOf('/request') !== -1 || path.indexOf('/builder') !== -1 ||
               hash.indexOf('/request') !== -1 || hash.indexOf('/builder') !== -1;
      }

      function forceHardRouteReload(tag) {
        try {
          var url = new URL(window.location.href);
          url.searchParams.set('aa_fix', tag);
          url.searchParams.set('aa_t', String(Date.now()));
          window.location.replace(url.toString());
        } catch (e) {
          window.location.reload();
        }
      }

      function clearCachesThenReload() {
        var completed = false;
        function done() {
          if (completed) return;
          completed = true;
          forceHardRouteReload('select-cache-reset');
        }

        // Prevent hanging forever if any async cache API stalls
        setTimeout(done, 1500);

        try {
          if (window.caches && caches.keys) {
            caches.keys().then(function(keys) {
              return Promise.all(keys.map(function(key) {
                return caches.delete(key);
              }));
            }).then(function() {
              done();
            }).catch(function() {
              done();
            });
          } else {
            done();
          }

          if (navigator.serviceWorker && navigator.serviceWorker.getRegistrations) {
            navigator.serviceWorker.getRegistrations().then(function(regs) {
              regs.forEach(function(reg) {
                reg.unregister().catch(function() {});
              });
            }).catch(function() {});
          }
        } catch (e) {
          done();
        }
      }

      function handleSelectTriggerCrash() {
        // This React context error crashes the entire component tree.
        // Strategy: request/builder routes get hard reload + cache reset attempts.
        var now = Date.now();
        if (now - lastSelectTriggerRetryTime < 3000) return; // debounce
        lastSelectTriggerRetryTime = now;
        selectTriggerRetryCount++;

        if (isSelectCrashRoute()) {
          var routeKey = (window.location.pathname || '') + '|' + (window.location.hash || '');
          var stepKey = 'aa-select-recover-step:' + routeKey;
          var step = parseInt(sessionStorage.getItem(stepKey) || '0', 10);

          if (step <= 0) {
            sessionStorage.setItem(stepKey, '1');
            forceHardRouteReload('select-reload-1');
            return;
          }

          if (step === 1) {
            sessionStorage.setItem(stepKey, '2');
            clearCachesThenReload();
            return;
          }

          // Last fallback for this specific route: one more hard refresh.
          if (step === 2) {
            sessionStorage.setItem(stepKey, '3');
            forceHardRouteReload('select-reload-2');
            return;
          }
        }

        var root = document.getElementById('root');
        if (!root) return;

        // If root is now empty/broken from React crash, show a reload prompt
        var rootText = (root.innerText || '').trim();
        if (rootText.length < 30 || root.childElementCount < 2) {
          // React tree has crashed — auto-retry once, then show manual retry
          if (selectTriggerRetryCount <= 2) {
            // Auto-retry: reload the current route
            setTimeout(function() {
              window.location.reload();
            }, 500);
          } else {
            // Show a minimal retry UI (NOT a "recovery screen" — just a button)
            if (!root.querySelector('.aa-select-fix')) {
              var fix = document.createElement('div');
              fix.className = 'aa-select-fix';
              fix.style.cssText = 'text-align:center;padding:60px 20px;';
              fix.innerHTML =
                '<p style="color:#666;margin-bottom:16px;">This page needs a moment to load.</p>' +
                '<button onclick="selectTriggerRetryCount=0;window.location.reload()" ' +
                'style="background:#c9a96e;color:#fff;border:none;padding:12px 24px;' +
                'border-radius:8px;font-size:16px;cursor:pointer;">Tap to Reload</button>' +
                '<br><button onclick="window.history.back()" ' +
                'style="background:transparent;color:#c9a96e;border:1px solid #c9a96e;' +
                'padding:10px 20px;border-radius:8px;font-size:14px;cursor:pointer;margin-top:12px;">Go Back</button>';
              root.appendChild(fix);
            }
          }
        }
      }

      window.addEventListener('error', function(event) {
        var msg = (event.error && event.error.message) || event.message || '';
        if (msg.indexOf('must be used within') !== -1) {
          event.preventDefault();
          event.stopImmediatePropagation && event.stopImmediatePropagation();
          setTimeout(handleSelectTriggerCrash, 300);
          return;
        }
        if (msg.indexOf('Cannot read properties of null') !== -1 ||
            msg.indexOf('Cannot read properties of undefined') !== -1) {
          event.preventDefault();
          setTimeout(detectAndFixErrorScreen, 500);
        }
      });

      window.addEventListener('unhandledrejection', function(event) {
        var msg = (event.reason && event.reason.message) || String(event.reason || '');
        if (msg.indexOf('must be used within') !== -1) {
          event.preventDefault();
          setTimeout(handleSelectTriggerCrash, 300);
        }
      });

      // ── 4. DUPLICATE BACK BUTTON FIX ──

      function isVisibleBackElement(el) {
        if (!el) return false;
        if (el.id === 'aa-fixed-back') return false;
        if (el.classList && el.classList.contains('aa-injected-back')) return false;
        if (el.closest('.aa-error-fallback')) return false;
        if (el.closest('nav.fixed.bottom-0')) return false;
        if (el.style.display === 'none') return false;
        if (el.offsetParent === null) return false;
        var text = (el.textContent || '').trim();
        var aria = (el.getAttribute('aria-label') || '').trim();
        return /^(\\u2190\\s*)?Back$/i.test(text) || /^\\u2039\\s*Back$/i.test(text) || /^back$/i.test(aria);
      }

      function getVisibleNativeBackButtons() {
        var root = document.getElementById('root');
        if (!root) return [];
        var buttons = [];
        root.querySelectorAll('button, a').forEach(function(el) {
          if (isVisibleBackElement(el)) buttons.push(el);
        });
        return buttons;
      }

      function fixDuplicateBackButtons() {
        var allBackBtns = getVisibleNativeBackButtons();
        if (allBackBtns.length === 0) return;

        // Keep a single native back button (closest to top-left) and hide the rest.
        allBackBtns.sort(function(a, b) {
          var ra = a.getBoundingClientRect();
          var rb = b.getBoundingClientRect();
          if (Math.abs(ra.top - rb.top) > 2) return ra.top - rb.top;
          return ra.left - rb.left;
        });

        var primary = allBackBtns[0];
        primary.classList.add('aa-back-topleft');
        primary.removeAttribute('data-aa-hidden');
        primary.style.display = '';

        for (var i = 1; i < allBackBtns.length; i++) {
          allBackBtns[i].style.display = 'none';
          allBackBtns[i].setAttribute('data-aa-hidden', 'duplicate');
        }
      }

      // ── 5. MISSING BACK BUTTON FIX ──

      function needsBackButton() {
        var path = window.location.pathname.toLowerCase();
        var hash = (window.location.hash || '').toLowerCase();
        return path === '/journal' || path === '/more' ||
               path.indexOf('/journal/') === 0 || path.indexOf('/more/') === 0 ||
               path.indexOf('/prayer') === 0 || path.indexOf('/request') === 0 ||
               path.indexOf('/builder') === 0 || path.indexOf('/wall') === 0 ||
               hash.indexOf('/prayer') !== -1 || hash.indexOf('/request') !== -1 ||
               hash.indexOf('/builder') !== -1 || hash.indexOf('/wall') !== -1 ||
               hash.indexOf('/journal') !== -1 || hash.indexOf('/more') !== -1;
      }

      function fixMissingBackButtons() {
        if (!needsBackButton()) {
          var staleBack = document.getElementById('aa-fixed-back');
          if (staleBack) staleBack.remove();
          return;
        }

        var root = document.getElementById('root');
        if (!root) return;

        var nativeBackButtons = getVisibleNativeBackButtons();
        var fixedBack = document.getElementById('aa-fixed-back');

        // Prefer native button when available to avoid duplicate stacked buttons.
        if (nativeBackButtons.length > 0) {
          if (fixedBack) fixedBack.remove();
          return;
        }

        if (fixedBack) return;

        // Insert as fixed-position button on body (not inside header)
        // so it's always visible below the safe area
        var backBtn = document.createElement('button');
        backBtn.id = 'aa-fixed-back';
        backBtn.className = 'aa-injected-back aa-back-topleft';
        backBtn.setAttribute('aria-label', 'Back');
        backBtn.style.cssText =
          'background:rgba(255,255,255,0.92);border:none;color:#1a1a1a;font-size:15px;font-weight:500;' +
          'padding:8px 14px;cursor:pointer;display:flex;align-items:center;gap:4px;' +
          'min-height:44px;min-width:44px;-webkit-tap-highlight-color:transparent;' +
          'border-radius:20px;box-shadow:0 1px 4px rgba(0,0,0,0.12);';
        backBtn.innerHTML =
          '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" ' +
          'stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
          '<polyline points="15 18 9 12 15 6"></polyline></svg>' +
          '<span style="font-size:15px;">Back</span>';
        backBtn.addEventListener('click', function(e) {
          e.preventDefault();
          window.history.back();
        });

        document.body.appendChild(backBtn);
      }

      // ── 6. CLEANUP STALE PATCHES ──

      function cleanupStalePatches() {
        // Remove fixed button when route doesn't need it OR native button exists.
        var fixedBack = document.getElementById('aa-fixed-back');
        if (fixedBack && (!needsBackButton() || getVisibleNativeBackButtons().length > 0)) {
          fixedBack.remove();
        }
        var injected = document.querySelectorAll('.aa-injected-back');
        injected.forEach(function(el) {
          if (!needsBackButton()) {
            el.remove();
          }
        });
        document.querySelectorAll('[data-aa-hidden]').forEach(function(el) {
          el.style.display = '';
          el.removeAttribute('data-aa-hidden');
        });
        document.querySelectorAll('button, a').forEach(function(el) {
          if (el.closest('.aa-error-fallback')) return;
          if (el.closest('nav.fixed.bottom-0')) return;
          var text = (el.textContent || '').trim();
          if (/^(\\u2190\\s*)?Back$/i.test(text) && el.style.display !== 'none') {
            if (!el.classList.contains('aa-back-topleft')) {
              el.classList.add('aa-back-topleft');
            }
          }
        });
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

      // ── 6b. DIAGNOSTICS OVERLAY (Build 6) ──
      // Triggered by 5-tap on version label OR /#/aa-diagnostics route.
      // Shows device info, auth markers, Google attempt counter, last nav URLs.
      // "Copy diagnostics" sends plaintext to native clipboard via WKScriptMessageHandler.

      var aaNavHistory = [];

      // Track navigation URLs (origin + path only, strip query/hash for privacy)
      (function trackNav() {
        function recordUrl() {
          try {
            var entry = window.location.origin + window.location.pathname;
            if (aaNavHistory.length === 0 || aaNavHistory[aaNavHistory.length - 1] !== entry) {
              aaNavHistory.push(entry);
              if (aaNavHistory.length > 5) aaNavHistory.shift();
            }
          } catch(e) {}
        }
        recordUrl();
        window.addEventListener('popstate', recordUrl);
        // pushState/replaceState are already monkey-patched above, so add tracking there
        var _origPush2 = history.pushState;
        history.pushState = function() {
          var r = _origPush2.apply(this, arguments);
          recordUrl();
          return r;
        };
        var _origReplace2 = history.replaceState;
        history.replaceState = function() {
          var r = _origReplace2.apply(this, arguments);
          recordUrl();
          return r;
        };
      })();

      function collectDiagnostics() {
        var native = window.__aaNativeDiag || {};
        var tokenKeys = ['base44_access_token', 'base44_refresh_token', 'base44_user', 'access_token', 'refresh_token'];
        var authPresence = {};
        var tokenLengths = {};
        tokenKeys.forEach(function(k) {
          try {
            var val = localStorage.getItem(k);
            authPresence[k] = val !== null;
            if (val !== null) tokenLengths[k] = val.length;
          } catch(e) { authPresence[k] = 'error'; }
        });

        var capPrefPresent = 'unknown';
        var capPrefLength = 0;
        try {
          var capVal = localStorage.getItem('CapacitorStorage.aa_token');
          capPrefPresent = capVal !== null;
          if (capVal !== null) capPrefLength = capVal.length;
        } catch(e) {}

        var lsKeyCount = 0;
        try { lsKeyCount = localStorage.length; } catch(e) {}

        var lines = [
          '=== Abide & Anchor Diagnostics ===',
          'Timestamp: ' + new Date().toISOString(),
          '',
          '-- Device --',
          'Model: ' + (native.deviceModel || 'unknown'),
          'Type: ' + (native.deviceType || 'unknown'),
          'iOS: ' + (native.iOSVersion || 'unknown'),
          '',
          '-- App --',
          'Version: ' + (native.appVersion || '?') + ' (' + (native.buildNumber || '?') + ')',
          'Origin: ' + window.location.origin,
          'Path: ' + window.location.pathname,
          'DataStore: ' + (native.dataStoreType || 'unknown'),
          '',
          '-- Auth Markers (presence + length, no values) --'
        ];
        Object.keys(authPresence).forEach(function(k) {
          var line = '  ' + k + ': ' + authPresence[k];
          if (tokenLengths[k]) line += ' (len=' + tokenLengths[k] + ')';
          lines.push(line);
        });
        lines.push('  CapacitorStorage.aa_token: ' + capPrefPresent + (capPrefLength ? ' (len=' + capPrefLength + ')' : ''));
        lines.push('  localStorage total keys: ' + lsKeyCount);
        lines.push('');
        lines.push('-- Login --');
        lines.push('  Method: Email/Password only (Google hidden on iOS)');
        lines.push('');
        lines.push('-- Recent Navigation (last ' + aaNavHistory.length + ') --');
        aaNavHistory.forEach(function(url, i) {
          lines.push('  ' + (i + 1) + '. ' + url);
        });
        lines.push('');
        lines.push('=== End ===');
        return lines.join('\\n');
      }

      function showDiagnosticsOverlay() {
        // Remove existing
        var existing = document.querySelector('.aa-diag-overlay');
        if (existing) { existing.remove(); return; } // toggle off

        var overlay = document.createElement('div');
        overlay.className = 'aa-diag-overlay';

        var text = collectDiagnostics();

        overlay.innerHTML =
          '<h2>\\ud83d\\udd27 Diagnostics</h2>' +
          '<pre id="aa-diag-text">' + text.replace(/</g, '&lt;') + '</pre>' +
          '<button class="aa-diag-btn aa-diag-copy" id="aa-diag-copy-btn">\\ud83d\\udccb Copy Diagnostics</button>' +
          '<button class="aa-diag-btn aa-diag-close" id="aa-diag-close-btn">Close</button>';

        document.body.appendChild(overlay);

        document.getElementById('aa-diag-copy-btn').addEventListener('click', function() {
          var diagText = collectDiagnostics(); // re-collect fresh
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.aaCopyDiagnostics) {
            window.webkit.messageHandlers.aaCopyDiagnostics.postMessage(diagText);
            this.textContent = '\\u2705 Copied!';
          } else {
            // Fallback: Clipboard API
            navigator.clipboard.writeText(diagText).then(function() {
              document.getElementById('aa-diag-copy-btn').textContent = '\\u2705 Copied!';
            }).catch(function() {
              document.getElementById('aa-diag-copy-btn').textContent = '\\u274c Copy failed';
            });
          }
          var btn = this;
          setTimeout(function() { btn.textContent = '\\ud83d\\udccb Copy Diagnostics'; }, 2000);
        });

        document.getElementById('aa-diag-close-btn').addEventListener('click', function() {
          overlay.remove();
        });
      }

      // 5-tap trigger: look for version text or app name elements
      (function setupDiagTrigger() {
        var tapCount = 0;
        var tapTimer = null;

        function handleTap() {
          tapCount++;
          if (tapTimer) clearTimeout(tapTimer);
          tapTimer = setTimeout(function() { tapCount = 0; }, 2000);
          if (tapCount >= 5) {
            tapCount = 0;
            showDiagnosticsOverlay();
          }
        }

        // Attach to any element with version text, or the nav bar title area
        function attachTrigger() {
          // Look for version labels, app title, or header elements
          var targets = document.querySelectorAll(
            '[class*="version"], [class*="Version"], h1, h2, .text-xs, nav .font-bold, ' +
            '[class*="app-name"], [class*="logo"], header'
          );
          targets.forEach(function(el) {
            if (el.getAttribute('data-aa-diag-trigger')) return;
            el.setAttribute('data-aa-diag-trigger', 'true');
            el.addEventListener('click', handleTap);
          });
        }

        // Also support /#/aa-diagnostics route
        function checkDiagRoute() {
          if (window.location.hash === '#/aa-diagnostics' ||
              window.location.pathname === '/aa-diagnostics') {
            showDiagnosticsOverlay();
          }
        }

        // Re-attach on DOM changes
        var diagObserver = new MutationObserver(function() { attachTrigger(); });
        function startDiagObserver() {
          var root = document.getElementById('root');
          if (root) {
            diagObserver.observe(root, { childList: true, subtree: true });
            attachTrigger();
          } else {
            setTimeout(startDiagObserver, 500);
          }
        }

        startDiagObserver();
        checkDiagRoute();
        window.addEventListener('hashchange', checkDiagRoute);
      })();

      // ── 6c. LOG OUT BUTTON (Build 7 — Stage One #7) ──
      // Injects a "Log Out" button on the More / Settings page.
      // Fully signs the user out: clears localStorage, cookies, Capacitor Preferences,
      // WKWebView data, and returns to the Login screen.

      function isMoreOrSettingsRoute() {
        var path = window.location.pathname.toLowerCase();
        var hash = (window.location.hash || '').toLowerCase();
        return path === '/more' || path.indexOf('/more/') === 0 ||
               path === '/settings' || path.indexOf('/settings/') === 0 ||
               path === '/profile' || path.indexOf('/profile/') === 0 ||
               path === '/account' || path.indexOf('/account/') === 0 ||
               hash.indexOf('/more') !== -1 || hash.indexOf('/settings') !== -1 ||
               hash.indexOf('/profile') !== -1 || hash.indexOf('/account') !== -1;
      }

      function performLogout() {
        // 1. Clear ALL auth-related localStorage keys
        var authKeys = [
          'base44_access_token', 'base44_refresh_token', 'base44_auth_token',
          'base44_user', 'access_token', 'refresh_token', 'token',
          'CapacitorStorage.aa_token', 'CapacitorStorage.base44_auth_token'
        ];
        authKeys.forEach(function(key) {
          try { localStorage.removeItem(key); } catch(e) {}
        });

        // 2. Clear sessionStorage recovery keys
        try {
          var ssKeys = [];
          for (var i = 0; i < sessionStorage.length; i++) {
            var k = sessionStorage.key(i);
            if (k && (k.indexOf('aa-') === 0 || k.indexOf('aa_') === 0)) {
              ssKeys.push(k);
            }
          }
          ssKeys.forEach(function(k) { sessionStorage.removeItem(k); });
        } catch(e) {}

        // 3. Tell native side to clear cookies + WKWebView data + navigate to login
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.aaLogout) {
          window.webkit.messageHandlers.aaLogout.postMessage('logout');
        } else {
          // Fallback for web: just navigate to login
          window.location.href = '/login';
        }
      }

      function showLogoutConfirmation() {
        // Remove any existing confirmation
        var existing = document.getElementById('aa-logout-confirm-overlay');
        if (existing) { existing.remove(); return; }

        var overlay = document.createElement('div');
        overlay.id = 'aa-logout-confirm-overlay';

        var card = document.createElement('div');
        card.id = 'aa-logout-confirm-card';

        var heading = document.createElement('h3');
        heading.textContent = 'Log Out';
        card.appendChild(heading);

        var desc = document.createElement('p');
        desc.textContent = 'Are you sure you want to log out? You will need to sign in again to access your account.';
        card.appendChild(desc);

        var yesBtn = document.createElement('button');
        yesBtn.className = 'aa-logout-confirm-btn aa-logout-confirm-yes';
        yesBtn.id = 'aa-logout-yes';
        yesBtn.textContent = 'Log Out';
        card.appendChild(yesBtn);

        var cancelBtn = document.createElement('button');
        cancelBtn.className = 'aa-logout-confirm-btn aa-logout-confirm-cancel';
        cancelBtn.id = 'aa-logout-cancel';
        cancelBtn.textContent = 'Cancel';
        card.appendChild(cancelBtn);

        overlay.appendChild(card);
        document.body.appendChild(overlay);

        yesBtn.addEventListener('click', function() {
          overlay.remove();
          performLogout();
        });
        cancelBtn.addEventListener('click', function() {
          overlay.remove();
        });
        // Dismiss on background tap
        overlay.addEventListener('click', function(e) {
          if (e.target === overlay) overlay.remove();
        });
      }

      function injectLogoutButton() {
        if (!isMoreOrSettingsRoute()) {
          // Remove logout button if navigated away
          var stale = document.getElementById('aa-logout-section');
          if (stale) stale.remove();
          return;
        }

        // Don't inject twice
        if (document.getElementById('aa-logout-section')) return;

        var root = document.getElementById('root');
        if (!root) return;

        // Find the best container to append to
        var container = root.querySelector('main') ||
                        root.querySelector('[class*="scroll"]') ||
                        root.querySelector('[class*="content"]') ||
                        root;

        // Wait until the page has some content (avoid injecting into loading state)
        var text = (container.innerText || '').trim();
        if (text.length < 10) return;

        var section = document.createElement('div');
        section.id = 'aa-logout-section';

        var btn = document.createElement('button');
        btn.id = 'aa-logout-btn';

        // Logout icon (door-arrow SVG)
        var svgNS = 'http://www.w3.org/2000/svg';
        var svg = document.createElementNS(svgNS, 'svg');
        svg.setAttribute('width', '18');
        svg.setAttribute('height', '18');
        svg.setAttribute('viewBox', '0 0 24 24');
        svg.setAttribute('fill', 'none');
        svg.setAttribute('stroke', 'currentColor');
        svg.setAttribute('stroke-width', '2');
        svg.setAttribute('stroke-linecap', 'round');
        svg.setAttribute('stroke-linejoin', 'round');

        var path1 = document.createElementNS(svgNS, 'path');
        path1.setAttribute('d', 'M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4');
        svg.appendChild(path1);

        var poly = document.createElementNS(svgNS, 'polyline');
        poly.setAttribute('points', '16 17 21 12 16 7');
        svg.appendChild(poly);

        var line = document.createElementNS(svgNS, 'line');
        line.setAttribute('x1', '21');
        line.setAttribute('y1', '12');
        line.setAttribute('x2', '9');
        line.setAttribute('y2', '12');
        svg.appendChild(line);

        btn.appendChild(svg);

        var label = document.createElement('span');
        label.textContent = 'Log Out';
        btn.appendChild(label);

        section.appendChild(btn);
        container.appendChild(section);

        btn.addEventListener('click', function(e) {
          e.preventDefault();
          e.stopPropagation();
          showLogoutConfirmation();
        });
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
          interceptGoogleAuth();
          injectLogoutButton();
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

      // Periodic checks (blank screen + prayer routes) — every 3s for first 30s
      var blankCheckCount = 0;
      function scheduleBlankChecks() {
        blankCheckCount = 0;
        blankConsecutiveHits = 0;
        prayerBlankHits = 0;
        var interval = setInterval(function() {
          blankCheckCount++;
          detectBlankScreen();
          monitorPrayerRoutes();
          if (blankCheckCount >= 10) clearInterval(interval);
        }, 3000);
      }

      // SPA navigation hooks
      window.addEventListener('popstate', function() {
        setTimeout(runAllPatches, 300);
        scheduleBlankChecks();
      });

      window.addEventListener('hashchange', function() {
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
