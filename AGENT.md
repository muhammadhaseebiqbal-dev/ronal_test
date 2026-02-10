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
| SelectTrigger context error | ✅ FIXED — WKUserScript error boundary |
| Duplicate back buttons | ✅ FIXED — DOM patch removes duplicates |
| Missing back buttons | ✅ FIXED — DOM patch injects back nav |
| Bottom nav squashed (5 tabs) | ✅ FIXED — CSS flex/min-width patch |
| White screen on error | ✅ FIXED — Global error handler fallback |
| Bundle ID mismatch | ✅ FIXED — com.abideandanchor.app |
| Missing privacy manifest | ✅ FIXED — PrivacyInfo.xcprivacy |
| armv7 architecture | ✅ FIXED — arm64 only |
| No offline handling | ✅ FIXED — OfflineScreen component |
| Debug config in Release | ✅ FIXED — Separate release.xcconfig |

## Safari Web Inspector Diagnostics
```javascript
window.diagnoseBase44Config()    // Check App ID & config
window.diagnoseTokenStorage()    // Check token persistence
```

## Last Change Log

**2026-02-10 — Raouf: Milestone 7 — Build 3 TestFlight Bug Fixes**
- Created PatchedBridgeViewController.swift — WKUserScript injection for error boundary, DOM fixes, CSS patches
- Fixes: SelectTrigger context error, duplicate back buttons, missing back buttons, bottom nav squash, white screens
- Updated Main.storyboard to use PatchedBridgeViewController
- Bumped build number: 2 → 3
- Verification: lint ✅ (0 src/ errors) test ✅ (42/42) build ✅ xcodebuild Release ✅

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
