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
    func startTransactionListener(onUpdate: @escaping (Bool, String?) -> Void) {
        transactionListener?.cancel()
        transactionListener = Task(priority: .background) {
            for await result in Transaction.updates {
                if case .verified(let transaction) = result {
                    await transaction.finish()
                    let jwsString = result.jwsRepresentation
                    os_log(.info, log: Self.log, "[TxnUpdate] productId=%{public}@ revoked=%{public}@ hasJWS=%{public}@",
                           transaction.productID,
                           transaction.revocationDate != nil ? "YES" : "NO",
                           jwsString.isEmpty ? "false" : "true")
                    let (isCompanion, _) = await self.checkEntitlements()
                    await MainActor.run { onUpdate(isCompanion, jwsString.isEmpty ? nil : jwsString) }
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

    /// Restore purchases: check local entitlements first, then fall back to AppStore.sync().
    /// Returns the JWS from the latest active Companion entitlement for server validation.
    func restorePurchases() async -> (status: String, isCompanion: Bool, restoredProducts: [String], message: String?, jws: String?) {
        // Build 21 FIX: Check local entitlements FIRST before calling AppStore.sync().
        // If we find entitlements locally, restore immediately without Apple ID sign-in.
        let (localIsCompanion, localProducts, localJWS) = await checkEntitlementsWithJWS()
        if localIsCompanion {
            os_log(.info, log: Self.log, "[Restore] Found local entitlements — products=%{public}@ hasJWS=%{public}@",
                   localProducts.joined(separator: ","), localJWS != nil ? "true" : "false")
            return ("success", true, localProducts, nil, localJWS)
        }

        // No local entitlements — call AppStore.sync() to force-refresh from App Store.
        // Apple docs: "In rare cases when a user suspects the app isn't showing all the
        // transactions, call sync(). Call this function only in response to an explicit
        // user action, like tapping or clicking a button."
        // This IS in response to the user tapping Restore Purchases, so it's correct.
        // AppStore.sync() may show Apple ID sign-in dialog — this is expected behavior
        // for restore on a new device or after reinstall.
        do {
            os_log(.info, log: Self.log, "[Restore] No local entitlements — calling AppStore.sync()")
            try await AppStore.sync()
            os_log(.info, log: Self.log, "[Restore] AppStore.sync() completed — re-checking entitlements")

            // Re-check after sync
            let (syncedIsCompanion, syncedProducts, syncedJWS) = await checkEntitlementsWithJWS()
            if syncedIsCompanion {
                os_log(.info, log: Self.log, "[Restore] Found entitlements after sync — products=%{public}@",
                       syncedProducts.joined(separator: ","))
                return ("success", true, syncedProducts, nil, syncedJWS)
            }

            os_log(.info, log: Self.log, "[Restore] No entitlements found after sync — nothing to restore")
            return ("success", false, [], nil, nil)
        } catch {
            os_log(.error, log: Self.log, "[Restore] AppStore.sync() failed: %{public}@", error.localizedDescription)
            return ("error", false, [], "Restore failed: \(error.localizedDescription)", nil)
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

    /// UserDefaults key for Companion subscription state persistence (Build 10).
    /// Survives app restarts. Down-synced to web at document start.
    private static let companionDefaultsKey = "aa_is_companion"

    /// Build 23: Flag set after logout to prevent StoreKit from re-setting companion state
    /// before server confirms the new logged-in user's actual subscription status.
    /// Cleared when checkCompanionOnServer() gets a response (the authoritative answer).
    private static let awaitingServerConfirmKey = "aa_awaiting_server_confirm"

    /// Build 23.2: Subject (`sub`) from the token that was active at logout.
    /// Used to safely decide whether fallback to local StoreKit is allowed if server
    /// confirmation fails after logout -> login (same account only).
    private static let lastLogoutTokenSubjectKey = "aa_last_logout_sub"

    /// Build 27: User-namespaced entitlement cache keys.
    /// Instead of a device-global `aa_is_companion` boolean, entitlement state is stored
    /// per-user as `aa_companion_{userId}`. This prevents logout from wiping entitlement
    /// detection and eliminates cross-account leakage.
    private static let activeUserIdKey = "aa_active_user_id"
    private static let companionKeyPrefix = "aa_companion_"

    /// BUILD 31: Flag set before cache-busting reload after purchase/restore.
    /// Allows buildNativeDiagJS to inject __aaServerVerified=true on the fresh page,
    /// so __aaSuppressContradictions runs immediately after reload.
    private static let justPurchasedKey = "aa_just_purchased"

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
                // Build 27: Check network reachability before purchase.
                // Prevents showing Apple purchase sheet when offline — the sheet
                // would appear and then fail, confusing the user.
                let isOnline = await self.canReachServer()
                if !isOnline {
                    os_log(.info, log: Self.log, "[IAP:buy] Offline — blocking purchase attempt")
                    self.sendPurchaseResult([
                        "status": "error",
                        "action": "buy",
                        "message": "Please connect to the internet to subscribe."
                    ])
                    return
                }
                let result = await AAStoreManager.shared.purchase(productId: productId)

                // Non-success: send result immediately (no server round-trip needed)
                if result.status != "success" {
                    var payload: [String: Any] = ["status": result.status, "action": "buy"]
                    if let pid = result.productId { payload["productId"] = pid }
                    if let msg = result.message { payload["message"] = msg }
                    self.sendPurchaseResult(payload)
                    return
                }

                // ── BUILD 28 FIX (Bug 1): Wait for server confirm BEFORE toast ──
                // Previously we sent isCompanion:true immediately (toast fired), then
                // did fire-and-forget server sync. The page reloaded before the PATCH
                // propagated, so Base44 re-fetched /User/me with stale is_companion=false.
                //
                // New flow:
                //   1. StoreKit confirms → persist locally + update JS __aaIsCompanion
                //   2. Sync JWS to server AND WAIT for 200 OK
                //   3. THEN send success to JS (toast + dismissPaywallOverlay)
                //   4. Force /User/me refetch via JS (no full page reload)
                self.clearAwaitingServerConfirmState(reason: "purchase-success")
                self.persistCompanionState(result.isCompanion)
                self.refreshWebEntitlements(isCompanion: result.isCompanion)

                // Step 2: Sync token first (may not be in UserDefaults yet if < 3s)
                let tokenFoundContinuation: Bool = await withCheckedContinuation { cont in
                    self.syncTokenToUserDefaults { found in
                        cont.resume(returning: found)
                    }
                }
                _ = tokenFoundContinuation  // Used for logging only

                var serverConfirmed = false
                if let jws = result.jws {
                    serverConfirmed = await self.syncCompanionToServerAndWait(jws: jws)
                    os_log(.info, log: Self.log, "[IAP:buy] Server confirm=%{public}@", serverConfirmed ? "YES" : "NO")
                }

                // Step 3: NOW send success toast — server has been updated
                var payload: [String: Any] = ["status": "success", "action": "buy"]
                payload["isCompanion"] = result.isCompanion
                if let pid = result.productId { payload["productId"] = pid }
                self.sendPurchaseResult(payload)

                // Step 4: Force /User/me refetch via JS (no full page reload)
                self.triggerWebRefreshAfterPurchase()
            }

        case "restore":
            Task { @MainActor in
                // Build 23: Check network reachability before restore.
                // StoreKit's Transaction.currentEntitlements works offline from cache,
                // but we need the server to confirm is_companion (E14). If offline,
                // tell the user to connect instead of showing fake "confirmed" from cache.
                let isOnline = await self.canReachServer()
                if !isOnline {
                    // NOTE: Do NOT send isCompanion in the payload — prevents JS from
                    // calling updateSubscriptionStatusUI(false) which would void the UI.
                    self.sendPurchaseResult([
                        "status": "info",
                        "action": "restore",
                        "message": "Please connect to the internet to restore your subscription."
                    ])
                    return
                }

                let result = await AAStoreManager.shared.restorePurchases()

                if !result.isCompanion {
                    // StoreKit found nothing — send result directly (no server check needed)
                    var payload: [String: Any] = [
                        "status": result.status,
                        "action": "restore"
                    ]
                    if let msg = result.message { payload["message"] = msg }
                    self.sendPurchaseResult(payload)
                    // Do NOT persist false or clear flag — preserve existing state.
                    return
                }

                // StoreKit found an active subscription on this Apple ID.
                // Build 27 FIX: Do NOT send isCompanion:true to JS yet — must verify
                // this subscription belongs to the current Base44 account first.
                // Otherwise JS calls updateSubscriptionStatusUI(true) immediately.
                self.clearAwaitingServerConfirmState(reason: "restore-storekit-active")

                // Sync token so we can identify the user + call server
                self.syncTokenToUserDefaults { [weak self] tokenFound in
                    guard let self = self else { return }
                    self.updateActiveUserId()

                    Task { @MainActor in
                        let serverIsCompanion = await self.checkCompanionOnServerAndWait()
                        os_log(.info, log: Self.log, "[IAP:restore] StoreKit=true Server=%{public}@",
                               serverIsCompanion ? "true" : "false")

                        if serverIsCompanion {
                            // Server confirms this Base44 account is companion — unlock
                            self.persistCompanionState(true)
                            self.refreshWebEntitlements(isCompanion: true)
                            self.sendPurchaseResult([
                                "status": "success",
                                "action": "restore",
                                "isCompanion": true
                            ])
                            self.triggerWebRefreshAfterPurchase()
                        } else {
                            // Server says no. Check namespaced cache — same user re-linking?
                            let cached = self.readCompanionStateForCurrentUser()
                            if cached.isCompanion, cached.userId != nil, let jws = result.jws {
                                os_log(.info, log: Self.log, "[IAP:restore] Cache hit for same user — syncing JWS to re-link")
                                self.persistCompanionState(true)
                                self.refreshWebEntitlements(isCompanion: true)
                                self.syncCompanionToServer(jws: jws)
                                self.sendPurchaseResult([
                                    "status": "success",
                                    "action": "restore",
                                    "isCompanion": true
                                ])
                            } else {
                                // Different account — do NOT transfer the subscription.
                                os_log(.info, log: Self.log, "[IAP:restore] StoreKit active but server says no — subscription belongs to different account")
                                self.sendPurchaseResult([
                                    "status": "info",
                                    "action": "restore",
                                    "message": "This subscription is linked to a different account. Please log in with the account that originally purchased the subscription."
                                ])
                            }
                        }
                    }
                }
            }

        case "recheckEntitlements":
            // Build 27 FIX: Server-first entitlement resolution with namespaced cache.
            //
            // Called by JS checkLoginTransition() after login, or by __aaCheckCompanion.
            //
            // Strategy:
            //   1. Check namespaced cache (instant, same-account re-login)
            //   2. Sync token → ask server (authoritative for Base44 account)
            //   3. StoreKit ONLY trusted for same-account (server true OR cache hit)
            //   4. StoreKit alone does NOT grant companion (prevents cross-account leakage)
            Task { @MainActor in
                // Clear any stale awaiting flag from older builds
                if UserDefaults.standard.bool(forKey: Self.awaitingServerConfirmKey) {
                    self.clearAwaitingServerConfirmState(reason: "recheck-cleanup")
                }

                // Step 1: Sync token first — we need user identity for everything
                self.syncTokenWithRetries(delays: [1.0, 3.0, 5.0]) { [weak self] tokenFound in
                    guard let self = self else { return }
                    guard tokenFound else {
                        os_log(.info, log: Self.log, "[IAP:recheck] No token — leaving current state for periodic recovery")
                        return
                    }
                    self.updateActiveUserId()

                    // Step 2: Check namespaced cache — instant same-account re-login
                    let cached = self.readCompanionStateForCurrentUser()
                    if cached.isCompanion, cached.userId != nil {
                        os_log(.info, log: Self.log, "[IAP:recheck] Namespaced cache hit (userId=%{public}@) — immediate unlock",
                               cached.userId ?? "?")
                        self.persistCompanionState(true)
                        self.refreshWebEntitlements(isCompanion: true)
                        // Background server confirm
                        self.checkCompanionOnServer()
                        return
                    }

                    // Step 3: Ask server — authoritative for this Base44 account
                    Task { @MainActor in
                        let serverIsCompanion = await self.checkCompanionOnServerAndWait()
                        let (storeKitIsCompanion, products, _) = await AAStoreManager.shared.checkEntitlementsWithJWS()
                        os_log(.info, log: Self.log, "[IAP:recheck] Server=%{public}@ StoreKit=%{public}@",
                               serverIsCompanion ? "true" : "false",
                               storeKitIsCompanion ? "true" : "false")

                        if serverIsCompanion {
                            // Server confirms this Base44 account is companion
                            self.persistCompanionState(true)
                            self.refreshWebEntitlements(isCompanion: true)
                            self.pushEntitlementCheckToJS(isCompanion: true, products: products)
                            self.triggerWebRefreshAfterPurchase()
                        } else {
                            // Server says no — do NOT trust StoreKit alone (could be
                            // different Apple ID's subscription). User must tap
                            // "Restore Purchases" to link StoreKit to this account.
                            self.persistCompanionState(false)
                            self.refreshWebEntitlements(isCompanion: false)
                            self.pushEntitlementCheckToJS(isCompanion: false, products: products)
                        }
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
    /// Build 27: Routes through namespaced storage when activeUserIdKey is available.
    /// Writes to BOTH `aa_companion_{userId}` AND legacy `aa_is_companion` (write-through
    /// for existing JS injection via `window.__aaIsCompanion` and `buildNativeDiagJS`).
    private func persistCompanionState(_ isCompanion: Bool) {
        let defaults = UserDefaults.standard
        // Always write legacy key (write-through for JS injection compatibility)
        defaults.set(isCompanion, forKey: Self.companionDefaultsKey)

        // Build 27: Also write to user-namespaced key if we know the active user
        if let userId = defaults.string(forKey: Self.activeUserIdKey), !userId.isEmpty {
            let namespacedKey = Self.companionKeyForUser(userId)
            defaults.set(isCompanion, forKey: namespacedKey)
            os_log(.info, log: Self.log, "[IAP] Persisted %{public}@=%{public}@ + legacy aa_is_companion=%{public}@",
                   namespacedKey, isCompanion ? "true" : "false", isCompanion ? "true" : "false")
        } else {
            os_log(.info, log: Self.log, "[IAP] Persisted aa_is_companion=%{public}@ (no active userId for namespace)",
                   isCompanion ? "true" : "false")
        }
    }

    // MARK: – Build 27: User-Namespaced Entitlement Helpers

    /// Returns the UserDefaults key for a specific user's companion state.
    private static func companionKeyForUser(_ userId: String) -> String {
        return "\(companionKeyPrefix)\(userId)"
    }

    /// Extracts user ID from the current auth token and saves it as the active user.
    /// Called after every successful token sync to ensure namespaced reads/writes
    /// target the correct user.
    private func updateActiveUserId() {
        guard let token = UserDefaults.standard.string(forKey: Self.tokenDefaultsKey),
              !token.isEmpty else {
            return
        }
        updateActiveUserId(fromToken: token)
    }

    /// Extracts user ID from a specific token and saves it as the active user.
    private func updateActiveUserId(fromToken token: String) {
        guard let subject = extractTokenSubject(token), !subject.isEmpty else {
            os_log(.info, log: Self.log, "[UserNS] Could not extract userId from token — activeUserId unchanged")
            return
        }
        let existing = UserDefaults.standard.string(forKey: Self.activeUserIdKey)
        if existing != subject {
            UserDefaults.standard.set(subject, forKey: Self.activeUserIdKey)
            os_log(.info, log: Self.log, "[UserNS] Updated activeUserId (changed=%{public}@)",
                   existing != nil ? "true" : "first-set")
        }
    }

    /// Reads the companion state for the currently active user.
    /// Returns the namespaced value if available, falls back to legacy `aa_is_companion`
    /// for migration from pre-Build 27 installs.
    private func readCompanionStateForCurrentUser() -> (isCompanion: Bool, userId: String?) {
        let defaults = UserDefaults.standard
        guard let userId = defaults.string(forKey: Self.activeUserIdKey), !userId.isEmpty else {
            // No active user ID — fall back to legacy key (migration path)
            let legacy = defaults.bool(forKey: Self.companionDefaultsKey)
            os_log(.info, log: Self.log, "[UserNS] No activeUserId — falling back to legacy aa_is_companion=%{public}@",
                   legacy ? "true" : "false")
            return (legacy, nil)
        }
        let namespacedKey = Self.companionKeyForUser(userId)
        if defaults.object(forKey: namespacedKey) != nil {
            let value = defaults.bool(forKey: namespacedKey)
            return (value, userId)
        }
        // Namespaced key doesn't exist yet — fall back to legacy (first run after upgrade)
        let legacy = defaults.bool(forKey: Self.companionDefaultsKey)
        os_log(.info, log: Self.log, "[UserNS] No namespaced key for user — falling back to legacy aa_is_companion=%{public}@",
               legacy ? "true" : "false")
        return (legacy, userId)
    }

    /// Reads a specific user's companion state.
    private func readCompanionStateForUser(_ userId: String) -> Bool {
        return UserDefaults.standard.bool(forKey: Self.companionKeyForUser(userId))
    }

    /// Triggers web-side entitlement refresh after purchase/restore.
    /// Build 20 FIX: Now calls runAllPatches() after updating __aaIsCompanion so the UI
    /// immediately reflects the new state (hides subscribe buttons if subscribed, etc.).
    /// BUILD 31: Also sets __aaServerVerified flag — this function is only called with
    /// isCompanion=true after server confirms, so the flag is trustworthy.
    private func refreshWebEntitlements(isCompanion: Bool) {
        guard let webView = self.webView else { return }
        let js = """
        (function() {
            window.__aaIsCompanion = \(isCompanion ? "true" : "false");
            window.__aaServerVerified = \(isCompanion ? "true" : "false");
            if (typeof window.refreshBase44Entitlements === 'function') {
                window.refreshBase44Entitlements();
            }
            // Build 20: Immediately refresh UI to match new entitlement state
            if (typeof window.__aaRunAllPatches === 'function') {
                window.__aaRunAllPatches();
            }
            // BUILD 31: Suppress contradictory text after server-confirmed update
            if (\(isCompanion ? "true" : "false") && typeof window.__aaSuppressContradictions === 'function') {
                window.__aaSuppressContradictions();
            }
        })();
        """
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                os_log(.error, log: Self.log, "[IAP] Entitlement refresh JS error: %{public}@", error.localizedDescription)
            }
        }
    }

    // MARK: – Build 24: Post-Login Subscription Recovery

    /// Called after login transition when aa_awaiting_server_confirm is set.
    /// Direct approach: check StoreKit → if active → sync JWS to server → unlock.
    /// No subject matching needed — the Worker identifies the user by auth token.
    private func performPostLoginRecovery() {
        guard #available(iOS 15.0, *) else {
            self.clearAwaitingServerConfirmState(reason: "ios-too-old")
            return
        }

        Task { @MainActor in
            // Check StoreKit for active subscription (tied to Apple ID on this device)
            let (storeKitIsCompanion, products, latestJWS) = await AAStoreManager.shared.checkEntitlementsWithJWS()
            os_log(.info, log: Self.log, "[PostLoginRecovery] StoreKit isCompanion=%{public}@ hasJWS=%{public}@ products=%{public}@",
                   storeKitIsCompanion ? "true" : "false",
                   latestJWS != nil ? "true" : "false",
                   products.joined(separator: ","))

            // Build 27 FIX: Server-first — do NOT trust StoreKit alone for companion state.
            // StoreKit reflects the Apple ID, not the Base44 account. Cross-account
            // leakage happens when a different user logs in on the same device.
            //
            // Step 1: Check namespaced cache (same-account instant re-login)
            let cached = self.readCompanionStateForCurrentUser()
            if cached.isCompanion, cached.userId != nil {
                os_log(.info, log: Self.log, "[PostLoginRecovery] Namespaced cache hit — immediate unlock")
                self.clearAwaitingServerConfirmState(reason: "login-cache-hit")
                self.persistCompanionState(true)
                self.refreshWebEntitlements(isCompanion: true)
                self.pushEntitlementCheckToJS(isCompanion: true, products: products)
                // Background: confirm with server
                self.checkCompanionOnServer()
                return
            }

            // Step 2: Ask server — authoritative source for this Base44 account
            let serverIsCompanion = await self.checkCompanionOnServerAndWait()
            os_log(.info, log: Self.log, "[PostLoginRecovery] Server=%{public}@ StoreKit=%{public}@",
                   serverIsCompanion ? "true" : "false",
                   storeKitIsCompanion ? "true" : "false")

            self.clearAwaitingServerConfirmState(reason: serverIsCompanion ? "login-server-confirmed" : "login-no-subscription")
            if serverIsCompanion {
                self.persistCompanionState(true)
                self.refreshWebEntitlements(isCompanion: true)
                self.triggerWebRefreshAfterPurchase()
            } else {
                // Server says no — do NOT trust StoreKit alone. User must
                // tap "Restore Purchases" to link this Apple ID's subscription.
                self.persistCompanionState(false)
                self.refreshWebEntitlements(isCompanion: false)
            }
            self.pushEntitlementCheckToJS(isCompanion: serverIsCompanion, products: products)
        }
    }

    // MARK: – Build 27: Server-First Entitlement Check

    /// Asks the server which Base44 account has is_companion=true.
    /// Build 27 FIX: Server is authoritative. StoreKit alone does NOT grant companion
    /// (prevents cross-account leakage when Apple ID ≠ Base44 user).
    private func performServerFirstEntitlementCheck(storeKitProducts products: [String]) {
        Task { @MainActor in
            let serverIsCompanion = await self.checkCompanionOnServerAndWait()

            os_log(.info, log: Self.log, "[ServerFirst] Server isCompanion=%{public}@",
                   serverIsCompanion ? "true" : "false")

            self.persistCompanionState(serverIsCompanion)
            self.refreshWebEntitlements(isCompanion: serverIsCompanion)
            self.pushEntitlementCheckToJS(isCompanion: serverIsCompanion, products: products)
            if serverIsCompanion {
                self.triggerWebRefreshAfterPurchase()
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

    /// Build 23: Quick reachability check — HEAD request to worker with 3s timeout.
    /// Returns true if server responds (any status code), false if network error.
    private func canReachServer() async -> Bool {
        let workerURL = Self.companionWorkerURL
        guard !workerURL.contains("YOUR_SUBDOMAIN"),
              let url = URL(string: "\(workerURL)/check-companion") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 3

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            os_log(.info, log: Self.log, "[Reachability] Server responded with %d", statusCode)
            return statusCode > 0
        } catch {
            os_log(.info, log: Self.log, "[Reachability] Server unreachable: %{public}@", error.localizedDescription)
            return false
        }
    }

    /// Build 23: Async version of syncCompanionToServer that waits for the result.
    /// Returns true if server confirmed (200 OK), false if network error or auth failure.
    /// Used by Restore flow to ensure server confirmation before claiming success (E14).
    private func syncCompanionToServerAndWait(jws: String?) async -> Bool {
        guard let jws = jws else {
            // No JWS — try a direct server check instead
            return await checkCompanionOnServerAndWait()
        }

        guard let authToken = UserDefaults.standard.string(forKey: Self.tokenDefaultsKey),
              !authToken.isEmpty else {
            os_log(.info, log: Self.log, "[ServerSync:await] No auth token — cannot verify with server")
            return false
        }

        let workerURL = Self.companionWorkerURL
        guard !workerURL.contains("YOUR_SUBDOMAIN"),
              let url = URL(string: "\(workerURL)/validate-receipt") else {
            os_log(.info, log: Self.log, "[ServerSync:await] Worker URL not configured")
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let body: [String: String] = ["jws": jws, "authToken": authToken]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return false
        }
        request.httpBody = bodyData

        os_log(.info, log: Self.log, "[ServerSync:await] Posting JWS to Worker...")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let responseStr = String(data: data, encoding: .utf8) {
                os_log(.info, log: Self.log, "[ServerSync:await] Response %d: %{public}@", statusCode, responseStr)
            }
            DispatchQueue.main.async {
                self.pushWorkerResponseToJS(endpoint: "/validate-receipt", statusCode: statusCode, error: nil)
            }
            return statusCode == 200
        } catch {
            os_log(.error, log: Self.log, "[ServerSync:await] Network error: %{public}@", error.localizedDescription)
            DispatchQueue.main.async {
                self.pushWorkerResponseToJS(endpoint: "/validate-receipt", statusCode: 0, error: error.localizedDescription)
            }
            return false
        }
    }

    /// Build 23: Async check-companion that returns true if server says companion.
    /// Build 24: No longer clears awaiting flag — callers manage flag lifecycle explicitly.
    private func checkCompanionOnServerAndWait() async -> Bool {
        guard let authToken = UserDefaults.standard.string(forKey: Self.tokenDefaultsKey),
              !authToken.isEmpty else {
            return false
        }

        let workerURL = Self.companionWorkerURL
        guard !workerURL.contains("YOUR_SUBDOMAIN"),
              let url = URL(string: "\(workerURL)/check-companion") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            let serverIsCompanion = json["isCompanion"] as? Bool ?? false
            os_log(.info, log: Self.log, "[ServerCheck:await] Status %d, isCompanion=%{public}@", statusCode, serverIsCompanion ? "true" : "false")
            return serverIsCompanion
        } catch {
            os_log(.error, log: Self.log, "[ServerCheck:await] Network error: %{public}@", error.localizedDescription)
            return false
        }
    }

    /// Forces the WebView to reload so the Base44 React app re-fetches /User/me
    /// BUILD 31 FIX: Force immediate unlock after purchase/restore.
    ///
    /// Root cause of Build 30 failure on real iOS:
    ///   We injected "Companion Active" from __aaIsCompanion (local state),
    ///   but Base44 React independently fetches /User/me from server.
    ///   If the Worker PATCH hadn't propagated yet, or Base44 cached old data,
    ///   Base44 showed "Companion isn't active" on the SAME page → contradiction.
    ///
    /// Build 31 approach:
    ///   1. Update localStorage.base44_user.is_companion = true
    ///   2. Set __aaIsCompanion = true + __aaServerVerified = true + run UI patches
    ///   3. Suppress any Base44 "not active" text (since server PATCH was already done)
    ///   4. Dismiss paywall overlays
    ///   5. Cache-busting reload after 2s (forces Base44 to re-fetch fresh /User/me)
    private func triggerWebRefreshAfterPurchase() {
        guard let webView = self.webView else {
            os_log(.error, log: Self.log, "[DIAG:iap] triggerWebRefreshAfterPurchase — webView is nil")
            return
        }

        // BUILD 31 CRITICAL: Set flag BEFORE reload so buildNativeDiagJS injects
        // __aaServerVerified=true on the fresh page. Without this, the reload
        // resets __aaServerVerified=false and contradiction suppression breaks.
        UserDefaults.standard.set(true, forKey: Self.justPurchasedKey)
        os_log(.info, log: Self.log, "[DIAG:iap] Set aa_just_purchased=true for post-reload")

        let js = """
        (function() {
            console.log('[AA:B31] triggerWebRefreshAfterPurchase — starting');

            // Step 1: Update localStorage so React sees is_companion=true on next mount
            try {
                var stored = localStorage.getItem('base44_user');
                if (stored) {
                    var u = JSON.parse(stored);
                    u.is_companion = true;
                    u.companion_product_id = 'com.abideandanchor.companion.monthly';
                    localStorage.setItem('base44_user', JSON.stringify(u));
                    console.log('[AA:B31] Updated localStorage.base44_user.is_companion=true');
                }
            } catch(e) {
                console.log('[AA:B31] localStorage update failed: ' + e.message);
            }

            // Step 2: Immediate visual update
            window.__aaIsCompanion = true;
            window.__aaServerVerified = true;  // BUILD 31: Flag that server has confirmed
            if (typeof window.__aaRunAllPatches === 'function') {
                window.__aaRunAllPatches();
            }

            // Step 3: Suppress any Base44 "not active" / contradictory text immediately
            if (typeof window.__aaSuppressContradictions === 'function') {
                window.__aaSuppressContradictions();
            }

            // Step 4: Dismiss any paywall overlays still showing
            var children = document.body.children;
            for (var i = 0; i < children.length; i++) {
                var el = children[i];
                if (el.id === 'root') continue;
                if (el.id && el.id.indexOf('aa-') === 0) continue;
                if (el.classList && (el.classList.contains('aa-toast') || el.classList.contains('aa-diag-overlay'))) continue;
                var style = window.getComputedStyle(el);
                if (style.display === 'none') continue;
                if (style.position === 'fixed' || style.position === 'absolute') {
                    var text = (el.textContent || '').toLowerCase();
                    if (text.indexOf('subscribe') !== -1 || text.indexOf('companion') !== -1 ||
                        text.indexOf('pricing') !== -1 || text.indexOf('upgrade') !== -1 ||
                        text.indexOf('monthly') !== -1 || text.indexOf('restore purchase') !== -1) {
                        el.style.display = 'none';
                        el.setAttribute('data-aa-paywall-dismissed', '1');
                        console.log('[AA:B31] Dismissed paywall overlay');
                    }
                }
            }

            // Step 5: Cache-busting reload after 2s
            // Use query param to bust CDN/browser cache on Base44's /User/me API
            // so React re-fetches FRESH data with is_companion=true from server
            setTimeout(function() {
                console.log('[AA:B31] Cache-busting reload for React re-mount');
                var path = window.location.pathname;
                // Strip any existing cache-bust param
                window.location.href = path + '?_aat=' + Date.now();
            }, 2000);
        })();
        """
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                os_log(.error, log: Self.log, "[DIAG:iap] B31 JS refresh failed: %{public}@ — direct reload", error.localizedDescription)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    webView.reloadFromOrigin()
                }
            } else {
                os_log(.info, log: Self.log, "[DIAG:iap] B31 JS refresh injected — cache-bust reload in 2s")
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
                self.resolveAwaitingConfirmFallbackIfSafe(clearIfNotApplied: true)
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async { self.pushWorkerResponseToJS(endpoint: "/check-companion", statusCode: statusCode, error: "Invalid response") }
                self.resolveAwaitingConfirmFallbackIfSafe(clearIfNotApplied: true)
                return
            }

            let serverIsCompanion = json["isCompanion"] as? Bool ?? false
            // Build 27: Use namespaced read for local comparison
            let localIsCompanion = self.readCompanionStateForCurrentUser().isCompanion
            let wasAwaitingConfirm = UserDefaults.standard.bool(forKey: Self.awaitingServerConfirmKey)

            DispatchQueue.main.async { self.pushWorkerResponseToJS(endpoint: "/check-companion", statusCode: statusCode, error: nil) }

            // Build 23.3: Awaiting-confirm + server false can otherwise lock user in false state
            // after logout->login (local was intentionally cleared on logout). Evaluate guarded
            // same-account fallback before normal reconciliation.
            // Build 24: Return after handling awaiting case — the fallback runs async and will
            // set the correct state. Falling through to the stale localIsCompanion reconciliation
            // would either no-op (both false) or interfere with the async fallback result.
            if wasAwaitingConfirm {
                if serverIsCompanion {
                    self.clearAwaitingServerConfirmState(reason: "server-answered-companion-true")
                    // Server confirmed companion — persist and update UI immediately
                    DispatchQueue.main.async {
                        self.persistCompanionState(true)
                        self.refreshWebEntitlements(isCompanion: true)
                    }
                } else {
                    self.resolveAwaitingConfirmFallbackIfSafe(clearIfNotApplied: true)
                }
                return
            }

            if serverIsCompanion != localIsCompanion {
                os_log(.info, log: Self.log, "[ServerCheck] Server companion=%{public}@ differs from local=%{public}@ — checking StoreKit",
                       serverIsCompanion ? "true" : "false", localIsCompanion ? "true" : "false")

                // Build 16: Before downgrading from companion → non-companion,
                // cross-check local StoreKit entitlements. If StoreKit says user has
                // an active subscription, trust StoreKit over the server.
                // The server's companion_expires_at can be stale (doesn't track auto-renewals).
                if !serverIsCompanion && localIsCompanion {
                    if #available(iOS 15.0, *) {
                        Task { @MainActor in
                            let (storeKitIsCompanion, products) = await AAStoreManager.shared.checkEntitlements()
                            os_log(.info, log: Self.log, "[ServerCheck] StoreKit cross-check: isCompanion=%{public}@ products=%{public}@",
                                   storeKitIsCompanion ? "true" : "false", products.joined(separator: ","))
                            if storeKitIsCompanion {
                                // StoreKit says active — server is wrong (stale expiry). Keep local state.
                                // Build 27: Do NOT auto-sync JWS to server — prevents cross-account
                                // leakage. User can tap "Restore Purchases" to explicitly sync.
                                os_log(.info, log: Self.log, "[ServerCheck] StoreKit active — ignoring server downgrade (no auto-sync)")
                            } else {
                                // StoreKit also says not subscribed — genuinely lost subscription.
                                os_log(.info, log: Self.log, "[ServerCheck] StoreKit also not subscribed — updating local to non-companion")
                                self.persistCompanionState(false)
                                self.refreshWebEntitlements(isCompanion: false)
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

        // Build 27: User-namespaced entitlement cache — logout clears SESSION state only.
        // Build 30 FIX (Bug C): Also clear all injected subscription DOM elements via JS.
        // Previously, the 'aa-already-subscribed' banner and subscription status section
        // persisted across logout/login because performFullLogout didn't touch the DOM.
        // User B would see User A's 'active subscription' banner.
        UserDefaults.standard.set(false, forKey: Self.companionDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.activeUserIdKey)
        // BUILD 31: Clear just-purchased flag on logout
        UserDefaults.standard.set(false, forKey: Self.justPurchasedKey)

        // BUILD 31 FIX (Bug C): Clear subscription UI state from DOM
        let clearSubUI = """
        (function() {
            console.log('[AA:B31] Clearing subscription UI state on logout');
            window.__aaIsCompanion = false;
            window.__aaServerVerified = false;  // BUILD 31: Clear server verification

            // Remove injected subscription elements
            var idsToRemove = ['aa-already-subscribed', 'aa-subscription-section', 'aa-sub-restore-btn', 'aa-paywall-restore-btn'];
            idsToRemove.forEach(function(id) {
                var el = document.getElementById(id);
                if (el) { el.remove(); console.log('[AA:B31] Removed #' + id); }
            });

            // Unhide any elements hidden by handleAlreadySubscribed
            document.querySelectorAll('[data-aa-sub-hidden]').forEach(function(el) {
                el.style.display = '';
                el.removeAttribute('data-aa-sub-hidden');
            });

            // Unhide any contradiction-suppressed elements (BUILD 31)
            document.querySelectorAll('[data-aa-contradiction-hidden]').forEach(function(el) {
                el.style.display = '';
                el.removeAttribute('data-aa-contradiction-hidden');
            });

            // Clear dismissed paywall overlays
            document.querySelectorAll('[data-aa-paywall-dismissed]').forEach(function(el) {
                el.style.display = '';
                el.removeAttribute('data-aa-paywall-dismissed');
            });

            // Update localStorage.base44_user to clear is_companion
            try {
                var stored = localStorage.getItem('base44_user');
                if (stored) {
                    var u = JSON.parse(stored);
                    u.is_companion = false;
                    delete u.companion_product_id;
                    localStorage.setItem('base44_user', JSON.stringify(u));
                }
            } catch(e) {}

            // Run patches to reset UI state
            if (typeof window.__aaRunAllPatches === 'function') {
                window.__aaRunAllPatches();
            }
        })();
        """
        webView.evaluateJavaScript(clearSubUI, completionHandler: nil)

        // Clear any stale awaiting flag from previous builds
        if UserDefaults.standard.bool(forKey: Self.awaitingServerConfirmKey) {
            UserDefaults.standard.set(false, forKey: Self.awaitingServerConfirmKey)
            UserDefaults.standard.removeObject(forKey: Self.lastLogoutTokenSubjectKey)
        }

        refreshNativeDiagUserScript()

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
        // Build 23: If awaiting server confirm (post-logout), skip persisting StoreKit result
        // to prevent Apple ID entitlements from leaking into a different app account.
        // HOWEVER: if aa_is_companion is already true in UserDefaults, it means a purchase
        // or restore was completed for this account — the flag is stale and should be cleared.
        if #available(iOS 15.0, *) {
            Task { @MainActor in
                var awaitingConfirm = UserDefaults.standard.bool(forKey: Self.awaitingServerConfirmKey)
                // Build 27: Use namespaced read for cold boot
                let (alreadyCompanion, _) = self.readCompanionStateForCurrentUser()
                let hasToken = self.hasTokenInUserDefaults()

                // Build 23: If no auth token, skip persisting NEW StoreKit results (the Apple ID
                // subscription might belong to a different app account). But still USE the existing
                // namespaced state — it was verified by a previous session's StoreKit check and is
                // trustworthy. This prevents cold boot from voiding subscriptions when the token
                // hasn't been synced from localStorage yet.
                if !hasToken {
                    os_log(.info, log: Self.log, "[BOOT] No auth token — using existing state (isCompanion=%{public}@), skipping StoreKit persist", alreadyCompanion ? "true" : "false")
                    self.pushEntitlementCheckToJS(isCompanion: alreadyCompanion, products: [])
                    return
                }

                // Stale flag guard: if UserDefaults already says companion, the flag was set
                // before a purchase/restore happened — clear it so we don't block the boot check.
                if awaitingConfirm && alreadyCompanion {
                    os_log(.info, log: Self.log, "[BOOT] Clearing stale awaiting flag — aa_is_companion already true")
                    self.clearAwaitingServerConfirmState(reason: "stale-flag-boot")
                    awaitingConfirm = false
                }

                let (isCompanion, activeProducts) = await AAStoreManager.shared.checkEntitlements()
                if awaitingConfirm {
                    os_log(.info, log: Self.log, "[BOOT] Awaiting server confirm — skipping StoreKit persist (StoreKit=%{public}@)", isCompanion ? "true" : "false")
                    self.pushEntitlementCheckToJS(isCompanion: false, products: [])
                } else {
                    self.persistCompanionState(isCompanion)
                    self.pushEntitlementCheckToJS(isCompanion: isCompanion, products: activeProducts)
                }
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
        AAStoreManager.shared.startTransactionListener { [weak self] isCompanion, jws in
            guard let self = self else { return }
            // Build 23: No auth token means no logged-in user — ignore transaction updates.
            if !self.hasTokenInUserDefaults() {
                os_log(.info, log: Self.log, "[TxnUpdate] No auth token — ignoring StoreKit update (no logged-in user)")
                return
            }
            // Build 23: Respect awaiting-server-confirm flag — don't let StoreKit
            // transaction updates leak Apple ID entitlements into a different app account.
            let awaitingConfirm = UserDefaults.standard.bool(forKey: Self.awaitingServerConfirmKey)
            if awaitingConfirm {
                os_log(.info, log: Self.log, "[TxnUpdate] Awaiting server confirm — ignoring StoreKit update (isCompanion=%{public}@)", isCompanion ? "true" : "false")
                return
            }
            // Build 27 FIX: Do NOT blindly trust StoreKit for companion state.
            // StoreKit reflects Apple ID, not Base44 account. Only apply if
            // server confirms or namespaced cache matches (same account).
            if isCompanion {
                // StoreKit says active — check if this is the same account (cache hit)
                self.updateActiveUserId()
                let cached = self.readCompanionStateForCurrentUser()
                if cached.isCompanion, cached.userId != nil {
                    // Same account, previously confirmed — apply immediately
                    os_log(.info, log: Self.log, "[TxnUpdate] Cache hit — applying StoreKit companion=true")
                    self.persistCompanionState(true)
                    self.refreshWebEntitlements(isCompanion: true)
                    self.sendPurchaseResult([
                        "status": "success",
                        "isCompanion": true,
                        "source": "transactionUpdate"
                    ])
                } else {
                    // Unknown account match — ask server instead of trusting StoreKit
                    os_log(.info, log: Self.log, "[TxnUpdate] No cache hit — checking server (not trusting StoreKit alone)")
                    Task { @MainActor in
                        let serverIsCompanion = await self.checkCompanionOnServerAndWait()
                        if serverIsCompanion {
                            self.persistCompanionState(true)
                            self.refreshWebEntitlements(isCompanion: true)
                            self.sendPurchaseResult([
                                "status": "success",
                                "isCompanion": true,
                                "source": "transactionUpdate"
                            ])
                        } else {
                            os_log(.info, log: Self.log, "[TxnUpdate] Server rejected StoreKit Apple ID subscription for this Base44 user. Reverting StoreKit leak.")
                            // Do NOT send success to JS — it's not their subscription!
                        }
                    }
                }
            } else {
                // StoreKit says NOT companion (expiry, refund) — safe to apply
                os_log(.info, log: Self.log, "[TxnUpdate] StoreKit companion=false — applying")
                self.persistCompanionState(false)
                self.refreshWebEntitlements(isCompanion: false)
                self.sendPurchaseResult([
                    "status": "success",
                    "isCompanion": false,
                    "source": "transactionUpdate"
                ])
            }
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

    /// Build 23: Replaces the atDocumentStart WKUserScript with a freshly-built version.
    /// Must be called after logout (or any state change) so that subsequent page loads
    /// inject the correct __aaIsCompanion / hasNativeToken values. Without this, the
    /// script captured at boot keeps injecting stale state on every navigation.
    private func refreshNativeDiagUserScript() {
        guard let webView = self.webView else { return }
        let controller = webView.configuration.userContentController

        // WKUserContentController has no API to remove a specific script,
        // so we must remove all and re-add them.
        controller.removeAllUserScripts()

        // Re-add native diagnostics (now with updated state)
        let nativeDiagScript = WKUserScript(
            source: buildNativeDiagJS(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        controller.addUserScript(nativeDiagScript)

        // Re-add IAP bridge
        let iapBridgeScript = WKUserScript(
            source: Self.iapBridgeJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        controller.addUserScript(iapBridgeScript)

        // Re-add CSS injection
        let cssScript = WKUserScript(
            source: Self.cssInjection,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        controller.addUserScript(cssScript)

        // Re-add main JS patches
        let jsScript = WKUserScript(
            source: Self.jsInjection,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        controller.addUserScript(jsScript)

        os_log(.info, log: Self.log, "[LOGOUT] Refreshed WKUserScripts with updated state (isCompanion will be false)")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        webView?.removeObserver(self, forKeyPath: "URL")
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
        syncTokenToUserDefaults(completion: nil)
    }

    /// Syncs auth token from localStorage to UserDefaults.
    /// The optional completion handler is called on the main thread with `true` if a token
    /// was found and saved (or already present), `false` otherwise.
    private func syncTokenToUserDefaults(completion: ((Bool) -> Void)?) {
        guard let webView = self.webView else {
            completion?(false)
            return
        }

        // Guard: skip if page hasn't navigated yet — localStorage throws SecurityError at about:blank
        guard let pageURL = webView.url, pageURL.scheme == "https" else {
            os_log(.info, log: Self.log, "[TokenSync:UP] Skipped — page not yet loaded (url=%{public}@)",
                   webView.url?.absoluteString ?? "nil")
            completion?(false)
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
            guard self != nil else {
                completion?(false)
                return
            }

            if let token = result as? String, !token.isEmpty {
                let existing = UserDefaults.standard.string(forKey: Self.tokenDefaultsKey)
                if existing != token {
                    UserDefaults.standard.set(token, forKey: Self.tokenDefaultsKey)
                    os_log(.info, log: Self.log, "[TokenSync:UP] Saved token to UserDefaults (len=%d)", token.count)
                } else {
                    os_log(.info, log: Self.log, "[TokenSync:UP] UserDefaults already has current token (len=%d)", token.count)
                }
                // Build 27: Update active user ID after every token sync so namespaced
                // entitlement reads/writes target the correct user.
                self?.updateActiveUserId(fromToken: token)
                completion?(true)
            } else {
                os_log(.info, log: Self.log, "[TokenSync:UP] No token found in localStorage")
                completion?(false)
            }
        }
    }

    /// Clears the token from UserDefaults (called during logout).
    private func clearTokenFromUserDefaults() {
        UserDefaults.standard.removeObject(forKey: Self.tokenDefaultsKey)
        os_log(.info, log: Self.log, "[TokenSync] Cleared token from UserDefaults")
    }

    /// Build 26: Retry token sync with configurable backoff delays.
    /// Calls `syncTokenToUserDefaults` immediately, then retries at each delay if token not found.
    /// Completion is called with `true` on first success, or `false` after all retries exhausted.
    private func syncTokenWithRetries(delays: [Double], completion: @escaping (Bool) -> Void) {
        syncTokenToUserDefaults { [weak self] found in
            guard let self = self else { completion(false); return }
            if found {
                completion(true)
                return
            }
            // Start retry chain
            self.syncTokenRetryChain(delays: delays, attempt: 0, completion: completion)
        }
    }

    private func syncTokenRetryChain(delays: [Double], attempt: Int, completion: @escaping (Bool) -> Void) {
        guard attempt < delays.count else {
            completion(false)
            return
        }
        let delay = delays[attempt]
        os_log(.info, log: Self.log, "[IAP:recheck] No token — retrying sync in %.1fs (attempt %d/%d)", delay, attempt + 1, delays.count)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { completion(false); return }
            self.syncTokenToUserDefaults { [weak self] found in
                guard let self = self else { completion(false); return }
                if found {
                    completion(true)
                } else {
                    self.syncTokenRetryChain(delays: delays, attempt: attempt + 1, completion: completion)
                }
            }
        }
    }

    /// Checks if UserDefaults has a stored token.
    private func hasTokenInUserDefaults() -> Bool {
        let token = UserDefaults.standard.string(forKey: Self.tokenDefaultsKey)
        return token?.isEmpty == false
    }

    /// Gets the stored token length (for diagnostics — never log the token itself).
    private func tokenLengthInUserDefaults() -> Int {
        return UserDefaults.standard.string(forKey: Self.tokenDefaultsKey)?.count ?? 0
    }

    /// Build 26 safety net: After periodic token sync succeeds, check if the user is
    /// currently marked as non-companion (e.g., after logout→login where recheckEntitlements
    /// retries all failed). If aa_is_companion is false and we now have a token, ask the
    /// server — it may confirm the subscription for the same account.
    /// Cross-account safety: `checkCompanionOnServer()` calls GET /check-companion with
    /// the current account's auth token. Server returns true only for the account that
    /// actually has is_companion = true.
    /// Build 27 FIX: Safety net recovery after periodic token sync.
    /// If we have a token but companion is false, check namespaced cache first (instant
    /// same-account), then server (authoritative). StoreKit alone does NOT grant companion
    /// (prevents cross-account leakage when Apple ID ≠ Base44 user).
    private func triggerPostLoginRecoveryIfNeeded(tokenFound: Bool) {
        guard tokenFound else { return }

        // Quick check: if already companion (from any source), nothing to do
        let legacyIsCompanion = UserDefaults.standard.bool(forKey: Self.companionDefaultsKey)
        if legacyIsCompanion {
            os_log(.info, log: Self.log, "[PostLoginRecovery] Already companion — no recovery needed")
            return
        }

        guard #available(iOS 15.0, *) else { return }
        Task { @MainActor in
            self.updateActiveUserId()

            // Step 1: Check namespaced cache (same-account instant re-login)
            let cached = self.readCompanionStateForCurrentUser()
            if cached.isCompanion, cached.userId != nil {
                os_log(.info, log: Self.log, "[PostLoginRecovery] Namespaced cache hit — immediate unlock")
                self.persistCompanionState(true)
                self.refreshWebEntitlements(isCompanion: true)
                // Background: confirm with server
                self.checkCompanionOnServer()
                return
            }

            // Step 2: Ask server — authoritative for this Base44 account
            os_log(.info, log: Self.log, "[PostLoginRecovery] No cache hit — checking server")
            self.checkCompanionOnServer()
        }
    }

    /// Decodes JWT payload and returns a stable user subject identifier when available.
    /// Used only for same-account safety checks; token signature validation is not required here.
    private func extractTokenSubject(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }

        guard let payloadData = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return nil
        }

        // Build 24: Expanded fallback chain — Base44 tokens may use _id or id instead
        // of standard JWT sub claim. Also try email as last resort (stable per-user).
        return (json["sub"] as? String) ??
               (json["user_id"] as? String) ??
               (json["uid"] as? String) ??
               (json["_id"] as? String) ??
               (json["id"] as? String) ??
               (json["email"] as? String)
    }

    /// Clears awaiting-server-confirm state and refreshes atDocumentStart script injection.
    private func clearAwaitingServerConfirmState(reason: String) {
        let defaults = UserDefaults.standard
        let hadFlag = defaults.bool(forKey: Self.awaitingServerConfirmKey)
        defaults.set(false, forKey: Self.awaitingServerConfirmKey)
        defaults.removeObject(forKey: Self.lastLogoutTokenSubjectKey)
        os_log(.info, log: Self.log, "[AwaitingConfirm] Cleared (%{public}@), hadFlag=%{public}@",
               reason, hadFlag ? "true" : "false")
        if hadFlag {
            DispatchQueue.main.async { self.refreshNativeDiagUserScript() }
        }
    }

    /// If server confirmation is unavailable, allow StoreKit fallback ONLY when the
    /// post-login token subject matches the subject from the just-logged-out account.
    /// This prevents cross-account leakage while avoiding same-account false downgrades.
    ///
    /// Build 24: When subject extraction fails (Base44 token format edge case), fall back
    /// to a StoreKit check + server sync approach: if StoreKit has an active entitlement,
    /// sync the JWS to the server (which ties it to the CURRENTLY logged-in user via auth
    /// token). This is safe because the Worker validates the JWS AND uses the auth token
    /// to update the correct Base44 user — no cross-account leakage possible.
    private func resolveAwaitingConfirmFallbackIfSafe(clearIfNotApplied: Bool = false) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.awaitingServerConfirmKey) else { return }

        let currentToken = defaults.string(forKey: Self.tokenDefaultsKey)
        let hasToken = currentToken?.isEmpty == false
        let currentSubject = hasToken ? extractTokenSubject(currentToken!) : nil
        let logoutSubject = defaults.string(forKey: Self.lastLogoutTokenSubjectKey)

        // Path A: Both subjects available — strict same-account check
        if let currentSub = currentSubject, !currentSub.isEmpty,
           let logoutSub = logoutSubject, !logoutSub.isEmpty {
            if currentSub == logoutSub {
                // Same account — trust StoreKit directly
                guard #available(iOS 15.0, *) else { return }
                Task { @MainActor in
                    let (isCompanion, products) = await AAStoreManager.shared.checkEntitlements()
                    os_log(.info, log: Self.log, "[AwaitingConfirm] Safe fallback applied for same account (isCompanion=%{public}@)",
                           isCompanion ? "true" : "false")
                    self.clearAwaitingServerConfirmState(reason: "same-account-safe-fallback")
                    self.persistCompanionState(isCompanion)
                    self.refreshWebEntitlements(isCompanion: isCompanion)
                    self.pushEntitlementCheckToJS(isCompanion: isCompanion, products: products)
                }
                return
            } else {
                // Different account — do NOT trust StoreKit locally
                os_log(.info, log: Self.log, "[AwaitingConfirm] Safe fallback blocked — account changed")
                if clearIfNotApplied {
                    self.clearAwaitingServerConfirmState(reason: "safe-fallback-account-changed")
                }
                return
            }
        }

        // Path B: Subject extraction failed — can't prove same or different account.
        // Build 24: Instead of leaving the user voided, check StoreKit and if active,
        // sync JWS to the server. The server sync uses the current auth token, so the
        // Worker will set is_companion=true on the CORRECT Base44 user (no leakage).
        // After sync, re-check the server to get authoritative state.
        guard hasToken else {
            os_log(.info, log: Self.log, "[AwaitingConfirm] Safe fallback skipped — no token available")
            if clearIfNotApplied {
                self.clearAwaitingServerConfirmState(reason: "safe-fallback-unavailable")
            }
            return
        }

        // Build 27 FIX: Subject unavailable — ask server (authoritative).
        // Do NOT trust StoreKit alone — prevents cross-account leakage.
        os_log(.info, log: Self.log, "[AwaitingConfirm] Subject unavailable — using server GET recovery (no StoreKit trust)")
        guard #available(iOS 15.0, *) else { return }
        Task { @MainActor in
            let serverIsCompanion = await self.checkCompanionOnServerAndWait()
            os_log(.info, log: Self.log, "[AwaitingConfirm] Server isCompanion=%{public}@",
                   serverIsCompanion ? "true" : "false")
            self.clearAwaitingServerConfirmState(reason: serverIsCompanion ? "server-confirmed" : "server-not-companion")
            if serverIsCompanion {
                self.persistCompanionState(true)
                self.refreshWebEntitlements(isCompanion: true)
            } else {
                self.refreshWebEntitlements(isCompanion: false)
            }
        }
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
        // Build 26 fix: After token sync succeeds, check if aa_is_companion is false
        // (e.g., after logout→login where recheckEntitlements retries all failed).
        // If so, trigger a server check as a safety net recovery.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.syncTokenToUserDefaults { [weak self] found in
                // Build 27: updateActiveUserId is called inside syncTokenToUserDefaults now,
                // so the namespaced key is ready before triggerPostLoginRecoveryIfNeeded.
                self?.triggerPostLoginRecoveryIfNeeded(tokenFound: found)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
            self?.syncTokenToUserDefaults { [weak self] found in
                self?.triggerPostLoginRecoveryIfNeeded(tokenFound: found)
            }
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
        // Build 23: Respect awaiting-server-confirm flag AND no-token guard on resume too.
        if #available(iOS 15.0, *) {
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let hasToken = self.hasTokenInUserDefaults()

                // Build 23: No auth token — skip persisting NEW StoreKit results but use existing
                // UserDefaults state. Token may not be synced from localStorage yet.
                if !hasToken {
                    // Build 27: Use namespaced read for foreground resume
                    let (existingCompanion, _) = self.readCompanionStateForCurrentUser()
                    os_log(.info, log: Self.log, "[RESUME] No auth token — using existing state (isCompanion=%{public}@), skipping StoreKit persist", existingCompanion ? "true" : "false")
                    self.pushEntitlementCheckToJS(isCompanion: existingCompanion, products: [])
                    return
                }

                let awaitingConfirm = UserDefaults.standard.bool(forKey: Self.awaitingServerConfirmKey)
                let (isCompanion, activeProducts) = await AAStoreManager.shared.checkEntitlements()
                if awaitingConfirm {
                    os_log(.info, log: Self.log, "[RESUME] Awaiting server confirm — skipping StoreKit persist (StoreKit=%{public}@)", isCompanion ? "true" : "false")
                    self.pushEntitlementCheckToJS(isCompanion: false, products: [])
                } else {
                    self.persistCompanionState(isCompanion)
                    self.refreshWebEntitlements(isCompanion: isCompanion)
                    self.pushEntitlementCheckToJS(isCompanion: isCompanion, products: activeProducts)
                }
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
            }

            // Build 27: Native safety net — check StoreKit on every navigation to a
            // non-login page. This catches the case where Base44 does a full page redirect
            // after login (window.location.href = '/') instead of SPA navigation.
            // JS checkLoginTransition() only hooks pushState/replaceState, so a full
            // redirect means recheckEntitlements never fires from JS.
            if let url = newURL, url.scheme == "https",
               !url.path.hasPrefix("/login") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    self?.nativeEntitlementRecovery()
                }
            }
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }

    // MARK: – Build 27: Native Entitlement Recovery

    /// BUILD 28 FIX (Bug 3): Added 5-second debounce to prevent rapid-fire calls during
    /// login transitions. Previously, every URL KVO notification triggered a server call
    /// with a 2-second delay. During login, multiple URL changes fire in quick succession
    /// (login → / → dashboard). Without debounce, the active userId could be stale
    /// during the first call (still set to previous user or nil), causing cross-account leakage.
    private var lastEntitlementRecoveryTime: Date = .distantPast

    /// Safety net: checks namespaced cache + server when navigating to a non-login page.
    /// If aa_is_companion is false but this user was previously confirmed, restore immediately.
    /// No-op if already companion. Runs on every URL change (debounced by 5s guard).
    /// Build 27 FIX: Does NOT trust StoreKit alone — prevents cross-account leakage.
    private func nativeEntitlementRecovery() {
        // Quick exit if already companion — nothing to do
        let isCompanion = UserDefaults.standard.bool(forKey: Self.companionDefaultsKey)
        if isCompanion { return }

        // BUILD 28 FIX: 5-second debounce prevents rapid-fire during login transitions
        let now = Date()
        if now.timeIntervalSince(lastEntitlementRecoveryTime) < 5.0 {
            os_log(.info, log: Self.log, "[NativeRecovery] Debounced — last check was %.1fs ago", now.timeIntervalSince(lastEntitlementRecoveryTime))
            return
        }
        lastEntitlementRecoveryTime = now

        guard #available(iOS 15.0, *) else { return }

        // BUILD 28 FIX: Validate activeUserId matches current token BEFORE cache read.
        // During login transitions, activeUserId may be stale (previous user or nil).
        // Re-sync it from the current token first.
        self.updateActiveUserId()

        // Step 1: Check namespaced cache (same-account instant re-login)
        let cached = readCompanionStateForCurrentUser()
        if cached.isCompanion, cached.userId != nil {
            os_log(.info, log: Self.log, "[NativeRecovery] Namespaced cache hit — immediate unlock")
            self.persistCompanionState(true)
            self.refreshWebEntitlements(isCompanion: true)
            // Background server confirm
            self.checkCompanionOnServer()
            return
        }

        // Step 2: Ask server — only trust server for companion state.
        // StoreKit alone could be a different Apple ID's subscription.
        Task { @MainActor in
            // Ensure we have a token for the server call
            guard self.hasTokenInUserDefaults() else {
                os_log(.info, log: Self.log, "[NativeRecovery] No token — skipping server check")
                return
            }

            let serverIsCompanion = await self.checkCompanionOnServerAndWait()
            os_log(.info, log: Self.log, "[NativeRecovery] Server isCompanion=%{public}@",
                   serverIsCompanion ? "true" : "false")
            if serverIsCompanion {
                self.persistCompanionState(true)
                self.refreshWebEntitlements(isCompanion: true)
            }
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

        // Build 27: Use namespaced read for companion state in JS injection
        let isCompanionRaw = readCompanionStateForCurrentUser().isCompanion
        let awaitingConfirm = UserDefaults.standard.bool(forKey: Self.awaitingServerConfirmKey)
        // Build 23: Report false if awaiting server confirm (post-logout).
        // NOTE: We trust isCompanionRaw from UserDefaults even without a token, because it was
        // already verified by a previous StoreKit check. The no-token guard only prevents NEW
        // StoreKit results from persisting — it should NOT override already-persisted state.
        // (Removing the !hasNativeToken guard here fixes cold boot voiding subscriptions when
        // the token hasn't been synced from localStorage to UserDefaults yet.)
        let isCompanion = awaitingConfirm ? false : isCompanionRaw

        let js = """
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
          awaitingServerConfirm: \(awaitingConfirm ? "true" : "false"),
          workerConfigured: \(!Self.companionWorkerURL.contains("YOUR_SUBDOMAIN") ? "true" : "false")
        };
        // Build 10: IAP callback default + companion state
        window.__aaPurchaseResult = window.__aaPurchaseResult || function(_){};
        
        // BUILD 34 FIX: On login screen, force states false to prevent UI flash from old UserDefaults 
        // state before recheckEntitlements syncs the new user's actual state.
        var isOnLogin = window.location.pathname.indexOf('/login') !== -1;
        window.__aaIsCompanion = isOnLogin ? false : \(isCompanion ? "true" : "false");
        
        // BUILD 31: Server-verified flag.
        window.__aaServerVerified = isOnLogin ? false : \(UserDefaults.standard.bool(forKey: Self.justPurchasedKey) && isCompanion ? "true" : "false");
        \(UserDefaults.standard.bool(forKey: Self.justPurchasedKey) ? "console.log('[AA:B31] Post-purchase reload detected — __aaServerVerified=true');" : "")
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

        // BUILD 31: Post-reload suppression safety net.
        // After cache-busting reload, Base44 React may render "not active" text
        // asynchronously (after our initial suppression ran). Retry every 2s for 10s.
        if (window.__aaServerVerified && window.__aaIsCompanion) {
          var __aaSuppressionCount = 0;
          var __aaSuppressionTimer = setInterval(function() {
            __aaSuppressionCount++;
            if (typeof window.__aaSuppressContradictions === 'function') {
              window.__aaSuppressContradictions();
            }
            if (__aaSuppressionCount >= 5) clearInterval(__aaSuppressionTimer);
          }, 2000);
          console.log('[AA:B31] Post-reload suppression timer started (5x at 2s intervals)');
        }
        """

        // BUILD 31: Clear the just-purchased flag after it's been consumed.
        // Must happen AFTER we build the string above (which reads it).
        if UserDefaults.standard.bool(forKey: Self.justPurchasedKey) {
            UserDefaults.standard.set(false, forKey: Self.justPurchasedKey)
            os_log(.info, log: Self.log, "[DIAG:iap] Cleared aa_just_purchased after buildNativeDiagJS consumed it")
        }

        return js
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
          z-index: 100000;
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
        #aa-sub-restore-btn {
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
        #aa-sub-restore-btn:active { background: #e2e8f0; }
        #aa-sub-restore-btn:disabled { opacity: 0.6; cursor: not-allowed; }

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
        /* ── Build 19: Hide trial/free-trial text elements via CSS ── */
        [data-aa-trial-hidden] {
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

      // ── 0a2. PAYWALL OVERLAY DISMISSAL AFTER PURCHASE (Build 21) ──
      // Called ONLY after a confirmed successful purchase/restore — NOT on every
      // handleAlreadySubscribed() cycle. This avoids Bug 5 (Build 20) where
      // overlay dismissal on every DOM mutation bypassed Base44's gating.
      // Here it's safe because StoreKit just confirmed the transaction.
      function dismissPaywallOverlay() {
        var children = document.body.children;
        for (var i = 0; i < children.length; i++) {
          var el = children[i];
          if (el.id === 'root') continue;
          if (el.id && el.id.indexOf('aa-') === 0) continue;
          if (el.classList && (el.classList.contains('aa-toast') || el.classList.contains('aa-diag-overlay'))) continue;
          var style = window.getComputedStyle(el);
          if (style.display === 'none') continue;
          if (style.position === 'fixed' || style.position === 'absolute') {
            var text = (el.textContent || '').toLowerCase();
            var hasPaywallWords = text.indexOf('subscribe') !== -1 || text.indexOf('companion') !== -1 ||
                                  text.indexOf('pricing') !== -1 || text.indexOf('plan') !== -1 ||
                                  text.indexOf('upgrade') !== -1 || text.indexOf('monthly') !== -1 ||
                                  text.indexOf('restore purchase') !== -1 || text.indexOf('get companion') !== -1;
            if (hasPaywallWords) {
              el.style.display = 'none';
              el.setAttribute('data-aa-paywall-dismissed', '1');
            }
          }
        }
      }

      // ── 0b. PURCHASE RESULT HANDLER WITH TOAST (Build 12) ──
      window.__aaPurchaseResult = function(result) {
        if (!result) return;
        var status = result.status;
        var action = result.action || '';
        var source = result.source || '';
        if (source === 'transactionUpdate') {
          if (result.isCompanion) { showAAToast('Subscription renewed', 'success'); }
          // Removed the confusing "Subscription status changed" info toast for non-subscribers
          updateSubscriptionStatusUI(result.isCompanion);
          return;
        }
        if (action === 'restore') {
          if (status === 'success' && result.isCompanion) {
            showAAToast('Subscription restored! Companion unlocked.', 'success');
            // Build 21: Dismiss the paywall popup immediately after confirmed restore
            dismissPaywallOverlay();
          } else if (status === 'success' && !result.isCompanion) {
            showAAToast(result.message || 'No active subscription found.', 'info');
          } else if (status === 'error') {
            showAAToast(result.message || 'Restore failed. Please try again.', 'error');
          } else if (status === 'info') {
            showAAToast(result.message || 'Unable to restore right now.', 'info');
          }
        } else if (action === 'buy') {
          if (status === 'success' && result.isCompanion) {
            showAAToast('Companion features unlocked!', 'success');
            // Build 21: Dismiss the paywall popup immediately after confirmed purchase
            dismissPaywallOverlay();
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
          // Build 23: Expanded to catch FAQ-style and informational links like
          // "How do I restore purchases", "Why Companion is paid", "Frequently Asked Questions".
          var nonIAPWords = ['support', 'help', 'contact', 'learn', 'about', 'faq',
                             'terms', 'privacy', 'policy', 'manage', 'cancel', 'account',
                             'frequently', 'question', 'asked',
                             'how do', 'how to', 'how does', 'how is',
                             'what is', 'what are', 'why is', 'why do', 'why companion',
                             'guide', 'info', 'detail', 'read more', 'learn more',
                             'paid', 'pricing', 'cost', 'charge', 'billing'];
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
          if (!isRestore && !isYearly) {
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
            if (text.indexOf('start companion') !== -1 ||
                text.indexOf('become companion') !== -1 ||
                text.indexOf('become a companion') !== -1 ||
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
            // Also override trial hiding if this is the primary button
            if (isMonthlySubscribe && isTrial) {
              isTrial = false;
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
            var origRestoreText = btn.textContent;
            btn.addEventListener('click', function(e) {
              e.preventDefault();
              e.stopPropagation();
              if (btn.disabled) return;
              btn.disabled = true;
              btn.textContent = 'Restoring...';
              // Listen for result to reset button
              window.addEventListener('aa:iap', function onResult(ev) {
                window.removeEventListener('aa:iap', onResult);
                btn.disabled = false;
                btn.textContent = origRestoreText;
              }, { once: true });
              // Timeout fallback
              setTimeout(function() {
                if (btn.disabled) {
                  btn.disabled = false;
                  btn.textContent = origRestoreText;
                }
              }, 15000);
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.aaPurchase) {
                window.webkit.messageHandlers.aaPurchase.postMessage({
                  action: 'restore'
                });
              } else {
                btn.disabled = false;
                btn.textContent = origRestoreText;
              }
            });
          }
        });

        // Build 18: Hide "yearly"/"annual" text labels/descriptions outside of buttons.
        // These are pricing text elements that Base44 renders (not action buttons).
        hideYearlyTextElements();

        // Build 19: Hide "trial"/"free trial" text labels/descriptions outside of buttons.
        hideTrialTextElements();
      }

      // Helper: hide parent container if all children are hidden.
      // Build 20 FIX: Never hide parent if it contains the monthly subscribe or restore button —
      // those must remain visible even after yearly/trial siblings are hidden.
      function hideEmptyParent(el) {
        var parent = el.parentElement;
        if (!parent) return;
        // Guard: if parent contains a wired monthly or restore button, don't hide it
        var monthlyBtn = parent.querySelector('[data-aa-iap-wired="monthly"]');
        var restoreBtn = parent.querySelector('[data-aa-iap-wired="restore"]');
        if (monthlyBtn || restoreBtn) return;
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
        // Build 23: REWRITE elements that mention both monthly AND yearly (e.g. "Choose monthly or yearly")
        // These can't be hidden (would kill the monthly option) — instead, remove the yearly reference.
        var rewriteCandidates = document.querySelectorAll('div, span, li, p, label, small, h1, h2, h3, h4, h5, h6, td');
        rewriteCandidates.forEach(function(el) {
          if (el.getAttribute('data-aa-yearly-rewritten')) return;
          if (el.closest('#aa-logout-section, #aa-subscription-section, .aa-diag-overlay, .aa-toast, #aa-already-subscribed')) return;
          if (el.getAttribute('data-aa-iap-wired')) return;
          var text = (el.textContent || '').trim();
          if (!text || text.length > 200) return;
          var lower = text.toLowerCase();
          // Only target elements that mention BOTH monthly and yearly/annual
          var hasMonthly = lower.indexOf('monthly') !== -1 || lower.indexOf('month') !== -1;
          var hasYearly = lower.indexOf('yearly') !== -1 || lower.indexOf('annual') !== -1;
          if (!hasMonthly || !hasYearly) return;
          // Skip if element has children with their own text (only rewrite leaf-ish nodes)
          if (el.children.length > 3) return;
          // Rewrite: remove yearly/annual references AND strip "monthly" since it's redundant
          // when yearly is removed (only one option remains). If only a bare verb remains
          // (Choose, Select, Pick), hide the element — a plan-selector heading makes no sense
          // with only one plan.
          var newText = text;
          // Strip "or yearly/annual" and "yearly/annual or" with optional plan/subscription
          newText = newText.replace(/\\s*(?:or|\\/)\\s*(?:yearly|annual)\\s*(?:plan|subscription)?/gi, '');
          newText = newText.replace(/(?:yearly|annual)\\s*(?:or|\\/)\\s*/gi, '');
          // Strip standalone yearly/annual references that survived
          newText = newText.replace(/\\s*(?:yearly|annual)\\s*(?:plan|subscription)?/gi, '');
          // Strip "monthly" — only option left, redundant to say it
          newText = newText.replace(/\\s*monthly\\s*/gi, ' ');
          // Strip plan-selector verbs — "Choose", "Select", "Pick" are useless with one plan
          // No word-boundary anchors — textContent can concatenate child nodes without spaces
          // (e.g. "optionsChoose" from <span>options</span><span>Choose</span>)
          newText = newText.replace(/choose/gi, '');
          newText = newText.replace(/select/gi, '');
          newText = newText.replace(/pick/gi, '');
          // Clean up double spaces, trailing punctuation, and trim
          newText = newText.replace(/\\s{2,}/g, ' ').replace(/[.:\\-]\\s*$/g, '').trim();
          if (newText !== text) {
            if (!newText || newText.length <= 2) {
              el.style.display = 'none';
            } else {
              newText = newText.replace(/\\.$/g, '');
              newText += ':';
              el.textContent = newText;
            }
            el.setAttribute('data-aa-yearly-rewritten', '1');
          }
        });

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

          // Build 20 FIX: If this element's text also contains monthly pricing content,
          // it's a shared subscription container — don't hide it (would kill the monthly option too).
          if ((text.indexOf('monthly') !== -1 || text.indexOf('9.99') !== -1 ||
               text.indexOf('per month') !== -1 || text.indexOf('/mo') !== -1) &&
              (text.indexOf('yearly') !== -1 || text.indexOf('annual') !== -1 || text.indexOf('trial') !== -1)) return;

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
            // Walk up to find the nearest pricing-option card container and hide it.
            // Build 20 FIX: NEVER hide a parent that also contains monthly pricing or
            // a wired monthly/restore button — that's a shared subscription container.
            var target = el;
            var parent = el.parentElement;
            var depth = 0;
            while (parent && parent !== document.body && depth < 5) {
              depth++;
              // Guard: if parent contains monthly content, it's a shared container — stop walking
              var parentText = (parent.textContent || '').toLowerCase();
              if (parentText.indexOf('monthly') !== -1 || parentText.indexOf('9.99') !== -1 ||
                  parentText.indexOf('per month') !== -1 || parentText.indexOf('/mo') !== -1) break;
              // Guard: if parent contains a wired monthly or restore button, stop walking
              if (parent.querySelector('[data-aa-iap-wired="monthly"], [data-aa-iap-wired="restore"]')) break;
              var siblings = parent.children;
              // If parent has few children and looks like a yearly-specific pricing card, hide the parent
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

      // Build 19: Hide elements containing "trial"/"free trial" text in subscription/paywall UI.
      // Only targets non-button elements (labels, descriptions, cards).
      // Trial buttons are already hidden by wireIAPButtons() classification.
      function hideTrialTextElements() {
        // Build 23.1: Rewrite shared monthly+trial labels so trial wording is removed
        // without hiding the monthly pricing container.
        var rewriteCandidates = document.querySelectorAll('div, span, li, p, label, small, h1, h2, h3, h4, h5, h6, td');
        rewriteCandidates.forEach(function(el) {
          if (el.getAttribute('data-aa-trial-rewritten')) return;
          if (el.closest('#aa-logout-section, #aa-subscription-section, .aa-diag-overlay, .aa-toast, #aa-already-subscribed')) return;
          if (el.getAttribute('data-aa-iap-wired')) return;
          if (el.children.length > 3) return;
          var text = (el.textContent || '').trim();
          if (!text || text.length > 200) return;
          var lower = text.toLowerCase();
          var hasMonthly = lower.indexOf('monthly') !== -1 || lower.indexOf('month') !== -1 ||
                           lower.indexOf('/mo') !== -1 || lower.indexOf('per month') !== -1 || lower.indexOf('9.99') !== -1;
          var hasTrial = lower.indexOf('trial') !== -1;
          if (!hasMonthly || !hasTrial) return;

          var newText = text;
          newText = newText.replace(/free\\s*trial/gi, '');
          newText = newText.replace(/start\\s*(?:a\\s*)?(?:free\\s*)?trial/gi, '');
          newText = newText.replace(/(?:7|14|30)[-\\s]*day\\s*trial/gi, '');
          newText = newText.replace(/trial\\s*period/gi, '');
          newText = newText.replace(/trial/gi, '');
          newText = newText.replace(/\\s{2,}/g, ' ').replace(/[,:;\\-]\\s*$/g, '').trim();

          if (newText !== text) {
            if (!newText || newText.length <= 2) {
              el.style.display = 'none';
            } else {
              el.textContent = newText;
            }
            el.setAttribute('data-aa-trial-rewritten', '1');
          }
        });

        var candidates = document.querySelectorAll('div, span, li, p, label, small, h1, h2, h3, h4, h5, h6, td');
        candidates.forEach(function(el) {
          if (el.getAttribute('data-aa-trial-hidden')) return;
          // Skip our own injected UI
          if (el.closest('#aa-logout-section, #aa-subscription-section, .aa-diag-overlay, .aa-toast, #aa-already-subscribed')) return;
          // Skip elements already handled by wireIAPButtons
          if (el.getAttribute('data-aa-iap-wired')) return;
          // Skip if it contains interactive children
          if (el.querySelector('button, input, textarea, select')) return;

          var text = (el.textContent || '').trim().toLowerCase();
          if (!text || text.length > 200) return;

          // Build 20 FIX: If this element's text also contains monthly pricing content,
          // it's a shared subscription container — don't hide it.
          if ((text.indexOf('monthly') !== -1 || text.indexOf('9.99') !== -1 ||
               text.indexOf('per month') !== -1 || text.indexOf('/mo') !== -1) &&
              text.indexOf('trial') !== -1) return;

          var isTrialText = false;

          // "free trial" in any context within subscription UI
          if (text.indexOf('free trial') !== -1) {
            isTrialText = true;
          }

          // "trial" with subscription/pricing context
          if (!isTrialText && text.indexOf('trial') !== -1 &&
              (text.indexOf('start') !== -1 || text.indexOf('day') !== -1 ||
               text.indexOf('free') !== -1 || text.indexOf('try') !== -1 ||
               text.indexOf('begin') !== -1 || text.indexOf('companion') !== -1 ||
               text.indexOf('subscribe') !== -1 || text.indexOf('included') !== -1 ||
               text.indexOf('offer') !== -1 || text.indexOf('introductory') !== -1)) {
            isTrialText = true;
          }

          // Standalone short labels: "Free Trial", "7-day trial", "Trial", "Start Trial"
          if (!isTrialText && text.length <= 30) {
            if (text === 'trial' || text === 'free trial' || text === 'start trial' ||
                text === 'start free trial' || text === 'try free' || text === 'try for free' ||
                text.indexOf('7-day') !== -1 || text.indexOf('7 day') !== -1 ||
                text.indexOf('-day trial') !== -1 || text.indexOf(' day trial') !== -1) {
              isTrialText = true;
            }
          }

          if (isTrialText) {
            // Walk up to find the nearest trial-specific container and hide it.
            // Build 20 FIX: NEVER hide a parent that also contains monthly pricing or
            // a wired monthly/restore button — that's a shared subscription container.
            var target = el;
            var parent = el.parentElement;
            var depth = 0;
            while (parent && parent !== document.body && depth < 5) {
              depth++;
              // Guard: if parent contains monthly content, it's a shared container — stop walking
              var parentText = (parent.textContent || '').toLowerCase();
              if (parentText.indexOf('monthly') !== -1 || parentText.indexOf('9.99') !== -1 ||
                  parentText.indexOf('per month') !== -1 || parentText.indexOf('/mo') !== -1) break;
              // Guard: if parent contains a wired monthly or restore button, stop walking
              if (parent.querySelector('[data-aa-iap-wired="monthly"], [data-aa-iap-wired="restore"]')) break;
              var siblings = parent.children;
              if (siblings.length <= 4) {
                var allText = '';
                for (var s = 0; s < siblings.length; s++) {
                  allText += ' ' + (siblings[s].textContent || '').trim().toLowerCase();
                }
                if (allText.indexOf('trial') !== -1 &&
                    (allText.indexOf('free') !== -1 || allText.indexOf('day') !== -1 ||
                     allText.indexOf('start') !== -1 || allText.indexOf('try') !== -1)) {
                  target = parent;
                  break;
                }
              }
              parent = parent.parentElement;
            }
            target.style.display = 'none';
            target.setAttribute('data-aa-trial-hidden', '1');
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

      // ── 6f. SUBSCRIPTION STATUS UI (Build 12, updated Build 23) ──
      // Visible "Companion Active" / "Free" indicator on More/Settings page.
      // "Restore Purchases" button calls native StoreKit restore via aaPurchase handler.

      function updateSubscriptionStatusUI(isCompanion) {
        // BUILD 31 FIX: Single source of truth — only show "Companion Active" when
        // BOTH __aaIsCompanion AND __aaServerVerified are true.
        // Without server verification, show neutral state to prevent contradicting
        // Base44's own subscription status text.
        window.__aaIsCompanion = isCompanion;
        var verified = window.__aaServerVerified === true;
        var showActive = isCompanion && verified;

        var statusEl = document.getElementById('aa-sub-status-text');
        if (statusEl) {
          if (showActive) {
            statusEl.textContent = 'Companion Active';
            statusEl.className = 'aa-sub-status active';
          } else if (isCompanion && !verified) {
            statusEl.textContent = 'Checking subscription...';
            statusEl.className = 'aa-sub-status checking';
          } else {
            statusEl.textContent = 'Free';
            statusEl.className = 'aa-sub-status free';
          }
        }
        var detailEl = document.getElementById('aa-sub-detail-text');
        if (detailEl) {
          if (showActive) {
            detailEl.textContent = 'Your Companion Monthly subscription is active.';
          } else if (isCompanion && !verified) {
            detailEl.textContent = 'Verifying subscription with server...';
          } else {
            detailEl.textContent = 'Subscribe monthly to unlock Companion features.';
          }
        }

        // When NOT companion, clean up all subscription UI artifacts
        if (!isCompanion) {
          var banner = document.getElementById('aa-already-subscribed');
          if (banner) banner.remove();
          document.querySelectorAll('[data-aa-sub-hidden]').forEach(function(el) {
            el.style.display = '';
            el.removeAttribute('data-aa-sub-hidden');
          });
          document.querySelectorAll('[data-aa-contradiction-hidden]').forEach(function(el) {
            el.style.display = '';
            el.removeAttribute('data-aa-contradiction-hidden');
          });
        } else {
          // When companion is ACTIVE, proactively hide subscribe sections
          document.querySelectorAll('[data-aa-iap-wired]').forEach(function(btn) {
            var wiredType = btn.getAttribute('data-aa-iap-wired');
            if (wiredType === 'monthly' || wiredType === 'yearly' ||
                wiredType === 'hidden-yearly' || wiredType === 'hidden-trial') {
              btn.style.display = 'none';
              btn.setAttribute('data-aa-sub-hidden', '1');
            }
          });
        }
      }

      function injectSubscriptionStatus() {
        if (!isMoreOrSettingsRoute()) {
          var stale = document.getElementById('aa-subscription-section');
          if (stale) stale.remove();
          return;
        }
        // BUILD 31: Only inject on the actual Settings detail page, not every More sub-page.
        // Detect Settings page by checking for 'Preferences' heading or 'Companion Status'
        // or a path containing '/settings'. This prevents duplicate cards on Support page etc.
        var path = window.location.pathname.toLowerCase();
        var hash = (window.location.hash || '').toLowerCase();
        var isSettingsPage = path === '/settings' || path.indexOf('/settings/') === 0 ||
                             hash.indexOf('/settings') !== -1;
        if (!isSettingsPage) {
          // Also detect by DOM content — look for Base44's own settings indicators
          var bodyText = (document.body.innerText || '').toLowerCase();
          isSettingsPage = bodyText.indexOf('preferences') !== -1 &&
                           (bodyText.indexOf('companion status') !== -1 ||
                            bodyText.indexOf('delete account') !== -1 ||
                            bodyText.indexOf('quick links') !== -1);
        }
        if (!isSettingsPage) {
          var stale2 = document.getElementById('aa-subscription-section');
          if (stale2) stale2.remove();
          return;
        }
        // Build 20 FIX: If section exists, update it in case __aaIsCompanion changed
        // (e.g. async StoreKit check completed after initial render)
        if (document.getElementById('aa-subscription-section')) {
          updateSubscriptionStatusUI(window.__aaIsCompanion === true);
          return;
        }
        var root = document.getElementById('root');
        if (!root) return;
        var container = root.querySelector('main') ||
                        root.querySelector('[class*="scroll"]') ||
                        root.querySelector('[class*="content"]') ||
                        root;
        var text = (container.innerText || '').trim();
        if (text.length < 10) return;

        var isCompanion = window.__aaIsCompanion === true;
        var verified = window.__aaServerVerified === true;
        var showActive = isCompanion && verified;
        var section = document.createElement('div');
        section.id = 'aa-subscription-section';

        var label = document.createElement('div');
        label.className = 'aa-sub-label';
        label.textContent = 'Subscription';
        section.appendChild(label);

        var status = document.createElement('div');
        status.id = 'aa-sub-status-text';
        if (showActive) {
          status.className = 'aa-sub-status active';
          status.textContent = 'Companion Active';
        } else if (isCompanion && !verified) {
          status.className = 'aa-sub-status checking';
          status.textContent = 'Checking subscription...';
        } else {
          status.className = 'aa-sub-status free';
          status.textContent = 'Free';
        }
        section.appendChild(status);

        var detail = document.createElement('div');
        detail.id = 'aa-sub-detail-text';
        detail.className = 'aa-sub-detail';
        if (showActive) {
          detail.textContent = 'Your Companion Monthly subscription is active.';
        } else if (isCompanion && !verified) {
          detail.textContent = 'Verifying subscription with server...';
        } else {
          detail.textContent = 'Subscribe monthly to unlock Companion features.';
        }
        section.appendChild(detail);

        var restoreBtn = document.createElement('button');
        restoreBtn.id = 'aa-sub-restore-btn';
        restoreBtn.textContent = 'Restore Purchases';
        restoreBtn.addEventListener('click', function(e) {
          e.preventDefault();
          restoreBtn.disabled = true;
          restoreBtn.textContent = 'Restoring...';
          // Build 23: Wire to native StoreKit restore instead of server check.
          // The native restore handler provides proper toast feedback.
          window.addEventListener('aa:iap', function onRestore(ev) {
            window.removeEventListener('aa:iap', onRestore);
            restoreBtn.disabled = false;
            restoreBtn.textContent = 'Restore Purchases';
            var d = ev.detail || {};
            if (d.isCompanion) {
              updateSubscriptionStatusUI(true);
            }
          }, { once: true });
          // Timeout fallback in case native handler doesn't fire
          setTimeout(function() {
            if (restoreBtn.disabled) {
              restoreBtn.disabled = false;
              restoreBtn.textContent = 'Restore Purchases';
            }
          }, 15000);
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.aaPurchase) {
            window.webkit.messageHandlers.aaPurchase.postMessage({ action: 'restore' });
          } else {
            restoreBtn.disabled = false;
            restoreBtn.textContent = 'Restore Purchases';
            showAAToast('Restore not available. Try again later.', 'error');
          }
        });
        section.appendChild(restoreBtn);

        var logoutSection = document.getElementById('aa-logout-section');
        if (logoutSection) {
          container.insertBefore(section, logoutSection);
        } else {
          container.appendChild(section);
        }
      }

      // ── 6g. ALREADY-SUBSCRIBED PAYWALL HANDLING (Build 15, rewritten Build 31) ──
      // BUILD 31: REMOVED injecting our own 'Companion Active' banner and extra Restore button.
      // Root cause of Build 30 failure: our injected banner said "Active" while Base44's
      // own React component said "not active" on the SAME page → client sees contradiction.
      //
      // Build 31 approach: ONLY hide subscribe/trial buttons when subscribed.
      // Do NOT inject competing UI elements. Let Base44 handle its own display.
      // Use suppressContradictorySubscriptionText() to hide any stale "not active" text
      // that contradicts server-confirmed companion state.

      function handleAlreadySubscribed() {
        // Remove any stale injected elements from previous builds
        var staleBanner = document.getElementById('aa-already-subscribed');
        if (staleBanner) staleBanner.remove();
        var stalePaywallRestore = document.getElementById('aa-paywall-restore-btn');
        if (stalePaywallRestore) stalePaywallRestore.remove();

        if (!window.__aaIsCompanion) {
          // Not subscribed — ensure subscribe buttons are visible
          document.querySelectorAll('[data-aa-sub-hidden]').forEach(function(el) {
            el.style.display = '';
            el.removeAttribute('data-aa-sub-hidden');
          });
          // Un-suppress any contradiction text (user is genuinely free)
          document.querySelectorAll('[data-aa-contradiction-hidden]').forEach(function(el) {
            el.style.display = '';
            el.removeAttribute('data-aa-contradiction-hidden');
          });
          return;
        }

        // SUBSCRIBED: Hide ALL subscribe/trial/yearly/restore buttons everywhere
        var wiredBtns = document.querySelectorAll('[data-aa-iap-wired]');
        wiredBtns.forEach(function(btn) {
          var wiredType = btn.getAttribute('data-aa-iap-wired');
          if (wiredType === 'monthly' || wiredType === 'yearly' ||
              wiredType === 'hidden-yearly' || wiredType === 'hidden-trial' ||
              wiredType === 'restore') {
            btn.style.display = 'none';
            btn.setAttribute('data-aa-sub-hidden', '1');
          }
        });

        // BUILD 31: Suppress Base44's contradictory "not active" text
        if (typeof window.__aaSuppressContradictions === 'function') {
          window.__aaSuppressContradictions();
        }
      }

      // ── 6g2. SUPPRESS CONTRADICTORY SUBSCRIPTION TEXT (Build 31) ──
      // When __aaIsCompanion is true AND server has confirmed (via Worker PATCH),
      // scan for Base44 React elements that say "not active" / "isn't active" / etc.
      // and hide them to prevent contradictory messaging.
      //
      // This is the KEY fix: instead of injecting our own "Active" banner that fights
      // with Base44, we suppress Base44's stale "not active" text.
      window.__aaSuppressContradictions = function() {
        // Only suppress if server-verified (not just local StoreKit state)
        if (!window.__aaIsCompanion || !window.__aaServerVerified) return;

        var contradictionPhrases = [
          "isn't active",
          "is not active",
          "not active on this account",
          "no active subscription",
          "no subscription",
          "companion isn't active",
          "companion is not active",
          "you don't have",
          "you do not have",
          "subscription inactive",
          "not subscribed"
        ];

        var root = document.getElementById('root');
        if (!root) return;
        var allEls = root.querySelectorAll('div, span, p, h1, h2, h3, h4, h5, h6, label, section');
        allEls.forEach(function(el) {
          if (el.getAttribute('data-aa-contradiction-hidden')) return;
          if (el.getAttribute('data-aa-base44-hidden')) return;
          if (el.id && el.id.indexOf('aa-') === 0) return;
          if (el.closest('#aa-subscription-section')) return;
          // ONLY target leaf elements — no parent walking
          if (el.children.length > 3) return;
          var text = (el.textContent || '').toLowerCase().trim();
          if (text.length < 5 || text.length > 200) return;

          for (var i = 0; i < contradictionPhrases.length; i++) {
            if (text.indexOf(contradictionPhrases[i]) !== -1) {
              if (text.indexOf('how to') !== -1 || text.indexOf('learn more') !== -1 ||
                  text.indexOf('faq') !== -1 || text.indexOf('help') !== -1) continue;
              // Hide ONLY this element, not its parent
              el.style.display = 'none';
              el.setAttribute('data-aa-contradiction-hidden', '1');
              break;
            }
          }
        });
      };

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
          // BUILD 34 FIX: Clear companion state immediately to prevent leakage to next login
          window.__aaIsCompanion = false;
          window.__aaServerVerified = false;
          if (typeof updateSubscriptionStatusUI === 'function') {
            updateSubscriptionStatusUI(false);
          }
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

      // ── 6h. HIDE BASE44 COMPANION STATUS (Build 31) ──
      // ALWAYS hide Base44's own "Companion Status" section on the Settings page.
      // Our injected SUBSCRIPTION card is the single source of truth.
      // This prevents having two competing status sections regardless of sub state.
      function hideBase44CompanionStatus() {
        var root = document.getElementById('root');
        if (!root) return;

        // Target specific text content to hide INDIVIDUALLY — no parent walking.
        // These are the elements Base44 renders in its "Companion Status" section.
        var hideTexts = [
          'companion status',                        // Section heading
          "companion isn't active on this account",  // Status text
          "companion is not active on this account",
          "companion isn't active",
          "companion is not active",
          'already subscribed on this apple id',     // Helper text
          'tap restore purchases'                    // Helper text continued
        ];

        var allEls = root.querySelectorAll('div, span, p, h1, h2, h3, h4, h5, h6, label, section');
        allEls.forEach(function(el) {
          if (el.getAttribute('data-aa-base44-hidden')) return;
          if (el.closest('#aa-subscription-section')) return;
          if (el.id && el.id.indexOf('aa-') === 0) return;
          // Skip large containers — only target leaf-ish elements
          if (el.children.length > 3) return;
          var text = (el.textContent || '').trim().toLowerCase();
          if (text.length < 5 || text.length > 300) return;

          for (var i = 0; i < hideTexts.length; i++) {
            if (text.indexOf(hideTexts[i]) !== -1) {
              el.style.display = 'none';
              el.setAttribute('data-aa-base44-hidden', '1');
              break;
            }
          }
        });

        // Hide any Base44 native "Restore purchases" buttons outside our section
        var allBtns = root.querySelectorAll('button, a, [role="button"]');
        allBtns.forEach(function(btn) {
          if (btn.id === 'aa-sub-restore-btn') return;
          if (btn.closest('#aa-subscription-section')) return;
          if (btn.getAttribute('data-aa-base44-hidden')) return;
          if (btn.getAttribute('data-aa-iap-wired')) return;
          var btnText = (btn.textContent || '').trim().toLowerCase();
          if (btnText === 'restore purchases' || btnText === 'restore purchase') {
            btn.style.display = 'none';
            btn.setAttribute('data-aa-base44-hidden', '1');
          }
        });
      }

      // ── 7. ORCHESTRATOR ──

      var patchTimer = null;
      // Build 20: Expose runAllPatches globally so native refreshWebEntitlements() can trigger
      // an immediate UI refresh after async StoreKit entitlement checks complete.
      window.__aaRunAllPatches = function() { runAllPatches(); };
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
          hideBase44CompanionStatus();
          wireIAPButtons();
          handleAlreadySubscribed();
          // BUILD 31: Suppress Base44 contradictory "not active" text
          if (typeof window.__aaSuppressContradictions === 'function') {
            window.__aaSuppressContradictions();
          }
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
      var __aaBlankCheckInterval = null;
      function scheduleBlankChecks() {
        // Build 23: Cancel previous interval to prevent overlapping checks on rapid navigation
        if (__aaBlankCheckInterval) clearInterval(__aaBlankCheckInterval);
        blankCheckCount = 0;
        blankConsecutiveHits = 0;
        prayerBlankHits = 0;
        __aaBlankCheckInterval = setInterval(function() {
          blankCheckCount++;
          detectBlankScreen();
          monitorPrayerRoutes();
          // Build 15: Also check for new IAP buttons (catches late-appearing popups)
          wireIAPButtons();
          handleAlreadySubscribed();
          if (blankCheckCount >= 10) {
            clearInterval(__aaBlankCheckInterval);
            __aaBlankCheckInterval = null;
          }
        }, 3000);
      }

      // SPA navigation hooks

      // Build 22 FIX: Track last URL to detect login→dashboard transitions.
      // After logout, aa_is_companion is cleared from UserDefaults, so the WKUserScript
      // sets window.__aaIsCompanion = false on the login page. After login, the SPA
      // navigates to dashboard but nothing re-checks StoreKit entitlements — so the
      // subscription appears lost. This detects the transition and triggers a native
      // entitlement recheck via the existing recheckEntitlements message handler.
      var __aaLastPath = window.location.pathname;

      function checkLoginTransition() {
        var currentPath = window.location.pathname;
        var wasOnLogin = __aaLastPath === '/login' || __aaLastPath === '/login/';
        var nowOnLogin = currentPath === '/login' || currentPath === '/login/';
        __aaLastPath = currentPath;

        // Transitioned FROM login TO another page → user just logged in
        if (wasOnLogin && !nowOnLogin) {
          console.log('[AA] Login transition detected — rechecking StoreKit entitlements');
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.aaPurchase) {
            window.webkit.messageHandlers.aaPurchase.postMessage({ action: 'recheckEntitlements' });
          }
        }
      }

      window.addEventListener('popstate', function() {
        setTimeout(runAllPatches, 300);
        scheduleBlankChecks();
        checkLoginTransition();
      });

      window.addEventListener('hashchange', function() {
        setTimeout(runAllPatches, 300);
        scheduleBlankChecks();
        checkLoginTransition();
      });

      var origPush = history.pushState;
      var origReplace = history.replaceState;
      history.pushState = function() {
        var result = origPush.apply(this, arguments);
        setTimeout(runAllPatches, 300);
        scheduleBlankChecks();
        checkLoginTransition();
        return result;
      };
      history.replaceState = function() {
        var result = origReplace.apply(this, arguments);
        setTimeout(runAllPatches, 300);
        scheduleBlankChecks();
        checkLoginTransition();
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

      // Build 27: JS safety net — on every page load (not login page), if not
      // companion, trigger recheckEntitlements after 3s. Catches full page reloads
      // after login where checkLoginTransition() doesn't fire (the history hooks
      // only catch pushState/replaceState, not window.location redirects).
      setTimeout(function() {
        var path = window.location.pathname;
        var onLogin = (path === '/login' || path === '/login/');
        if (!onLogin && !window.__aaIsCompanion) {
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.aaPurchase) {
            console.log('[AA] Safety net: not companion after page load — rechecking StoreKit');
            window.webkit.messageHandlers.aaPurchase.postMessage({ action: 'recheckEntitlements' });
          }
        }
      }, 3000);
    })();
    """
}
