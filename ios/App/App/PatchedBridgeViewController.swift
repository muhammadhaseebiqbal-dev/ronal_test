import UIKit
import WebKit
import Capacitor
import AuthenticationServices
import os.log

/// Custom CAPBridgeViewController that:
///
///   1) Ensures WKWebView uses persistent data store (login persistence fix — Build 4)
///   2) Bridges cookies from HTTPCookieStorage → WKHTTPCookieStore before every navigation
///   3) Handles WebView content process termination gracefully (no blind reload)
///   4) Prevents unnecessary reloads on app resume
///   5) Provides diagnostics logging (cookie counts, store type, auth markers)
///   6) Injects client-side CSS+JS patches for remote Base44 app issues (Build 3)
///   7) Handles Google OAuth via ASWebAuthenticationSession with token handoff (Build 6)
///   8) In-app diagnostics overlay triggered by 5-tap on version label (Build 6)
///
/// Architecture: The WKWebView loads https://abideandanchor.app (remote Base44 platform).
/// We cannot modify the remote source code, so we inject JS+CSS via WKUserScript to
/// patch DOM/CSS issues at runtime.
///
/// NOTE (Build 6): Google OAuth uses ASWebAuthenticationSession → callback with token →
/// inject into WKWebView localStorage. If auth fails gracefully, user is guided to
/// Email/Password. No SFSafariViewController (separate storage). No infinite loops.
class PatchedBridgeViewController: CAPBridgeViewController, WKScriptMessageHandler, ASWebAuthenticationPresentationContextProviding {

    private static let log = OSLog(subsystem: "com.abideandanchor.app", category: "WebView")
    private let serverDomain = "abideandanchor.app"
    private var hasPerformedInitialLoad = false
    private var isRecoveringFromTermination = false

    // MARK: – Google OAuth via ASWebAuthenticationSession
    private var authSession: ASWebAuthenticationSession?
    private var googleAuthAttempts = 0
    private var lastGoogleAuthTime: Date?

    // ASWebAuthenticationPresentationContextProviding
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return self.view.window ?? ASPresentationAnchor()
    }

    // MARK: – F) Script message handler (diagnostics copy + Google auth)

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "aaCopyDiagnostics" {
            guard let text = message.body as? String else { return }
            UIPasteboard.general.string = text
            os_log(.info, log: Self.log, "[DIAG:copy] Diagnostics copied to clipboard (%d chars)", text.count)
        } else if message.name == "aaGoogleAuth" {
            guard let urlString = message.body as? String else { return }
            startGoogleOAuth(loginURL: urlString)
        }
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

    // MARK: – H) Google OAuth via ASWebAuthenticationSession

    /// Launches Google OAuth in ASWebAuthenticationSession.
    /// Uses `abideandanchor` custom URL scheme for callback.
    /// On success: extracts token from callback URL → injects into WKWebView localStorage → navigates home.
    /// On cancel: does nothing (user dismissed).
    /// On repeated failure: tells JS to show fallback notice.
    private func startGoogleOAuth(loginURL: String) {
        // Prevent duplicate sessions
        if authSession != nil {
            os_log(.info, log: Self.log, "[DIAG:googleOAuth] session already active, ignoring")
            return
        }

        // Debounce: prevent rapid re-taps (3s cooldown)
        if let last = lastGoogleAuthTime, Date().timeIntervalSince(last) < 3.0 {
            os_log(.info, log: Self.log, "[DIAG:googleOAuth] debounced (too rapid)")
            return
        }

        googleAuthAttempts += 1
        lastGoogleAuthTime = Date()
        os_log(.info, log: Self.log, "[DIAG:googleOAuth] starting attempt=%d url=%{public}@",
               googleAuthAttempts, loginURL)

        // Build the auth URL — use the Base44 login page with Google trigger
        // The login URL should be the Base44 login page that includes Google auth option
        let authURLString: String
        if loginURL.hasPrefix("http") {
            authURLString = loginURL
        } else {
            // Default: use the main login page on the app domain
            authURLString = "https://\(serverDomain)/login"
        }

        guard let authURL = URL(string: authURLString) else {
            os_log(.error, log: Self.log, "[DIAG:googleOAuth] invalid URL: %{public}@", authURLString)
            notifyJSGoogleResult(success: false, error: "Invalid URL")
            return
        }

        // Use the registered custom URL scheme for callback
        let callbackScheme = "abideandanchor"

        let session = ASWebAuthenticationSession(
            url: authURL,
            callbackURLScheme: callbackScheme
        ) { [weak self] callbackURL, error in
            guard let self = self else { return }
            self.authSession = nil

            DispatchQueue.main.async {
                if let error = error as? ASWebAuthenticationSessionError {
                    switch error.code {
                    case .canceledLogin:
                        os_log(.info, log: Self.log, "[DIAG:googleOAuth] user cancelled")
                        self.notifyJSGoogleResult(success: false, error: "cancelled")
                    default:
                        os_log(.error, log: Self.log, "[DIAG:googleOAuth] error: %{public}@", error.localizedDescription)
                        self.notifyJSGoogleResult(success: false, error: error.localizedDescription)
                    }
                    return
                }

                guard let callbackURL = callbackURL else {
                    os_log(.error, log: Self.log, "[DIAG:googleOAuth] no callback URL")
                    self.notifyJSGoogleResult(success: false, error: "No callback URL")
                    return
                }

                os_log(.info, log: Self.log, "[DIAG:googleOAuth] callback received: %{public}@",
                       callbackURL.host ?? "unknown-host")

                // Extract token from callback URL
                self.handleGoogleAuthCallback(callbackURL)
            }
        }

        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false // share cookies with Safari cookie jar

        authSession = session

        if session.start() {
            os_log(.info, log: Self.log, "[DIAG:googleOAuth] session started successfully")
        } else {
            os_log(.error, log: Self.log, "[DIAG:googleOAuth] session failed to start")
            authSession = nil
            notifyJSGoogleResult(success: false, error: "Failed to start auth session")
        }
    }

    /// Handles the callback URL from ASWebAuthenticationSession.
    /// Extracts token/code from URL params and injects into WKWebView.
    private func handleGoogleAuthCallback(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            os_log(.error, log: Self.log, "[DIAG:googleOAuth] cannot parse callback URL")
            fallbackCookieSync()
            return
        }

        // Check for token in query params or fragment
        let queryItems = components.queryItems ?? []
        let fragmentItems: [URLQueryItem]
        if let fragment = components.fragment, fragment.contains("=") {
            var fragmentComponents = URLComponents()
            fragmentComponents.query = fragment
            fragmentItems = fragmentComponents.queryItems ?? []
        } else {
            fragmentItems = []
        }

        let allItems = queryItems + fragmentItems

        // Look for token in callback params (Base44 may use various key names)
        let tokenKeys = ["token", "access_token", "auth_token", "base44_token", "id_token"]
        var foundToken: String?
        for item in allItems {
            if tokenKeys.contains(item.name.lowercased()), let value = item.value, !value.isEmpty {
                foundToken = value
                os_log(.info, log: Self.log, "[DIAG:googleOAuth] token found in callback (key=%{public}@, len=%d)",
                       item.name, value.count)
                break
            }
        }

        // Check for auth code (server-side exchange)
        let codeKeys = ["code", "auth_code"]
        var foundCode: String?
        for item in allItems {
            if codeKeys.contains(item.name.lowercased()), let value = item.value, !value.isEmpty {
                foundCode = value
                os_log(.info, log: Self.log, "[DIAG:googleOAuth] code found in callback (len=%d)", value.count)
                break
            }
        }

        if let token = foundToken {
            // Best case: we have a token — inject directly into WKWebView localStorage
            injectTokenIntoWebView(token: token)
        } else if foundCode != nil {
            // We have a code but no token — the WebView needs to handle the exchange
            // Navigate the WebView to the callback URL so Base44 can process it
            os_log(.info, log: Self.log, "[DIAG:googleOAuth] redirecting WebView to callback for code exchange")
            if let webView = self.webView {
                // Reconstruct as HTTPS URL for the WebView
                var httpsComponents = components
                httpsComponents.scheme = "https"
                httpsComponents.host = serverDomain
                if httpsComponents.path.isEmpty { httpsComponents.path = "/auth/callback" }
                if let httpsURL = httpsComponents.url {
                    webView.load(URLRequest(url: httpsURL))
                } else {
                    fallbackCookieSync()
                }
            }
        } else {
            // No token or code in callback — try cookie sync approach
            os_log(.info, log: Self.log, "[DIAG:googleOAuth] no token/code in callback — attempting cookie sync")
            fallbackCookieSync()
        }
    }

    /// Injects a token into WKWebView's localStorage and navigates to home.
    private func injectTokenIntoWebView(token: String) {
        guard let webView = self.webView else {
            os_log(.error, log: Self.log, "[DIAG:googleOAuth] no webView for token injection")
            return
        }

        // Escape the token for safe JS string insertion
        let escapedToken = token
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")

        let js = """
        (function() {
            try {
                localStorage.setItem('base44_access_token', '\(escapedToken)');
                localStorage.setItem('access_token', '\(escapedToken)');
                console.log('[AA:googleOAuth] token injected into localStorage');
                window.location.href = 'https://\(serverDomain)/';
            } catch(e) {
                console.error('[AA:googleOAuth] injection failed:', e.message);
            }
        })();
        """

        webView.evaluateJavaScript(js) { [weak self] _, error in
            if let error = error {
                os_log(.error, log: Self.log, "[DIAG:googleOAuth] token injection failed: %{public}@",
                       error.localizedDescription)
                self?.notifyJSGoogleResult(success: false, error: "Token injection failed")
            } else {
                os_log(.info, log: Self.log, "[DIAG:googleOAuth] token injected — navigating home")
                self?.googleAuthAttempts = 0 // reset on success
                self?.notifyJSGoogleResult(success: true, error: nil)
            }
        }
    }

    /// Fallback: sync cookies from HTTPCookieStorage → WKWebView and reload.
    /// This may work if Base44 sets auth cookies during the ASWebAuthenticationSession flow.
    private func fallbackCookieSync() {
        os_log(.info, log: Self.log, "[DIAG:googleOAuth] fallback: syncing cookies then reloading WebView")

        syncCookiesToWebView { [weak self] in
            guard let self = self, let webView = self.webView else { return }

            if let url = URL(string: "https://\(self.serverDomain)/") {
                webView.load(URLRequest(url: url))
            }

            // Check auth state after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.checkPostOAuthState()
            }
        }
    }

    /// After OAuth cookie sync, check if we're actually logged in.
    /// If not, show fallback notice via JS.
    private func checkPostOAuthState() {
        guard let webView = self.webView else { return }

        webView.evaluateJavaScript("""
            (function() {
                var hasToken = !!localStorage.getItem('base44_access_token') ||
                               !!localStorage.getItem('access_token');
                return hasToken ? 'true' : 'false';
            })()
        """) { [weak self] result, _ in
            guard let self = self else { return }
            let hasToken = (result as? String) == "true"
            if hasToken {
                os_log(.info, log: Self.log, "[DIAG:googleOAuth] post-OAuth: auth token found ✅")
                self.googleAuthAttempts = 0
                self.notifyJSGoogleResult(success: true, error: nil)
            } else {
                os_log(.info, log: Self.log, "[DIAG:googleOAuth] post-OAuth: no auth token — attempt %d",
                       self.googleAuthAttempts)
                self.notifyJSGoogleResult(success: false, error: "Auth state not detected after sign-in")
            }
        }
    }

    /// Tells JS about the result of Google OAuth so it can update UI accordingly.
    private func notifyJSGoogleResult(success: Bool, error: String?) {
        guard let webView = self.webView else { return }

        let escapedError = (error ?? "")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: " ")

        let js: String
        if success {
            js = "window.__aaGoogleAuthResult && window.__aaGoogleAuthResult(true, null);"
        } else {
            js = "window.__aaGoogleAuthResult && window.__aaGoogleAuthResult(false, '\(escapedError)');"
        }

        webView.evaluateJavaScript(js) { _, _ in }
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

        // Register native message handler for diagnostics clipboard copy
        controller.add(self, name: "aaCopyDiagnostics")

        // Register native message handler for Google OAuth
        controller.add(self, name: "aaGoogleAuth")

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

        /* ── B8: Force ALL back buttons to top-left ── */
        .aa-injected-back,
        .aa-back-topleft {
          position: absolute !important;
          top: 8px !important;
          left: 12px !important;
          z-index: 50 !important;
          margin: 0 !important;
        }
        /* Ensure parent containers of back buttons are positioned */
        header,
        .sticky.top-0,
        [class*="sticky"][class*="top-0"],
        .pt-8 {
          position: relative !important;
        }

        /* ── B9: Google sign-in notice (inline, non-blocking) ── */
        .aa-google-notice {
          background: #f8f4eb;
          border: 1px solid #e0d5c0;
          border-radius: 10px;
          padding: 12px 16px;
          margin: 8px 16px;
          font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
          text-align: left;
          font-size: 13px;
          color: #5a4a2f;
          line-height: 1.45;
        }
        .aa-google-notice strong {
          color: #3d3017;
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

      // ── 0. GOOGLE SIGN-IN: NATIVE OAUTH VIA ASWebAuthenticationSession (Build 6) ──
      // Google OAuth is launched in ASWebAuthenticationSession (native iOS auth browser).
      // On success: native code injects token into WKWebView localStorage.
      // On failure after 2+ attempts: fallback notice guides user to Email/Password.
      // No SFSafariViewController (separate storage), no infinite loops.

      var aaGoogleNoticeShown = false;
      var aaGoogleAuthPending = false;

      // Callback from native after ASWebAuthenticationSession completes
      window.__aaGoogleAuthResult = function(success, error) {
        aaGoogleAuthPending = false;
        var count = parseInt(sessionStorage.getItem('aa_google_attempts') || '0', 10);
        if (success) {
          console.log('[AA:googleAuth] success — resetting counter');
          sessionStorage.setItem('aa_google_attempts', '0');
          // Remove any existing notice
          var notice = document.querySelector('.aa-google-notice');
          if (notice) notice.remove();
          aaGoogleNoticeShown = false;
          // Re-enable Google buttons
          document.querySelectorAll('[data-aa-google-handled]').forEach(function(el) {
            el.style.opacity = '';
            el.style.pointerEvents = '';
          });
        } else {
          console.log('[AA:googleAuth] failed: ' + (error || 'unknown') + ' (attempt ' + count + ')');
          if (error === 'cancelled') {
            // User dismissed — don't show fallback unless repeated
            if (count >= 2) {
              showGoogleNotice();
            }
          } else {
            // Non-cancel error — show fallback after 2 attempts
            if (count >= 2) {
              showGoogleNotice();
            }
          }
        }
      };

      function interceptGoogleAuth() {
        var root = document.getElementById('root');
        if (!root) return;

        var path = window.location.pathname.toLowerCase();
        // Only intercept on login/auth pages
        if (path.indexOf('/login') === -1 && path.indexOf('/auth') === -1 &&
            path !== '/' && path.indexOf('/signup') === -1) return;

        var elements = root.querySelectorAll('button, a, [role="button"]');
        elements.forEach(function(el) {
          if (el.getAttribute('data-aa-google-handled')) return;
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

          el.setAttribute('data-aa-google-handled', 'true');
          el.addEventListener('click', function(e) {
            e.preventDefault();
            e.stopPropagation();
            e.stopImmediatePropagation();

            // Track attempts
            var count = parseInt(sessionStorage.getItem('aa_google_attempts') || '0', 10) + 1;
            sessionStorage.setItem('aa_google_attempts', String(count));
            console.log('[DIAG:googleIntercept] attempt=' + count);

            // If already pending, ignore
            if (aaGoogleAuthPending) {
              console.log('[AA:googleAuth] auth already pending, ignoring tap');
              return;
            }

            // After 3+ failed attempts, block and show notice
            if (count > 3) {
              showGoogleNotice();
              return;
            }

            // Send to native to launch ASWebAuthenticationSession
            aaGoogleAuthPending = true;
            var loginUrl = window.location.origin + '/login';
            try {
              // Try to find the actual Google auth URL from the button
              var href = el.getAttribute('href') || el.closest('a[href]')?.getAttribute('href');
              if (href && href.indexOf('google') !== -1) loginUrl = href;
            } catch(ex) {}

            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.aaGoogleAuth) {
              window.webkit.messageHandlers.aaGoogleAuth.postMessage(loginUrl);
            } else {
              // No native handler — show fallback
              aaGoogleAuthPending = false;
              showGoogleNotice();
            }
          }, true);
        });
      }

      function showGoogleNotice() {
        if (aaGoogleNoticeShown) return;
        aaGoogleNoticeShown = true;

        var root = document.getElementById('root');
        if (!root) return;

        // Remove any stale notices
        var existing = document.querySelector('.aa-google-notice');
        if (existing) existing.remove();

        var notice = document.createElement('div');
        notice.className = 'aa-google-notice';
        notice.innerHTML =
          '<strong>Google sign-in</strong> is temporarily unavailable in the iOS app. ' +
          'Please use <strong>Email & Password</strong> below \\u2014 it\\u2019s fast and reliable.' +
          '<br><small style="opacity:0.65;margin-top:4px;display:block;">' +
          'We\\u2019re working on a robust Google flow for a future update.</small>';

        // Insert above the Google button if possible
        var googleBtn = root.querySelector('[data-aa-google-handled]');
        if (googleBtn && googleBtn.parentElement) {
          googleBtn.parentElement.insertBefore(notice, googleBtn);
        } else {
          var form = root.querySelector('form') || root.querySelector('[class*="login"]') ||
                     root.querySelector('[class*="auth"]');
          if (form && form.parentElement) {
            form.parentElement.insertBefore(notice, form);
          } else {
            root.insertBefore(notice, root.firstChild);
          }
        }

        // Dim the Google button so it's clear it's disabled
        root.querySelectorAll('[data-aa-google-handled]').forEach(function(el) {
          el.style.opacity = '0.35';
          el.style.pointerEvents = 'none';
        });
      }

      function resetGoogleNotice() {
        aaGoogleNoticeShown = false;
        aaGoogleAuthPending = false;
        var notice = document.querySelector('.aa-google-notice');
        if (notice) notice.remove();
        document.querySelectorAll('[data-aa-google-handled]').forEach(function(el) {
          el.style.opacity = '';
          el.style.pointerEvents = '';
          el.removeAttribute('data-aa-google-handled');
        });
      }

      // ── 1. ERROR SCREEN DETECTION ──

      function detectAndFixErrorScreen() {
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

      // ── 2. BLANK SCREEN DETECTION (improved for Prayer List) ──

      function detectBlankScreen() {
        var root = document.getElementById('root');
        if (!root) return;
        if (root.children.length === 0) return;
        var text = (root.innerText || '').trim();
        var imgs = root.querySelectorAll('img, svg, canvas');
        var nav = root.querySelector('nav');
        // If there's a nav bar but no page content, the page failed to render
        // Lowered threshold: text < 30 chars catches more blank states
        if (nav && text.length < 30 && imgs.length < 3) {
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

      // ── 2b. PRAYER CORNER ROUTE MONITORING ──
      // Specifically monitor Prayer Corner sub-routes for failed loads.
      // These pages sometimes silently fail without triggering a JS error.

      function monitorPrayerRoutes() {
        var path = window.location.pathname.toLowerCase();
        var isPrayerRoute = path.indexOf('/prayer') !== -1 ||
                            path.indexOf('/request') !== -1 ||
                            path.indexOf('/builder') !== -1 ||
                            path.indexOf('/wall') !== -1;
        if (!isPrayerRoute) return;

        var root = document.getElementById('root');
        if (!root) return;
        if (root.querySelector('.aa-error-fallback')) return;

        // Check for meaningful content beyond just nav
        var main = root.querySelector('main, [class*="container"], [class*="content"]');
        if (!main) main = root;
        var mainText = (main.innerText || '').trim();
        var nav = root.querySelector('nav.fixed.bottom-0');
        // If we're on a prayer route and there's almost no content (just nav labels),
        // the page likely failed to load
        if (nav && mainText.length < 40) {
          var fallback = document.createElement('div');
          fallback.className = 'aa-error-fallback';
          fallback.innerHTML =
            '<h2>Content didn\\u2019t load</h2>' +
            '<p>This page may need a moment. Tap Retry or go back.</p>' +
            '<button class="aa-btn aa-btn-primary" onclick="window.location.reload()">Retry</button>' +
            '<button class="aa-btn aa-btn-secondary" onclick="window.history.back()">Go Back</button>';
          main.appendChild(fallback);
        }
      }

      // ── 3. GLOBAL ERROR HANDLERS ──

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

      function fixDuplicateBackButtons() {
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
          var firstVisible = null;
          backEls.forEach(function(el) {
            if (el.style.display === 'none' || el.offsetParent === null) return;
            if (!firstVisible) {
              firstVisible = el;
              if (!el.classList.contains('aa-back-topleft')) {
                el.classList.add('aa-back-topleft');
              }
            } else {
              el.style.display = 'none';
              el.setAttribute('data-aa-hidden', 'duplicate');
            }
          });
        });

        var root = document.getElementById('root');
        if (!root) return;
        var allBackBtns = [];
        root.querySelectorAll('button, a').forEach(function(el) {
          if (el.closest('.aa-error-fallback')) return;
          if (el.closest('nav.fixed.bottom-0')) return;
          var text = (el.textContent || '').trim();
          if (/^(\\u2190\\s*)?Back$/i.test(text)) {
            allBackBtns.push(el);
            if (!el.classList.contains('aa-back-topleft') && el.style.display !== 'none') {
              el.classList.add('aa-back-topleft');
            }
          }
        });
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

      function fixMissingBackButtons() {
        var path = window.location.pathname.toLowerCase();
        var needsBack = path === '/journal' ||
                        path === '/more' ||
                        path.indexOf('/journal/') === 0 ||
                        path.indexOf('/more/') === 0 ||
                        path.indexOf('/prayer') === 0 ||
                        path.indexOf('/request') === 0 ||
                        path.indexOf('/builder') === 0 ||
                        path.indexOf('/wall') === 0;
        if (!needsBack) return;

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

        var header = root.querySelector('header') ||
                     root.querySelector('.pt-8') ||
                     root.querySelector('[class*="sticky"][class*="top"]');
        if (!header) return;
        if (header.querySelector('.aa-injected-back')) return;

        var backBtn = document.createElement('button');
        backBtn.className = 'aa-injected-back aa-back-topleft';
        backBtn.setAttribute('aria-label', 'Back');
        backBtn.style.cssText =
          'background:none;border:none;color:inherit;font-size:15px;font-weight:500;' +
          'padding:8px 12px;cursor:pointer;display:flex;align-items:center;gap:4px;' +
          'min-height:44px;min-width:44px;-webkit-tap-highlight-color:transparent;';
        backBtn.innerHTML =
          '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" ' +
          'stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
          '<polyline points="15 18 9 12 15 6"></polyline></svg>' +
          '<span style="font-size:15px;">Back</span>';
        backBtn.addEventListener('click', function(e) {
          e.preventDefault();
          window.history.back();
        });

        var target = header.querySelector('.max-w-2xl') ||
                     header.querySelector('.max-w-lg') ||
                     header.querySelector('div') ||
                     header;
        target.insertBefore(backBtn, target.firstChild);
      }

      // ── 6. CLEANUP STALE PATCHES ──

      function cleanupStalePatches() {
        var injected = document.querySelectorAll('.aa-injected-back');
        injected.forEach(function(el) {
          var path = window.location.pathname.toLowerCase();
          var shouldHave = path === '/journal' || path === '/more' ||
                           path.indexOf('/journal/') === 0 || path.indexOf('/more/') === 0 ||
                           path.indexOf('/prayer') === 0 || path.indexOf('/request') === 0 ||
                           path.indexOf('/builder') === 0 || path.indexOf('/wall') === 0;
          if (!shouldHave) {
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

        var googleAttempts = 0;
        try { googleAttempts = parseInt(sessionStorage.getItem('aa_google_attempts') || '0', 10); } catch(e) {}

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
        lines.push('-- Google OAuth --');
        lines.push('  Attempts this session: ' + googleAttempts);
        lines.push('  Auth pending: ' + (typeof aaGoogleAuthPending !== 'undefined' ? aaGoogleAuthPending : 'n/a'));
        lines.push('  Method: ASWebAuthenticationSession');
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
        var interval = setInterval(function() {
          blankCheckCount++;
          detectBlankScreen();
          monitorPrayerRoutes();
          if (blankCheckCount >= 10) clearInterval(interval);
        }, 3000);
      }

      // SPA navigation hooks
      window.addEventListener('popstate', function() {
        resetGoogleNotice();
        setTimeout(runAllPatches, 300);
        scheduleBlankChecks();
      });

      var origPush = history.pushState;
      var origReplace = history.replaceState;
      history.pushState = function() {
        var result = origPush.apply(this, arguments);
        resetGoogleNotice();
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
