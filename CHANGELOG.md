# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

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

**Verification:**
- Manual audit of all iOS project files
- Live site verification (https://abideandanchor.app responds correctly)
- App icon validated (1024x1024, RGB, no alpha)
- Bundle identifier mismatch confirmed between Capacitor and Xcode

**Follow-ups:**
- Fix bundle identifier in Xcode
- Create PrivacyInfo.xcprivacy
- Add native features to mitigate Guideline 4.2 risk
- Host privacy policy

---

## [Previous Changes]

### 2026-02-05 — Raouf: Token Persistence Fix (Milestone 1)

**Scope:** iOS token persistence, Base44 App ID wiring  
**Summary:** Fixed critical bugs where App ID was null in iOS builds and auth tokens were lost on cold restart.

**Files Changed:**
- `src/lib/app-params.js` — Config resolver with iOS fallback
- `src/lib/tokenStorage.js` — Native token storage via Capacitor Preferences
- `src/lib/runtime.js` — Runtime environment detection
- `src/lib/deepLinkHandler.js` — Deep link OAuth callback handler
- `src/api/base44Client.js` — Base44 SDK client
- `src/context/AuthContext.jsx` — Auth provider with token persistence
- `src/main.jsx` — App entry point
- `.env.production` — Production config with App ID
- `capacitor.config.ts` — Capacitor configuration
- `scripts/verify-ios-build.js` — Build verification script
- `tests/*.test.js` — 37 unit tests
