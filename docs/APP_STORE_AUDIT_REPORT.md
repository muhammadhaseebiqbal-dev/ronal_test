# 🍎 App Store Readiness Audit Report

**App:** Abide & Anchor  
**Bundle ID (Capacitor):** `com.abideandanchor.app`  
**Bundle ID (Xcode):** `com.raouf.abideanchor.dev`  
**Date:** 2026-02-08  
**Auditor:** Raouf (Senior iOS Release Engineer)  
**Capacitor Version:** 8.0.2  
**Deployment Target:** iOS 15.0  
**Server URL:** https://abideandanchor.app  

---

## 📊 Overall Readiness: 35% — NOT READY FOR SUBMISSION

| Category | Status | Risk |
|----------|--------|------|
| Capacitor Config | ⚠️ WARNING | Medium |
| Bundle Identifier | ❌ FAIL | **Critical** |
| Info.plist | ❌ FAIL | **Critical** |
| Privacy Manifest | ❌ FAIL | **Critical** |
| App Icon | ✅ PASS | Low |
| ATS Compliance | ✅ PASS | Low |
| Web Wrapper Risk | ❌ FAIL | **Critical** |
| Cookie/Storage | ✅ PASS | Low |
| Signing & Provisioning | ⚠️ WARNING | High |
| Versioning | ⚠️ WARNING | Medium |
| App Store Connect | ❌ FAIL | **Critical** |
| Git/CI Readiness | ❌ FAIL | High |

---

## 1. Capacitor Health Check

### ✅ PASS — `capacitor.config.ts` Core Configuration

| Check | Result |
|-------|--------|
| `server.url` set to `https://abideandanchor.app` | ✅ Correct |
| `server.cleartext` set to `false` | ✅ Correct |
| No `ios.scheme` override | ✅ Correct (comment explains why) |
| No `ios.hostname` override | ✅ Correct |
| `webDir` set to `dist` | ✅ Correct |
| `appId` set to `com.abideandanchor.app` | ✅ Correct |
| Plugins: Preferences | ✅ Registered |

### ⚠️ WARNING — `capacitor://localhost` References

Found in **comments only** (not in code logic):
- `capacitor.config.ts` line 9: comment explaining migration from `capacitor://localhost`
- `tests/capacitor-env.test.js`: test cases referencing old `capacitor://localhost` URLs

**Verdict:** These are non-functional references in comments/tests. Not a blocker.

### ⚠️ WARNING — `ios/App/App/capacitor.config.json` Sync

The compiled `capacitor.config.json` in the iOS project correctly mirrors `capacitor.config.ts`:
```json
{
  "server": { "url": "https://abideandanchor.app", "cleartext": false },
  "plugins": { "Preferences": {} },
  "packageClassList": ["AppPlugin", "CAPBrowserPlugin", "PreferencesPlugin"]
}
```
**Verdict:** Synced correctly. `packageClassList` matches installed plugins.

---

## 2. iOS Build & Validation Audit

### ❌ FAIL — Bundle Identifier Mismatch (CRITICAL BLOCKER)

| Source | Bundle ID |
|--------|-----------|
| `capacitor.config.ts` | `com.abideandanchor.app` |
| Xcode Debug config | `com.raouf.abideanchor.dev` |
| Xcode Release config | `com.raouf.abideanchor.dev` |

**Impact:**
- ❌ App Store Connect registration will fail or mismatch
- ❌ Provisioning profile won't match
- ❌ Push notifications won't work
- ❌ Deep link associated domains won't validate

**Required Fix:** Change Xcode `PRODUCT_BUNDLE_IDENTIFIER` to `com.abideandanchor.app` in both Debug and Release configurations. Then regenerate provisioning profiles in Apple Developer Portal.

### ⚠️ WARNING — Development Team

- Team ID: `3L5A4R7JNY`
- Code Sign Style: Automatic
- **Verify:** This team must have an active Apple Developer Program membership ($99/year) for App Store distribution.

### ⚠️ WARNING — No Release xcconfig

- Only `debug.xcconfig` exists with `CAPACITOR_DEBUG = true`
- Both Debug AND Release build configurations reference `debug.xcconfig`
- **Impact:** Release builds will have `CAPACITOR_DEBUG = true`, enabling verbose logging and debug features in production.

**Required Fix:** Create `release.xcconfig` without debug flags and point the Release build configuration to it.

### ⚠️ WARNING — Missing Entitlements File

No `.entitlements` file found in the iOS project. If the app uses:
- Associated Domains (universal links)
- Push Notifications
- App Groups
- Keychain Sharing

...these MUST be declared in an entitlements file.

**Current Risk:** Medium. The app uses a custom URL scheme (`abideandanchor://`) which does NOT require entitlements, but if Roland wants universal links later, this will be needed.

---

## 3. Info.plist Audit

### ✅ PASS — No NSAllowsArbitraryLoads

The Info.plist does NOT contain `NSAppTransportSecurity` or `NSAllowsArbitraryLoads`. Since the app only loads HTTPS (`https://abideandanchor.app`), default ATS policy is sufficient.

### ✅ PASS — Core Keys Present

| Key | Value | Status |
|-----|-------|--------|
| CFBundleDisplayName | Abide & Anchor | ✅ |
| CFBundleIdentifier | $(PRODUCT_BUNDLE_IDENTIFIER) | ✅ (resolves from build settings) |
| CFBundleURLSchemes | abideandanchor | ✅ |
| LSRequiresIPhoneOS | true | ✅ |
| UILaunchStoryboardName | LaunchScreen | ✅ |
| UIViewControllerBasedStatusBarAppearance | true | ✅ |
| UISupportedInterfaceOrientations | Portrait + Landscape | ✅ |

### ❌ FAIL — UIRequiredDeviceCapabilities Contains `armv7`

```xml
<key>UIRequiredDeviceCapabilities</key>
<array>
    <string>armv7</string>
</array>
```

**Issue:** `armv7` is the 32-bit ARM architecture. It has been unsupported since iOS 11 (2017). All modern iOS devices use `arm64`. While this won't cause rejection, it's technically incorrect and may cause compatibility filtering issues on the App Store.

**Required Fix:** Change to `arm64` or remove entirely (Xcode will handle it).

### ⚠️ WARNING — Missing Usage Descriptions

The live web app (https://abideandanchor.app) is a devotional app with journal features. If the web app's JavaScript calls any of these APIs through WKWebView, the corresponding `NS*UsageDescription` keys MUST be in Info.plist:

| API | Info.plist Key | Present? |
|-----|----------------|----------|
| Camera | NSCameraUsageDescription | ❌ Missing |
| Photo Library | NSPhotoLibraryUsageDescription | ❌ Missing |
| Microphone | NSMicrophoneUsageDescription | ❌ Missing |
| Location | NSLocationWhenInUseUsageDescription | ❌ Missing |

**Impact:** If the web app calls `navigator.mediaDevices.getUserMedia()` or `navigator.geolocation.getCurrentPosition()` from within WKWebView, the app will **crash immediately** without these keys. Apple will reject the app.

**Required Action:** Audit the live web app at https://abideandanchor.app for all Web API usage and add corresponding usage descriptions.

---

## 4. Web Wrapper Risk Audit — ❌ CRITICAL

### Apple Guideline 4.2 Compliance Assessment

**Apple Review Guideline 4.2 — Minimum Functionality:**
> "Your app should include features, content, and UI that elevate it beyond a repackaged website."

### Current State Analysis

| Factor | Assessment |
|--------|------------|
| Native UI elements | ❌ None — all UI is rendered in WKWebView |
| Native navigation | ❌ None — web-based routing |
| Offline capability | ❌ None — requires network to load remote URL |
| Push notifications | ❌ Not implemented |
| Native hardware access | ❌ Not used (no camera, GPS, etc.) |
| Platform integration | ⚠️ Minimal — only token storage via Preferences and deep link handling |
| App-specific functionality | ⚠️ Deep link OAuth flow is native-adjacent |

### Rejection Risk: **HIGH (70-80%)**

**Why Apple will likely reject:**
1. The app loads `https://abideandanchor.app` entirely in WKWebView
2. The `main.jsx` renders a debug/auth UI — not the actual app content
3. The same experience is available at https://abideandanchor.app in Safari
4. No offline functionality whatsoever
5. No native features beyond token storage
6. The app is functionally identical to adding a website to the home screen

### Mitigation Strategies

To reduce rejection risk, implement **at least 3** of the following:

1. **Push Notifications** (strongest signal)
   - Daily devotional reminders via APNs
   - Requires: `@capacitor/push-notifications`, entitlements, server-side

2. **Offline Mode**
   - Cache daily verses and journal entries locally
   - Use Capacitor Storage or SQLite
   - Show cached content when offline

3. **Native Share Sheet**
   - Use `@capacitor/share` for sharing verses/journal entries
   - Provides native iOS share experience

4. **Widgets (WidgetKit)**
   - Daily verse widget on home screen
   - Strongest "not a web wrapper" signal to Apple reviewers

5. **Haptic Feedback**
   - Use `@capacitor/haptics` for UI interactions
   - Low effort, adds native feel

6. **Status Bar / Safe Area Integration**
   - Already partially done with `viewport-fit=cover`
   - Ensure proper safe area handling

7. **App Clips** (advanced)
   - A lightweight version for quick access

---

## 5. Cookie & Storage Audit

### ✅ PASS — localStorage Persistence

| Check | Result |
|-------|--------|
| Origin is HTTPS (https://abideandanchor.app) | ✅ |
| WKWebView localStorage persists under HTTPS | ✅ |
| Not using capacitor://localhost (which loses storage) | ✅ |
| Capacitor Preferences backup for token | ✅ |

### ✅ PASS — Token Storage Architecture

The token storage module (`src/lib/tokenStorage.js`) correctly:
- Uses `@capacitor/preferences` (iOS UserDefaults) on native
- Falls back to `localStorage` on web
- Waits for Capacitor bridge readiness before accessing Preferences
- Includes verification after save
- Has timeout handling (5s default)

### ✅ PASS — Cookie Persistence Under HTTPS Origin

With `server.url` set to `https://abideandanchor.app`, WKWebView will:
- Use HTTPS origin for all cookies
- Persist cookies in the standard WKWebView cookie jar
- Not lose cookies across app restarts (same-origin persistence)

### ⚠️ WARNING — Potential Race Condition

The `AuthContext.jsx` has a token version counter (`tokenVersion`) to guard against race conditions where expired token cleanup overlaps with new token arrival via deep link. This is a good pattern, **but**:

- `tokenVersion` is React state, which is async
- The check `if (tokenVersion !== versionAtStart)` uses a stale closure value
- **Recommendation:** Use a `useRef` instead of `useState` for the version counter to ensure immediate reads

### ✅ PASS — Login Loop Protection

- 5-second auth timeout forces Login button visibility (`AUTH_TIMEOUT_MS = 5000`)
- Deep link deduplication guard (`lastProcessedUrl`)
- Proper token clearing on 401/403 with race guard

---

## 6. App Store Connect Readiness

### ✅ PASS — App Icon

| Check | Result |
|-------|--------|
| Size | 1024x1024 ✅ |
| Format | PNG ✅ |
| Alpha channel | No ✅ (Apple rejects icons with alpha) |
| Color space | RGB ✅ |

### ❌ FAIL — Missing App Store Connect Assets

The following are REQUIRED for App Store submission but cannot be verified from the codebase alone:

| Requirement | Status |
|-------------|--------|
| App Store screenshots (6.7", 6.5", 5.5") | ❓ Unknown |
| iPad screenshots (if universal) | ❓ Unknown (TARGETED_DEVICE_FAMILY = "1,2" includes iPad) |
| App description (max 4000 chars) | ❓ Unknown |
| Privacy Policy URL | ❓ Unknown (REQUIRED) |
| Support URL | ❓ Unknown (REQUIRED) |
| App category | ❓ Unknown |
| Age rating questionnaire | ❓ Unknown |
| App review contact info | ❓ Unknown |

### ❌ FAIL — Privacy Policy URL

Apple REQUIRES a privacy policy URL for all apps. The app collects:
- Authentication tokens
- Journal entries (user-generated content)
- Usage data

**A privacy policy MUST be hosted at a public URL and linked in App Store Connect.**

---

## 7. Versioning & Build Strategy

### Current State

| Setting | Value |
|---------|-------|
| MARKETING_VERSION | 1.0 |
| CURRENT_PROJECT_VERSION | 1 |
| package.json version | 0.0.0 |

### ⚠️ WARNING — Version Mismatch

- `package.json` says `0.0.0` while Xcode says `1.0`
- These should be kept in sync

### Recommended Strategy

**Version Format:** `MAJOR.MINOR.PATCH` (Semantic Versioning)
- First release: `1.0.0`
- Bug fixes: `1.0.1`, `1.0.2`
- New features: `1.1.0`, `1.2.0`
- Breaking changes: `2.0.0`

**Build Number:** Auto-incrementing integer
- Start at `1`
- Increment for EVERY build uploaded to TestFlight/App Store
- Each build number must be unique per version
- Recommendation: Use timestamp-based build numbers (e.g., `20260208001`)

**TestFlight Flow:**
1. Internal Testing: Upload via Xcode → Organizer → Distribute App → TestFlight Internal
   - No review required, available immediately
   - Up to 100 internal testers
2. External Testing: Requires Beta App Review
   - Up to 10,000 external testers
   - Must pass basic review (less strict than full review)

---

## 8. Privacy Manifest (PrivacyInfo.xcprivacy) — ❌ FAIL

### Missing Required File

Since Spring 2024, Apple requires ALL apps to include a `PrivacyInfo.xcprivacy` file that declares:
1. **Privacy Tracking:** Whether the app tracks users
2. **Privacy Nutrition Labels:** Data types collected
3. **Required Reason APIs:** Use of specific APIs (UserDefaults, file timestamps, etc.)

### Impact

- ❌ App Store submission WILL fail without this file
- ❌ TestFlight external testing WILL fail without this file
- ⚠️ TestFlight internal testing MAY show warnings

### Required APIs to Declare

The app uses `@capacitor/preferences` which wraps `UserDefaults`. This MUST be declared in the privacy manifest under `NSPrivacyAccessedAPITypes` with category `NSPrivacyAccessedAPICategoryUserDefaults`.

---

## 9. Git/CI Readiness — ❌ FAIL

### Critical `.gitignore` Issue

The `.gitignore` file contains:
```
ios/
android/
```

**Impact:** The entire iOS project (`Info.plist`, Xcode project, assets, native code) will NOT be committed to Git. This means:
- ❌ No version control for iOS-specific changes
- ❌ No CI/CD pipeline can build the iOS app
- ❌ Collaborators cannot clone and build
- ❌ Loss of Xcode project configuration if machine changes

**Required Fix:** Remove `ios/` from `.gitignore` and commit the iOS directory.

---

## 📋 Summary of Blockers

### 🔴 CRITICAL BLOCKERS (Must fix before submission)

| # | Issue | Fix |
|---|-------|-----|
| 1 | Bundle ID mismatch (Xcode vs Capacitor) | Change Xcode to `com.abideandanchor.app` |
| 2 | Missing PrivacyInfo.xcprivacy | Create privacy manifest file |
| 3 | Web wrapper rejection risk (Guideline 4.2) | Add native features |
| 4 | Missing Privacy Policy URL | Host and link privacy policy |
| 5 | `ios/` in `.gitignore` | Remove and commit iOS project |
| 6 | `armv7` in UIRequiredDeviceCapabilities | Change to `arm64` |

### 🟡 HIGH PRIORITY (Should fix before submission)

| # | Issue | Fix |
|---|-------|-----|
| 7 | Both configs use debug.xcconfig | Create release.xcconfig |
| 8 | Missing usage descriptions in Info.plist | Audit web app and add required keys |
| 9 | Version mismatch (package.json vs Xcode) | Synchronize to 1.0.0 |
| 10 | Missing App Store Connect assets | Prepare screenshots, description, etc. |

### 🟢 LOW PRIORITY (Recommended improvements)

| # | Issue | Fix |
|---|-------|-----|
| 11 | Token version race condition (useState vs useRef) | Use useRef for tokenVersion |
| 12 | `config.xml` has `<access origin="*" />` | Restrict to required origins |
| 13 | Excessive console.log in production | Strip debug logging for release |

---

## 🎯 Recommended Next Actions (Priority Order)

1. **Fix bundle identifier** in Xcode project to match `com.abideandanchor.app`
2. **Create PrivacyInfo.xcprivacy** with UserDefaults API declaration
3. **Remove `ios/` from `.gitignore`** and commit iOS project
4. **Fix `armv7` → `arm64`** in Info.plist
5. **Create `release.xcconfig`** without CAPACITOR_DEBUG
6. **Implement at least 3 native features** to mitigate Guideline 4.2 risk
7. **Create and host privacy policy**
8. **Prepare App Store Connect listing** (screenshots, description, URLs)
9. **Audit web app for API usage** and add Info.plist usage descriptions
10. **Synchronize version numbers** across package.json and Xcode

---

*Report generated by Raouf on 2026-02-08 AEDT*  
*Audit assumes adversarial Apple review process*
