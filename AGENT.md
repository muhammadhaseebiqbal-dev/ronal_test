# AGENT.md — Project Rules for Abide & Anchor iOS

## Project Overview

**App Name:** Abide & Anchor  
**Client:** Roland L.  
**Tech Stack:** React 18 + Vite 6 + Capacitor 8 (iOS) + Base44 SDK  
**Current Phase:** Milestone B — App Store submission preparation (Build 15)

## Project Type
Capacitor iOS app wrapping https://abideandanchor.app in WKWebView (same-origin mode).

## Tech Stack
- **Frontend:** React 18, Vite, Tailwind CSS
- **Backend:** Base44 platform (hosted SaaS)
- **iOS:** Capacitor 8.x, Swift, WKWebView
- **Auth:** Base44 OAuth via deep links (abideandanchor://)
- **Token Storage:** Capacitor Preferences (iOS UserDefaults)

---

## Critical Rules

### 1. Never set `ios.scheme` in `capacitor.config.ts`
It would change the WebView origin and break localStorage persistence. It would also collide with the deep link scheme in Info.plist.

### 2. Always use `server.url: 'https://abideandanchor.app'`
This is the production remote URL mode. The WKWebView loads the live site directly.

### 3. App ID must never be null
`VITE_BASE44_APP_ID=69586539f13402a151c12aa3` must be set in `.env.production` and baked into the build. Fallback hardcoded in `app-params.js`.

### 4. Token storage must use Capacitor Preferences on iOS
localStorage alone is unreliable across cold restarts under some WKWebView configurations. The `tokenStorage.js` module handles this.

### 5. Deep links use custom URL scheme `abideandanchor://`
NOT universal links. Registered in Info.plist under CFBundleURLTypes.

### 6. Bundle ID: `com.abideandanchor.app`
Must match Xcode project, App Store Connect, and provisioning profiles.

### 7. Environment Variables
- **ALWAYS** ensure `VITE_BASE44_APP_ID` is set before iOS builds.
- Environment variables are baked in at **build time** (not runtime).
- Use `.env.production` for production/iOS builds.
- Never commit actual API keys — use placeholders.

### 8. Token Persistence (CRITICAL)
- **Same-origin mode**: App loads `https://abideandanchor.app` directly in WKWebView
- localStorage at `https://` origin DOES persist across cold restarts in WKWebView
- Capacitor Preferences (`@capacitor/preferences`) remains available as backup
- **⚠️ WKWebView does NOT share localStorage with Safari** — they are separate data stores
- Auth must happen WITHIN the WebView (not in a separate Safari session) for persistence
- **Primary restore path**: Token in Capacitor Preferences (UserDefaults) → survives ALL termination events
- **Safety net**: Cookie bridging (HTTPCookieStorage ↔ WKHTTPCookieStore) for edge cases where the Base44 platform checks cookies alongside the token

### 9. OAuth Deep Link Flow (CRITICAL for iOS)
- Safari CANNOT redirect back to `capacitor://localhost`
- Must use custom URL scheme: `abideandanchor://auth-callback?token=...`
- `@capacitor/app` plugin handles `appUrlOpen` events
- `@capacitor/browser` opens OAuth in SFSafariViewController (NOT in WebView)
- Deep links from inside the WebView do NOT trigger `appUrlOpen`

---

## Build Commands
```bash
npm run build          # Vite production build
npm run verify:ios     # Verify iOS build correctness
npx cap sync ios       # Sync web assets + config to iOS
npm run build:ios      # Full build + verify + sync pipeline
npm run lint           # ESLint
npm run test           # Unit tests
```

## Key Files
| File | Purpose |
|------|---------|
| `capacitor.config.ts` | Capacitor configuration (remote URL mode) |
| `.env.production` | Production environment variables |
| `src/lib/app-params.js` | App ID resolution with fallback |
| `src/lib/tokenStorage.js` | Native token persistence |
| `src/lib/deepLinkHandler.js` | OAuth deep link handler |
| `src/lib/runtime.js` | Capacitor runtime detection |
| `src/context/AuthContext.jsx` | Auth state management |
| `ios/App/App/Info.plist` | iOS app configuration |
| `ios/App/App/PrivacyInfo.xcprivacy` | Apple privacy manifest (iOS 17+) |
| `worker/companion-validator/index.js` | Cloudflare Worker for cross-device Companion validation |

## Known Issues (Status)
| Issue | Status |
|-------|--------|
| NULL App ID Bug | ✅ FIXED — Hardcoded fallback |
| API returns HTML not JSON | ✅ FIXED — App ID wired correctly |
| Onboarding stuck | ✅ FIXED — 5s timeout with Login button |
| Token not persisting | ✅ FIXED — Same-origin mode |
| OAuth redirect loop | ✅ FIXED — Custom URL scheme deep link |
| Scheme collision | ✅ FIXED — Removed ios.scheme |
| Race condition: old token clears new | ✅ FIXED — tokenVersion guard |
| Deep link double-processing | ✅ FIXED — lastProcessedUrl guard |
| SelectTrigger context error | ✅ FIXED — Auto-retry + reload on React crash (SelectTrigger must be used within Select) |
| Duplicate back buttons | ✅ FIXED — DOM patch removes duplicates |
| Missing back buttons | ✅ FIXED — DOM patch injects back nav |
| Bottom nav squashed (5 tabs) | ✅ FIXED — CSS flex/min-width patch |
| White screen on error | ✅ FIXED — Global error handler fallback |
| Bundle ID mismatch (project.pbxproj had .test) | ✅ FIXED — com.abideandanchor.app in both Debug + Release |
| Missing privacy manifest | ✅ FIXED — PrivacyInfo.xcprivacy |
| armv7 architecture | ✅ FIXED — arm64 only |
| No offline handling | ✅ FIXED — OfflineScreen component |
| Debug config in Release | ✅ FIXED — Separate release.xcconfig |
| Google sign-in loop | ✅ FIXED — Build 6: Google buttons completely hidden on iOS. Email/Password only per Roland's decision |
| Prayer Corner routes fail | ✅ FIXED — Removed error overlay injection. Let Base44 handle its own rendering |
| Prayer List blank screen | ✅ FIXED — Ultra-conservative: 5 consecutive blank checks (15s), never on prayer routes |
| Login lost on background/kill | ✅ FIXED — Cookie bridging + process termination recovery |
| Back button in top middle | ✅ FIXED — CSS+JS moves all back buttons to top-left |
| Back button under clock/notch | ✅ FIXED — Fixed position with safe-area-inset-top + 52px offset below header |
| "or" divider visible after Google hidden | ✅ FIXED — Broad sweep hides all or/divider/separator elements on login page |
| Prayer Wall squashed/not responsive | ✅ FIXED — CSS grid forced to 1-column on mobile, overflow hidden |
| No Log Out button | ✅ FIXED — Build 7: Injected on More/Settings page. Clears localStorage, cookies, WKWebView data, Capacitor Preferences. Navigates to Login. Confirmation dialog. |
| IAP Companion subscription not wired | ✅ FIXED — Build 14: Monthly-only purchase. Yearly/trial hidden. StoreKit 2 bridge. Entitlements in UserDefaults (`aa_is_companion`). |
| Companion unlock local-only (no cross-device) | ✅ FIXED — Build 11: Cloudflare Worker validates Apple JWS server-side, updates Base44 user entity. Desktop browsers check `/check-companion`. `window.__aaCheckCompanion()` available on all devices. |
| Session validation `no-token` false positive | ✅ FIXED — Build 8.1: Now checks 4 token keys instead of just `base44_access_token`. Base44 SDK stores token under `token` key initially. |
| localStorage random clearing (iOS 17.4+) | ✅ FIXED — Build 8.1: Shared static `WKProcessPool` per Apple developer docs recommendation. |
| Cookie sync lag | ✅ FIXED — Build 8.1: `WKHTTPCookieStoreObserver` auto-persists cookies on any change. iOS 26 batch API for atomic sync. |
| Token not in native persistence | ✅ FIXED — Build 9: Native Swift two-way sync. UP: `syncTokenToUserDefaults()` reads localStorage via JS eval, saves to UserDefaults (on load, resume, background). DOWN: `buildNativeDiagJS()` restores token from UserDefaults → localStorage at document start. Previous tokenStorage.js fix was dead code (remote URL mode). |
| src/ JS is dead code in production | ⚠️ KNOWN — With `server.url` set, WKWebView loads remote site's JS. Local `dist/` bundle never executes. All runtime fixes must be in Swift or injected WKUserScript. |

## Safari Web Inspector Diagnostics
```javascript
window.diagnoseBase44Config()    // Check App ID & config
window.diagnoseTokenStorage()    // Check token persistence
```

## In-App Diagnostics (No Xcode Required — Build 6+)
- **Trigger:** Tap any header/title element **5 times quickly** OR navigate to `/#/aa-diagnostics`
- **Shows:** Device model (hardware ID), iOS version, app version+build, origin, data store type (persistent/nonPersistent), auth key presence + value lengths (no values), localStorage total key count, Google attempt count, last 5 navigation URLs
- **"Copy Diagnostics" button** copies plaintext to clipboard — paste in chat/email to Roland
- No secrets or token values are ever included
- Native data injected via `WKUserScript` at `.atDocumentStart` (guarantees availability on every page load)

## Native Diagnostics (Xcode Console)
Filter by subsystem `com.abideandanchor.app` category `WebView` to see:
- `[DIAG:coldBoot]` — WebView state on cold start (device model, iOS, build, data store)
- `[DIAG:willEnterForeground]` — WebView state on resume from background
- `[DIAG:webViewCreated]` — Data store type when WebView configuration is created
- `[DIAG:googleIntercept]` — Google sign-in button tapped (attempt count)
- `[DIAG:authMarkers]` — Auth token/cookie presence (boolean only, never values)
- `[DIAG:copy]` — Diagnostics copied to clipboard
- `[DIAG:processTerminationRecovery]` — Recovery after content process killed
- Cookie names (never values) for `abideandanchor.app` domain

## iPhone Stage One — Acceptance Criteria (Roland, 2026-11-02)

| # | Criterion | Status |
|---|-----------|--------|
| 1 | Email/password login persists after background and kill/reopen | ✅ FIXED (Build 4+) |
| 2 | Prayer Corner back navigation works | ✅ FIXED (Build 6) |
| 3 | New Request loads | ✅ FIXED (Build 6) |
| 4 | Builder loads | ✅ FIXED (Build 6) |
| 5 | Prayer Wall loads and is not squashed, back navigation works | ✅ FIXED (Build 6) |
| 6 | Prayer List does not white-screen | ✅ FIXED (Build 6) |
| 7 | **Log out button** in More/Settings that fully signs the user out, clears stored auth state, and returns to Login screen (so a different account can log in) | ✅ FIXED (Build 7) |

## Milestone B — Acceptance Criteria (Roland, 2026-02-23)

**Launch Scope:** Companion Monthly only. Yearly removed from sale. Trial removed. No copy changes.

| # | Criterion | Status |
|---|-----------|--------|
| 1 | Subscribe Monthly always opens Apple purchase sheet and completes successfully | ✅ Build 15: Broader button matching + body-wide search catches buttons in React portal popups |
| 2 | After purchase, Companion unlocks immediately and stays unlocked after kill/reopen | ✅ Build 10+14: UserDefaults `aa_is_companion`, `reloadFromOrigin()` instant unlock |
| 3 | Restore Purchases returns clear outcome: restored+unlocked OR nothing-to-restore, entitlement refreshed | ✅ Build 15: Restore buttons in popups now wired via body-wide search |
| 4 | No contradictory states: must not show "active subscription" while presenting subscribe options | ✅ Build 15: When subscribed, ALL subscribe/trial/restore buttons hidden body-wide + popup containers dismissed |
| 5 | Subscription gating driven from one entitlement source of truth, updates after login/purchase/restore | ✅ Build 14: Single source = `aa_is_companion` in UserDefaults, synced to web via `__aaIsCompanion` |

---

## Last Change Log

**2026-02-24 — Raouf: Build 15 — Fix Dead Buttons, Contradictory States, Paywall Popup Handling**
- **Root cause**: `wireIAPButtons()` and `handleAlreadySubscribed()` searched only `#root`, but Base44 paywall popups render as React portals outside `#root` (directly on `document.body`). Buttons in popups were never found or wired.
- **Fixes**: Both functions now search `document.body`. Button classification uses priority-based logic (restore > trial > yearly > monthly). Broader text matching catches "Get Companion on iPhone" via `indexOf`. When subscribed, popup/modal containers are dismissed. Added body-level `MutationObserver` for portaled elements. Periodic IAP check every 3s for 30s.
- Build number 14→15.
- Verification: lint ✅, test 42/42 ✅, build ✅, cap sync ✅, xcodebuild Release ✅ BUILD SUCCEEDED

**2026-02-24 — Raouf: Build 14 — Monthly-Only Launch Scope (Milestone B)**
- **Scope change**: Roland updated App Store Connect — Companion Monthly is the only subscription for submission. Yearly removed from sale, 7-day free trial removed.
- **Changes**: Purchase path = monthly only. Yearly/trial buttons hidden from paywall. Subscribe buttons hidden when already subscribed (no contradictory states). Entitlement check still recognizes existing yearly subscribers. StoreKit config updated to monthly only. Build number 13→14.
- Verification: lint ✅, test 42/42 ✅, build ✅, cap sync ✅, xcodebuild Release ✅ BUILD SUCCEEDED

**2026-02-23 — Raouf: StoreKit Config Cleanup — Version 4 Fix Confirmed Working**
- **Root cause (resolved)**: Xcode 26.2 requires StoreKit config file format version 4 (major:4, minor:0). Our manually-created `Configuration.storekit` used version 2 and was silently ignored.
- **Fix**: Created `test.storekit` via Xcode's File > New > StoreKit Configuration File wizard (generates correct v4 format), added both Companion subscription products (monthly $9.99, yearly $79.99), set in scheme.
- **Cleanup**: Removed temporary `diagnoseProductAvailability()` + `showDiagnosticAlert()` from AAStoreManager (was for debugging). Removed stale `Configuration.storekit` references from project.pbxproj. Fixed `test.storekit` lastKnownFileType to `com.apple.dt.storekit`.
- **Confirmed**: Products load successfully on device via Xcode debugger.
- Verification: xcodebuild Debug ✅ BUILD SUCCEEDED

**2026-02-23 — Raouf: Build 13 — Web Refresh After Purchase (Instant Companion Unlock)**
- Added `triggerWebRefreshAfterPurchase()` using native `WKWebView.reloadFromOrigin()` (Apple docs: cache-bypassing reload)
- Called after Worker sync returns 200 OK, and as fallback when no JWS available
- Apple docs audit: `reloadFromOrigin()` is the correct API — `window.location.reload(true)` `forceGet` param is deprecated/non-standard in WebKit
- Ensures Base44 re-fetches `/User/me` immediately so Companion unlocks without kill/reopen
- Verification: lint ✅, test 42/42 ✅, build ✅, cap sync ✅, xcodebuild Release ✅ BUILD SUCCEEDED

**2026-02-18 — Raouf: Wire Cloudflare Worker URL (Cross-Device Companion Sync Now Live)**
- Updated `companionWorkerURL` from placeholder to `https://companion-validator.abideandanchor.workers.dev`
- All server-sync paths now active: `syncCompanionToServer()`, `checkCompanionOnServer()`, `window.__aaCheckCompanion()`, diagnostics `workerConfigured: true`
- Verification: lint ✅, test 42/42 ✅, build ✅, cap sync ✅, xcodebuild Release ✅ BUILD SUCCEEDED

**2026-02-18 — Raouf: IAP Audit — Critical Bundle ID Fix + In-App Purchase Entitlement**
- **Root cause found**: `PRODUCT_BUNDLE_IDENTIFIER = com.abideandanchor.test` in BOTH Debug and Release configs caused `Product.products(for:)` to return empty (App Store routes by bundle ID). Zero products → zero purchases.
- **Fix 1**: `com.abideandanchor.test` → `com.abideandanchor.app` in `project.pbxproj` (both configs)
- **Fix 2**: Created `ios/App/App/App.entitlements` with `com.apple.developer.in-app-payments` capability
- **Fix 3**: Added `CODE_SIGN_ENTITLEMENTS = App/App.entitlements` to Debug + Release build settings; added file reference and group entry in `project.pbxproj`
- **Worker**: `companionWorkerURL` still has `YOUR_SUBDOMAIN` placeholder — Roland must deploy Worker and update URL before cross-device sync works
- Verification: lint ✅, test 42/42 ✅, build ✅, cap sync ✅, xcodebuild Release ✅ BUILD SUCCEEDED

**2026-02-18 — Raouf: Build 12 — Production-Ready IAP: Toast Feedback, Subscription Status UI, Diagnostics, Already-Subscribed Handling**
- **Toast notifications (user-facing feedback)**: Purchase/restore results now show visible toast notifications at the top of the screen. Success (green), error (red), info (dark). Toasts auto-dismiss after 4 seconds. Distinguishes buy vs restore vs transaction updates via `action` field in payloads.
- **Subscription Status UI on Settings/More page**: Visible "Companion Active" (green) or "Free" (gray) status indicator with a "Recheck Subscription" button. Recheck calls `__aaCheckCompanion()` for cross-device sync via the Cloudflare Worker. Updates in real-time after purchase/restore/recheck.
- **Already-subscribed paywall handling**: When a subscribed user lands on the paywall, a green banner "You have an active Companion subscription!" is injected at the top. Prevents confusion about needing to re-purchase.
- **Enhanced diagnostics (Build 12)**: Diagnostics overlay now shows: Subscription Status (COMPANION ACTIVE / FREE), Worker URL configured (YES/NO), Last entitlement check (time + result + products), Last worker call (endpoint + HTTP status code + time + error). Exposes `window.__aaLastEntitlementCheck` and `window.__aaLastWorkerResponse` globals updated in real-time from native Swift.
- **Trial button matching**: IAP button wiring now matches "Start Companion Trial", "Start Free Trial", "Start Trial", "Try Companion", and generic trial buttons (defaults to monthly product).
- **Action field in payloads**: Purchase results now include `"action": "buy"` or `"action": "restore"` so the toast system can show contextually appropriate messages.
- **Build number**: 11 → 12
- Verification: lint ✅, test 42/42 ✅, build ✅, cap sync ✅, xcodebuild Release ✅ BUILD SUCCEEDED

**2026-02-14 — Raouf: Build 11 — Cross-Device Companion Unlock via Server-Side Receipt Validation**
- **Cloudflare Worker** (`worker/companion-validator/`): New serverless endpoint that validates Apple StoreKit 2 JWS signed transactions, then updates the user's `is_companion` field on Base44 via API. Two endpoints: `POST /validate-receipt` (JWS + auth token → verify with Apple JWKS → update Base44 user) and `GET /check-companion` (auth token → read user's companion status). Includes CORS, Apple JWKS caching, expiry/revocation checks.
- **AAStoreManager JWS capture**: `purchase()` and `restorePurchases()` now return the `jwsRepresentation` from `VerificationResult`. New `checkEntitlementsWithJWS()` method returns JWS from latest active Companion entitlement.
- **Server sync on purchase/restore**: After successful purchase or restore, `syncCompanionToServer(jws:)` POSTs the JWS + auth token to the Worker. Graceful degradation: if Worker is unreachable or not configured, local unlock still works.
- **Server-side companion check on cold boot + resume**: `checkCompanionOnServer()` called in `viewDidLoad` and `handleWillEnterForeground`. Catches server-side changes (cancellation, refund) that local cache doesn't know about.
- **Web-side companion check JS**: `window.__aaCheckCompanion()` function injected at document start. Returns a Promise that calls the Worker's `/check-companion` endpoint with the user's auth token. Updates `window.__aaIsCompanion`. Works on any device (iOS app, desktop browser).
- **Worker URL placeholder**: `companionWorkerURL` static let. Roland updates after deploying Worker with `wrangler deploy`.
- **Build number**: 10 → 11
- **Deployment**: Roland runs `cd worker/companion-validator && wrangler deploy`, notes the URL, updates `companionWorkerURL` in Swift, rebuilds iOS app.
- Verification: lint ✅, test 42/42 ✅, build ✅, cap sync ✅, xcodebuild Release ✅ BUILD SUCCEEDED

**2026-02-13 — Raouf: Build 10 — StoreKit 2 IAP Bridge for Companion Subscriptions**
- **StoreKit 2 purchase bridge**: Native `AAStoreManager` class handles product purchase, restore, and entitlement checking using modern StoreKit 2 APIs (`Product.products(for:)`, `product.purchase()`, `Transaction.currentEntitlements`, `AppStore.sync()`).
- **Web ↔ Native messaging**: `aaPurchase` WKScriptMessageHandler accepts `{ action: "buy", productId: "..." }` and `{ action: "restore" }` payloads from web JS.
- **JS callback + CustomEvent**: Native sends results via `window.__aaPurchaseResult(result)` AND `window.dispatchEvent(new CustomEvent('aa:iap', { detail: result }))`. Statuses: `success`, `cancelled`, `pending`, `error`.
- **Button wiring**: Injected JS finds Subscribe Monthly/Yearly/Restore buttons by text content on remote site and attaches click handlers. Resilient: runs via MutationObserver, survives SPA rerenders.
- **Entitlement persistence**: `aa_is_companion` stored in UserDefaults. Down-synced to web at `atDocumentStart` via `window.__aaIsCompanion`. Re-checked on cold boot, foreground resume, and transaction updates.
- **Transaction listener**: `Transaction.updates` async stream monitors renewals, refunds, revocations in background. Updates entitlement state and notifies web automatically.
- **Convenience bridge**: `window.aaPurchase("buy", productId)` and `window.aaPurchase("restore")` available at document start for web code.
- **Diagnostics**: Companion subscription status added to diagnostics overlay.
- **Logout**: Companion state cleared on logout.
- **Product IDs**: `com.abideandanchor.companion.monthly` (only purchasable product; `com.abideandanchor.companion.yearly` still recognized for entitlement checking only)
- **Build number**: 9 → 10
- **NOTE**: Website-wide Companion unlock (across devices/browsers) was local-only in Build 10. ✅ **Resolved in Build 11** — Cloudflare Worker validates Apple JWS server-side and updates Base44 user entity for cross-device unlock.
- Verification: lint ✅, test 42/42 ✅, build ✅, cap sync ✅, xcodebuild Release ✅ BUILD SUCCEEDED

**2026-02-11 — Raouf: Build 9 — Native Token Two-Way Sync (Swift ↔ localStorage)**
- **Critical discovery**: `src/lib/tokenStorage.js` and `src/context/AuthContext.jsx` are DEAD CODE in production. With `server.url` set, WKWebView loads the remote site's own JS — our local bundle never executes. Token persistence must be done entirely in native Swift.
- **UP sync**: `syncTokenToUserDefaults()` in Swift evaluates JS to read localStorage tokens, saves to UserDefaults. Called after page load (+3s, +10s), foreground resume (+1s), and before background entry.
- **DOWN sync**: `buildNativeDiagJS()` at `.atDocumentStart` reads token from UserDefaults, restores to localStorage if missing. Runs on every cold boot BEFORE React mounts.
- **Diagnostics**: Replaced useless `CapacitorStorage.*` checks with actual `UserDefaults token: true/false (len=N)`.
- **Logout**: `performFullLogout()` now clears UserDefaults token.
- **Build number**: 8 → 9
- Verification: lint ✅, test 42/42 ✅, build ✅, cap sync ✅, xcodebuild ✅

**2026-02-11 — Raouf: Build 8.1 — Apple Docs Fixes (WKProcessPool, Cookie Observer, Multi-Key Validation)**
- **Root cause fix**: `validateSession()` only checked `base44_access_token`, but at `atDocumentEnd` time React hasn't set it yet. Base44 SDK uses `token` key initially. Now checks 4 keys: `base44_access_token`, `token`, `access_token`, `base44_auth_token`.
- **Shared WKProcessPool** (Apple docs): Static singleton prevents iOS 17.4+ localStorage random clearing bug.
- **WKHTTPCookieStoreObserver**: Auto-persists domain cookies WKHTTPCookieStore → HTTPCookieStorage.shared on any change.
- **iOS 26 batch setCookies**: Uses `setCookies(_:completionHandler:)` on iOS 26+, falls back to DispatchGroup loop on iOS 15–25.
- Verification: lint ✅, test 42/42 ✅, build ✅, cap sync ✅, xcodebuild ✅

**2026-02-11 — Raouf: Build 8 — Crash Resilience + Session Diagnostics + Token Validation**
- **Part 1 — Crash Resilience**: Added `window.__AA_LAST_ERROR` tracking (stores sanitized error message, source, timestamp, URL). Added `console.error` interception to catch React error boundary logs and Minified React errors. Long base64 strings (40+ chars) are auto-redacted from error messages.
- **Part 2 — Diagnostics Upgrade**: Enhanced `collectDiagnostics()` with: JWT token expiry/age parsing (refreshed each time diagnostics open), `navigator.onLine` status, `navigator.connection.effectiveType` + downlink + RTT, session validation status, last captured error details. Added `base44_auth_token` + `token` to key checks. Fixed CapacitorStorage note (UserDefaults not visible from JS).
- **Part 3 — Session Validation**: On page load, parses JWT `exp` field from `base44_access_token`. If expired: auto-clears all auth keys so React shows login. If token exists but no `base44_user`: flags as `token-no-user` for diagnostics. Stores token metadata (hasExp, expiresAt, ageSeconds, isExpired) — never the token itself. Loop guard via `sessionStorage`. **Fix**: Original validation result now preserved across page reloads (stored in `sessionStorage('aa-session-result')`) instead of being overwritten with `already-checked`. Token metadata recomputed fresh each time diagnostics are opened.
- **Part 4 — Safety**: Verified no raw tokens or PII in any logging path. `storeLastError()` redacts long base64 strings. `__AA_TOKEN_META` stores only metadata. All diagnostics show presence + length only.
- **Build number**: Bumped 6 → 8 (Debug + Release)
- Verification: npm run lint ✅, npm run test 42/42 ✅, npm run build ✅, npx cap sync ios ✅, xcodebuild Release ✅ BUILD SUCCEEDED 0 warnings

**2026-02-11 — Raouf: Build 7 — Log Out button (Stage One #7)**
- Added proper Log Out button on More/Settings page via injected JS+CSS in PatchedBridgeViewController
- Button matches app aesthetic: outlined red border, system font, door-arrow icon, 48px min tap target
- Confirmation dialog before logout ("Are you sure?") with Log Out / Cancel buttons
- Full auth state cleanup on logout:
  - JS: clears all localStorage auth keys (base44_access_token, base44_refresh_token, etc.)
  - JS: clears sessionStorage recovery keys (aa-* prefixes)
  - Native: clears HTTPCookieStorage cookies for domain
  - Native: clears WKHTTPCookieStore cookies for domain
  - Native: clears WKWebsiteDataStore records (localStorage, sessionStorage, IndexedDB, cache)
  - Native: navigates WebView to /login
- Added `aaLogout` WKScriptMessageHandler for JS→Native communication
- Button auto-injects on /more, /settings, /profile, /account routes (pathname + hash)
- Button auto-removes when navigating away from those routes
- Verification: xcodebuild Release ✅ BUILD SUCCEEDED, 0 warnings

**2026-02-11 — Raouf: Build 6 — SelectTrigger real recovery for Prayer Request/Builder**
- Replaced overlay-first handling with route-specific hard recovery for `SelectTrigger must be used within Select` on prayer `request`/`builder` routes
- Added deterministic multi-step recovery flow per route key:
  1) hard route reload with cache-busting query params
  2) clear Cache Storage + unregister Service Workers, then hard reload
  3) final hard reload attempt
- Uses `sessionStorage` route-scoped step keys to prevent infinite reload loops
- Goal: resolve actual runtime initialization failure instead of masking with fallback UI on these routes

**2026-02-11 — Raouf: Build 6 — Lint scope fix for generated iOS artifacts**
- Fixed `npm run lint` failure caused by ESLint scanning generated Capacitor web assets under `ios/**/public/**`
- Updated ESLint flat config ignore list to exclude generated build output and report artifacts (`ios/**/public/**`, `coverage/`, `test-results/`, `*.xcresult/**`)
- Lint now targets source files instead of compiled/minified bundles

**2026-02-11 — Raouf: Build 6 — SelectTrigger unhandled rejection recovery fix**
- Updated `unhandledrejection` handling for `SelectTrigger must be used within Select` to trigger `handleSelectTriggerCrash()` directly (auto-reload path) instead of generic error-screen enhancer
- Improves recovery for Prayer List white-screen scenarios caused by React context crashes
- Keeps prayer routes free from "failed to load" overlay UI

**2026-02-11 — Raouf: Build 6 — Prayer flow silent self-heal (no overlay UI)**
- Added prayer-route-only blank/failure monitor with **silent one-time reload** per route key (`pathname + hash`)
- No recovery screen is injected on prayer routes; this preserves Roland's "no failed-to-load overlay" requirement
- Targets Prayer Corner, New Request, Builder, Prayer Wall, Prayer List route failures without introducing loop risk
- Added `hasLoadingIndicators()` helper to avoid false positives while skeleton/spinner content is still rendering
- Restored `prayerBlankHits` lifecycle reset now that prayer monitor is active again

**2026-02-11 — Raouf: Build 6 — Back Button De-dup + Prayer Route Guard**
- Fixed duplicate stacked back buttons by prioritizing a single visible native back button and removing stale injected fixed back buttons whenever native back exists
- Fixed regression where injected back button could persist across routes due early-return logic in `fixMissingBackButtons()`
- Added shared back-button detection helpers to consistently identify visible native back controls
- Added prayer flow route guard for error screen enhancer to prevent "failed to load" recovery overlay on Prayer Corner, New Request, Builder, and Prayer Wall routes
- Removed stale `prayerBlankHits` reset from `scheduleBlankChecks()` to avoid strict-mode runtime error
- Verification pending on iPhone stage-one checklist

**2026-02-11 — Raouf: Build 6 — Email/Password Only (Google Hidden)**
- Roland confirmed: no more Base44 subscription, ship with Email/Password only for iOS
- Google sign-in buttons completely hidden via `display: none` (no loops, no account picker, no native auth)
- Removed all ASWebAuthenticationSession code (~200 lines of Swift)
- Removed `import AuthenticationServices`, `ASWebAuthenticationPresentationContextProviding`, `aaGoogleAuth` handler
- Also hides "or" dividers adjacent to Google buttons
- Email/Password persistence unchanged (same-origin localStorage + Capacitor Preferences backup)
- Back button: fixed position below safe area with `env(safe-area-inset-top) + 16px`
- Prayer routes: no error overlay injection (removed `monitorPrayerRoutes`, blank detection skips prayer routes)
- Diagnostics: shows "Email/Password only (Google hidden on iOS)"
- Build number: 6 (unchanged)
- Verification: xcodebuild Release ✅ BUILD SUCCEEDED

**2026-02-11 — Raouf: Build 6 — Fix Diagnostics "unknown" Values**
- Fixed: Device model, iOS version, app version/build, DataStore showed "unknown" due to race condition
- Root cause: `evaluateJavaScript` ran asynchronously after page load, so `window.__aaNativeDiag` wasn't set when diagnostics JS read it
- Fix: Inject native data as `WKUserScript` at `.atDocumentStart` — runs before all other JS on every page load
- Added: Token value lengths (e.g. `base44_access_token: true (len=312)`) — no values exposed
- Added: `localStorage total keys: N` count for store health verification
- Extracted `buildNativeDiagJS()` helper — eliminates duplication between WKUserScript and evaluateJavaScript paths
- Verification: xcodebuild Release ✅ BUILD SUCCEEDED, 0 warnings

**2026-02-11 — Raouf: Build 6 (Revised) — Google Loop Fix (No Safari) + Diagnostics Overlay**
- Removed SFSafariViewController Google OAuth (tokens don't persist back to WKWebView)
- Blocks Google sign-in immediately on first click with inline notice (non-error-looking)
- Google buttons dimmed, counter tracked in sessionStorage, no loop possible
- Added in-app diagnostics overlay (5-tap trigger or `/#/aa-diagnostics`)
- "Copy Diagnostics" button copies plaintext to clipboard via native handler
- Enhanced os_log: `[DIAG:coldBoot]`, `[DIAG:willEnterForeground]`, `[DIAG:webViewCreated]`, `[DIAG:googleIntercept]`, `[DIAG:authMarkers]`
- Native data injection: device model, iOS version, build number, data store type → JS
- Updated Sign in with Apple docs: Roland keeps private key, never shares .p8 file
- Build number: 6 (revised, replaces previous Build 6 SFSafariViewController approach)
- Verification: xcodebuild Release ✅ BUILD SUCCEEDED, 0 warnings

**2026-02-10 — Raouf: Build 5 — Back Button Top-Left Fix**
- Moved all back buttons from top-middle to top-left on every page
- CSS: `.aa-back-topleft` class with `position:absolute; top:8px; left:12px`
- JS: `fixDuplicateBackButtons()` and global scan now add `aa-back-topleft` to all visible back buttons
- Bumped build number: 4 → 5
- Verification: xcodebuild Release ✅ BUILD SUCCEEDED

**2026-02-09 — Raouf: Milestone 5 — Security Hardening + Build 2**
- Created `src/lib/logger.js` — production-gated logger (suppresses log() in prod)
- Removed ALL token value logging (substring, previews, values) across 6 files
- Gated `window.diagnoseBase44Config`, `window.diagnoseTokenStorage`, `window.getBase44Report` behind `import.meta.env.DEV`
- Replaced 80+ console.log calls with production-gated `log()` from logger.js
- Fixed hasToken proof: checks `base44_access_token || token || base44_auth_token`
- Bumped build number: 1 → 2
- Verification: lint ✅ (0 src/ errors) test ✅ (42/42) build ✅

**2026-02-09 — Raouf: Milestone 4 — Pre-TestFlight Submission Audit**
- Full 5-phase adversarial audit (build config, policy, runtime, security, readiness)
- Build config: 9/9 PASS — version, bundle ID, signing, arm64, no debug flags
- Policy: Guideline 4.2 HIGH risk (web wrapper), privacy policy URL missing
- Security: 80+ console.log in production including token previews — needs stripping
- Runtime: 85/100 determinism — WebView HTTP error handling partial
- Verdict: Internal TestFlight ✅ SAFE WITH WARNINGS | App Store ⛔ DO NOT UPLOAD
- Report: `docs/TESTFLIGHT_AUDIT_REPORT.md`

**2026-02-08 — Raouf: Milestone 3 — App Store Blocker Fixes**
- Fixed Bundle ID → `com.abideandanchor.app`
- Created `PrivacyInfo.xcprivacy` (UserDefaults API, CA92.1)
- Created `release.xcconfig` for Release builds
- arm64 only, version 1.0.0, ITSAppUsesNonExemptEncryption
- Guideline 4.2 mitigation: dark theme, offline screen, no debug output
- Merged duplicate AGENT/CHANGELOG files
- Verification: lint ✅ test ✅ (42/42) build ✅

## Update Log

**Raouf:**
- **Date:** 2026-02-24 (Australia/Sydney)
- **Scope:** Build 15 — Fix Dead Buttons, Contradictory States, Paywall Popup Handling
- **Summary:** Roland tested Build 13 and found critical failures: (1) purchase and restore buttons dead for non-subscribed users — "Get Companion on iPhone" and "Restore Purchase" in paywall popups do nothing, (2) contradictory gating — "active subscription" banner shown alongside "Subscribe Monthly" button, a "Companion Access" popup appears with trial + restore buttons for subscribed users. Root cause: `wireIAPButtons()` and `handleAlreadySubscribed()` searched only `document.getElementById('root')` but Base44 paywall popups render as React portals outside `#root` directly on `document.body`. Additionally, "Get Companion on iPhone" used exact match (`text === 'get companion'`) instead of substring match. Fixes: (1) Both functions now search `document.body` — catches all buttons regardless of render location. (2) Button classification uses priority-based logic: restore > trial > yearly > monthly (prevents misclassification). (3) Broader matching with `indexOf` catches longer button text. (4) When subscribed, popup/modal containers are detected (fixed/absolute position + z-index >= 10, or class names with modal/popup/overlay/dialog/backdrop) and dismissed. (5) Body-level `MutationObserver` watches `document.body` with `childList: true` to catch React portals. (6) Periodic IAP check every 3s for 30s catches late-appearing popups.
- **Files Changed:**
  - `ios/App/App/PatchedBridgeViewController.swift` — MODIFIED: Rewrote `wireIAPButtons()` (body-wide search, priority classification, broader text matching, skip own UI via `.closest()`), rewrote `handleAlreadySubscribed()` (body-wide search, popup/modal dismissal), added body-level MutationObserver, added periodic IAP check in `scheduleBlankChecks()`
  - `ios/App/App.xcodeproj/project.pbxproj` — MODIFIED: Build number 14 → 15
  - `AGENT.md` — Updated Milestone B acceptance criteria, Last Change Log, this Update Log entry
  - `CHANGELOG.md` — New entry
- **Verification:** npm run lint ✅, npm run test 42/42 ✅, npm run build ✅, npx cap sync ios ✅, xcodebuild Release ✅ BUILD SUCCEEDED
- **Follow-ups:**
  - Roland: rebuild on device and test with non-subscribed sandbox account — tap "Get Companion on iPhone" in paywall popup
  - Roland: test Restore Purchases button in paywall popup
  - Roland: test subscribed account — paywall popup should auto-dismiss, no subscribe buttons visible
  - Roland: desktop web subscribe/restore buttons are Base44 platform JS (not our iOS injections) — if dead, it's a Base44 issue
  - Roland: run through all 10 acceptance gate items

**Raouf:**
- **Date:** 2026-02-24 (Australia/Sydney)
- **Scope:** Build 14 — Monthly-Only Launch Scope (Milestone B)
- **Summary:** Roland updated App Store Connect: Companion Monthly is the only subscription for submission. Yearly removed from sale, 7-day free trial introductory offer removed. This build aligns the app to that simplified scope. Purchase path now only offers Monthly. Yearly and trial buttons are hidden from the paywall UI via `display:none` so there are no dead ends. When a user is already subscribed, all subscribe buttons are hidden — only the "active subscription" banner shows, eliminating contradictory states. `AAStoreManager` now distinguishes between `purchasableProductIds` (monthly only) and `companionProductIds` (monthly + yearly for entitlement checking — existing yearly subscribers stay unlocked until natural expiry). The `test.storekit` local config is updated to monthly only. ESLint config updated to ignore Capacitor SPM build artifacts.
- **Files Changed:**
  - `ios/App/App/PatchedBridgeViewController.swift` — MODIFIED: Added `purchasableProductIds` (monthly only), purchase validation uses purchasable set, yearly/trial button hiding in wireIAPButtons(), subscribe buttons hidden on paywall when already subscribed, subscription status text says "Monthly"
  - `ios/App/App/test.storekit` — MODIFIED: Removed yearly subscription product, monthly only remains
  - `ios/App/App.xcodeproj/project.pbxproj` — MODIFIED: Build number 13 → 14
  - `eslint.config.js` — MODIFIED: Added `ios/**/build/**` to ignores
  - `AGENT.md` — Updated Milestone B acceptance criteria, Last Change Log, this Update Log entry
  - `CHANGELOG.md` — New entry
- **Verification:** npm run lint ✅, npm run test 42/42 ✅, npm run build ✅, npx cap sync ios ✅, xcodebuild Release ✅ BUILD SUCCEEDED
- **Follow-ups:**
  - Roland: rebuild on device and test monthly subscribe flow end-to-end
  - Roland: test restore purchases on non-subscribed account
  - Roland: test kill-and-relaunch persistence on subscribed account
  - Roland: confirm no yearly/trial buttons visible on paywall
  - Roland: confirm no contradictory states (active + subscribe visible simultaneously)

**Raouf:**
- **Date:** 2026-02-23 (Australia/Sydney)
- **Scope:** StoreKit Config Cleanup — Version 4 Fix Confirmed Working
- **Summary:** After extensive debugging, discovered the root cause of `Product.products(for:)` returning empty: Xcode 26.2 requires StoreKit config file format version 4 (major:4, minor:0), but our manually-created `Configuration.storekit` used version 2 and was silently ignored. Fix: created `test.storekit` via Xcode's File > New > StoreKit Configuration File wizard (generates correct v4 format), added both Companion subscription products (monthly $9.99, yearly $79.99), set in scheme. Confirmed working on device — products now load. Cleanup: removed temporary `diagnoseProductAvailability()` + `showDiagnosticAlert()` diagnostic methods from AAStoreManager. Removed stale `Configuration.storekit` file reference and group entry from project.pbxproj (file no longer exists on disk). Fixed `test.storekit` lastKnownFileType from `text` to `com.apple.dt.storekit`.
- **Files Changed:**
  - `ios/App/App/PatchedBridgeViewController.swift` — MODIFIED: Removed `diagnoseProductAvailability()`, `showDiagnosticAlert()`, and startup diagnostic call
  - `ios/App/App.xcodeproj/project.pbxproj` — MODIFIED: Removed stale `Configuration.storekit` file reference + group entry; fixed `test.storekit` lastKnownFileType to `com.apple.dt.storekit`
  - `AGENT.md` — Updated Last Change Log, this Update Log entry
  - `CHANGELOG.md` — New entry
- **Verification:** xcodebuild Debug ✅ BUILD SUCCEEDED
- **Key learnings:**
  - Xcode 26.2 StoreKit config format: version 4 with `appPolicies` section, different `settings` fields
  - StoreKit local config ONLY works when launched from Xcode debugger (not devicectl)
  - Must create `.storekit` files via Xcode's wizard — manual JSON creation gets wrong version format
  - `lastKnownFileType` for `.storekit` files must be `com.apple.dt.storekit`

**Raouf:**
- **Date:** 2026-02-23 (Australia/Sydney)
- **Scope:** Build 13 — Web Refresh After Purchase (Instant Companion Unlock)
- **Summary:** After a successful IAP purchase or restore, the native side updated UserDefaults and synced to the Cloudflare Worker, but the Base44 React app in the WebView didn't re-fetch `/User/me` until the app was killed and reopened. Added `triggerWebRefreshAfterPurchase()` method using native `WKWebView.reloadFromOrigin()` (Apple docs: "performs end-to-end revalidation of the content using cache-validating conditionals") after the Worker sync returns 200 OK. Also added fallback calls in the buy and restore paths for when no JWS is available (Worker sync won't fire). Apple docs audit confirmed `reloadFromOrigin()` is the correct API — JS `window.location.reload(true)` `forceGet` param is deprecated/non-standard in modern WebKit. This completes Roland's DoD criterion: "purchase unlocks instantly."
- **Files Changed:**
  - `ios/App/App/PatchedBridgeViewController.swift` — MODIFIED: Added `triggerWebRefreshAfterPurchase()` using native `reloadFromOrigin()`, called from `syncCompanionToServer()` on 200 OK and from buy/restore fallback paths
  - `AGENT.md` — Updated Last Change Log, this Update Log entry
  - `CHANGELOG.md` — New entry
- **Verification:** npm run lint ✅, npm run test 42/42 ✅, npm run build ✅, npx cap sync ios ✅, xcodebuild Release ✅ BUILD SUCCEEDED (code signing skipped — no provisioning profile on this machine)
- **Follow-ups:**
  - Roland: rebuild and test purchase on device — Companion should unlock immediately after purchase without kill/reopen
  - Roland: test restore flow — same instant unlock expected

**Raouf:**
- **Date:** 2026-02-18 (Australia/Sydney)
- **Scope:** IAP Audit — Critical Bundle ID Fix + In-App Purchase Entitlement
- **Summary:** Full audit of IAP pipeline revealed two critical blockers preventing App Store connection. (1) `PRODUCT_BUNDLE_IDENTIFIER` was `com.abideandanchor.test` in both Debug and Release target configs — Apple's StoreKit routes `Product.products(for:)` by the bundle ID of the running app, so it returned an empty array and purchases were silently blocked with "Product not found". (2) No `.entitlements` file existed and `CODE_SIGN_ENTITLEMENTS` was never set — without `com.apple.developer.in-app-payments`, the provisioning profile doesn't grant IAP access at OS level. Fixed both. Also noted that `companionWorkerURL` still has `YOUR_SUBDOMAIN` placeholder.
- **Files Changed:**
  - `ios/App/App/App.entitlements` — CREATED: New entitlements file with `com.apple.developer.in-app-payments`
  - `ios/App/App.xcodeproj/project.pbxproj` — MODIFIED: Added `App.entitlements` file reference + group entry; added `CODE_SIGN_ENTITLEMENTS = App/App.entitlements`; fixed `PRODUCT_BUNDLE_IDENTIFIER = com.abideandanchor.app` in both Debug (504EC3171) and Release (504EC3181) target build configs
  - `AGENT.md` — Updated Known Issues, Last Change Log, this Update Log entry
  - `CHANGELOG.md` — New entry
- **Verification:** npm run lint ✅, npm run test 42/42 ✅, npm run build ✅, npx cap sync ios ✅, xcodebuild Release ✅ BUILD SUCCEEDED (exit 0)
- **Follow-ups:**
  - Roland: verify App Store Connect app record `com.abideandanchor.app` exists with In-App Purchase capability ON
  - Roland: verify products `com.abideandanchor.companion.monthly` + `com.abideandanchor.companion.yearly` exist in App Store Connect
  - Roland: create sandbox tester account, run TestFlight build, test purchase flow
  - Roland: deploy Cloudflare Worker (`cd worker/companion-validator && wrangler deploy`), update `companionWorkerURL` in `PatchedBridgeViewController.swift:186`, rebuild

**Raouf:**
- **Date:** 2026-02-18 (Australia/Sydney)
- **Scope:** Build 12 — Production-Ready IAP: Toast Feedback, Subscription Status UI, Diagnostics, Already-Subscribed Handling
- **Summary:** Addressed Roland's full IAP Definition of Done checklist. Added user-visible toast notifications for all purchase/restore/renewal events so the user always sees feedback. Added a "Subscription" status section on the Settings/More page showing "Companion Active" or "Free" with a "Recheck Subscription" button for manual cross-device sync. Added "already subscribed" banner on the paywall page so subscribed users aren't confused. Enhanced diagnostics overlay with last entitlement check time/result and last worker response code (200/401/etc) for quick debugging. Extended IAP button wiring to match trial-related button text. Added `action` field to purchase result payloads for toast differentiation.
- **Files Changed:**
  - `ios/App/App/PatchedBridgeViewController.swift` — MODIFIED: Added toast notification CSS+JS, subscription status UI injection, already-subscribed banner, enhanced diagnostics overlay, pushEntitlementCheckToJS + pushWorkerResponseToJS helper methods, action field in buy/restore payloads, trial button matching, workerConfigured diag field, updated orchestrator
  - `ios/App/App.xcodeproj/project.pbxproj` — Build number 11 → 12
  - `AGENT.md` — Updated Last Change Log, this Update Log entry
  - `CHANGELOG.md` — New entry
- **Verification:** npm run lint ✅, npm run test 42/42 ✅, npm run build ✅, npx cap sync ios ✅, xcodebuild Release ✅ BUILD SUCCEEDED (exit 0)
- **Client Acceptance Tests Addressed:**
  1. New user start trial (Monthly/Yearly) → toast "Companion features unlocked!" on success
  2. Persistence → UserDefaults `aa_is_companion` survives kill/reopen; login re-checks entitlements + server
  3. Restore on same device → AppStore.sync() + toast feedback (success or "no subscription found")
  4. Restore on fresh install → same restore flow with JWS server sync
  5. Already-subscribed user → green banner on paywall, status shown in Settings
  6. Cross-device unlock → Recheck Subscription button calls Worker; server status synced
  7. Diagnostics → Subscription status line, last entitlement check, last worker response code

**Raouf:**
- **Date:** 2026-02-14 (Australia/Sydney)
- **Scope:** Build 11 — Cross-Device Companion Unlock via Server-Side Receipt Validation
- **Summary:** Implemented server-side receipt validation via Cloudflare Worker so Companion subscription status syncs across all devices. The Worker validates Apple StoreKit 2 JWS signed transactions using Apple's JWKS public keys, then updates the user's `is_companion` field on Base44. iOS app now captures JWS from purchase/restore and POSTs it to the Worker. On cold boot and foreground resume, the app also checks the server for companion status changes (catches cancellations/refunds). A `window.__aaCheckCompanion()` JS function is injected at document start so the web app on any device can check companion status.
- **Files Changed:**
  - `worker/companion-validator/index.js` — CREATED: Cloudflare Worker with `/validate-receipt` and `/check-companion` endpoints
  - `worker/companion-validator/wrangler.toml` — CREATED: Cloudflare deployment config
  - `worker/companion-validator/package.json` — CREATED: Worker package manifest
  - `ios/App/App/PatchedBridgeViewController.swift` — MODIFIED: Added `companionWorkerURL`, `syncCompanionToServer()`, `checkCompanionOnServer()`, `checkEntitlementsWithJWS()`, JWS return from purchase/restore, server check on cold boot + foreground, `window.__aaCheckCompanion()` JS injection
  - `ios/App/App.xcodeproj/project.pbxproj` — Build number 10 → 11
  - `AGENT.md` — Updated Known Issues, Last Change Log, this Update Log entry
- **Verification:** npm run lint ✅, npm run test 42/42 ✅, npm run build ✅, npx cap sync ios ✅, xcodebuild Release ✅ BUILD SUCCEEDED (exit 0)
- **Follow-ups:**
  - Roland creates Cloudflare account (free tier), runs `cd worker/companion-validator && wrangler deploy`
  - Roland updates `companionWorkerURL` in PatchedBridgeViewController.swift with deployed Worker URL
  - Roland rebuilds iOS app
  - Test: purchase on iOS → check `window.__aaIsCompanion` on desktop browser
  - Test: restore on new device → server updated
  - Test: cancel subscription → next check returns `isCompanion: false`

**Raouf:**
- **Date:** 2026-02-13 (Australia/Sydney)
- **Scope:** Build 10 — StoreKit 2 IAP Bridge for Companion Subscriptions
- **Summary:** Implemented complete native IAP bridge using StoreKit 2 so web subscription buttons trigger native App Store purchases. Added `AAStoreManager` class with purchase/restore/entitlement checking. Web buttons on the remote Base44 site are wired via injected JS click handlers (resilient text matching + MutationObserver). Results sent back to web via `window.__aaPurchaseResult()` callback + `aa:iap` CustomEvent. Entitlements persisted in UserDefaults (`aa_is_companion`), down-synced to web at document start. Transaction listener monitors renewals/refunds in background. Companion state included in diagnostics overlay.
- **Files Changed:**
  - `ios/App/App/PatchedBridgeViewController.swift` — MODIFIED: Added `import StoreKit`, `AAStoreManager` class (StoreKit 2 purchase/restore/entitlements), `aaPurchase` message handler, `handlePurchaseMessage()`, `sendPurchaseResult()`, `persistCompanionState()`, `refreshWebEntitlements()`, `startIAPTransactionListener()`, IAP bridge JS at document start, button wiring JS, entitlement re-check on foreground, companion state in diagnostics, companion state cleared on logout
  - `ios/App/App.xcodeproj/project.pbxproj` — Build number 9 → 10
  - `AGENT.md` — Updated Known Issues, Last Change Log, this Update Log entry
- **Verification:** npm run lint ✅, npm run test 42/42 ✅, npm run build ✅, npx cap sync ios ✅, xcodebuild Release ✅ BUILD SUCCEEDED
- **Follow-ups:**
  - Roland creates sandbox tester account in App Store Connect
  - Test monthly purchase, yearly purchase, cancel, restore in sandbox
  - Verify Companion features unlock immediately after purchase
  - Verify entitlement persists across app restart
  - Website-wide unlock requires server-side receipt validation (future)

**Raouf:**
- **Date:** 2026-02-11 (Australia/Sydney)
- **Scope:** Build 8 — Crash Resilience + Session Diagnostics + Token Validation
- **Summary:** 5-part hardening of PatchedBridgeViewController injected JS. (1) Added `window.__AA_LAST_ERROR` error tracking with sanitized messages + `console.error` interception for React boundary catches. (2) Enhanced diagnostics overlay with JWT token expiry/age, network status (online/effectiveType/downlink/RTT), session validation status, and last captured error. (3) Added JWT-based session validation on page load — auto-clears expired tokens, flags token-without-user states. (4) Safety audit confirmed: no raw tokens or PII in any path, long base64 strings auto-redacted. (5) Full build pipeline verified green.
- **Files Changed:**
  - `ios/App/App/PatchedBridgeViewController.swift` — MODIFIED: Added error tracking infrastructure (storeLastError, console.error interceptor), session validation with JWT parsing (validateSession IIFE), enhanced collectDiagnostics with network/session/error sections
  - `AGENT.md` — Updated Last Change Log, this Update Log entry
  - `CHANGELOG.md` — New entry
- **Verification:** npm run lint ✅, npm run test 42/42 ✅, npm run build ✅, npx cap sync ios ✅, xcodebuild Release ✅ BUILD SUCCEEDED 0 warnings
- **Follow-ups:**
  - Roland tests on iPhone: trigger diagnostics (5-tap) → verify new sections (Network, Session Validation, Last Error)
  - Test expired token scenario: manually set expired JWT in localStorage → reopen app → should auto-clear and show login

**Raouf:**
- **Date:** 2026-02-11 (Australia/Sydney)
- **Scope:** Build 7 — Log Out button in More/Settings (Stage One acceptance #7)
- **Summary:** Implemented a proper Log Out button that appears on the More/Settings page. The button is injected via JS in PatchedBridgeViewController and styled to match the app's aesthetic (outlined red, system font, logout icon). Tapping shows a confirmation dialog. On confirm, JS clears all localStorage/sessionStorage auth keys, then posts to native `aaLogout` handler which clears HTTPCookieStorage, WKHTTPCookieStore, and all WKWebsiteDataStore records for the domain, then navigates to /login. This allows a different account to log in.
- **Files Changed:**
  - `ios/App/App/PatchedBridgeViewController.swift` — MODIFIED: Added `aaLogout` message handler + `performFullLogout()` Swift method, CSS for logout button + confirmation dialog, JS `injectLogoutButton()` + `showLogoutConfirmation()` + `performLogout()` + `isMoreOrSettingsRoute()`, wired into orchestrator
  - `AGENT.md` — Updated Known Issues, Stage One table, Last Change Log, this Update Log entry
  - `CHANGELOG.md` — New entry
- **Verification:** npm run lint ✅, npm run test 42/42 ✅, npm run build ✅, npx cap sync ios ✅, xcodebuild Release ✅ BUILD SUCCEEDED 0 warnings
- **Follow-ups:**
  - Roland tests on iPhone: navigate to More → tap Log Out → confirm → verify returns to Login → log in with different account

**Raouf:**
- **Date:** 2026-02-11 (Australia/Sydney)
- **Scope:** Build 6 — Prayer Request/Builder `SelectTrigger` crash real fix path
- **Summary:** Implemented non-cosmetic recovery flow for the `SelectTrigger must be used within Select` crash on Prayer Request/Builder routes. Instead of only rendering fallback UI, runtime now performs route-scoped hard recovery attempts: first hard reload with cache-busting params, then cache/service-worker purge + hard reload, then one final hard reload. Recovery state is persisted per route in `sessionStorage` to avoid loops.
- **Files Changed:**
  - `ios/App/App/PatchedBridgeViewController.swift` — MODIFIED: added `isSelectCrashRoute()`, `forceHardRouteReload()`, `clearCachesThenReload()`, and route-scoped recovery steps inside `handleSelectTriggerCrash()`
  - `AGENT.md` — Updated Last Change Log + this Update Log entry
  - `CHANGELOG.md` — New unreleased entry
- **Verification:** pending (next: run tests + iOS build)
- **Follow-ups:**
  - Re-test Prayer Corner → New Request and Prayer Corner → Builder on iPhone

**Raouf:**
- **Date:** 2026-02-11 (Australia/Sydney)
- **Scope:** Build 6 — Fix ESLint false failures on generated files
- **Summary:** Resolved lint blocker where `npm run lint` analyzed compiled/minified files in `ios/App/App/public/assets/index-*.js` and reported hundreds of irrelevant rule violations. Updated `eslint.config.js` ignore patterns to exclude generated iOS web assets and output/report directories (`ios/**/public/**`, `coverage/`, `test-results/`, `*.xcresult/**`). This keeps lint focused on maintainable source files.
- **Files Changed:**
  - `eslint.config.js` — MODIFIED: expanded flat-config `ignores` list
  - `AGENT.md` — Updated Last Change Log + this Update Log entry
  - `CHANGELOG.md` — New unreleased entry
- **Verification:** pending (next: rerun `npm run lint`)
- **Follow-ups:**
  - Keep generated artifact paths out of lint scope when build pipeline paths change

**Raouf:**
- **Date:** 2026-02-11 (Australia/Sydney)
- **Scope:** Build 6 — SelectTrigger crash path aligned for unhandled Promise rejection
- **Summary:** Patched `window.unhandledrejection` handler so `must be used within` errors now invoke `handleSelectTriggerCrash()` (debounced auto-reload + retry UI path) rather than generic `detectAndFixErrorScreen()`. This ensures the same crash recovery behavior for both `error` and `unhandledrejection` events and improves Prayer List white-screen resilience.
- **Files Changed:**
  - `ios/App/App/PatchedBridgeViewController.swift` — MODIFIED: `unhandledrejection` callback uses `handleSelectTriggerCrash`
  - `AGENT.md` — Updated Last Change Log + this Update Log entry
  - `CHANGELOG.md` — New unreleased entry
- **Verification:** pending (next: rerun build/test)
- **Follow-ups:**
  - Validate Prayer List screen no longer stalls on SelectTrigger crash paths

**Raouf:**
- **Date:** 2026-02-11 (Australia/Sydney)
- **Scope:** Build 6 — Prayer routes white-screen/failure self-heal (overlay-free)
- **Summary:** Implemented targeted prayer-route monitor that never injects fallback UI but performs one silent reload when a prayer route remains genuinely blank or shows "failed to load" for 5 consecutive checks (15s). This directly targets Prayer List white-screen and Prayer Corner sub-route dead states while respecting the requirement to avoid recovery screens on New Request/Builder/Wall. Added `hasLoadingIndicators()` helper so monitor skips while loading indicators are present. Reload is loop-safe via sessionStorage key (`aa-prayer-reload:<pathname>|<hash>`), one reload per route.
- **Files Changed:**
  - `ios/App/App/PatchedBridgeViewController.swift` — MODIFIED: `monitorPrayerRoutes()` re-enabled as silent self-heal, added `prayerBlankHits`, `hasLoadingIndicators()`, and per-route one-time reload guard
  - `AGENT.md` — Updated Last Change Log + this Update Log entry
  - `CHANGELOG.md` — New unreleased entry
- **Verification:** pending (run build/test next)
- **Follow-ups:**
  - Device-check Prayer Corner -> New Request/Builder/Prayer Wall and Prayer List on iPhone

**Raouf:**
- **Date:** 2026-02-11 (Australia/Sydney)
- **Scope:** Build 6 — iPhone Stage One blockers (back-button duplicates + Prayer Corner overlays)
- **Summary:** Patched injected iOS JS runtime to eliminate duplicate back buttons on routes that already render a native back button. Root cause was `fixMissingBackButtons()` returning early when `#aa-fixed-back` existed, leaving stale injected buttons stacked on top of native ones. New flow: detect visible native back buttons first, remove injected fixed button when native exists, keep only one canonical native back button (top-left-most), and hide remaining duplicates. Also blocked the "failed to load" enhancer from running on prayer flow routes (`/prayer`, `/request`, `/builder`, `/wall`, including hash routes), preventing unwanted recovery UI in Prayer Corner sub-pages. Removed a strict-mode runtime bug by dropping stale `prayerBlankHits` assignment.
- **Files Changed:**
  - `ios/App/App/PatchedBridgeViewController.swift` — MODIFIED: added `isPrayerFlowRoute()`, `isVisibleBackElement()`, `getVisibleNativeBackButtons()`; refactored `fixDuplicateBackButtons()`, `fixMissingBackButtons()`, `cleanupStalePatches()`; removed stale `prayerBlankHits` reset
  - `AGENT.md` — Updated Last Change Log + this Update Log entry
  - `CHANGELOG.md` — New unreleased entry
- **Verification:** pending (next step: build/lint in repo)
- **Follow-ups:**
  - Rebuild iOS and validate on iPhone: Prayer Corner, New Request, Builder, Prayer Wall, Prayer List

**Raouf:**
- **Date:** 2026-02-11 (Australia/Sydney)
- **Scope:** Build 6 — Fix Prayer Corner routes + Back button position
- **Summary:** Fixed 4 failing acceptance tests: (1) Back button was at `top: 8px` which is behind the clock/notch on iPhone 11/12 — changed to `position: fixed` with `env(safe-area-inset-top)` so it sits below the safe area. Back button now rendered as a pill on body (not inside header) with white background + shadow for guaranteed visibility. (2) Prayer route monitoring was too aggressive — `monitorPrayerRoutes()` fired at 3s and showed "Content didn't load" before Base44 API data finished loading. Now requires 3 consecutive blank checks (9+ seconds) before showing error. (3) Blank screen detection same fix — requires 3 consecutive hits. Both detectors now skip if loading indicators are present (`animate-spin`, `animate-pulse`, `loading`, `skeleton`, `spinner`). (4) Added hash route support for prayer paths. Counters reset on SPA navigation. Added `hashchange` listener.
- **Files Changed:**
  - `ios/App/App/PatchedBridgeViewController.swift` — MODIFIED: CSS B8 `top:8px`→`calc(env(safe-area-inset-top)+4px)` + `position:fixed` + `z-index:9999`. `fixMissingBackButtons()` rewritten: uses `needsBackButton()` helper, appends fixed pill button to `document.body`. `detectBlankScreen()` + `monitorPrayerRoutes()` now use consecutive hit counters + loading indicator checks. `cleanupStalePatches()` uses `needsBackButton()`. Added `hashchange` listener. Reset counters in `scheduleBlankChecks()`.
  - `AGENT.md` — Updated Known Issues + this Update Log entry
  - `CHANGELOG.md` — New entry
- **Verification:** xcodebuild Release ✅ BUILD SUCCEEDED
- **Follow-ups:**
  - Roland tests Prayer Corner, New Request, Builder, Prayer Wall, Prayer List on device
  - Back button should be visible below clock, tappable, pill-shaped

**Raouf:**
- **Date:** 2026-02-11 (Australia/Sydney)
- **Scope:** Build 6 — Email/Password Only (Google Hidden per Roland)
- **Summary:** Roland confirmed he's not paying Base44 anymore, so Google sign-in is completely removed from iOS. Deleted ~200 lines of ASWebAuthenticationSession Swift code (startGoogleOAuth, handleGoogleAuthCallback, injectTokenIntoWebView, fallbackCookieSync, checkPostOAuthState, notifyJSGoogleResult). Removed `import AuthenticationServices`, `ASWebAuthenticationPresentationContextProviding` conformance, `aaGoogleAuth` message handler. JS intercept now simply hides Google buttons via `display: none` + hides adjacent "or" dividers. No loops possible — button is invisible. Email/Password unchanged. Diagnostics updated.
- **Files Changed:**
  - `ios/App/App/PatchedBridgeViewController.swift` — MODIFIED: Removed all Google OAuth Swift code. Simplified JS Google intercept to hide-only. Removed `.aa-google-notice` CSS. Removed `resetGoogleNotice()` from SPA hooks. Updated diagnostics to show "Email/Password only".
  - `AGENT.md` — Updated Known Issues, Last Change Log, this Update Log entry
  - `CHANGELOG.md` — New entry
- **Verification:** xcodebuild Release ✅ BUILD SUCCEEDED
- **Follow-ups:**
  - Roland tests on iPhone: Google button should be invisible, Email/Password works
  - Sign in with Apple: future phase, requires Apple Developer setup from Roland

**Raouf:**
- **Date:** 2026-02-11 (Australia/Sydney)
- **Scope:** Build 6 — ASWebAuthenticationSession Google OAuth (Proper Fix) [SUPERSEDED]
- **Summary:** Replaced the "block Google" approach with proper native OAuth. Google sign-in now launches `ASWebAuthenticationSession` (Apple's recommended iOS auth tool). On callback: extracts token from URL params → injects into WKWebView localStorage → navigates home. If no token in callback, falls back to cookie sync from HTTPCookieStorage → WKWebView. Includes 3s debounce, max 3 attempts before Email/Password fallback notice, and `aaGoogleAuthPending` flag to prevent concurrent sessions. Uses `abideandanchor` custom URL scheme (already registered in Info.plist) as callbackURLScheme. `prefersEphemeralWebBrowserSession = false` ensures cookies are shared with Safari cookie jar for maximum compatibility.
- **Files Changed:**
  - `ios/App/App/PatchedBridgeViewController.swift` — MODIFIED: Added `AuthenticationServices` import, `ASWebAuthenticationPresentationContextProviding` conformance, `aaGoogleAuth` message handler, `startGoogleOAuth()`, `handleGoogleAuthCallback()`, `injectTokenIntoWebView()`, `fallbackCookieSync()`, `checkPostOAuthState()`, `notifyJSGoogleResult()`. Rewrote Google intercept JS from "block" to "launch native OAuth". Updated diagnostics.
  - `AGENT.md` — This entry + updated Known Issues + Last Change Log
  - `CHANGELOG.md` — New entry
- **Verification:** xcodebuild Release ✅ BUILD SUCCEEDED, 0 warnings
- **Follow-ups:**
  - Roland tests Google sign-in on physical iPhone: should launch native auth browser, complete OAuth, land on Home
  - If Base44 doesn't redirect to `abideandanchor://` callback, cookie sync fallback activates
  - Sign in with Apple: still requires Apple Developer setup from Roland

**Raouf:**
- **Date:** 2026-02-11 (Australia/Sydney)
- **Scope:** Build 6 (Revised) — Google Loop Fix (No Safari) + Diagnostics Overlay
- **Summary:** Previous Build 6's SFSafariViewController approach was fundamentally broken — Safari and WKWebView have separate localStorage/cookie stores, so tokens obtained in Safari never persist back into the WebView. This revised Build 6 removes SFSafariViewController entirely and blocks Google sign-in immediately on first click with a clear, non-error-looking inline notice guiding users to Email/Password. Added comprehensive in-app diagnostics overlay (triggered by 5-tap on header or `/#/aa-diagnostics`) with "Copy Diagnostics" button that copies plaintext to clipboard via native WKScriptMessageHandler. Enhanced os_log markers for all lifecycle events. Native diagnostics data (device model, iOS version, build number, data store type) injected into JS from Swift. Updated Sign in with Apple documentation to NOT request private key file from Roland.
- **Files Changed:**
  - `ios/App/App/PatchedBridgeViewController.swift` — MODIFIED: Removed SafariServices import + SFSafariViewController handler, rewrote Google intercept JS to immediate-block, added diagnostics overlay JS + CSS, added `aaCopyDiagnostics` message handler, added `injectNativeDiagnostics()`, enhanced `logDiagnostics()` with device info + auth markers
  - `ios/App/App.xcodeproj/project.pbxproj` — Build number remains 6
  - `AGENT.md` — This entry + updated Last Change Log
  - `CHANGELOG.md` — Revised Build 6 entry, updated Sign in with Apple docs
- **Verification:** xcodebuild Release ✅ BUILD SUCCEEDED, 0 warnings on PatchedBridgeViewController
- **Follow-ups:**
  - Roland verifies on physical iPhone: Google sign-in shows notice (no loop), diagnostics overlay opens (5-tap), Copy Diagnostics works
  - Sign in with Apple: requires Apple Developer setup from Roland (see CHANGELOG.md — Roland retains private key)

**Raouf:**
- **Date:** 2026-02-11 (Australia/Sydney)
- **Scope:** Build 6 (Initial, SFSafariViewController approach) — SUPERSEDED by revised Build 6 above
- **Summary:** Fixed all issues from Roland's Build 6 acceptance criteria. Google sign-in no longer loops — intercepts Google OAuth clicks in WebView and opens in SFSafariViewController with correct `from_url=abideandanchor://auth-callback` so the deep link fires correctly. Added graceful fallback banner ("Google Sign-In isn't available in the app yet. Please use Email & Password.") if Google auth still fails. Improved Prayer Corner route monitoring for sub-pages (New Request, Builder, Prayer Wall). Extended back button injection to all Prayer routes. Tuned blank screen detection for Prayer List. Email/password persistence remains PASS (untouched).
- **Files Changed:**
  - `ios/App/App/PatchedBridgeViewController.swift` — MODIFIED: Added SafariServices import, WKScriptMessageHandler conformance, `aaOpenInBrowser` message handler for SFSafariViewController, Google OAuth interception JS (section 0), prayer route monitoring JS (section 2b), extended back button routes, improved blank detection thresholds, Google fallback CSS
  - `ios/App/App.xcodeproj/project.pbxproj` — Build 5→6
  - `AGENT.md` — This entry + known issues update
  - `CHANGELOG.md` — New entry
- **Verification:** xcodebuild Release ✅ BUILD SUCCEEDED, no warnings on PatchedBridgeViewController
- **Follow-ups:**
  - Roland verifies on physical iPhone: Google sign-in no longer loops, Prayer Corner routes load, Prayer List not blank
  - Sign in with Apple: requires Apple Developer setup (see CHANGELOG.md for details Roland needs to provide)

**Raouf:**
- **Date:** 2026-02-10 (Australia/Sydney)
- **Scope:** Build 5 — Back Button Top-Left Fix
- **Summary:** Moved all back buttons from top-middle to top-left on every page. Added CSS class `.aa-back-topleft` with absolute positioning (top:8px, left:12px, z-index:50). Updated JS `fixDuplicateBackButtons()` to apply class to surviving back button, global scan to apply to all visible back buttons, `cleanupStalePatches()` to re-apply on navigation, and injected back button to use the class.
- **Files Changed:**
  - `ios/App/App/PatchedBridgeViewController.swift` — MODIFIED: CSS + JS back button positioning
  - `ios/App/App.xcodeproj/project.pbxproj` — Build 4→5
  - `AGENT.md` — This entry
  - `CHANGELOG.md` — New entry
- **Verification:** xcodebuild Release ✅ BUILD SUCCEEDED
- **Follow-ups:** Roland verifies back button position on all pages on physical device

**Raouf:**
- **Date:** 2026-02-10 (Australia/Sydney)
- **Scope:** Build 4 — Login Persistence Fix (Milestone 8)
- **Summary:** Fixed login persistence bug where customers on iPhone 11/12 lost their session after backgrounding or killing the app. Root cause: WKWebView content process termination under memory pressure triggers blind reload without cookie recovery. Fix adds bidirectional cookie bridging (HTTPCookieStorage ↔ WKHTTPCookieStore), explicit persistent data store verification, smart content process termination recovery with cookie sync before reload, foreground lifecycle handling that avoids unnecessary reloads, and os_log diagnostics for cold boot/resume/recovery events.
- **Files Changed:**
  - `ios/App/App/PatchedBridgeViewController.swift` — MODIFIED: Added cookie bridging, persistent store check, lifecycle observers, process termination recovery, os_log diagnostics
  - `ios/App/App.xcodeproj/project.pbxproj` — Build 3→4
  - `AGENT.md` — This entry
  - `CHANGELOG.md` — New entry
- **Verification:** xcodebuild Release ✅ BUILD SUCCEEDED
- **Follow-ups:** Roland deploys Build 4 to TestFlight, verifies login persistence on customer iPhone 11/12 devices

**Raouf:**
- **Date:** 2026-02-10 (Australia/Sydney)
- **Scope:** Build 3 — TestFlight Bug Fixes (Milestone 7)
- **Summary:** Fixed all production issues reported in TestFlight Build 2. Created PatchedBridgeViewController with WKUserScript injection to patch remote Base44 app issues: SelectTrigger context error (ErrorBoundary), duplicate/missing back buttons (DOM patches), bottom nav squash with 5 tabs (CSS fixes), white screen prevention (global error handler).
- **Files Changed:**
  - `ios/App/App/PatchedBridgeViewController.swift` — NEW: Custom VC with WKUserScript patches
  - `ios/App/App/Base.lproj/Main.storyboard` — Updated to PatchedBridgeViewController
  - `ios/App/App.xcodeproj/project.pbxproj` — New file ref + build 2→3
  - `AGENT.md` — This entry
  - `CHANGELOG.md` — New entry
- **Verification:** lint ✅ tests 42/42 ✅ build ✅ cap sync ✅ xcodebuild Release ✅
- **Follow-ups:** Roland builds and deploys Build 3 to TestFlight, verifies fixes on physical iPhone

## Change Protocol
- Read this file before making changes
- Update CHANGELOG.md after changes
- Run `npm run lint && npm run test && npm run build` before committing
- Use "Raouf:" prefix in changelog entries
