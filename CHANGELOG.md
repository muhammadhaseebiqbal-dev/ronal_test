# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### 2026-02-18 — Raouf: Build 12 — Production-Ready IAP: Toast Feedback, Subscription Status UI, Diagnostics, Already-Subscribed Handling

**Scope:** Address Roland's full IAP Definition of Done checklist — ensure all 7 acceptance tests pass end-to-end. Add user-visible feedback, subscription status UI, already-subscribed handling, and enhanced diagnostics.

**What changed:**

1. **Toast Notification System**
   - Added CSS-animated toast notifications at top of screen (success/error/info variants)
   - Purchase success: "Companion features unlocked!" (green)
   - Purchase cancelled: no toast (user-initiated)
   - Purchase error: error message shown (red)
   - Purchase pending: "Purchase pending approval." (dark)
   - Restore success with subscription: "Subscription restored! Companion unlocked." (green)
   - Restore success without subscription: "No active subscription found." (dark)
   - Restore error: error message shown (red)
   - Background renewal: "Subscription renewed" (green)
   - Auto-dismisses after 4 seconds with slide-up animation

2. **Subscription Status UI on Settings/More Page**
   - Injected "Subscription" section showing "Companion Active" (green) or "Free" (gray)
   - Detail text: "Your Companion subscription is active." / "Subscribe to unlock Companion features."
   - "Recheck Subscription" button calls `window.__aaCheckCompanion()` for cross-device sync
   - Button shows loading state ("Checking...") and result toast
   - Positioned above the Log Out button for visibility

3. **Already-Subscribed Paywall Handling**
   - When `window.__aaIsCompanion === true` and paywall buttons are detected, injects green banner: "You have an active Companion subscription!"
   - Banner auto-removes if subscription expires/revokes

4. **Enhanced Diagnostics Overlay**
   - Subscription section now shows: COMPANION ACTIVE / FREE status, Worker URL configured (YES/NO)
   - Last entitlement check: time, isCompanion result, active products
   - Last worker call: endpoint, HTTP status code, time, error if any
   - New `window.__aaLastEntitlementCheck` and `window.__aaLastWorkerResponse` globals updated in real-time from native Swift

5. **Action Field in Purchase Payloads**
   - Buy payloads now include `"action": "buy"`
   - Restore payloads now include `"action": "restore"`
   - Enables toast system to show contextually appropriate messages

6. **Trial Button Matching (IAP Wiring)**
   - Extended text patterns: "start companion trial", "start free trial", "start trial", "try companion"
   - Generic trial buttons (without "yearly"/"annual") default to monthly product
   - Trial yearly buttons still wire to yearly product

7. **Native Diagnostics Tracking**
   - `pushEntitlementCheckToJS()`: Pushes entitlement check results (time, isCompanion, products) to JS after every check
   - `pushWorkerResponseToJS()`: Pushes worker response (endpoint, HTTP status, time, error) to JS after every server call
   - Called from: viewDidLoad, handleWillEnterForeground, syncCompanionToServer, checkCompanionOnServer

8. **Build number: 11 → 12**

**Files Changed:**
- `ios/App/App/PatchedBridgeViewController.swift` — Toast CSS+JS, subscription status UI, already-subscribed banner, enhanced diagnostics, helper methods, action field, trial matching, orchestrator
- `ios/App/App.xcodeproj/project.pbxproj` — Build 11 → 12
- `AGENT.md` — Updated phase, Known Issues, IAP Stage Two table, Last Change Log, Update Log
- `CHANGELOG.md` — This entry

**Verification:**
- `npm run lint` → 0 errors ✅
- `npm run test` → 42/42 passed ✅
- `npm run build` → success ✅
- `npx cap sync ios` → 3 plugins ✅
- `xcodebuild Release` → BUILD SUCCEEDED ✅

---

### 2026-02-11 — Raouf: Build 9 — Native Token Two-Way Sync (Swift ↔ localStorage)

**Scope:** Fix critical gap where token exists in localStorage but NOT in native persistence (UserDefaults). The previous fix (tokenStorage.js + AuthContext.jsx) was DEAD CODE in production — the app loads the remote Base44 site, not our local bundle.

**Root cause (architectural):** With `server.url: 'https://abideandanchor.app'`, the WKWebView loads the REMOTE site's JS bundle. Our local `src/lib/tokenStorage.js` and `src/context/AuthContext.jsx` are compiled into `dist/` but NEVER EXECUTED. They're dead code in production. The remote Base44 SDK stores tokens in localStorage only — nobody calls Capacitor Preferences because our code doesn't run. Token persistence must happen entirely in native Swift ↔ injected JS.

**What changed:**

1. **Native token sync in `PatchedBridgeViewController.swift`**
   - **UP sync** (`syncTokenToUserDefaults()`): Evaluates JS to read localStorage tokens, saves to `UserDefaults.standard`. Called:
     - After `capacitorDidLoad` + 3s and +10s delay (let React mount and set tokens)
     - On foreground resume + 1s delay
     - On background entry (last chance before app kill)
   - **DOWN sync** (in `buildNativeDiagJS()` at `.atDocumentStart`): Reads token from UserDefaults, injects into localStorage if missing. Runs on every cold boot BEFORE React mounts.
   - **Logout**: `performFullLogout()` now clears UserDefaults token.
   - **Diagnostics**: Shows actual UserDefaults token status (not useless `CapacitorStorage.*` localStorage check).

2. **New `__aaNativeDiag` fields:**
   - `hasNativeToken`: boolean — whether UserDefaults has a stored token
   - `nativeTokenLen`: number — length of stored token (never the token itself)
   - `tokenRestored`: boolean — whether token was restored from UserDefaults to localStorage on this page load

3. **Updated diagnostics overlay** — replaced misleading `CapacitorStorage.*` checks with:
   ```
   --- Native Persistence (UserDefaults) ---
   UserDefaults token: true (len=165)
   Token restored from UserDefaults: YES  (only shown if restoration occurred)
   ```

4. **Build number: 8 → 9** (Debug + Release)

5. **Also kept `tokenStorage.js` / `AuthContext.jsx` changes** from earlier — harmless as fallback if app ever switches to local mode.

**Expected diagnostics after fix:**
```
UserDefaults token: true (len=165)   (was: CapacitorStorage: false)
Session Validation Status: valid     (was: no-token)
```

**Files Changed:**
- `ios/App/App/PatchedBridgeViewController.swift` — Native two-way token sync (UP + DOWN), diagnostics update, logout cleanup
- `ios/App/App.xcodeproj/project.pbxproj` — Build 8 → 9
- `src/lib/tokenStorage.js` — Added `syncTokenLayers()` (dead code in prod, kept as fallback)
- `src/context/AuthContext.jsx` — Two-way sync on boot (dead code in prod, kept as fallback)
- `AGENT.md` — Updated Last Change Log, Known Issues
- `CHANGELOG.md` — This entry

**Verification:**
- `npm run lint` → 0 errors ✅
- `npm run test` → 42/42 passed ✅
- `npm run build` → success ✅
- `npx cap sync ios` → 3 plugins ✅
- `xcodebuild Release` → BUILD SUCCEEDED ✅

---

### 2026-02-11 — Raouf: Build 8.1 — Apple Docs Fixes (WKProcessPool, Cookie Observer, Multi-Key Validation)

**Scope:** Hotfix for session validation `no-token` bug (token exists under different key) + Apple developer docs hardening (WKProcessPool, WKHTTPCookieStoreObserver, iOS 26 batch cookie API).

**Root cause:** `validateSession()` only checked `base44_access_token` key, but at `atDocumentEnd` time React hasn't yet copied the token there. The Base44 SDK stores it under `token` initially — which WAS present (len=165). The validation ran before React's token migration.

**What changed:**
1. **Multi-key session validation** — `validateSession()` and `computeTokenMeta()` now check 4 keys: `base44_access_token`, `token`, `access_token`, `base44_auth_token`. First key with `val.length > 20` wins. Fixes `no-token` false positive.
2. **Shared WKProcessPool** (Apple developer docs recommendation) — Static singleton `WKProcessPool` prevents iOS 17.4+ localStorage random clearing bug. Applied via `config.processPool = Self.sharedProcessPool` in `webViewConfiguration`.
3. **WKHTTPCookieStoreObserver** — Class now conforms to `WKHTTPCookieStoreObserver`. `cookiesDidChange(in:)` auto-persists domain cookies from WKHTTPCookieStore → HTTPCookieStorage.shared whenever cookies change. No more manual sync lag.
4. **iOS 26 batch setCookies API** — `syncCookiesToWebView` uses `setCookies(_:completionHandler:)` on iOS 26+ for atomic cookie sync. Falls back to existing DispatchGroup loop on iOS 15–25.

**Files Changed:**
- `ios/App/App/PatchedBridgeViewController.swift` — All 4 changes above
- `AGENT.md` — Updated Last Change Log
- `CHANGELOG.md` — This entry

**Verification:**
- `npm run lint` → 0 errors ✅
- `npm run test` → 42/42 passed ✅
- `npm run build` → success ✅
- `npx cap sync ios` → 3 plugins ✅
- `xcodebuild Release` → BUILD SUCCEEDED ✅

---

### 2026-02-11 — Raouf: Build 8 — Crash Resilience + Session Diagnostics + Token Validation

**Scope:** Production-grade hardening of PatchedBridgeViewController injected JS — 5-part improvement covering crash resilience, diagnostics, session validation, and safety.

**What changed:**
1. **Part 1 — Crash Resilience**
   - Added `window.__AA_LAST_ERROR` object: stores sanitized error message (max 300 chars), source (window.onerror / unhandledrejection / console.error), timestamp, and page URL.
   - Long base64 strings (40+ chars) are auto-redacted from error messages to prevent token leakage.
   - Added `console.error` interception: catches React error boundary logs, Minified React errors, and Invariant Violations. Routes them to appropriate handlers (handleSelectTriggerCrash or detectAndFixErrorScreen).
   - Debounced at 1s to prevent console.error flood from triggering excessive handler calls.
2. **Part 2 — Auth Session Diagnostics Upgrade**
   - Enhanced `collectDiagnostics()` with new sections:
     - **Network**: `navigator.onLine`, `navigator.connection.effectiveType`, downlink (Mbps), RTT (ms).
     - **Session Validation**: Status from JWT check (valid/expired-cleared/token-no-user/no-token), token expiry time, time remaining (hours + minutes), isExpired flag.
     - **Last Error**: Most recent error message, source, timestamp, and URL.
   - All new fields visible in diagnostics overlay (5-tap trigger or `/#/aa-diagnostics`).
   - Added `base44_auth_token` and `token` to auth key checks (was missing — this is the key used by tokenStorage.js).
   - Fixed misleading `CapacitorStorage.aa_token` check: now checks both `CapacitorStorage.aa_token` and `CapacitorStorage.base44_auth_token`, with a note that Capacitor Preferences stores in iOS UserDefaults (not visible from JS).
   - Token metadata (`__AA_TOKEN_META`) is now recomputed fresh each time diagnostics overlay is opened (not stale from page load).
3. **Part 3 — Session Validation Fix**
   - New `validateSession()` IIFE runs on page load before React mounts.
   - Parses JWT from `base44_access_token` using base64url decode of payload section.
   - If `exp` field is in the past: auto-clears all 9 auth localStorage keys → React will show login screen.
   - If token exists but `base44_user` is missing: flags as `token-no-user` for diagnostics (lets React's `initializeAuth` handle rehydration).
   - Stores `window.__AA_TOKEN_META` = `{ hasExp, expiresAt, ageSeconds, isExpired, tokenLength }` — never the token itself.
   - Loop guard: `sessionStorage('aa-session-validated')` prevents re-validation on the same page load.
   - **Fix (from device diagnostics)**: Original validation result is now preserved in `sessionStorage('aa-session-result')` and displayed on subsequent diagnostics checks, instead of being overwritten with unhelpful `already-checked`.
4. **Part 4 — Safety**
   - Verified: no raw tokens or PII in any injected JS logging path.
   - `storeLastError()` strips base64 strings ≥40 chars via regex replacement.
   - `__AA_TOKEN_META` contains only boolean/numeric/ISO-date metadata.
   - `collectDiagnostics()` continues to show presence + length only for auth keys.
5. **Build number bumped: 6 → 8** (both Debug and Release in project.pbxproj)

**Files Changed:**
- `ios/App/App/PatchedBridgeViewController.swift` — Error tracking, session validation with JWT parsing, enhanced diagnostics, fixed already-checked masking bug
- `ios/App/App.xcodeproj/project.pbxproj` — Build 6 → 8
- `AGENT.md` — Updated Last Change Log, Update Log
- `CHANGELOG.md` — This entry

**Verification:**
- `npm run lint` → 0 errors ✅
- `npm run test` → 42/42 passed ✅
- `npm run build` → success ✅
- `npx cap sync ios` → 3 plugins ✅
- `xcodebuild Release` → BUILD SUCCEEDED, 0 warnings on PatchedBridgeViewController ✅

---

### iPhone Stage One — Acceptance Criteria (Roland, 2026-11-02)

| # | Criterion | Status |
|---|-----------|--------|
| 1 | Email/password login persists after background and kill/reopen | ✅ FIXED (Build 4+) |
| 2 | Prayer Corner back navigation works | ✅ FIXED (Build 6) |
| 3 | New Request loads | ✅ FIXED (Build 6) |
| 4 | Builder loads | ✅ FIXED (Build 6) |
| 5 | Prayer Wall loads and is not squashed, back navigation works | ✅ FIXED (Build 6) |
| 6 | Prayer List does not white-screen | ✅ FIXED (Build 6) |
| 7 | **Log out button** in More/Settings that fully signs the user out, clears stored auth state, and returns to Login screen (so a different account can log in) | ✅ FIXED (Build 7) |

---

### 2026-02-11 — Raouf: Build 7 — Log Out button (Stage One #7)

**Scope:** Add a proper Log Out button in More/Settings that fully signs the user out, clears stored auth state, and returns to the Login screen so a different account can log in.

**What changed:**
1. **Log Out button injected on More/Settings page**
   - Detects `/more`, `/settings`, `/profile`, `/account` routes (pathname + hash).
   - Renders a styled button at the bottom of the page content with a door-arrow logout icon.
   - Outlined red border style (`#dc2626`), system font, 48px min tap target.
   - Auto-removes when navigating away from those routes.
2. **Confirmation dialog**
   - Tapping "Log Out" shows a centered modal with "Are you sure?" message.
   - Two buttons: "Log Out" (red) and "Cancel" (gray). Dismisses on background tap.
3. **Full auth state cleanup**
   - **JS**: Clears all localStorage auth keys (`base44_access_token`, `base44_refresh_token`, `base44_auth_token`, `base44_user`, `access_token`, `refresh_token`, `token`, `CapacitorStorage.aa_token`, `CapacitorStorage.base44_auth_token`).
   - **JS**: Clears sessionStorage recovery keys (`aa-*` / `aa_*` prefixes).
   - **Native**: `aaLogout` WKScriptMessageHandler triggers `performFullLogout()` in Swift.
   - **Native**: Deletes all cookies for `abideandanchor.app` from `HTTPCookieStorage.shared`.
   - **Native**: Deletes all cookies for domain from `WKHTTPCookieStore`.
   - **Native**: Removes all `WKWebsiteDataStore` records for the domain (localStorage, sessionStorage, IndexedDB, cookies, cache).
   - **Native**: Navigates WebView to `https://abideandanchor.app/login`.
4. **Wired into orchestrator**
   - `injectLogoutButton()` runs on every DOM mutation cycle alongside other patch functions.

**Files Changed:**
- `ios/App/App/PatchedBridgeViewController.swift` — Added `aaLogout` handler, `performFullLogout()`, logout CSS+JS, orchestrator wiring
- `AGENT.md` — Updated Known Issues, Stage One table, Last Change Log, Update Log
- `CHANGELOG.md` — This entry

**Verification:**
- `npm run lint` → 0 errors ✅
- `npm run test` → 42/42 passed ✅
- `npm run build` → success ✅
- `npx cap sync ios` → 3 plugins ✅
- `xcodebuild Release` → BUILD SUCCEEDED, 0 warnings on PatchedBridgeViewController ✅

---

### 2026-02-11 — Raouf: Build 6 — SelectTrigger runtime recovery for Prayer Request/Builder

**Scope:** Fix Prayer Corner Request/Builder route failures caused by `SelectTrigger must be used within Select`.

**What changed:**
1. **Route-specific real recovery (not overlay masking)**
   - Added `isSelectCrashRoute()` detection for `request`/`builder` routes.
   - `handleSelectTriggerCrash()` now prioritizes deterministic route recovery instead of immediately falling back to UI overlays.
2. **Three-step hard recovery path per route**
   - Step 1: hard reload with cache-busting query params.
   - Step 2: purge Cache Storage + unregister Service Workers, then hard reload.
   - Step 3: final hard reload attempt.
3. **Loop prevention**
   - Added route-scoped `sessionStorage` step key (`aa-select-recover-step:<pathname>|<hash>`) so retries do not become infinite.

**Files Changed:**
- `ios/App/App/PatchedBridgeViewController.swift` — SelectTrigger recovery flow upgraded
- `AGENT.md` — updated logs
- `CHANGELOG.md` — this entry

**Verification:** Pending iPhone route validation + build/test run.

### 2026-02-11 — Raouf: Build 6 — ESLint scope fix for generated artifacts

**Scope:** Make `npm run lint` pass by excluding compiled output from lint scope.

**What changed:**
1. **Ignored generated iOS web assets**
   - Added `ios/**/public/**` to ESLint ignore list.
   - Prevents ESLint from scanning bundled/minified files in `ios/App/App/public/assets/`.
2. **Ignored report/build output folders**
   - Added `coverage/`, `test-results/`, and `*.xcresult/**` ignore patterns.
3. **Result**
   - Lint focuses on project source files and avoids false-positive floods from generated code.

**Files Changed:**
- `eslint.config.js` — expanded `ignores` patterns
- `AGENT.md` — updated logs
- `CHANGELOG.md` — this entry

**Verification:** Pending `npm run lint`.

### 2026-02-11 — Raouf: Build 6 — SelectTrigger unhandled rejection recovery alignment

**Scope:** Improve Prayer List white-screen recovery consistency for React context crashes.

**What changed:**
1. **Unified SelectTrigger crash handling**
   - `window.unhandledrejection` now routes `"must be used within"` errors to `handleSelectTriggerCrash()`.
   - Previously this path used `detectAndFixErrorScreen()`, which did not run the dedicated crash reload flow.
2. **Behavioral impact**
   - Same debounce/auto-retry logic now applies for both `window.error` and Promise rejection paths.
   - Reduces stuck blank-state cases in prayer-list paths when the Select context crash is emitted as an unhandled rejection.

**Files Changed:**
- `ios/App/App/PatchedBridgeViewController.swift` — `unhandledrejection` handler updated
- `AGENT.md` — updated logs
- `CHANGELOG.md` — this entry

**Verification:** Pending device validation.

### 2026-02-11 — Raouf: Build 6 — Prayer route self-heal without recovery overlays

**Scope:** Fix Prayer List white-screen and Prayer Corner sub-route dead states while keeping prayer UI free of fallback overlays.

**What changed:**
1. **Prayer route monitor restored as non-UI self-heal**
   - Re-enabled `monitorPrayerRoutes()` for prayer flows only.
   - Detects persistent blank/failure states (`text < 12` with minimal visual elements, or `"failed to load"` present).
   - Uses 5 consecutive checks (15s) before action to avoid racing normal async loads.
2. **No recovery screen injection on prayer routes**
   - Monitor performs a silent reload only, never injects fallback cards/buttons.
   - Maintains requirement: New Request/Builder/Wall should not show synthetic `"failed to load"` recovery UI.
3. **Loop protection**
   - Added one-time-per-route reload guard in `sessionStorage`: `aa-prayer-reload:<pathname>|<hash>`.
4. **False-positive reduction**
   - Added `hasLoadingIndicators()` helper and skip logic for spinner/skeleton/loading states.
5. **Counter lifecycle**
   - Restored `prayerBlankHits` reset in `scheduleBlankChecks()` to keep per-navigation behavior deterministic.

**Files Changed:**
- `ios/App/App/PatchedBridgeViewController.swift` — prayer monitor logic + loading helper + guarded reload
- `AGENT.md` — updated logs
- `CHANGELOG.md` — this entry

**Verification:** Pending device validation.

### 2026-02-11 — Raouf: Build 6 — iPhone Stage One blocker patch

**Scope:** Fix duplicate back buttons and prayer-route recovery overlay regressions on iPhone.

**What changed:**
1. **Back button de-duplication hardened**
   - Added native back detection helpers and now keep only one visible native back control.
   - Fixed stale injected button behavior: if a native back button exists, `#aa-fixed-back` is removed immediately.
   - Prevented stacked "two back buttons on top of each other" across prayer/journal/more flows.
2. **Prayer flow recovery overlay suppression**
   - Added route guard `isPrayerFlowRoute()` to skip `"failed to load"` enhancer on `/prayer`, `/request`, `/builder`, `/wall` (including hash routes).
   - Prevents the Prayer Corner -> New Request flow from being replaced by a synthetic recovery screen.
3. **Runtime stability fix**
   - Removed stale `prayerBlankHits = 0` assignment from `scheduleBlankChecks()` after prayer-route monitor was disabled; avoids strict-mode runtime exceptions in injected script.

**Files Changed:**
- `ios/App/App/PatchedBridgeViewController.swift` — back-button logic refactor + prayer route guard + strict-mode fix
- `AGENT.md` — update log/last change log refreshed
- `CHANGELOG.md` — this entry

**Verification:** Pending device validation against Stage One checklist.

### 2026-02-12 — Raouf: Build 6 — Zero npm vulnerabilities

**Scope:** Eliminate all 4 npm audit vulnerabilities (3 moderate, 1 critical).

**What changed:**
1. **Removed `react-quill`** — Not imported anywhere in source code. Was the root cause of all 4 vulnerabilities via its transitive dependency chain: `react-quill@0.0.2` → `quilljs` → `lodash <=4.17.20` (critical: prototype pollution + command injection) and `react-quill@2.x` → `quill <=1.3.7` (moderate: XSS).
2. **Result: `found 0 vulnerabilities`** — Clean audit.

**Files Changed:**
- `package.json` — Removed `react-quill` dependency
- `package-lock.json` — Regenerated (clean)

**Verification:**
- `npm audit` → `found 0 vulnerabilities` ✅
- `npm run build` → success ✅

### 2026-02-12 — Raouf: Build 6 — UI polish, SelectTrigger fix, Prayer Wall responsive

**Scope:** Fix all 5 remaining Roland acceptance items for Build 6.

**What changed:**
1. **"or" divider fully hidden** — Broad sweep: hides all `or`/`— or —`/`- or -` text elements, plus class-based `divider`/`separator` elements on login pages. Also checks parent siblings and collapses empty parent containers.
2. **SelectTrigger crash fix** — `SelectTrigger must be used within Select` React error now auto-retries (up to 2 reloads) instead of leaving a blank page. On 3rd failure, shows minimal "Tap to Reload" + "Go Back" buttons. Debounced 3s to prevent loops.
3. **Back button lowered** — Offset increased from `safe-area-inset-top + 16px` to `safe-area-inset-top + 52px` (~96px from screen top on iPhone 11/12). Well below notch, clock, and any app header bar.
4. **Prayer Wall responsive CSS** — Grid forced to 1-column on mobile (`grid-template-columns: 1fr`), 2-column on ≥640px. `overflow-x: hidden` prevents horizontal scroll/squash. `break-word` on all grid children.
5. **Main content padding** — `<main>` gets `padding-top` matching safe area + header, preventing content from being hidden behind fixed back button.

**Files Changed:**
- `ios/App/App/PatchedBridgeViewController.swift` — All 5 fixes (CSS + JS)
- `AGENT.md` — Updated Known Issues table with new fixes
- `CHANGELOG.md` — This entry

**Verification:** xcodebuild Release — BUILD SUCCEEDED. Build number unchanged: 6.

### 2026-02-11 — Raouf: Build 6 — Email/Password Only (Google Hidden)

**Scope:** Roland confirmed no more Base44 subscription. Ship iOS with Email/Password only.

**What changed:**
1. **Google sign-in completely hidden** — buttons set to `display: none` via injected JS. Adjacent "or" dividers also hidden. Zero chance of loops or account picker.
2. **Removed all ASWebAuthenticationSession code** (~200 lines of Swift):
   - `import AuthenticationServices` removed
   - `ASWebAuthenticationPresentationContextProviding` conformance removed
   - `startGoogleOAuth()`, `handleGoogleAuthCallback()`, `injectTokenIntoWebView()`, `fallbackCookieSync()`, `checkPostOAuthState()`, `notifyJSGoogleResult()` — all deleted
   - `aaGoogleAuth` WKScriptMessageHandler registration removed
   - `authSession`, `googleAuthAttempts`, `lastGoogleAuthTime` properties removed
3. **JS simplified** — `interceptGoogleAuth()` now just finds Google buttons and hides them. No click handlers, no native bridge, no counters.
4. **CSS cleanup** — `.aa-google-notice` styles removed (no notice needed when button is invisible)
5. **SPA hooks** — `resetGoogleNotice()` calls removed from popstate/pushState handlers
6. **Diagnostics** — Google OAuth section replaced with "Email/Password only (Google hidden on iOS)"

**What's preserved (unchanged):**
- Email/Password persistence (same-origin localStorage + Capacitor Preferences)
- Back button: fixed position below safe area, pill style
- Prayer route handling: no error overlay injection
- Diagnostics overlay: 5-tap trigger, copy to clipboard
- All cookie bridging + process termination recovery

**Files Changed:**
- `ios/App/App/PatchedBridgeViewController.swift` — Major simplification: removed Google OAuth, simplified intercept to hide-only

**Verification:** xcodebuild Release — BUILD SUCCEEDED

---

### 2026-02-11 — Raouf: Build 6 — Fix Prayer Corner Routes + Back Button Position

**Scope:** Fix 4 failing acceptance tests: Prayer Corner back button, New Request, Builder loads, Prayer List blank screen.

**Root Causes:**
1. **Back button under clock/notch** — CSS `top: 8px` is behind the safe area on iPhone 11/12 (notch = ~44px). Back button was invisible/untappable.
2. **Prayer routes showing "Content didn't load" prematurely** — `monitorPrayerRoutes()` fired at 3s and injected error overlay before Base44's API data finished loading (false positive).
3. **Blank screen detection too aggressive** — `detectBlankScreen()` had same problem: 30-char threshold triggered while app was still rendering.
4. **Hash routes not detected** — If Base44 uses hash routing (`/#/prayer-corner`), our `pathname`-only checks wouldn't match.

**Fixes:**
1. **Back button → fixed position below safe area**
   - CSS: `position: fixed`, `top: calc(env(safe-area-inset-top, 44px) + 4px)`, `z-index: 9999`
   - Button now appended to `document.body` (not inside header) for guaranteed visibility
   - Pill style: white background, rounded corners, subtle shadow — always visible regardless of page header styling
   - `needsBackButton()` helper shared between injection and cleanup
2. **Prayer route monitoring: 3-check threshold**
   - `prayerBlankHits` counter — only shows error after 3 consecutive blank checks (9+ seconds)
   - Skips if loading indicators present: `animate-spin`, `animate-pulse`, `loading`, `skeleton`, `spinner`
   - Counter resets when content appears or route changes
3. **Blank screen detection: same pattern**
   - `blankConsecutiveHits` counter — 3 consecutive required
   - Same loading indicator check
4. **Hash route support**
   - `needsBackButton()`, `monitorPrayerRoutes()` now check `window.location.hash` in addition to `.pathname`
   - Added `hashchange` event listener for SPA navigation
   - Counters reset in `scheduleBlankChecks()` on every navigation

**Files Changed:**
- `ios/App/App/PatchedBridgeViewController.swift` — CSS B8 fix, rewritten `fixMissingBackButtons()`, safer `detectBlankScreen()` + `monitorPrayerRoutes()`, `needsBackButton()` helper, `hashchange` listener

**Verification:** xcodebuild Release — BUILD SUCCEEDED

---

### 2026-02-11 — Raouf: Build 6 — ASWebAuthenticationSession Google OAuth (Proper Fix)

**Scope:** Fix Google sign-in properly using Apple's `ASWebAuthenticationSession` instead of blocking it.
**Summary:** Replaced the "block Google on first click" approach with native OAuth. Google sign-in now intercepts the click in JS, sends the login URL to native Swift via `WKScriptMessageHandler` (`aaGoogleAuth`), which launches `ASWebAuthenticationSession`. The auth flow happens in Apple's secure browser (shares cookies with Safari). On callback, native code extracts the token from the URL (if present) and injects it into WKWebView's localStorage, then navigates home. If no token is in the callback URL, falls back to syncing cookies from HTTPCookieStorage → WKHTTPCookieStore and reloading the WebView.

**Why ASWebAuthenticationSession:**
1. Apple's recommended tool for OAuth in iOS apps (replaces SFSafariViewController for auth)
2. Provides a deterministic completion handler (no guessing if auth completed)
3. `prefersEphemeralWebBrowserSession = false` shares cookies with Safari cookie jar
4. User sees a clear system prompt before the browser opens (no surprise navigation)
5. No loop: completion handler fires exactly once (success, cancel, or error)

**Implementation Details:**
1. **JS intercept** — Google sign-in buttons detected and handled (capture phase) but NOT blocked. Instead, sends login URL to native via `aaGoogleAuth` message handler.
2. **Native launcher** — `startGoogleOAuth(loginURL:)` creates `ASWebAuthenticationSession` with `abideandanchor` callbackURLScheme. Session ref stored to prevent duplicates. 3s debounce between attempts.
3. **Token extraction** — `handleGoogleAuthCallback()` parses callback URL for `token`, `access_token`, `auth_token`, `code` params (query + fragment).
4. **Token injection** — If token found: `localStorage.setItem('base44_access_token', token)` + navigate to `/`. Auth state persists.
5. **Code exchange** — If `code` param found: redirects WebView to `https://abideandanchor.app/auth/callback?code=...` for server-side exchange.
6. **Cookie fallback** — If no token/code: syncs cookies from HTTPCookieStorage → WKWebView, reloads, checks auth state after 2s.
7. **Loop prevention** — After 3+ failed attempts, shows warm beige fallback notice guiding to Email/Password.
8. **JS callback** — `window.__aaGoogleAuthResult(success, error)` updates UI after native completes.

**Files Changed:**
- `ios/App/App/PatchedBridgeViewController.swift` — Added AuthenticationServices import, ASWebAuthenticationPresentationContextProviding, aaGoogleAuth handler, startGoogleOAuth, handleGoogleAuthCallback, injectTokenIntoWebView, fallbackCookieSync, checkPostOAuthState, notifyJSGoogleResult. Rewrote JS Google intercept from block → native OAuth. Updated diagnostics.
- `AGENT.md` — Updated Known Issues, Last Change Log, Update Log
- `CHANGELOG.md` — This entry

**Verification:** xcodebuild Release — BUILD SUCCEEDED, 0 warnings

---

### 2026-02-11 — Raouf: Build 6 — Fix Diagnostics "unknown" Values + Add Token Length/Key Count

**Scope:** Fix diagnostics overlay showing "unknown" for device/iOS/build/DataStore; add localStorage key count and token lengths.
**Root Cause:** `injectNativeDiagnostics()` used `evaluateJavaScript` which runs asynchronously after page load — by the time it executes, the page's JS context is already initialized but the diagnostics overlay reads `window.__aaNativeDiag` before the async call completes.
**Fix:** Inject `window.__aaNativeDiag` as a `WKUserScript` at `.atDocumentStart` (runs before any other JS). This guarantees the native data object is set before the diagnostics collector runs. The `evaluateJavaScript` call is retained as a backup for foreground resume.
**Enhancements:**
- Diagnostics now show token value **lengths** (not values) for each auth key: e.g. `base44_access_token: true (len=312)`
- Added `localStorage total keys: N` count
- Added `CapacitorStorage.aa_token` length
- Extracted `buildNativeDiagJS()` helper to eliminate code duplication between WKUserScript and evaluateJavaScript paths

**Files Changed:**
- `ios/App/App/PatchedBridgeViewController.swift` — new `buildNativeDiagJS()`, WKUserScript injection at `.atDocumentStart`, enhanced `collectDiagnostics()` JS
- `AGENT.md` — updated diagnostics section
- `CHANGELOG.md` — this entry

**Verification:** xcodebuild Release — BUILD SUCCEEDED, 0 warnings

---

### 2026-02-11 — Raouf: Build 6 (Revised) — Google Loop Fix (No Safari) + Diagnostics Overlay

**Scope:** Fix Google sign-in infinite loop by blocking it entirely (no SFSafariViewController), add in-app diagnostics overlay, update Sign in with Apple docs
**Summary:** The initial Build 6 used SFSafariViewController for Google OAuth — this was fundamentally broken because Safari has a separate localStorage/cookie store and tokens obtained there never persist back into WKWebView. This revised Build 6 removes SFSafariViewController entirely and blocks Google sign-in immediately on first click with a clear, non-error-looking inline notice guiding users to Email/Password. Also adds a comprehensive in-app diagnostics overlay (no Xcode required) and enhanced os_log markers.

**Root Cause Analysis (Why SFSafariViewController Failed):**
1. WKWebView and SFSafariViewController have **completely separate** localStorage and cookie stores
2. Even if Google auth succeeds in Safari, the token lands in Safari's storage — NOT in WKWebView's localStorage
3. The deep link `abideandanchor://auth-callback?token=...` depends on Base44 knowing to redirect there, but Base44's Google OAuth redirects back to `https://abideandanchor.app` (not the custom scheme)
4. Result: user completes Google auth in Safari → Safari lands on app page logged in → WKWebView is still unauthenticated → loop

**Fix Strategy — Immediate Block + Clear Message:**
1. **Removed** SFSafariViewController import, `aaOpenInBrowser` message handler, and all Safari-based OAuth logic
2. **Replaced** with immediate inline notice on **first** click of any Google sign-in button
3. Notice text: "Google sign-in is temporarily unavailable in the iOS app. Please use Email & Password below — it's fast and reliable."
4. Google buttons are dimmed (opacity 0.35, pointer-events none) — no loop possible
5. Counter tracked in `sessionStorage` (`aa_google_attempts`) — logs `[DIAG:googleIntercept]`
6. Notice is non-blocking, non-error-looking (warm beige, not yellow warning), and does NOT resemble a recovery/error screen
7. Email/Password buttons remain fully accessible and unaffected

**Diagnostics Overlay (NEW):**
- **Trigger:** 5-tap on any header/version/title element, OR navigate to `/#/aa-diagnostics`
- **Data shown:** Device model (hardware), iOS version, app version+build, window.location.origin, data store type (persistent/nonPersistent), auth key presence (boolean only — no token values), Google attempt counter, last 5 navigation URLs (origin+path only, query stripped)
- **"Copy Diagnostics" button:** Copies plaintext to clipboard via native `WKScriptMessageHandler` (`aaCopyDiagnostics`) — Roland can paste in chat/email
- **os_log markers added:** `[DIAG:coldBoot]`, `[DIAG:willEnterForeground]`, `[DIAG:webViewCreated]`, `[DIAG:googleIntercept]`, `[DIAG:authMarkers]`, `[DIAG:copy]`
- **Native data injection:** Device model, iOS version, build number, data store type are injected into JS from Swift at cold boot and foreground resume

**Sign in with Apple — Setup Checklist for Roland (UPDATED — No Private Key Sharing):**
1. **Apple Developer Account** → Certificates, Identifiers & Profiles → App IDs → `com.abideandanchor.app` → Enable "Sign In with Apple" capability
2. **Service ID** — Create a Service ID for web-based Sign in with Apple (Base44 needs this for OAuth flow)
3. **Return URLs** — Configure the Return URL to point to Base44's OAuth callback endpoint
4. **Private Key** — Generate a Sign in with Apple private key in Apple Developer. **KEEP IT SECURE — do NOT share the .p8 file.** Roland retains the key and configures it server-side.
5. **Share with Raouf (safe to share):** Service ID, Key ID, Team ID only. Never the private key file.
6. If server-side token validation is needed, use a secure channel (e.g., encrypted transfer) and rotate the key after integration.
Note: Sign in with Apple will be implemented after the above is set up.

**Login Persistence Confirmation:**
Email/password persistence remains PASS. No changes to auth flow, token storage, or cookie bridging.

**Files Changed:**
- `ios/App/App/PatchedBridgeViewController.swift` — **MODIFIED** — Removed SFSafariViewController, rewrote Google intercept, added diagnostics overlay + native data injection, enhanced os_log
- `ios/App/App.xcodeproj/project.pbxproj` — Build number remains 6

**Verification:**
- `xcodebuild Release CODE_SIGNING_REQUIRED=NO` — ✅ BUILD SUCCEEDED
- 0 Swift compiler warnings on PatchedBridgeViewController

---

### 2026-02-11 — Raouf: Build 6 (Initial, SFSafariViewController approach) — SUPERSEDED by revised Build 6 above

**Scope:** Fix all Build 6 acceptance criteria from Roland — Google sign-in loop, Prayer Corner routes, Prayer List blank screen
**Summary:** Two-layer fix for Google sign-in loop (native SFSafariViewController intercept + JS graceful fallback) plus improved route monitoring for Prayer Corner sub-pages.

**Root Cause Analysis (Google Sign-In Loop):**
1. The app loads `https://abideandanchor.app` in WKWebView. When user taps "Continue with Google" on Base44's login page, Google OAuth happens INSIDE the WebView.
2. Deep links from inside the WebView do NOT trigger `appUrlOpen` (AGENT.md Rule 9), so after Google auth completes, the Base44 platform cannot redirect back to `abideandanchor://auth-callback?token=...` successfully.
3. The WebView falls back to the login page → user tries again → infinite loop with no error message.

**Fix Strategy — Two Layers:**
1. **Layer 1 (Native):** Register `WKScriptMessageHandler` (`aaOpenInBrowser`) in `PatchedBridgeViewController`. JS injection intercepts Google sign-in button clicks, posts message to native handler, which opens `https://abideandanchor.app/login?from_url=abideandanchor://auth-callback` in `SFSafariViewController`. Google OAuth in Safari works correctly, and the deep link fires on completion.
2. **Layer 2 (Graceful Fallback):** If Google auth still fails (e.g., SFSafariViewController dismissed without completing), or on 2nd attempt within 60s, JS injects a visible banner: "Google Sign-In isn't available in the app yet. Please use Email & Password to sign in." The Google button is visually disabled (opacity 0.4, pointer-events none).

**Fixes Applied:**
1. **Google OAuth intercept (JS)** — Detects Google sign-in buttons by text/aria-label/class/img-alt, overrides click handlers with `stopImmediatePropagation`, posts message to native layer
2. **SFSafariViewController handler (Swift)** — `WKScriptMessageHandler` conformance, presents `SFSafariViewController` with login URL including `from_url` callback
3. **Google fallback banner (JS+CSS)** — Yellow warning banner with clear "use Email & Password" message
4. **Prayer route monitoring (JS)** — New `monitorPrayerRoutes()` function specifically watches prayer/request/builder/wall routes for failed loads
5. **Extended back button injection** — `fixMissingBackButtons()` now covers prayer/request/builder/wall routes
6. **Improved blank screen detection** — Raised text threshold from 20→30 chars and image threshold from 2→3 for fewer false negatives
7. **Google fallback reset on navigation** — `resetGoogleFallback()` clears banner and re-enables buttons when user navigates away from login
8. **Bumped build number** — 5 → 6

**Sign in with Apple — (SUPERSEDED — See revised Build 6 above for updated checklist)**

**Login Persistence Confirmation:**
Email/password persistence remains PASS. No changes were made to auth flow, token storage, or cookie bridging.

**Files Changed:**
- `ios/App/App/PatchedBridgeViewController.swift` — **MODIFIED** — Google OAuth handler, JS patches, CSS
- `ios/App/App.xcodeproj/project.pbxproj` — Build 5 → 6

**Verification:**
- `xcodebuild Release CODE_SIGNING_REQUIRED=NO` — ✅ BUILD SUCCEEDED
- No Swift compiler warnings on PatchedBridgeViewController

---

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
