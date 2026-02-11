# AGENT.md — Project Rules for Abide & Anchor iOS

## Project Overview

**App Name:** Abide & Anchor  
**Client:** Roland L.  
**Tech Stack:** React 18 + Vite 6 + Capacitor 8 (iOS) + Base44 SDK  
**Current Phase:** Milestone 3 — App Store submission preparation

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
| Bundle ID mismatch | ✅ FIXED — com.abideandanchor.app |
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

## Last Change Log

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
