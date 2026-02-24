import UIKit
import WebKit
import Capacitor
import os.log
import StoreKit

// MARK: – StoreKit 2 Manager (Build 10 — IAP Bridge)

/// Manages StoreKit 2 product fetching, purchasing, restoring, and entitlement checking.
/// Companion subscription product IDs are configured in App Store Connect.
@available(iOS 15.0, *)
final class AAStoreManager {

    static let shared = AAStoreManager()

    private static let log = OSLog(subsystem: "com.abideandanchor.app", category: "IAP")

    /// Products available for NEW purchases — Monthly only (yearly + trial removed per Roland 2026-02-23).
    static let purchasableProductIds: Set<String> = [
        "com.abideandanchor.companion.monthly"
    ]

    /// All Companion product IDs for ENTITLEMENT checking (includes yearly for existing subscribers).
    /// Yearly is removed from sale but existing subscriptions remain valid until expiry.
    static let companionProductIds: Set<String> = [
        "com.abideandanchor.companion.monthly",
        "com.abideandanchor.companion.yearly"
    ]

    private var transactionListener: Task<Void, Never>?

    private init() {}

    /// Starts listening for transaction updates (renewals, refunds, revocations).
    /// The callback is invoked on the main actor with the updated companion state.
    func startTransactionListener(onUpdate: @escaping (Bool) -> Void) {
        transactionListener?.cancel()
        transactionListener = Task(priority: .background) {
            for await result in Transaction.updates {
                if case .verified(let transaction) = result {
                    await transaction.finish()
                    os_log(.info, log: Self.log, "[TxnUpdate] productId=%{public}@ revoked=%{public}@",
                           transaction.productID,
                           transaction.revocationDate != nil ? "YES" : "NO")
                    let (isCompanion, _) = await self.checkEntitlements()
                    await MainActor.run { onUpdate(isCompanion) }
                }
            }
        }
    }

    /// Purchase a product by its full product ID.
    /// Returns a tuple: (status, productId, isCompanion, message, jws)
    func purchase(productId: String) async -> (status: String, productId: String?, isCompanion: Bool, message: String?, jws: String?) {
        do {
            let products = try await Product.products(for: [productId])
            guard let product = products.first else {
                os_log(.error, log: Self.log, "[Purchase] Product not found: %{public}@", productId)
                return ("error", nil, false, "Product not found: \(productId)", nil)
            }

            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    let isCompanion = Self.companionProductIds.contains(transaction.productID)
                    let jwsString = verification.jwsRepresentation
                    os_log(.info, log: Self.log, "[Purchase] SUCCESS productId=%{public}@ isCompanion=%{public}@ hasJWS=%{public}@",
                           transaction.productID, isCompanion ? "true" : "false", jwsString.isEmpty ? "false" : "true")
                    return ("success", transaction.productID, isCompanion, nil, jwsString)
                case .unverified(_, let error):
                    os_log(.error, log: Self.log, "[Purchase] Unverified: %{public}@", error.localizedDescription)
                    return ("error", nil, false, "Transaction verification failed", nil)
                }
            case .userCancelled:
                os_log(.info, log: Self.log, "[Purchase] User cancelled")
                return ("cancelled", nil, false, nil, nil)
            case .pending:
                os_log(.info, log: Self.log, "[Purchase] Pending (Ask to Buy or deferred)")
                return ("pending", nil, false, nil, nil)
            @unknown default:
                return ("error", nil, false, "Unknown purchase result", nil)
            }
        } catch {
            os_log(.error, log: Self.log, "[Purchase] Error: %{public}@", error.localizedDescription)
            return ("error", nil, false, error.localizedDescription, nil)
        }
    }

    /// Restore purchases via AppStore.sync() then re-check entitlements.
    /// Returns the JWS from the latest active Companion entitlement for server validation.
    func restorePurchases() async -> (status: String, isCompanion: Bool, restoredProducts: [String], message: String?, jws: String?) {
        do {
            try await AppStore.sync()
            let (isCompanion, products, latestJWS) = await checkEntitlementsWithJWS()
            os_log(.info, log: Self.log, "[Restore] isCompanion=%{public}@ products=%{public}@ hasJWS=%{public}@",
                   isCompanion ? "true" : "false", products.joined(separator: ","), latestJWS != nil ? "true" : "false")
            return ("success", isCompanion, products, nil, latestJWS)
        } catch {
            os_log(.error, log: Self.log, "[Restore] Error: %{public}@", error.localizedDescription)
            return ("error", false, [], error.localizedDescription, nil)
        }
    }

    /// Check current entitlements for active Companion subscriptions.
    func checkEntitlements() async -> (isCompanion: Bool, activeProducts: [String]) {
        var activeProducts: [String] = []
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                guard Self.companionProductIds.contains(transaction.productID) else { continue }
                guard transaction.revocationDate == nil else { continue }
                if let expirationDate = transaction.expirationDate, expirationDate < Date() {
                    continue
                }
                activeProducts.append(transaction.productID)
            }
        }
        return (!activeProducts.isEmpty, activeProducts)
    }

    /// Check entitlements and return JWS from the latest active Companion transaction.
    /// Used for server-side receipt validation during restore.
    func checkEntitlementsWithJWS() async -> (isCompanion: Bool, activeProducts: [String], latestJWS: String?) {
        var activeProducts: [String] = []
        var latestJWS: String? = nil
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                guard Self.companionProductIds.contains(transaction.productID) else { continue }
                guard transaction.revocationDate == nil else { continue }
                if let expirationDate = transaction.expirationDate, expirationDate < Date() {
                    continue
                }
                activeProducts.append(transaction.productID)
                latestJWS = result.jwsRepresentation
            }
        }
        return (!activeProducts.isEmpty, activeProducts, latestJWS)
    }

    deinit {
        transactionListener?.cancel()
    }
}

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
///   9) StoreKit 2 IAP bridge for Companion subscriptions (Build 10)
///  10) Cross-device Companion unlock via server-side receipt validation (Build 11)
///
/// Architecture: The WKWebView loads https://abideandanchor.app (remote Base44 platform).
/// We cannot modify the remote source code, so we inject JS+CSS via WKUserScript to
/// patch DOM/CSS issues at runtime.
///
/// NOTE (Build 6): Google sign-in is hidden on iOS. Roland confirmed Email/Password only.
/// No Base44 subscription, so no Google OAuth flow needed.
class PatchedBridgeViewController: CAPBridgeViewController, WKScriptMessageHandler, WKHTTPCookieStoreObserver {

    private static let log = OSLog(subsystem: "com.abideandanchor.app", category: "WebView")
    private let serverDomain = "abideandanchor.app"
    private var hasPerformedInitialLoad = false
    private var isRecoveringFromTermination = false

    /// UserDefaults key for native token persistence.
    /// This is the ONLY reliable persistence layer on iOS — localStorage can be
    /// cleared by WebKit under storage pressure, but UserDefaults survives everything.
    /// NOTE: src/lib/tokenStorage.js is DEAD CODE in production (remote URL mode).
    /// The WKWebView loads https://abideandanchor.app which has its own JS bundle.
    /// Token sync must happen entirely via native Swift ↔ injected JS.
    private static let tokenDefaultsKey = "com.abideandanchor.authToken"

    /// Shared WKProcessPool — Apple recommends reusing a single process pool
    /// across all WKWebViews to prevent localStorage from being randomly cleared.
    /// See: https://developer.apple.com/forums/thread/751820
    private static let sharedProcessPool = WKProcessPool()

    /// UserDefaults key for Companion subscription state persistence (Build 10).
    /// Survives app restarts. Down-synced to web at document start.
    private static let companionDefaultsKey = "aa_is_companion"

    /// Cloudflare Worker URL for cross-device Companion validation (Build 11).
    /// Deployed by Roland — 2026-02-18.
    private static let companionWorkerURL = "https://companion-validator.abideandanchor.workers.dev"

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

        if message.name == "aaPurchase" {
            handlePurchaseMessage(message)
        }
    }

    // MARK: – IAP Purchase Message Handler (Build 10)

    /// Handles `aaPurchase` messages from web JS.
    /// Payloads:
    ///   { action: "buy", productId: "com.abideandanchor.companion.monthly" }
    ///   { action: "restore" }
    private func handlePurchaseMessage(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else {
            os_log(.error, log: Self.log, "[IAP] Invalid message body")
            sendPurchaseResult(["status": "error", "message": "Invalid message format"])
            return
        }

        os_log(.info, log: Self.log, "[IAP] Received action=%{public}@", action)

        guard #available(iOS 15.0, *) else {
            sendPurchaseResult(["status": "error", "message": "StoreKit 2 requires iOS 15+"])
            return
        }

        switch action {
        case "buy":
            guard let productId = body["productId"] as? String else {
                sendPurchaseResult(["status": "error", "message": "Missing productId"])
                return
            }
            // Validate product ID is one of our purchasable IDs (monthly only)
            guard AAStoreManager.purchasableProductIds.contains(productId) else {
                os_log(.error, log: Self.log, "[IAP] Unknown productId: %{public}@", productId)
                sendPurchaseResult(["status": "error", "message": "Unknown product: \(productId)"])
                return
            }
            Task { @MainActor in
                let result = await AAStoreManager.shared.purchase(productId: productId)
                var payload: [String: Any] = ["status": result.status, "action": "buy"]
                if let pid = result.productId { payload["productId"] = pid }
                payload["isCompanion"] = result.isCompanion
                if let msg = result.message { payload["message"] = msg }

                self.sendPurchaseResult(payload)

                if result.status == "success" {
                    self.persistCompanionState(result.isCompanion)
                    self.refreshWebEntitlements(isCompanion: result.isCompanion)

                    // Build 11: Sync to server for cross-device unlock
                    if let jws = result.jws {
                        self.syncCompanionToServer(jws: jws)
                        // Web refresh happens inside syncCompanionToServer on 200 OK
                    } else {
                        // Build 13: No JWS available — refresh web directly so Base44 re-fetches /User/me
                        self.triggerWebRefreshAfterPurchase()
                    }
                }
            }

        case "restore":
            Task { @MainActor in
                let result = await AAStoreManager.shared.restorePurchases()
                var payload: [String: Any] = [
                    "status": result.status,
                    "isCompanion": result.isCompanion,
                    "action": "restore"
                ]
                if !result.restoredProducts.isEmpty {
                    payload["productId"] = result.restoredProducts.first ?? ""
                }
                if let msg = result.message { payload["message"] = msg }

                self.sendPurchaseResult(payload)
                self.persistCompanionState(result.isCompanion)
                self.refreshWebEntitlements(isCompanion: result.isCompanion)

                // Build 11: Sync to server for cross-device unlock
                if result.isCompanion, let jws = result.jws {
                    self.syncCompanionToServer(jws: jws)
                    // Web refresh happens inside syncCompanionToServer on 200 OK
                } else if result.isCompanion {
                    // Build 13: No JWS available — refresh web directly so Base44 re-fetches /User/me
                    self.triggerWebRefreshAfterPurchase()
                }
            }

        case "recheckEntitlements":
            // Build 16: JS-triggered recheck — cross-verify server claim with local StoreKit.
            // Called when server says not-companion but user was previously companion.
            Task { @MainActor in
                let (storeKitIsCompanion, products) = await AAStoreManager.shared.checkEntitlements()
                os_log(.info, log: Self.log, "[IAP:recheck] StoreKit isCompanion=%{public}@ products=%{public}@",
                       storeKitIsCompanion ? "true" : "false", products.joined(separator: ","))

                self.persistCompanionState(storeKitIsCompanion)
                self.refreshWebEntitlements(isCompanion: storeKitIsCompanion)
                self.pushEntitlementCheckToJS(isCompanion: storeKitIsCompanion, products: products)

                if storeKitIsCompanion {
                    // StoreKit says active — re-sync fresh JWS to server to fix stale expiry
                    let (_, _, latestJWS) = await AAStoreManager.shared.checkEntitlementsWithJWS()
                    if let jws = latestJWS {
                        self.syncCompanionToServer(jws: jws)
                    }
                }
            }

        default:
            os_log(.error, log: Self.log, "[IAP] Unknown action: %{public}@", action)
            sendPurchaseResult(["status": "error", "message": "Unknown action: \(action)"])
        }
    }

    /// Sends a purchase result back to web via JS callback + CustomEvent.
    /// Serializes the payload as JSON and calls window.__aaPurchaseResult + dispatches aa:iap.
    private func sendPurchaseResult(_ result: [String: Any]) {
        guard let webView = self.webView else { return }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: result),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            os_log(.error, log: Self.log, "[IAP] Failed to serialize result to JSON")
            return
        }

        let js = """
        (function() {
            var result = \(jsonString);
            if (typeof window.__aaPurchaseResult === 'function') {
                window.__aaPurchaseResult(result);
            }
            window.dispatchEvent(new CustomEvent('aa:iap', { detail: result }));
        })();
        """

        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                os_log(.error, log: Self.log, "[IAP] JS callback error: %{public}@", error.localizedDescription)
            }
        }
    }

    /// Persists the Companion subscription state in UserDefaults.
    private func persistCompanionState(_ isCompanion: Bool) {
        UserDefaults.standard.set(isCompanion, forKey: Self.companionDefaultsKey)
        os_log(.info, log: Self.log, "[IAP] Persisted aa_is_companion=%{public}@", isCompanion ? "true" : "false")
    }

    /// Triggers web-side entitlement refresh after purchase/restore.
    /// Calls refreshBase44Entitlements() if available, otherwise relies on aa:iap event.
    private func refreshWebEntitlements(isCompanion: Bool) {
        guard let webView = self.webView else { return }
        let js = """
        (function() {
            window.__aaIsCompanion = \(isCompanion ? "true" : "false");
            if (typeof window.refreshBase44Entitlements === 'function') {
                window.refreshBase44Entitlements();
            }
        })();
        """
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                os_log(.error, log: Self.log, "[IAP] Entitlement refresh JS error: %{public}@", error.localizedDescription)
            }
        }
    }

    // MARK: – Build 11: Server-Side Companion Sync

    /// Posts the JWS signed transaction to the Cloudflare Worker for server-side validation.
    /// This enables cross-device Companion unlock (desktop browser, new device, etc.).
    /// Graceful degradation: if this fails, local unlock still works.
    private func syncCompanionToServer(jws: String) {
        guard let authToken = UserDefaults.standard.string(forKey: Self.tokenDefaultsKey),
              !authToken.isEmpty else {
            os_log(.info, log: Self.log, "[ServerSync] No auth token in UserDefaults — skipping server sync")
            return
        }

        let workerURL = Self.companionWorkerURL
        guard !workerURL.contains("YOUR_SUBDOMAIN"),
              let url = URL(string: "\(workerURL)/validate-receipt") else {
            os_log(.info, log: Self.log, "[ServerSync] Worker URL not configured — skipping server sync")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let body: [String: String] = ["jws": jws, "authToken": authToken]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            os_log(.error, log: Self.log, "[ServerSync] Failed to serialize request body")
            return
        }
        request.httpBody = bodyData

        os_log(.info, log: Self.log, "[ServerSync] Posting JWS to Worker for server-side validation...")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                os_log(.error, log: Self.log, "[ServerSync] Network error: %{public}@", error.localizedDescription)
                DispatchQueue.main.async { self?.pushWorkerResponseToJS(endpoint: "/validate-receipt", statusCode: 0, error: error.localizedDescription) }
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else { return }
            let statusCode = httpResponse.statusCode

            if let data = data, let responseStr = String(data: data, encoding: .utf8) {
                os_log(.info, log: Self.log, "[ServerSync] Response %d: %{public}@", statusCode, responseStr)
            } else {
                os_log(.info, log: Self.log, "[ServerSync] Response %d (no body)", statusCode)
            }
            DispatchQueue.main.async {
                self?.pushWorkerResponseToJS(endpoint: "/validate-receipt", statusCode: statusCode, error: nil)
                // Build 13: Trigger web refresh after successful server sync so Base44 re-fetches /User/me
                if statusCode == 200 {
                    self?.triggerWebRefreshAfterPurchase()
                }
            }
        }.resume()
    }

    /// Forces the WebView to reload so the Base44 React app re-fetches /User/me
    /// and immediately reflects the updated Companion subscription status.
    /// Uses native WKWebView.reloadFromOrigin() (Apple docs: "performs end-to-end
    /// revalidation of the content using cache-validating conditionals") instead of
    /// JS window.location.reload() — more reliable and bypasses cache properly.
    /// Called after successful purchase/restore + server sync.
    private func triggerWebRefreshAfterPurchase() {
        DispatchQueue.main.async {
            if let nav = self.webView?.reloadFromOrigin() {
                os_log(.info, log: Self.log, "[DIAG:iap] Successfully triggered web refresh after purchase (navigation: %{public}@)", String(describing: nav))
            } else {
                os_log(.error, log: Self.log, "[DIAG:iap] Failed to trigger web refresh — webView or reload returned nil")
            }
        }
    }

    /// Checks companion status from the server (Build 11 — cross-device sync).
    /// Called on cold boot and foreground resume to catch server-side changes
    /// (e.g., subscription cancelled/refunded that local cache doesn't know about).
    private func checkCompanionOnServer() {
        guard let authToken = UserDefaults.standard.string(forKey: Self.tokenDefaultsKey),
              !authToken.isEmpty else {
            os_log(.info, log: Self.log, "[ServerCheck] No auth token — skipping server companion check")
            return
        }

        let workerURL = Self.companionWorkerURL
        guard !workerURL.contains("YOUR_SUBDOMAIN"),
              let url = URL(string: "\(workerURL)/check-companion") else {
            return // Worker not configured yet — silently skip
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            if let error = error {
                os_log(.error, log: Self.log, "[ServerCheck] Error: %{public}@", error.localizedDescription)
                DispatchQueue.main.async { self.pushWorkerResponseToJS(endpoint: "/check-companion", statusCode: 0, error: error.localizedDescription) }
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async { self.pushWorkerResponseToJS(endpoint: "/check-companion", statusCode: statusCode, error: "Invalid response") }
                return
            }

            let serverIsCompanion = json["isCompanion"] as? Bool ?? false
            let localIsCompanion = UserDefaults.standard.bool(forKey: Self.companionDefaultsKey)

            DispatchQueue.main.async { self.pushWorkerResponseToJS(endpoint: "/check-companion", statusCode: statusCode, error: nil) }

            if serverIsCompanion != localIsCompanion {
                os_log(.info, log: Self.log, "[ServerCheck] Server companion=%{public}@ differs from local=%{public}@ — checking StoreKit",
                       serverIsCompanion ? "true" : "false", localIsCompanion ? "true" : "false")

                // Build 16: Before downgrading from companion → non-companion,
                // cross-check local StoreKit entitlements. If StoreKit says user has
                // an active subscription, trust StoreKit over the server.
                // The server's companion_expires_at can be stale (doesn't track auto-renewals).
                if !serverIsCompanion && localIsCompanion {
                    if #available(iOS 15.0, *) {
                        Task {
                            let (storeKitIsCompanion, products) = await AAStoreManager.shared.checkEntitlements()
                            os_log(.info, log: Self.log, "[ServerCheck] StoreKit cross-check: isCompanion=%{public}@ products=%{public}@",
                                   storeKitIsCompanion ? "true" : "false", products.joined(separator: ","))
                            if storeKitIsCompanion {
                                // StoreKit says active — server is wrong (stale expiry). Keep local state.
                                // Also re-sync to server with fresh JWS.
                                os_log(.info, log: Self.log, "[ServerCheck] StoreKit active — ignoring server downgrade, re-syncing JWS")
                                let (_, _, latestJWS) = await AAStoreManager.shared.checkEntitlementsWithJWS()
                                if let jws = latestJWS {
                                    await MainActor.run { self.syncCompanionToServer(jws: jws) }
                                }
                            } else {
                                // StoreKit also says not subscribed — genuinely lost subscription.
                                os_log(.info, log: Self.log, "[ServerCheck] StoreKit also not subscribed — updating local to non-companion")
                                await MainActor.run {
                                    self.persistCompanionState(false)
                                    self.refreshWebEntitlements(isCompanion: false)
                                }
                            }
                        }
                    }
                } else {
                    // Server says companion, local says not — upgrade (server has newer info)
                    DispatchQueue.main.async {
                        self.persistCompanionState(serverIsCompanion)
                        self.refreshWebEntitlements(isCompanion: serverIsCompanion)
                    }
                }
            } else {
                os_log(.info, log: Self.log, "[ServerCheck] Server companion=%{public}@ matches local", serverIsCompanion ? "true" : "false")
            }
        }.resume()
    }

    // MARK: – Build 12: Push diagnostics to JS

    /// Pushes entitlement check results to JS for diagnostics (Build 12).
    private func pushEntitlementCheckToJS(isCompanion: Bool, products: [String]) {
        guard let webView = self.webView else { return }
        let timeStr = ISO8601DateFormatter().string(from: Date())
        let productsStr = products.joined(separator: ",")
        let js = """
        window.__aaLastEntitlementCheck = {
          time: '\(timeStr)',
          isCompanion: \(isCompanion ? "true" : "false"),
          products: '\(productsStr)'
        };
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Pushes worker response details to JS for diagnostics (Build 12).
    private func pushWorkerResponseToJS(endpoint: String, statusCode: Int, error: String?) {
        guard let webView = self.webView else { return }
        let timeStr = ISO8601DateFormatter().string(from: Date())
        let safeError = (error ?? "").replacingOccurrences(of: "'", with: "\\'")
        let js = """
        window.__aaLastWorkerResponse = {
          endpoint: '\(endpoint)',
          statusCode: \(statusCode),
          time: '\(timeStr)',
          error: \(error != nil ? "'\(safeError)'" : "null")
        };
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
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

        // Clear token from UserDefaults (native persistence layer)
        clearTokenFromUserDefaults()

        // Clear companion subscription state (Build 10)
        UserDefaults.standard.removeObject(forKey: Self.companionDefaultsKey)

        logDiagnostics(event: "logout")
    }

    // MARK: – Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        injectPatches()
        injectNativeDiagnostics()
        setupLifecycleObservers()
        startIAPTransactionListener()
        logDiagnostics(event: "coldBoot")

        // Check entitlements on cold boot and persist state
        if #available(iOS 15.0, *) {
            Task { @MainActor in
                let (isCompanion, activeProducts) = await AAStoreManager.shared.checkEntitlements()
                self.persistCompanionState(isCompanion)
                self.pushEntitlementCheckToJS(isCompanion: isCompanion, products: activeProducts)
            }
        }

        // Build 11: Also check server-side companion status (catches remote changes)
        checkCompanionOnServer()
    }

    // MARK: – IAP Transaction Listener (Build 10)

    /// Starts listening for StoreKit 2 transaction updates (renewals, refunds, etc.)
    /// Updates entitlement state and notifies web when changes occur.
    private func startIAPTransactionListener() {
        guard #available(iOS 15.0, *) else { return }
        AAStoreManager.shared.startTransactionListener { [weak self] isCompanion in
            guard let self = self else { return }
            self.persistCompanionState(isCompanion)
            self.refreshWebEntitlements(isCompanion: isCompanion)
            self.sendPurchaseResult([
                "status": "success",
                "isCompanion": isCompanion,
                "source": "transactionUpdate"
            ])
        }
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

        // Apple recommends sharing a single WKProcessPool across all WKWebViews
        // to prevent localStorage from being randomly cleared (iOS 17.4+ issue).
        // See: https://developer.apple.com/forums/thread/751820
        config.processPool = Self.sharedProcessPool
        os_log(.info, log: Self.log, "[DIAG:webViewCreated] processPool=shared")

        // Register as cookie observer for automatic persistence
        config.websiteDataStore.httpCookieStore.add(self)

        return config
    }

    // MARK: – WKHTTPCookieStoreObserver — auto-persist cookies on change

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        // When WKWebView cookies change, sync them to HTTPCookieStorage
        // so they survive content process termination.
        cookieStore.getAllCookies { cookies in
            let domainCookies = cookies.filter { $0.domain.contains(self.serverDomain) }
            for cookie in domainCookies {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
            if !domainCookies.isEmpty {
                os_log(.info, log: Self.log, "[CookieObserver] auto-synced %d domain cookies to HTTPCookieStorage", domainCookies.count)
            }
        }
    }

    // MARK: – H) Native Token Persistence (Build 9 — two-way sync)
    //
    // ARCHITECTURE NOTE: In production, the WKWebView loads https://abideandanchor.app
    // (remote Base44 platform). Our local src/lib/tokenStorage.js is DEAD CODE — it's
    // compiled into dist/ but never served because server.url overrides it.
    // The remote site's own JS manages tokens in localStorage only.
    //
    // Therefore, token persistence to UserDefaults MUST happen here in native Swift:
    //   UP:   localStorage → UserDefaults (after page load, on foreground resume)
    //   DOWN: UserDefaults → localStorage (on cold boot via WKUserScript at documentStart)

    /// Reads auth token from localStorage (via JS evaluation) and saves to UserDefaults.
    /// Called after page load and on foreground resume.
    private func syncTokenToUserDefaults() {
        guard let webView = self.webView else { return }

        // Guard: skip if page hasn't navigated yet — localStorage throws SecurityError at about:blank
        guard let pageURL = webView.url, pageURL.scheme == "https" else {
            os_log(.info, log: Self.log, "[TokenSync:UP] Skipped — page not yet loaded (url=%{public}@)",
                   webView.url?.absoluteString ?? "nil")
            return
        }

        webView.evaluateJavaScript("""
            (function() {
                var keys = ['base44_access_token', 'token', 'access_token', 'base44_auth_token'];
                for (var i = 0; i < keys.length; i++) {
                    try {
                        var val = localStorage.getItem(keys[i]);
                        if (val && val.length > 20) return val;
                    } catch(e) {}
                }
                return null;
            })()
        """) { [weak self] result, error in
            guard let self = self else { return }

            if let token = result as? String, !token.isEmpty {
                let existing = UserDefaults.standard.string(forKey: Self.tokenDefaultsKey)
                if existing != token {
                    UserDefaults.standard.set(token, forKey: Self.tokenDefaultsKey)
                    os_log(.info, log: Self.log, "[TokenSync:UP] Saved token to UserDefaults (len=%d)", token.count)
                } else {
                    os_log(.info, log: Self.log, "[TokenSync:UP] UserDefaults already has current token (len=%d)", token.count)
                }
            } else {
                os_log(.info, log: Self.log, "[TokenSync:UP] No token found in localStorage")
            }
        }
    }

    /// Clears the token from UserDefaults (called during logout).
    private func clearTokenFromUserDefaults() {
        UserDefaults.standard.removeObject(forKey: Self.tokenDefaultsKey)
        os_log(.info, log: Self.log, "[TokenSync] Cleared token from UserDefaults")
    }

    /// Checks if UserDefaults has a stored token.
    private func hasTokenInUserDefaults() -> Bool {
        let token = UserDefaults.standard.string(forKey: Self.tokenDefaultsKey)
        return token != nil && !(token!.isEmpty)
    }

    /// Gets the stored token length (for diagnostics — never log the token itself).
    private func tokenLengthInUserDefaults() -> Int {
        return UserDefaults.standard.string(forKey: Self.tokenDefaultsKey)?.count ?? 0
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

        // iOS 26+: Use batch setCookies API (Apple WWDC 2025)
        // Fallback: Loop with DispatchGroup for iOS 15-25
        if #available(iOS 26.0, *) {
            cookieStore.setCookies(domainCookies) {
                os_log(.info, log: Self.log, "syncCookies: batch done — %d cookies synced (iOS 26 API)", domainCookies.count)
                completion?()
            }
        } else {
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

        // Token UP sync: localStorage → UserDefaults
        // Delay to let the remote site's React app mount and set tokens in localStorage.
        // Two stages: 3s (catch fast logins) and 10s (catch slow hydration).
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.syncTokenToUserDefaults()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
            self?.syncTokenToUserDefaults()
        }
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

        // Token UP sync on resume — catches tokens set during the session
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.syncTokenToUserDefaults()
        }

        // Re-check IAP entitlements on resume (catches renewals/expirations while backgrounded)
        if #available(iOS 15.0, *) {
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let (isCompanion, activeProducts) = await AAStoreManager.shared.checkEntitlements()
                self.persistCompanionState(isCompanion)
                self.refreshWebEntitlements(isCompanion: isCompanion)
                self.pushEntitlementCheckToJS(isCompanion: isCompanion, products: activeProducts)
            }
        }

        // Build 11: Also check server-side companion status on resume
        checkCompanionOnServer()

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
        // Token UP sync — last chance before app may be killed
        syncTokenToUserDefaults()
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
        // Guard: skip if page hasn't navigated yet — localStorage throws SecurityError at about:blank
        guard let pageURL = webView.url, pageURL.scheme == "https" else {
            os_log(.info, log: Self.log,
                   "[DIAG:authMarkers] localStorage: skipped (page not yet loaded, url=%{public}@)",
                   webView.url?.absoluteString ?? "nil")
            return
        }

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
        controller.add(self, name: "aaPurchase")

        // Inject native diagnostics data + IAP callback at DOCUMENT START so it's available
        // before any other scripts run (fixes "unknown" race condition)
        let nativeDiagScript = WKUserScript(
            source: buildNativeDiagJS(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        controller.addUserScript(nativeDiagScript)

        // Inject IAP bridge helper at DOCUMENT START (Build 10)
        // Provides window.aaPurchase() convenience function for web buttons
        let iapBridgeScript = WKUserScript(
            source: Self.iapBridgeJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        controller.addUserScript(iapBridgeScript)

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

    /// Builds the JS string that sets window.__aaNativeDiag with device/build info
    /// AND restores token from UserDefaults to localStorage if needed.
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

        // Token restoration: read from UserDefaults, inject into localStorage if missing.
        // JWT tokens are base64url (A-Z, a-z, 0-9, -, _, .) — safe for JS string literal.
        let hasNativeToken = hasTokenInUserDefaults()
        let nativeTokenLen = tokenLengthInUserDefaults()
        let savedToken = UserDefaults.standard.string(forKey: Self.tokenDefaultsKey) ?? ""
        // Escape for JS safety (JWTs shouldn't need this, but be defensive)
        let escapedToken = savedToken
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")

        let isCompanion = UserDefaults.standard.bool(forKey: Self.companionDefaultsKey)

        return """
        window.__aaNativeDiag = {
          deviceModel: '\(machineStr)',
          deviceType: '\(model)',
          iOSVersion: '\(systemVersion)',
          deviceName: '\(deviceName)',
          appVersion: '\(appVersion)',
          buildNumber: '\(buildNumber)',
          dataStoreType: '\(storeType)',
          hasNativeToken: \(hasNativeToken ? "true" : "false"),
          nativeTokenLen: \(nativeTokenLen),
          isCompanion: \(isCompanion ? "true" : "false"),
          workerConfigured: \(!Self.companionWorkerURL.contains("YOUR_SUBDOMAIN") ? "true" : "false")
        };
        // Build 10: IAP callback default + companion state
        window.__aaPurchaseResult = window.__aaPurchaseResult || function(_){};
        window.__aaIsCompanion = \(isCompanion ? "true" : "false");
        // Build 11: Cross-device companion check via Cloudflare Worker
        window.__aaCompanionWorkerURL = '\(Self.companionWorkerURL)';
        // Build 12: Diagnostics tracking globals
        window.__aaLastEntitlementCheck = window.__aaLastEntitlementCheck || null;
        window.__aaLastWorkerResponse = window.__aaLastWorkerResponse || null;
        window.__aaCheckCompanion = function() {
          var workerURL = window.__aaCompanionWorkerURL;
          if (!workerURL || workerURL.indexOf('YOUR_SUBDOMAIN') !== -1) return Promise.resolve({ isCompanion: window.__aaIsCompanion });
          var token = null;
          try {
            var keys = ['base44_access_token', 'token', 'access_token', 'base44_auth_token'];
            for (var i = 0; i < keys.length; i++) {
              var val = localStorage.getItem(keys[i]);
              if (val && val.length > 20) { token = val; break; }
            }
          } catch(e) {}
          if (!token) return Promise.resolve({ isCompanion: false, reason: 'no-token' });
          var wasCompanion = window.__aaIsCompanion === true;
          return fetch(workerURL + '/check-companion', {
            method: 'GET',
            headers: { 'Authorization': 'Bearer ' + token }
          })
          .then(function(res) { return res.json(); })
          .then(function(data) {
            // Build 16: If server says not-companion but we were companion,
            // trigger native StoreKit entitlement recheck before downgrading.
            // The server's expiry data can be stale (doesn't track auto-renewals).
            if (!data.isCompanion && wasCompanion) {
              // Ask native to recheck — it will cross-verify with StoreKit
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.aaPurchase) {
                window.webkit.messageHandlers.aaPurchase.postMessage({ action: 'recheckEntitlements' });
              }
              // Don't update __aaIsCompanion yet — let native decide
              return { isCompanion: wasCompanion, pendingNativeRecheck: true };
            }
            window.__aaIsCompanion = data.isCompanion === true;
            return data;
          })
          .catch(function(err) {
            return { isCompanion: window.__aaIsCompanion, error: err.message };
          });
        };
        // Build 9: Restore token from UserDefaults → localStorage on cold boot.
        // This is the DOWN sync: native persistence → web persistence.
        // Only restores if localStorage has NO auth token (cleared by WebKit, reinstall, etc.)
        (function restoreTokenFromNative() {
          if (!\(hasNativeToken ? "true" : "false")) return; // No token in UserDefaults
          try {
            var keys = ['base44_access_token', 'token', 'access_token', 'base44_auth_token'];
            var anyPresent = false;
            for (var i = 0; i < keys.length; i++) {
              var val = localStorage.getItem(keys[i]);
              if (val && val.length > 20) { anyPresent = true; break; }
            }
            if (!anyPresent) {
              var nativeToken = '\(escapedToken)';
              if (nativeToken.length > 20) {
                localStorage.setItem('token', nativeToken);
                localStorage.setItem('base44_auth_token', nativeToken);
                window.__aaNativeDiag.tokenRestored = true;
              }
            }
          } catch(e) {}
        })();
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

        /* ── Build 12: Toast notification ── */
        .aa-toast {
          position: fixed;
          top: calc(env(safe-area-inset-top, 44px) + 8px);
          left: 16px;
          right: 16px;
          z-index: 99997;
          padding: 16px 20px;
          border-radius: 14px;
          font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
          font-size: 15px;
          font-weight: 600;
          text-align: center;
          box-shadow: 0 4px 24px rgba(0,0,0,0.15);
          transform: translateY(-120%);
          transition: transform 0.35s cubic-bezier(0.4, 0, 0.2, 1);
          pointer-events: none;
        }
        .aa-toast.visible { transform: translateY(0); }
        .aa-toast.success { background: #059669; color: #ffffff; }
        .aa-toast.error { background: #dc2626; color: #ffffff; }
        .aa-toast.info { background: #1e293b; color: #ffffff; }

        /* ── Build 12: Subscription Status section on More/Settings ── */
        #aa-subscription-section {
          margin: 16px 16px 8px 16px;
          padding: 16px;
          background: #f8f9fa;
          border-radius: 12px;
          border: 1px solid #e5e7eb;
          font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
        }
        #aa-subscription-section .aa-sub-label {
          font-size: 13px;
          font-weight: 500;
          color: #6b7280;
          text-transform: uppercase;
          letter-spacing: 0.5px;
          margin: 0 0 8px 0;
        }
        #aa-subscription-section .aa-sub-status {
          font-size: 17px;
          font-weight: 700;
          margin: 0 0 4px 0;
        }
        #aa-subscription-section .aa-sub-status.active { color: #059669; }
        #aa-subscription-section .aa-sub-status.free { color: #6b7280; }
        #aa-subscription-section .aa-sub-detail {
          font-size: 13px;
          color: #9ca3af;
          margin: 0 0 12px 0;
        }
        #aa-sub-recheck-btn {
          display: block;
          width: 100%;
          padding: 12px;
          background: #f1f5f9;
          border: 1px solid #cbd5e1;
          border-radius: 10px;
          color: #334155;
          font-size: 15px;
          font-weight: 600;
          cursor: pointer;
          -webkit-tap-highlight-color: transparent;
          font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
          text-align: center;
        }
        #aa-sub-recheck-btn:active { background: #e2e8f0; }
        #aa-sub-recheck-btn:disabled { opacity: 0.6; cursor: not-allowed; }

        /* ── Build 12: Already-subscribed banner on paywall ── */
        #aa-already-subscribed {
          background: #059669;
          color: #fff;
          padding: 14px 16px;
          text-align: center;
          font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
          font-weight: 600;
          font-size: 15px;
          border-radius: 10px;
          margin: 8px 16px;
        }

        /* ── Build 18: Hide yearly/annual pricing elements via CSS ── */
        [data-aa-yearly-hidden] {
          display: none !important;
        }
        /* Hide Base44 native logout (non-red) */
        [data-aa-native-logout-hidden] {
          display: none !important;
        }

        /* ── Build 18: Ensure feature popup cards (Captain's Log, etc.) are NOT blacked out ── */
        /* Override any stale data-aa-sub-hidden on non-paywall popups after navigation */
        [data-aa-sub-hidden] {
          /* This attribute may need to be cleaned on route change */
        }
      `;
      document.head.appendChild(style);
    })();
    """

    // MARK: – IAP Bridge JS (Build 10 — atDocumentStart)

    /// Convenience bridge injected at document start so web code can call
    /// `window.aaPurchase("buy", "com.abideandanchor.companion.monthly")`
    /// or `window.aaPurchase("restore")` directly without checking messageHandlers.
    private static let iapBridgeJS: String = """
    (function() {
      if (window.__aaIAPBridgeReady) return;
      window.__aaIAPBridgeReady = true;
      window.aaPurchase = function(action, productId) {
        var payload = { action: action };
        if (productId) payload.productId = productId;
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.aaPurchase) {
          window.webkit.messageHandlers.aaPurchase.postMessage(payload);
        } else {
          if (typeof window.__aaPurchaseResult === 'function') {
            window.__aaPurchaseResult({ status: 'error', message: 'Native IAP bridge not available' });
          }
        }
      };
    })();
    """

    // MARK: – JS Patch

    private static let jsInjection: String = """
    (function() {
      'use strict';
      if (window.__aaPatched) return;
      window.__aaPatched = true;

      // ── 0a. TOAST NOTIFICATION SYSTEM (Build 12) ──
      var __aaToastTimer = null;
      function showAAToast(message, type) {
        var existing = document.querySelector('.aa-toast');
        if (existing) existing.remove();
        if (__aaToastTimer) { clearTimeout(__aaToastTimer); __aaToastTimer = null; }
        var toast = document.createElement('div');
        toast.className = 'aa-toast ' + (type || 'info');
        toast.textContent = message;
        document.body.appendChild(toast);
        requestAnimationFrame(function() {
          requestAnimationFrame(function() { toast.classList.add('visible'); });
        });
        __aaToastTimer = setTimeout(function() {
          toast.classList.remove('visible');
          setTimeout(function() { if (toast.parentNode) toast.remove(); }, 400);
          __aaToastTimer = null;
        }, 4000);
      }

      // ── 0b. PURCHASE RESULT HANDLER WITH TOAST (Build 12) ──
      window.__aaPurchaseResult = function(result) {
        if (!result) return;
        var status = result.status;
        var action = result.action || '';
        var source = result.source || '';
        // Background renewal/refund
        if (source === 'transactionUpdate') {
          if (result.isCompanion) { showAAToast('Subscription renewed', 'success'); }
          else { showAAToast('Subscription status changed', 'info'); }
          updateSubscriptionStatusUI(result.isCompanion);
          return;
        }
        if (action === 'restore') {
          if (status === 'success' && result.isCompanion) {
            showAAToast('Subscription restored! Companion unlocked.', 'success');
          } else if (status === 'success' && !result.isCompanion) {
            showAAToast('No active subscription found.', 'info');
          } else if (status === 'error') {
            showAAToast(result.message || 'Restore failed. Please try again.', 'error');
          }
        } else if (action === 'buy') {
          if (status === 'success' && result.isCompanion) {
            showAAToast('Companion features unlocked!', 'success');
          } else if (status === 'error') {
            showAAToast(result.message || 'Purchase failed. Please try again.', 'error');
          } else if (status === 'pending') {
            showAAToast('Purchase pending approval.', 'info');
          }
          // cancelled: no toast — user initiated it
        }
        if (result.isCompanion !== undefined) {
          updateSubscriptionStatusUI(result.isCompanion);
        }
      };

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

      // ── 3b. LAST ERROR TRACKING (Build 8) ──
      // Stores the last error for diagnostics. Never stores raw tokens or PII.
      window.__AA_LAST_ERROR = null;

      function storeLastError(msg, source) {
        try {
          // Sanitize: strip anything that looks like a token (long base64 strings)
          var safe = String(msg || '').substring(0, 300);
          safe = safe.replace(/[A-Za-z0-9_-]{40,}/g, '[REDACTED]');
          window.__AA_LAST_ERROR = {
            message: safe,
            source: source || 'unknown',
            timestamp: new Date().toISOString(),
            url: window.location.pathname + (window.location.hash || '')
          };
        } catch(e) {}
      }

      // ── 3c. CONSOLE.ERROR INTERCEPTION (Build 8) ──
      // Catches React error boundary logs and other console.error calls.
      var _origConsoleError = console.error;
      var lastConsoleErrorTime = 0;
      console.error = function() {
        _origConsoleError.apply(console, arguments);
        try {
          var now = Date.now();
          if (now - lastConsoleErrorTime < 1000) return; // debounce 1s
          lastConsoleErrorTime = now;
          var msg = '';
          for (var i = 0; i < arguments.length; i++) {
            var arg = arguments[i];
            if (arg && arg.message) msg += arg.message + ' ';
            else if (typeof arg === 'string') msg += arg + ' ';
          }
          if (msg.length > 0) {
            storeLastError(msg.trim(), 'console.error');
            // Detect React invariant violations via console.error
            if (msg.indexOf('Minified React error') !== -1 ||
                msg.indexOf('Invariant Violation') !== -1 ||
                msg.indexOf('must be used within') !== -1) {
              setTimeout(function() {
                if (msg.indexOf('must be used within') !== -1) {
                  handleSelectTriggerCrash();
                } else {
                  detectAndFixErrorScreen();
                }
              }, 500);
            }
          }
        } catch(e) {}
      };

      window.addEventListener('error', function(event) {
        var msg = (event.error && event.error.message) || event.message || '';
        storeLastError(msg, 'window.onerror');
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
        storeLastError(msg, 'unhandledrejection');
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
        // Build 18: Clean up stale data-aa-sub-hidden on non-paywall elements.
        // When navigating away from the paywall to features (Captain's Log, etc.),
        // previously-hidden overlay containers must be restored so feature popups work.
        document.querySelectorAll('[data-aa-sub-hidden]').forEach(function(el) {
          // Only clean elements outside #root (body-level portals that may be reused)
          if (!el.closest('#root') && !el.id.match(/^aa-/)) {
            el.style.display = '';
            el.removeAttribute('data-aa-sub-hidden');
          }
        });
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
        // Refresh token metadata each time diagnostics are collected
        window.__AA_TOKEN_META = computeTokenMeta();

        var native = window.__aaNativeDiag || {};
        var tokenKeys = ['base44_access_token', 'base44_refresh_token', 'base44_auth_token', 'base44_user', 'access_token', 'refresh_token', 'token'];
        var authPresence = {};
        var tokenLengths = {};
        tokenKeys.forEach(function(k) {
          try {
            var val = localStorage.getItem(k);
            authPresence[k] = val !== null;
            if (val !== null) tokenLengths[k] = val.length;
          } catch(e) { authPresence[k] = 'error'; }
        });

        // Native token persistence (UserDefaults) — injected by Swift at document start
        var nativeDiag = window.__aaNativeDiag || {};
        var nativeTokenPresent = nativeDiag.hasNativeToken || false;
        var nativeTokenLen = nativeDiag.nativeTokenLen || 0;
        var tokenRestoredFromNative = nativeDiag.tokenRestored || false;

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
        lines.push('  --- Native Persistence (UserDefaults) ---');
        lines.push('  UserDefaults token: ' + (nativeTokenPresent ? 'true (len=' + nativeTokenLen + ')' : 'false'));
        if (tokenRestoredFromNative) {
          lines.push('  Token restored from UserDefaults: YES');
        }
        lines.push('  localStorage total keys: ' + lsKeyCount);
        lines.push('');
        lines.push('-- Network --');
        lines.push('  Online: ' + (typeof navigator.onLine !== 'undefined' ? navigator.onLine : 'unknown'));
        try {
          var conn = navigator.connection || navigator.mozConnection || navigator.webkitConnection;
          if (conn) {
            lines.push('  EffectiveType: ' + (conn.effectiveType || 'unknown'));
            lines.push('  Downlink: ' + (conn.downlink !== undefined ? conn.downlink + ' Mbps' : 'unknown'));
            lines.push('  RTT: ' + (conn.rtt !== undefined ? conn.rtt + 'ms' : 'unknown'));
          } else {
            lines.push('  Connection API: not available');
          }
        } catch(e) {
          lines.push('  Connection: error reading');
        }
        lines.push('');
        lines.push('-- Session Validation (Build 8) --');
        lines.push('  Status: ' + (window.__AA_SESSION_STATUS || 'unknown'));
        if (window.__AA_TOKEN_META) {
          var tm = window.__AA_TOKEN_META;
          lines.push('  Token has exp: ' + tm.hasExp);
          if (tm.expiresAt) lines.push('  Expires: ' + tm.expiresAt);
          if (tm.ageSeconds !== null) {
            var hrs = Math.floor(tm.ageSeconds / 3600);
            var mins = Math.floor((tm.ageSeconds % 3600) / 60);
            lines.push('  Time remaining: ' + hrs + 'h ' + mins + 'm');
          }
          lines.push('  Expired: ' + tm.isExpired);
        }
        lines.push('');
        lines.push('-- Last Error --');
        if (window.__AA_LAST_ERROR) {
          var le = window.__AA_LAST_ERROR;
          lines.push('  Message: ' + (le.message || 'none'));
          lines.push('  Source: ' + (le.source || 'unknown'));
          lines.push('  Time: ' + (le.timestamp || 'unknown'));
          lines.push('  URL: ' + (le.url || 'unknown'));
        } else {
          lines.push('  No errors captured');
        }
        lines.push('');
        lines.push('-- Companion Subscription (Build 12) --');
        lines.push('  Status: ' + (window.__aaIsCompanion ? 'COMPANION ACTIVE' : 'FREE'));
        lines.push('  JS isCompanion: ' + (window.__aaIsCompanion ? 'true' : 'false'));
        lines.push('  nativeDiag.isCompanion: ' + (native.isCompanion ? 'true' : 'false'));
        lines.push('  Worker URL configured: ' + (native.workerConfigured ? 'YES' : 'NO'));
        var lastCheck = window.__aaLastEntitlementCheck;
        if (lastCheck) {
          lines.push('  Last entitlement check: ' + (lastCheck.time || 'never'));
          lines.push('  Check result: isCompanion=' + lastCheck.isCompanion + ' products=[' + (lastCheck.products || '') + ']');
        } else {
          lines.push('  Last entitlement check: none yet');
        }
        var lastWorker = window.__aaLastWorkerResponse;
        if (lastWorker) {
          lines.push('  Last worker call: ' + (lastWorker.endpoint || '?') + ' -> HTTP ' + (lastWorker.statusCode || '?'));
          lines.push('  Worker call time: ' + (lastWorker.time || 'unknown'));
          if (lastWorker.error) lines.push('  Worker error: ' + lastWorker.error);
        } else {
          lines.push('  Last worker call: none yet');
        }
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

      // ── 6e. IAP BUTTON WIRING (Build 15) ──
      // Searches the ENTIRE document.body (not just #root) to catch buttons
      // in React portals, modals, popups, and overlays that render outside #root.
      // Uses broad text-content matching to be resilient to copy changes.

      function wireIAPButtons() {
        // CRITICAL: Search entire body — Base44 paywall popups render outside #root
        var buttons = document.querySelectorAll('button, a, [role="button"]');
        buttons.forEach(function(btn) {
          if (btn.getAttribute('data-aa-iap-wired')) return;
          // Skip our own injected UI
          if (btn.closest('.aa-diag-overlay, #aa-logout-section, #aa-subscription-section, .aa-error-fallback, #aa-logout-confirm-overlay, #aa-already-subscribed, .aa-toast')) return;
          var text = (btn.textContent || '').trim().toLowerCase();
          if (!text || text.length > 80) return; // Skip empty or very long text (nav items, paragraphs)

          // Skip <a> tags with external href — these are navigation links, not action buttons
          if (btn.tagName === 'A') {
            var href = (btn.getAttribute('href') || '').toLowerCase();
            if (href.indexOf('http') === 0 || href.indexOf('mailto:') === 0 || href.indexOf('tel:') === 0) return;
          }

          // ── CLASSIFY BUTTON ──
          var isMonthlySubscribe = false;
          var isYearly = false;
          var isTrial = false;
          var isRestore = false;

          // Non-IAP context words — if present, skip classification entirely.
          // Prevents hijacking support/help/about/contact links and navigation items.
          var nonIAPWords = ['support', 'help', 'contact', 'learn', 'about', 'faq',
                             'terms', 'privacy', 'policy', 'manage', 'cancel', 'account'];
          var hasNonIAP = false;
          for (var w = 0; w < nonIAPWords.length; w++) {
            if (text.indexOf(nonIAPWords[w]) !== -1) { hasNonIAP = true; break; }
          }
          if (hasNonIAP) return;

          // RESTORE — check first (highest priority, prevents misclassification)
          if (text.indexOf('restore') !== -1 && text.indexOf('purchase') !== -1) {
            isRestore = true;
          }
          // Also match just "restore purchases" or standalone "restore" only if short
          if (!isRestore && text.indexOf('restore') !== -1 && text.length <= 25) {
            isRestore = true;
          }

          // TRIAL — "trial" anywhere (except restore)
          if (!isRestore && text.indexOf('trial') !== -1) {
            isTrial = true;
          }

          // YEARLY — "yearly" or "annual" in subscribe/action context
          if (!isRestore && !isTrial) {
            if ((text.indexOf('yearly') !== -1 || text.indexOf('annual') !== -1) &&
                (text.indexOf('subscribe') !== -1 || text.indexOf('companion') !== -1 ||
                 text === 'yearly' || text === 'annual')) {
              isYearly = true;
            }
          }

          // MONTHLY SUBSCRIBE — broad matching for all subscribe-like actions
          if (!isRestore && !isTrial && !isYearly) {
            // Exact patterns
            if (text === 'subscribe' || text === 'subscribe monthly' || text === 'monthly') {
              isMonthlySubscribe = true;
            }
            // "subscribe" without yearly/annual qualifier
            if (text.indexOf('subscribe') !== -1 && text.indexOf('yearly') === -1 && text.indexOf('annual') === -1) {
              isMonthlySubscribe = true;
            }
            // "get companion" (e.g. "Get Companion on iPhone", "Get Companion")
            if (text.indexOf('get companion') !== -1) {
              isMonthlySubscribe = true;
            }
            // "start companion" / "become a companion" / "join companion"
            if (text.indexOf('start companion') !== -1 || text.indexOf('become') !== -1 ||
                text.indexOf('join companion') !== -1) {
              isMonthlySubscribe = true;
            }
            // "companion" in action context (not status/info text, not navigation)
            if (text.indexOf('companion') !== -1 &&
                text.indexOf('active') === -1 && text.indexOf('recheck') === -1 &&
                text.indexOf('subscription is') === -1 && text.indexOf('have an') === -1 &&
                text.indexOf('status') === -1 && text.indexOf('unlock') === -1 &&
                text.indexOf('feature') === -1 && text.indexOf('captain') === -1 &&
                text.indexOf('drill') === -1 && text.indexOf('review') === -1 &&
                text.indexOf('highlight') === -1 && text.indexOf('verse') === -1) {
              isMonthlySubscribe = true;
            }
            // Generic subscribe/upgrade actions (no "companion" needed)
            if (text === 'upgrade' || text === 'upgrade now' || text === 'start now' ||
                text === 'choose plan' || text === 'select plan') {
              isMonthlySubscribe = true;
            }
          }

          // ── WIRE OR HIDE ──

          if (isMonthlySubscribe) {
            btn.setAttribute('data-aa-iap-wired', 'monthly');
            btn.addEventListener('click', function(e) {
              e.preventDefault();
              e.stopPropagation();
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.aaPurchase) {
                window.webkit.messageHandlers.aaPurchase.postMessage({
                  action: 'buy',
                  productId: 'com.abideandanchor.companion.monthly'
                });
              }
            });
          }

          if (isYearly) {
            btn.setAttribute('data-aa-iap-wired', 'hidden-yearly');
            btn.style.display = 'none';
            hideEmptyParent(btn);
          }

          if (isTrial) {
            btn.setAttribute('data-aa-iap-wired', 'hidden-trial');
            btn.style.display = 'none';
            hideEmptyParent(btn);
          }

          if (isRestore) {
            btn.setAttribute('data-aa-iap-wired', 'restore');
            btn.addEventListener('click', function(e) {
              e.preventDefault();
              e.stopPropagation();
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.aaPurchase) {
                window.webkit.messageHandlers.aaPurchase.postMessage({
                  action: 'restore'
                });
              }
            });
          }
        });

        // Build 18: Hide "yearly"/"annual" text labels/descriptions outside of buttons.
        // These are pricing text elements that Base44 renders (not action buttons).
        hideYearlyTextElements();
      }

      // Helper: hide parent container if all children are hidden
      function hideEmptyParent(el) {
        var parent = el.parentElement;
        if (!parent) return;
        var visibleChildren = 0;
        for (var i = 0; i < parent.children.length; i++) {
          if (parent.children[i].style.display !== 'none' &&
              parent.children[i].offsetHeight > 0) visibleChildren++;
        }
        if (visibleChildren === 0) parent.style.display = 'none';
      }

      // Build 18: Hide elements containing "yearly"/"annual" pricing text.
      // Only targets non-button elements that display pricing info (labels, cards, options).
      // Buttons are already handled by wireIAPButtons() classification.
      function hideYearlyTextElements() {
        // Target common pricing containers: divs, spans, li, p, label, small, h-tags
        var candidates = document.querySelectorAll('div, span, li, p, label, small, h1, h2, h3, h4, h5, h6, td');
        candidates.forEach(function(el) {
          if (el.getAttribute('data-aa-yearly-hidden')) return;
          // Skip our own injected UI
          if (el.closest('#aa-logout-section, #aa-subscription-section, .aa-diag-overlay, .aa-toast, #aa-already-subscribed')) return;
          // Skip elements already handled by wireIAPButtons
          if (el.getAttribute('data-aa-iap-wired')) return;
          // Skip if it contains interactive children (buttons, inputs) — might be a feature container
          if (el.querySelector('button, input, textarea, select')) return;

          var text = (el.textContent || '').trim().toLowerCase();
          if (!text || text.length > 200) return;

          // Match elements that are pricing option cards/labels for yearly/annual
          var isYearlyPricing = false;

          // "yearly" or "annual" combined with pricing context
          if ((text.indexOf('yearly') !== -1 || text.indexOf('annual') !== -1) &&
              (text.indexOf('$') !== -1 || text.indexOf('month') !== -1 ||
               text.indexOf('year') !== -1 || text.indexOf('price') !== -1 ||
               text.indexOf('plan') !== -1 || text.indexOf('subscribe') !== -1 ||
               text.indexOf('/yr') !== -1 || text.indexOf('/year') !== -1 ||
               text.indexOf('per year') !== -1 || text.indexOf('billed') !== -1)) {
            isYearlyPricing = true;
          }

          // Standalone "Yearly" or "Annual" label (short text, likely a pricing option tab/label)
          if (!isYearlyPricing && text.length <= 30) {
            if (text === 'yearly' || text === 'annual' || text === 'yearly plan' ||
                text === 'annual plan' || text === 'yearly subscription' ||
                text === 'annual subscription') {
              isYearlyPricing = true;
            }
          }

          // "$79.99" — the yearly price (hide regardless of surrounding text)
          if (text.indexOf('79.99') !== -1) {
            isYearlyPricing = true;
          }

          if (isYearlyPricing) {
            // Walk up to find the nearest pricing-option card container and hide it
            var target = el;
            var parent = el.parentElement;
            var depth = 0;
            while (parent && parent !== document.body && depth < 5) {
              depth++;
              var siblings = parent.children;
              // If parent has few children and looks like a pricing card (option container), hide the parent
              if (siblings.length <= 4) {
                var siblingTexts = [];
                for (var s = 0; s < siblings.length; s++) {
                  siblingTexts.push((siblings[s].textContent || '').trim().toLowerCase());
                }
                var allText = siblingTexts.join(' ');
                if ((allText.indexOf('yearly') !== -1 || allText.indexOf('annual') !== -1) &&
                    (allText.indexOf('$') !== -1 || allText.indexOf('plan') !== -1 ||
                     allText.indexOf('subscribe') !== -1)) {
                  target = parent;
                  break;
                }
              }
              parent = parent.parentElement;
            }
            target.style.display = 'none';
            target.setAttribute('data-aa-yearly-hidden', '1');
          }
        });
      }

      // Build 18: Hide the Base44 platform's own logout button (non-red one).
      // Our injected #aa-logout-btn (red-styled) is the canonical logout.
      function hideBase44NativeLogout() {
        if (!isMoreOrSettingsRoute()) return;
        // Find all buttons/links that say "log out" / "sign out" but are NOT our injected one
        var allEls = document.querySelectorAll('button, a, [role="button"]');
        allEls.forEach(function(el) {
          if (el.getAttribute('data-aa-native-logout-hidden')) return;
          // Skip our own injected logout
          if (el.id === 'aa-logout-btn' || el.closest('#aa-logout-section, #aa-logout-confirm-overlay')) return;
          var text = (el.textContent || '').trim().toLowerCase();
          if (text === 'log out' || text === 'logout' || text === 'sign out' || text === 'signout') {
            el.style.display = 'none';
            el.setAttribute('data-aa-native-logout-hidden', '1');
            // Also hide the parent if it's a menu item / list item wrapper
            var parent = el.parentElement;
            if (parent && parent.tagName !== 'BODY' && parent.tagName !== 'MAIN') {
              var parentText = (parent.textContent || '').trim().toLowerCase();
              if (parentText === text) {
                parent.style.display = 'none';
                parent.setAttribute('data-aa-native-logout-hidden', '1');
              }
            }
          }
        });
      }

      // ── 6f. SUBSCRIPTION STATUS UI (Build 12) ──
      // Visible "Companion Active" / "Free" indicator on More/Settings page.
      // "Recheck Subscription" button calls __aaCheckCompanion() for cross-device sync.

      function updateSubscriptionStatusUI(isCompanion) {
        var statusEl = document.getElementById('aa-sub-status-text');
        if (statusEl) {
          statusEl.textContent = isCompanion ? 'Companion Active' : 'Free';
          statusEl.className = 'aa-sub-status ' + (isCompanion ? 'active' : 'free');
        }
        var detailEl = document.getElementById('aa-sub-detail-text');
        if (detailEl) {
          detailEl.textContent = isCompanion ? 'Your Companion Monthly subscription is active.' : 'Subscribe monthly to unlock Companion features.';
        }
        // Update global state
        window.__aaIsCompanion = isCompanion;
        // Remove already-subscribed banner if subscription expired
        if (!isCompanion) {
          var banner = document.getElementById('aa-already-subscribed');
          if (banner) banner.remove();
        }
      }

      function injectSubscriptionStatus() {
        if (!isMoreOrSettingsRoute()) {
          var stale = document.getElementById('aa-subscription-section');
          if (stale) stale.remove();
          return;
        }
        if (document.getElementById('aa-subscription-section')) return;
        var root = document.getElementById('root');
        if (!root) return;
        var container = root.querySelector('main') ||
                        root.querySelector('[class*="scroll"]') ||
                        root.querySelector('[class*="content"]') ||
                        root;
        var text = (container.innerText || '').trim();
        if (text.length < 10) return;

        var isCompanion = window.__aaIsCompanion === true;
        var section = document.createElement('div');
        section.id = 'aa-subscription-section';

        var label = document.createElement('div');
        label.className = 'aa-sub-label';
        label.textContent = 'Subscription';
        section.appendChild(label);

        var status = document.createElement('div');
        status.id = 'aa-sub-status-text';
        status.className = 'aa-sub-status ' + (isCompanion ? 'active' : 'free');
        status.textContent = isCompanion ? 'Companion Active' : 'Free';
        section.appendChild(status);

        var detail = document.createElement('div');
        detail.id = 'aa-sub-detail-text';
        detail.className = 'aa-sub-detail';
        detail.textContent = isCompanion ? 'Your Companion Monthly subscription is active.' : 'Subscribe monthly to unlock Companion features.';
        section.appendChild(detail);

        var recheckBtn = document.createElement('button');
        recheckBtn.id = 'aa-sub-recheck-btn';
        recheckBtn.textContent = 'Recheck Subscription';
        recheckBtn.addEventListener('click', function(e) {
          e.preventDefault();
          recheckBtn.disabled = true;
          recheckBtn.textContent = 'Checking...';
          var p = (typeof window.__aaCheckCompanion === 'function')
            ? window.__aaCheckCompanion()
            : Promise.resolve({ isCompanion: window.__aaIsCompanion });
          p.then(function(data) {
            window.__aaIsCompanion = data.isCompanion === true;
            updateSubscriptionStatusUI(data.isCompanion === true);
            recheckBtn.disabled = false;
            recheckBtn.textContent = 'Recheck Subscription';
            if (data.isCompanion) {
              showAAToast('Companion subscription confirmed!', 'success');
            } else {
              showAAToast('No active subscription found.', 'info');
            }
          }).catch(function() {
            recheckBtn.disabled = false;
            recheckBtn.textContent = 'Recheck Subscription';
            showAAToast('Could not check subscription. Try again.', 'error');
          });
        });
        section.appendChild(recheckBtn);

        var logoutSection = document.getElementById('aa-logout-section');
        if (logoutSection) {
          container.insertBefore(section, logoutSection);
        } else {
          container.appendChild(section);
        }
      }

      // ── 6g. ALREADY-SUBSCRIBED PAYWALL HANDLING (Build 15) ──
      // Searches entire document.body to catch paywall popups/modals.
      // When subscribed: hides subscribe/trial buttons AND dismisses paywall overlays.
      // When not subscribed: ensures buttons are visible.

      function handleAlreadySubscribed() {
        if (!window.__aaIsCompanion) {
          // Not subscribed: remove banner and unhide buttons
          var banner = document.getElementById('aa-already-subscribed');
          if (banner) banner.remove();
          var hiddenBuy = document.querySelectorAll('[data-aa-sub-hidden]');
          hiddenBuy.forEach(function(el) {
            el.style.display = '';
            el.removeAttribute('data-aa-sub-hidden');
          });
          return;
        }

        // SUBSCRIBED: Search entire body (catches popups/portals outside #root)
        var wiredBtns = document.querySelectorAll('[data-aa-iap-wired]');
        if (wiredBtns.length === 0) return;

        // Hide ALL subscribe/trial/yearly buttons everywhere
        wiredBtns.forEach(function(btn) {
          var wiredType = btn.getAttribute('data-aa-iap-wired');
          if (wiredType === 'monthly' || wiredType === 'yearly' ||
              wiredType === 'hidden-yearly' || wiredType === 'hidden-trial') {
            btn.style.display = 'none';
            btn.setAttribute('data-aa-sub-hidden', '1');
          }
          // Also hide restore on paywall when subscribed (not needed)
          if (wiredType === 'restore') {
            btn.style.display = 'none';
            btn.setAttribute('data-aa-sub-hidden', '1');
          }
        });

        // Build 18 FIX: Only dismiss parent popups that are PAYWALL-SPECIFIC.
        // Previous logic was too aggressive — it hid ANY modal/popup/dialog parent
        // (e.g. Captain's Log "Write" popup) just because it happened to be a modal.
        // Now: only dismiss if the container's content is predominantly subscription/pricing text.
        wiredBtns.forEach(function(btn) {
          if (!btn.getAttribute('data-aa-sub-hidden')) return;
          var el = btn.parentElement;
          var depth = 0;
          while (el && el !== document.body && el !== document.documentElement && depth < 10) {
            depth++;
            // Skip our own injected elements
            if (el.id && el.id.indexOf('aa-') === 0) { el = el.parentElement; continue; }
            var style = window.getComputedStyle(el);
            var pos = style.position;
            var zIndex = parseInt(style.zIndex) || 0;
            var cls = (el.className || '').toLowerCase();
            var isOverlay = ((pos === 'fixed' || pos === 'absolute') && zIndex >= 10) ||
                            cls.indexOf('modal') !== -1 || cls.indexOf('popup') !== -1 ||
                            cls.indexOf('overlay') !== -1 || cls.indexOf('dialog') !== -1 ||
                            cls.indexOf('backdrop') !== -1;

            if (isOverlay) {
              // GUARD: Only dismiss if content is paywall/subscription-related.
              // Check the container's text for subscription keywords.
              var containerText = (el.textContent || '').toLowerCase();
              var isPaywall = (containerText.indexOf('subscribe') !== -1 ||
                               containerText.indexOf('companion') !== -1 ||
                               containerText.indexOf('pricing') !== -1 ||
                               containerText.indexOf('plan') !== -1 ||
                               containerText.indexOf('upgrade') !== -1 ||
                               containerText.indexOf('subscription') !== -1 ||
                               containerText.indexOf('monthly') !== -1 ||
                               containerText.indexOf('restore purchase') !== -1);

              // Reject: if the container has content that is NOT paywall-related,
              // it's a different feature popup (Captain's Log, Drill Notes, etc.)
              var isFeaturePopup = (containerText.indexOf('captain') !== -1 ||
                                    containerText.indexOf('drill') !== -1 ||
                                    containerText.indexOf('weekly review') !== -1 ||
                                    containerText.indexOf('highlight') !== -1 ||
                                    containerText.indexOf('verse') !== -1 ||
                                    containerText.indexOf('prayer') !== -1 ||
                                    containerText.indexOf('journal') !== -1 ||
                                    containerText.indexOf('write') !== -1 ||
                                    containerText.indexOf('note') !== -1 ||
                                    containerText.indexOf('log') !== -1);

              if (isPaywall && !isFeaturePopup) {
                el.style.display = 'none';
                el.setAttribute('data-aa-sub-hidden', '1');
              }
              break; // Stop walking up regardless — we found the overlay boundary
            }
            el = el.parentElement;
          }
        });

        // Inject banner in #root on paywall pages
        if (document.getElementById('aa-already-subscribed')) return;
        var root = document.getElementById('root');
        if (!root) return;
        var banner = document.createElement('div');
        banner.id = 'aa-already-subscribed';
        banner.textContent = 'You have an active Companion subscription!';
        var main = root.querySelector('main') || root;
        main.insertBefore(banner, main.firstChild);
      }

      // ── 6d. SESSION VALIDATION (Build 8) ──
      // Detects stale/expired tokens and clears them before the React app mounts.
      // This prevents "logged in but broken" states where an expired JWT sits in localStorage.
      // Loop guard: only runs once per page load via sessionStorage key.

      window.__AA_SESSION_STATUS = 'unknown';
      window.__AA_TOKEN_META = null;

      // Parse JWT expiry (base64url decode payload). Reusable.
      function parseJwtExp(jwt) {
        try {
          var parts = jwt.split('.');
          if (parts.length !== 3) return null;
          var payload = parts[1];
          payload = payload.replace(/-/g, '+').replace(/_/g, '/');
          while (payload.length % 4 !== 0) payload += '=';
          var decoded = atob(payload);
          var obj = JSON.parse(decoded);
          return obj.exp ? Number(obj.exp) : null;
        } catch(e) {
          return null;
        }
      }

      // Compute token metadata snapshot (called at validation + diagnostics time)
      // Checks multiple token keys since Base44 may use different keys at different times
      function computeTokenMeta() {
        var token = null;
        var tokenKeys = ['base44_access_token', 'token', 'access_token', 'base44_auth_token'];
        for (var i = 0; i < tokenKeys.length; i++) {
          try {
            var val = localStorage.getItem(tokenKeys[i]);
            if (val && val.length > 20) { token = val; break; }
          } catch(e) {}
        }
        if (!token) return null;
        var exp = parseJwtExp(token);
        var now = Math.floor(Date.now() / 1000);
        return {
          hasExp: !!exp,
          expiresAt: exp ? new Date(exp * 1000).toISOString() : null,
          ageSeconds: exp ? (exp - now) : null,
          isExpired: exp ? (exp < now) : false,
          tokenLength: token.length
        };
      }

      (function validateSession() {
        var guardKey = 'aa-session-validated';
        var alreadyRan = sessionStorage.getItem(guardKey) === '1';

        // Always recompute token metadata (so diagnostics are always fresh)
        window.__AA_TOKEN_META = computeTokenMeta();

        if (alreadyRan) {
          // Preserve the original validation result stored in sessionStorage
          var prevResult = sessionStorage.getItem('aa-session-result') || 'already-checked';
          window.__AA_SESSION_STATUS = prevResult;
          return;
        }
        sessionStorage.setItem(guardKey, '1');

        // Check multiple token keys — Base44 SDK may use different keys
        var token = null;
        var tokenSearchKeys = ['base44_access_token', 'token', 'access_token', 'base44_auth_token'];
        for (var ti = 0; ti < tokenSearchKeys.length; ti++) {
          try {
            var tv = localStorage.getItem(tokenSearchKeys[ti]);
            if (tv && tv.length > 20) { token = tv; break; }
          } catch(e) {}
        }
        if (!token) {
          window.__AA_SESSION_STATUS = 'no-token';
          sessionStorage.setItem('aa-session-result', 'no-token');
          return;
        }

        var exp = parseJwtExp(token);
        var now = Math.floor(Date.now() / 1000);

        if (exp && exp < now) {
          // Token is expired — clear all auth keys so React shows login
          window.__AA_SESSION_STATUS = 'expired-cleared';
          sessionStorage.setItem('aa-session-result', 'expired-cleared');
          var authKeys = [
            'base44_access_token', 'base44_refresh_token', 'base44_auth_token',
            'base44_user', 'access_token', 'refresh_token', 'token',
            'CapacitorStorage.aa_token', 'CapacitorStorage.base44_auth_token'
          ];
          authKeys.forEach(function(key) {
            try { localStorage.removeItem(key); } catch(e) {}
          });
          // Recompute after clearing
          window.__AA_TOKEN_META = computeTokenMeta();
          return;
        }

        // Token exists and not expired (or no exp field)
        var hasUser = false;
        try { hasUser = !!localStorage.getItem('base44_user'); } catch(e) {}

        if (hasUser) {
          window.__AA_SESSION_STATUS = 'valid';
          sessionStorage.setItem('aa-session-result', 'valid');
        } else {
          // Token exists but user data missing — flag it, let React rehydrate
          window.__AA_SESSION_STATUS = 'token-no-user';
          sessionStorage.setItem('aa-session-result', 'token-no-user');
        }
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
          injectSubscriptionStatus();
          injectLogoutButton();
          hideBase44NativeLogout();
          wireIAPButtons();
          handleAlreadySubscribed();
        }, 250);
      }

      // MutationObserver for DOM changes in #root
      var observer = new MutationObserver(function(mutations) {
        for (var i = 0; i < mutations.length; i++) {
          if (mutations[i].addedNodes.length > 0 || mutations[i].removedNodes.length > 0) {
            runAllPatches();
            return;
          }
        }
      });

      // Build 15: Body-level observer for popups/modals that render outside #root
      // React portals, paywall popups, and modal overlays often attach directly to document.body
      var bodyObserver = new MutationObserver(function(mutations) {
        for (var i = 0; i < mutations.length; i++) {
          if (mutations[i].addedNodes.length > 0) {
            // Only run IAP-related patches for body changes (not full patch suite)
            setTimeout(function() {
              wireIAPButtons();
              handleAlreadySubscribed();
            }, 150);
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
        // Observe body for portaled popups (only direct children, not subtree — more efficient)
        bodyObserver.observe(document.body, { childList: true });
      }

      // Periodic checks (blank screen + prayer routes + IAP button wiring) — every 3s for first 30s
      var blankCheckCount = 0;
      function scheduleBlankChecks() {
        blankCheckCount = 0;
        blankConsecutiveHits = 0;
        prayerBlankHits = 0;
        var interval = setInterval(function() {
          blankCheckCount++;
          detectBlankScreen();
          monitorPrayerRoutes();
          // Build 15: Also check for new IAP buttons (catches late-appearing popups)
          wireIAPButtons();
          handleAlreadySubscribed();
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
