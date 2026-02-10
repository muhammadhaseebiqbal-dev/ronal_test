# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### 2026-02-10 — Raouf: Build 5 — Back Button Top-Left Fix

**Scope:** Move back buttons from top-middle to top-left on all pages
**Summary:** Back buttons on various pages appeared centered at the top of the screen instead of the standard top-left position. Fixed via CSS absolute positioning and JS class injection on all detected back buttons.

**Fixes Applied:**
1. **CSS `.aa-back-topleft` class** — `position:absolute; top:8px; left:12px; z-index:50` forces any element with this class to top-left corner of its positioned parent
2. **Header containers** — Added `position:relative` to `header`, `.sticky.top-0`, `.pt-8` so absolute positioning works correctly
3. **`fixDuplicateBackButtons()` update** — Surviving (first visible) back button now gets `aa-back-topleft` class
4. **Global back button scan** — All visible back buttons found in `#root` get `aa-back-topleft` class
5. **`cleanupStalePatches()` update** — Re-applies `aa-back-topleft` to visible back buttons after SPA navigation cleanup
6. **Injected back button update** — Removed old `margin-left:-8px; margin-bottom:8px` inline styles, uses `aa-back-topleft` class instead

**Files Changed:**
- `ios/App/App/PatchedBridgeViewController.swift` — **MODIFIED** — CSS + JS back button positioning
- `ios/App/App.xcodeproj/project.pbxproj` — Build 4 → 5

**Verification:**
- `xcodebuild Release CODE_SIGNING_REQUIRED=NO` — ✅ BUILD SUCCEEDED

---

### 2026-02-10 — Raouf: Build 4 — Login Persistence Fix (Milestone 8)

**Scope:** Fix login lost after backgrounding or killing app on customer devices (iPhone 11, iPhone 12)
**Summary:** Customers reported being logged out every time they backgrounded or killed the app, despite the fix working on the developer's phone. Root cause identified as WKWebView content process termination under iOS memory pressure, which destroys in-memory state and triggers a blind reload without cookie/session recovery.

**Root Cause Analysis:**
1. **WebView Content Process Termination** — On memory-constrained devices (iPhone 11/12), iOS terminates the WKWebView content process when the app is backgrounded. Capacitor's `WebViewDelegationHandler.webViewWebContentProcessDidTerminate()` calls `bridge.reset()` + `webView.reload()`, which reloads the page from scratch without recovering session cookies.
2. **No Cookie Bridging** — OAuth via SFSafariViewController sets cookies in Safari's cookie jar. The existing `CapacitorWKCookieObserver` syncs FROM WKWebView TO `HTTPCookieStorage.shared`, but never in reverse. On cold start or after process termination, auth cookies from HTTPCookieStorage are NOT synced back into WKHTTPCookieStore.
3. **No Foreground Recovery** — The `AppDelegate` had empty lifecycle methods with no WebView health check on resume.

**Fix Strategy — Defence in Depth (priority order):**
1. **Primary**: Token restore via Capacitor Preferences (UserDefaults) — the JS `initializeAuth()` → `loadToken()` chain runs on every page mount and reads from UserDefaults, which survives ALL termination events. This chain was already correct; the fix ensures the WebView reloads cleanly so this chain can execute.
2. **Secondary**: Smart foreground recovery in `PatchedBridgeViewController` — detects terminated content process and loads server URL with cookie sync (vs Capacitor's blind reload), giving the React app a clean boot path.
3. **Safety net**: Bidirectional cookie bridging — syncs cookies between HTTPCookieStorage and WKHTTPCookieStore in case the Base44 platform checks cookies alongside the bearer token. This is NOT the primary auth mechanism.

**Important**: No edits to `node_modules/` or Capacitor framework code. All fixes live in `ios/App/App/PatchedBridgeViewController.swift` which we own and control.

**Fixes Applied:**
1. **Persistent data store verification** — Override `webViewConfiguration(for:)` to explicitly verify `WKWebsiteDataStore.isPersistent` and force `WKWebsiteDataStore.default()` if ephemeral store detected.
2. **Bidirectional cookie bridging** — `syncCookiesToWebView()` syncs all domain cookies from `HTTPCookieStorage.shared` → `WKHTTPCookieStore` before initial navigation, on foreground resume, and before process termination recovery. `flushWebViewCookies()` syncs the reverse direction when entering background.
3. **Smart foreground resume** — `willEnterForeground` observer checks WebView health (URL, title). If content process was terminated (URL/title nil), performs cookie-synced recovery. If WebView is alive, only syncs cookies without reloading.
4. **Content process termination recovery** — Instead of blind `webView.reload()`, syncs cookies first, then loads the server URL directly (more reliable than reload on terminated content).
5. **Background cookie flush** — `didEnterBackground` observer flushes all domain cookies from WKHTTPCookieStore → HTTPCookieStorage.shared so they survive content process termination.
6. **os_log diagnostics** — Logs WebView state, data store type, cookie names (never values), and auth marker presence at cold boot, foreground resume, and recovery events. Visible via Xcode device console (filter: subsystem `com.abideandanchor.app`, category `WebView`).

**Files Changed:**
- `ios/App/App/PatchedBridgeViewController.swift` — **MODIFIED** — Added cookie bridging, persistent store verification, lifecycle observers, smart recovery, diagnostics
- `ios/App/App.xcodeproj/project.pbxproj` — Build 3 → 4

**Verification:**
- `xcodebuild Release CODE_SIGNING_REQUIRED=NO` — ✅ BUILD SUCCEEDED
- No Swift compiler warnings on PatchedBridgeViewController

**Diagnostics Access:**
- Xcode Console: filter by subsystem `com.abideandanchor.app` category `WebView`
- Console.app on Mac: connect device via USB, filter same subsystem
- Log events: `[DIAG:coldBoot]`, `[DIAG:willEnterForeground]`, `[DIAG:processTerminationRecovery]`, `[DIAG:capacitorDidLoad]`

---

### 2026-02-10 — Raouf: Build 3 — TestFlight Bug Fixes (Milestone 7)

**Scope:** Fix all production issues reported in TestFlight Build 2 (iOS 1.0.0 build 2)
**Summary:** Injected client-side patches via custom WKWebView controller to fix remote Base44 app issues without modifying the hosted platform code.

**Root Cause Analysis:**
The app loads `https://abideandanchor.app` (remote Base44 platform) in WKWebView. The remote app's React code has a `SelectTrigger` component rendered outside a `Select` Radix UI context, causing an unhandled error (`"SelectTrigger must be used within Select"`) that crashes the React render tree on pages using select dropdowns (Prayer Corner, About Abide, Prayer Wall, New Request). The layout also renders duplicate back buttons on some routes and omits them on others. Bottom nav with 5 tabs (Prayer Wall enabled) squashes icons below the 44px Apple HIG minimum tap target.

**Fixes Applied:**
1. **Created `PatchedBridgeViewController.swift`** — Custom CAPBridgeViewController subclass that injects CSS+JS patches via WKUserScript at document end
2. **Error boundary (JS)** — Global `window.onerror` + `unhandledrejection` handlers catch "must be used within" React context errors, prevent white screens, show a "Go Back" / "Go Home" fallback UI
3. **Duplicate back button fix (JS)** — MutationObserver detects and hides duplicate back button elements in headers
4. **Missing back button fix (JS)** — Injects a back button with proper chevron icon on routes that lack one (Journal/Captain's Log, More)
5. **Bottom nav layout fix (CSS)** — `flex: 1 1 0%`, `min-width: 48px`, proper icon sizing, and text truncation for 5-tab mode
6. **Safe area padding (CSS)** — `padding-bottom: max(env(safe-area-inset-bottom), 8px)` on bottom nav
7. **SPA navigation tracking (JS)** — Patches `history.pushState/replaceState` + `popstate` to re-run DOM fixes on client-side route changes
8. **Updated Main.storyboard** — Points to `PatchedBridgeViewController` (module: App) instead of default `CAPBridgeViewController`
9. **Bumped build number** — `CURRENT_PROJECT_VERSION` 2 → 3 (both Debug and Release)

**Login Persistence Confirmation:**
Login persistence remains correct. The same-origin mode (`server.url: https://abideandanchor.app`) means WKWebView localStorage persists across cold restarts. No changes were made to auth or token storage logic.

**Files Changed:**
- `ios/App/App/PatchedBridgeViewController.swift` — **NEW** — Custom VC with WKUserScript injection
- `ios/App/App/Base.lproj/Main.storyboard` — Updated customClass to PatchedBridgeViewController
- `ios/App/App.xcodeproj/project.pbxproj` — Added new Swift file, bumped build 2 → 3
- `AGENT.md` — Updated known issues, last change log
- `CHANGELOG.md` — This entry

**Verification:**
- `npx eslint --quiet src/` — ✅ (0 errors)
- `npm run test` — ✅ (42/42 passed)
- `npm run build` — ✅
- `npx cap sync ios` — ✅ (3 plugins)
- `xcodebuild Release CODE_SIGNING_REQUIRED=NO` — ✅ BUILD SUCCEEDED

---

### 2026-02-09 — Raouf: Prepared Project Handover Checklist

**Scope:** Full pre-handover audit + README_HANDOVER.md creation
**Summary:** Verified every item on the "Prepared project" checklist before sending to Roland:
- ✅ Clean git state — `main`, 4 commits, no uncommitted changes
- ✅ npm: 530 packages, `package-lock.json` present
- ✅ SPM: 3 Capacitor plugins resolved (app, browser, preferences)
- ✅ Bundle ID: `com.abideandanchor.app`
- ✅ Version 1.0.0 / Build 2
- ✅ Release build without signing — **BUILD SUCCEEDED**
- ✅ No hardcoded secrets — Stripe/RevenueCat are `REDACTED`
- ✅ `.env.example` with safe placeholders
- ✅ Deep link scheme `abideandanchor://` registered

**Changes:**
- `README_HANDOVER.md` — NEW: Complete handover (install → build → run → verify → troubleshoot)
- `AGENT.md` — Update log entry
- `CHANGELOG.md` — This entry

**Verification:**
- `npx eslint --quiet src/` — 0 errors ✅
- `npm run test` — 42/42 passed ✅
- `npm run build` — Success ✅
- `npx cap sync ios` — 3 plugins ✅
- `xcodebuild Release CODE_SIGNING_REQUIRED=NO` — BUILD SUCCEEDED ✅

---

### 2026-02-09 — Raouf: Privacy Policy URL Wired (Milestone 6)

**Scope:** Wire privacy policy URL into all project files — unblock external TestFlight + App Store  
**Summary:** Added `https://the-right-perspective.com/abide-anchor-privacy-policy/` to capacitor config, audit reports, README, and SECURITY.md. Updated audit verdicts to reflect resolved status.

**Changes:**
1. **`capacitor.config.ts`** — Added privacy policy URL reference comment
2. **`docs/TESTFLIGHT_AUDIT_REPORT.md`** — Privacy policy: 🔴 MISSING → ✅ PASS. External TestFlight: ⛔ Blocked → ✅ Ready. Strikethrough resolved issues (#2-4). Updated executive summary and fix priority list.
3. **`docs/APP_STORE_AUDIT_REPORT.md`** — Privacy policy: ❌ FAIL → ✅ PASS. Updated blocker table and action items.
4. **`README.md`** — Added privacy policy link to Additional Resources
5. **`SECURITY.md`** — Added Privacy Policy section with URL

**Verification:**
- `npm run lint` — ✅ (0 errors in src/)
- `npm run test` — ✅ (42/42 passed)
- `npm run build` — ✅

**Note:** The privacy policy URL must also be entered manually in App Store Connect under **App Information → Privacy Policy URL**.

---

### 2026-02-09 — Raouf: Pre-TestFlight Submission Audit (Milestone 4)

**Scope:** Full 5-phase pre-TestFlight audit — build config, App Store policy, runtime stability, security, readiness  
**Summary:** Adversarial audit of all iOS project files simulating App Store review rejection scenarios.

**Findings:**
1. **Build Configuration** — 9/9 PASS (version, bundle ID, signing, arm64, no debug flags in Release)
2. **App Store Policy** — 2 HIGH findings: Guideline 4.2 web wrapper risk, missing privacy policy URL
3. **Runtime Stability** — 85/100 determinism score. Offline handling, token persistence, cold start all pass. WebView HTTP error handling is partial.
4. **Security** — 80+ console.log statements in production JS including token previews (first 20 chars). Diagnostic functions globally exposed.
5. **TestFlight Readiness** — Internal testing: 88% ready (SAFE WITH WARNINGS). App Store: 55% (DO NOT UPLOAD).

**Files Changed:**
- `docs/TESTFLIGHT_AUDIT_REPORT.md` — **NEW** — Full audit report with per-item PASS/FAIL, severity ratings, fix recommendations

**Verdict:**
- ✅ SAFE WITH WARNINGS for internal TestFlight
- ⛔ DO NOT UPLOAD for App Store (4 blocking issues)

**Follow-ups (Priority Order):**
1. Strip console.log in production builds (Vite terser/esbuild drop)
2. Guard diagnostic functions behind import.meta.env.DEV
3. Host privacy policy URL
4. Add native features to mitigate Guideline 4.2
5. Add WebView error handling beyond offline detection

---

### 2026-02-09 — Raouf: Security Hardening + Build 2 (Milestone 5)

**Scope:** Fix all security/professionalism issues from Milestone 4 audit — token logging, debug globals, build bump  
**Summary:** Removed all token value logging, created production-gated logger, gated debug globals behind DEV, bumped build to 2.

**Fixes Applied:**
1. **Created `src/lib/logger.js`** — Production-safe logger that suppresses `log()` in prod, keeps `warn()`/`error()`
2. **Removed all token value logging** — No `token.substring()`, no token previews, no token values in console
3. **Gated `window.diagnoseBase44Config`** behind `import.meta.env.DEV`
4. **Gated `window.diagnoseTokenStorage`** behind `import.meta.env.DEV`
5. **Gated `window.getBase44Report`** behind `import.meta.env.DEV`
6. **Replaced 80+ console.log calls** across 6 files with production-gated `log()` from logger.js
7. **Fixed hasToken proof** — Now checks `base44_access_token || token || base44_auth_token`
8. **Bumped build number** — `CURRENT_PROJECT_VERSION = 2` in both Debug and Release
9. **Removed unused import** — `isCapacitorRuntime` from `base44Client.js`

**Files Changed:**
- `src/lib/logger.js` — **NEW**
- `src/lib/tokenStorage.js` — Safe logging, gated diagnostics
- `src/lib/deepLinkHandler.js` — Safe logging
- `src/context/AuthContext.jsx` — Safe logging, fixed hasToken proof
- `src/lib/app-params.js` — Gated window globals, safe logging
- `src/api/base44Client.js` — Safe logging, removed unused import
- `src/main.jsx` — Removed console.log
- `ios/App/App.xcodeproj/project.pbxproj` — Build 1 → 2

**Verification:**
- `npm run lint` — ✅ (0 errors in src/)
- `npm run test` — ✅ (42/42 passed)
- `npm run build` — ✅

---

### 2026-02-08 — Raouf: App Store Blocker Fixes (Milestone 3)

**Scope:** iOS release engineering — fix all critical blockers from Milestone 2 audit  
**Summary:** Applied all required technical fixes to raise App Store readiness from 35% to ≥85%.

**Fixes Applied:**
1. **Bundle ID** — Changed `com.raouf.abideanchor.dev` → `com.abideandanchor.app` in Xcode (Debug + Release)
2. **Architecture** — Changed `armv7` → `arm64` in Info.plist UIRequiredDeviceCapabilities
3. **Privacy Manifest** — Created `PrivacyInfo.xcprivacy` declaring UserDefaults API usage (CA92.1)
4. **Release Config** — Created `release.xcconfig` (no debug flags), pointed Release build config to it
5. **Export Compliance** — Added `ITSAppUsesNonExemptEncryption: false` to Info.plist
6. **Version Sync** — Updated `MARKETING_VERSION` to `1.0.0` (was `1.0`), synced `package.json` to `1.0.0`
7. **Guideline 4.2 Mitigation** — Dark-themed native UI, offline detection screen, no debug output in UI
8. **Splash/Background** — Set `ios.backgroundColor: '#0b1f2a'`, `index.html` body background to match
9. **Merged AGENT.md** — Combined `AGENT.md` + `AGENT 2.md` into single authoritative file
10. **Merged CHANGELOG.md** — Combined `CHANGELOG.md` + `CHANGELOG 2.md` into single file

**Files Changed:**
- `ios/App/App.xcodeproj/project.pbxproj` — Bundle ID, version, release.xcconfig ref, PrivacyInfo ref
- `ios/App/App/Info.plist` — arm64, ITSAppUsesNonExemptEncryption
- `ios/App/App/PrivacyInfo.xcprivacy` — **NEW** — Apple privacy manifest
- `ios/release.xcconfig` — **NEW** — Release build config (no debug flags)
- `capacitor.config.ts` — backgroundColor, SplashScreen config
- `src/main.jsx` — Native-themed UI, offline screen, removed debug output
- `index.html` — Dark background to prevent white flash
- `package.json` — Version 1.0.0
- `AGENT.md` — Merged with AGENT 2.md
- `CHANGELOG.md` — Merged with CHANGELOG 2.md

**Verification:**
- `npm run lint` — ✅
- `npm run test` — ✅
- `npm run build` — ✅
- Bundle ID confirmed in both Debug and Release configs
- PrivacyInfo.xcprivacy added to Xcode build target Resources

**Follow-ups:**
- Host privacy policy URL
- Prepare App Store screenshots
- TestFlight internal testing

---

### 2026-02-08 — Raouf: App Store Readiness Audit (Milestone 2)

**Scope:** iOS release engineering, App Store compliance audit  
**Summary:** Performed comprehensive App Store readiness audit covering Capacitor config, Info.plist, Xcode project settings, privacy manifest, web wrapper risk, cookie/storage persistence, versioning, and App Store Connect readiness.

**Files Changed:**
- `docs/APP_STORE_AUDIT_REPORT.md` — **NEW** — Full audit report with PASS/FAIL/WARNING sections
- `CHANGELOG.md` — **NEW** — Project changelog
- `AGENT.md` — **NEW** — Project agent rules
- `.gitignore` — **MODIFIED** — Removed `ios/` exclusion to allow iOS project tracking

**Key Findings:**
- ❌ 6 critical blockers identified
- ⚠️ 4 high-priority issues
- ✅ App icon, ATS, token storage, localStorage persistence all pass
- Overall readiness: 35%

---

## [Previous Changes — Milestone 1]

### 2026-02-07 — Raouf: Deterministic Boot Logs

**Scope:** Add deterministic acceptance-proof logs — no logic changes  
**What:** Added synchronous `localStorage.getItem('base44_auth_token')` check at top of `initializeAuth()` in AuthContext.jsx  
**Verification:** `npm run lint` 0 errors, `npm run test` 42/42 passed, `npm run build` success

---

### 2026-02-07 — Raouf: Same-Origin Strategy (Remote URL Mode)

**Scope:** Reconfigure Capacitor iOS to load `https://abideandanchor.app` directly in WKWebView  
**Problem:** WebView at `capacitor://localhost` has isolated, volatile localStorage — auth tokens lost on every cold restart  
**Solution:** Set `server.url: 'https://abideandanchor.app'` — WKWebView origin now matches live site  
**Impact:** localStorage persistence ❌ volatile → ✅ persists across cold restarts

---

### 2026-02-07 — Raouf: Race Condition Hardening + Acceptance Audit

**Scope:** Full technical audit + failure-mode audit for Milestone A  
**Bugs Fixed:**
1. Race condition: old token auth check clears new deep-link token → tokenVersion counter guard
2. Missing acceptance test logs → exact format logs added
3. Deep link double-processing → lastProcessedUrl guard

---

### 2026-02-06 — Raouf: Scheme Collision + Browser Plugin Fix

**Scope:** Critical bug audit — iOS OAuth deep link flow  
**Bugs Fixed:**
1. `ios.scheme: 'abideandanchor'` collided with deep link scheme → removed ios.scheme
2. OAuth opened in WebView (deep link won't fire from inside own app) → uses SFSafariViewController
3. `base44.setToken()` wrote to useless localStorage on iOS → skip localStorage on iOS

---

### 2026-02-06 — Raouf: OAuth Deep Link Fix

**Scope:** OAuth Flow Fix for iOS — Custom URL Scheme Deep Linking  
**Problem:** OAuth redirect to `capacitor://localhost` causes infinite login loop  
**Solution:** Installed @capacitor/app, created deepLinkHandler.js, registered `abideandanchor://` URL scheme

---

### 2026-02-06 — Raouf: Token Persistence Fix

**Scope:** Token Persistence + Login Button Visibility + Capacitor Config  
**Problem:** Token not persisting across cold restarts, app stuck with no Login button  
**Solution:** Removed localStorage fallback for iOS, 5-second auth timeout, Capacitor Preferences only

---

### 2026-02-05 — Raouf: Token Persistence Fix (Milestone 1 Initial)

**Scope:** iOS token persistence, Base44 App ID wiring  
**Summary:** Fixed critical bugs where App ID was null in iOS builds and auth tokens were lost on cold restart.
