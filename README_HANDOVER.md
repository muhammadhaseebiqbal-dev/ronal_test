# 📦 README_HANDOVER.md — Prepared Project for Roland

**Date:** 2026-02-09 (Australia/Sydney)
**From:** Raouf
**To:** Roland L.

---

## ✅ Pre-Flight Checklist (All Verified)

| Item | Status | Details |
|------|--------|---------|
| Clean repo state | ✅ | `main` branch, 4 commits, no uncommitted changes |
| Dependencies (npm) | ✅ | `node_modules/` present, 530 packages, `package-lock.json` included |
| Dependencies (SPM) | ✅ | `Package.swift` resolved — `@capacitor/app`, `@capacitor/browser`, `@capacitor/preferences` |
| No CocoaPods | ✅ | Project uses Swift Package Manager (SPM), not CocoaPods |
| Bundle ID | ✅ | `com.abideandanchor.app` — set in `capacitor.config.ts` + Xcode project |
| Version | ✅ | `1.0.0` (MARKETING_VERSION) |
| Build Number | ✅ | `2` (CURRENT_PROJECT_VERSION) |
| Release build | ✅ | Compiles in Release configuration (without signing) |
| No secrets in code | ✅ | Stripe/RevenueCat keys are `REDACTED` placeholders |
| `.env.example` | ✅ | Provided with safe placeholder values |
| URL scheme | ✅ | `abideandanchor://` registered in `Info.plist` |

---

## 🚀 Exact Steps to Build & Run

### Step 1: Install npm dependencies (if `node_modules/` is missing)

```bash
cd Raouf_Fix_2
npm install
```

### Step 2: Build the web bundle

```bash
npm run build
```

> This creates the `dist/` folder. Required by `cap sync` even though the app loads the remote site at runtime.

### Step 3: Sync to iOS

```bash
npx cap sync ios
```

> Expected output: `Found 3 Capacitor plugins for ios: @capacitor/app, @capacitor/browser, @capacitor/preferences`

### Step 4: Open in Xcode

```bash
open ios/App/App.xcodeproj
```

> **NOT** `.xcworkspace` — this project uses SPM, not CocoaPods.

### Step 5: Configure Signing in Xcode

1. Select the **App** target
2. Go to **Signing & Capabilities**
3. Select your **Team** (Apple Developer account)
4. Xcode should auto-resolve provisioning profiles
5. The Bundle ID is already set: `com.abideandanchor.app`

### Step 6: Build & Run

1. Select your physical iPhone as the destination
2. Press **⌘R** (or ▶️ Build & Run)
3. Wait for the app to install and launch

---

## 🧪 On-Device Verification

### First Launch
1. App opens → loads `https://abideandanchor.app` in WKWebView
2. Login button appears within 5 seconds
3. Tap **Login** → opens Safari (SFSafariViewController) for OAuth

### After Login
1. Complete OAuth in the Safari sheet
2. App receives token via deep link (`abideandanchor://auth-callback?token=...`)
3. Safari sheet closes automatically
4. App shows authenticated UI

### Token Persistence Test
1. **Kill the app** (swipe up from app switcher)
2. **Reopen** — should go straight to authenticated state (no login)
3. Repeat 3–5 times to confirm persistence

### Safari Web Inspector (Debug)
1. Connect iPhone via USB
2. Safari → Develop → [Your iPhone] → `abideandanchor.app`
3. Console commands:
   ```javascript
   window.diagnoseBase44Config()   // Check App ID + config
   window.diagnoseTokenStorage()   // Check token persistence
   ```

---

## 📂 Key Files

| File | Purpose |
|------|---------|
| `capacitor.config.ts` | Capacitor config — Bundle ID, server URL, iOS settings |
| `.env.production` | Build-time env vars — Base44 App ID, server URLs |
| `.env.example` | Safe template with placeholder values |
| `ios/App/App/Info.plist` | iOS config — URL scheme (`abideandanchor://`) |
| `ios/App/App.xcodeproj/project.pbxproj` | Xcode project — signing, version, build number |
| `src/lib/deepLinkHandler.js` | OAuth deep link handler |
| `src/context/AuthContext.jsx` | Auth provider with token management |
| `src/lib/tokenStorage.js` | Token persistence (Capacitor Preferences API) |

---

## ⚠️ Important Notes

1. **WKWebView ≠ Safari**: The app's WKWebView has its own storage, completely separate from Safari. Auth must happen inside the app.

2. **Network required**: The app loads `https://abideandanchor.app` at runtime — no offline mode.

3. **OAuth redirect**: The Base44 backend must redirect to `abideandanchor://auth-callback?token=...` after login. If Base44 ignores the `from_url` parameter, the deep link won't fire.

4. **Version/Build bumping**: Before each TestFlight upload, increment `CURRENT_PROJECT_VERSION` (Build Number) in Xcode → Target → General.

5. **Stripe/RevenueCat**: Keys are `REDACTED` in `.env.production`. Replace with real keys when ready to enable payments.

---

## 🛠️ Troubleshooting

| Problem | Solution |
|---------|----------|
| App shows blank white screen | Check network — app needs internet to load remote site |
| Login button doesn't appear | Wait 5 seconds; check Safari console for JS errors |
| OAuth doesn't return to app | Verify Base44 redirects to `abideandanchor://auth-callback` |
| Token lost after restart | Kill + reopen (not just background); check `window.diagnoseTokenStorage()` |
| Xcode build fails | Run `npx cap sync ios` again; check SPM packages resolve |
| SPM packages won't resolve | File → Packages → Reset Package Caches in Xcode |

---

## 📧 Quick Reference (for email)

```
1. cd Raouf_Fix_2
2. npm install          (if node_modules missing)
3. npm run build
4. npx cap sync ios
5. open ios/App/App.xcodeproj
6. Set signing team in Xcode
7. Build & Run to iPhone (⌘R)
```

That's it. The project is ready to build.
