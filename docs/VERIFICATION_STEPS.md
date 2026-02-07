# Token Persistence Verification Guide for Roland

## Current Status: ✅ Implementation Complete

All code changes for native token persistence are complete. The implementation uses `@capacitor/preferences` (iOS UserDefaults) to persist authentication tokens across app cold restarts.

---

## Verification Steps

### Step 1: Build and Sync

Run these commands in the project directory:

```bash
# Clean build
rm -rf dist
npm run build

# Verify App ID baked in
npm run verify:ios

# Sync to iOS (if ios/ folder exists, or add it first)
# If no ios/ folder: npx cap add ios
npx cap sync ios
```

### Step 2: Build in Xcode

1. Open `ios/App/App.xcworkspace` in Xcode
2. Select your physical iPhone
3. Build and run (Cmd+R)

### Step 3: First Launch (Baseline)

On first launch, you should see:
- Console: `[tokenStorage] Loading token... { isNative: true }`
- Console: `[tokenStorage] Token loaded from native storage: { hasToken: false }`
- UI shows "Not authenticated" with "Log In" button
- This is expected — no token stored yet

### Step 4: Log In

1. Tap "Log In" button
2. Complete OAuth flow on Base44
3. App should redirect back with token in URL
4. Console should show:
   ```
   [AuthContext] Token found in URL (OAuth callback)
   [tokenStorage] Saving token... { isNative: true }
   [tokenStorage] Token saved to native storage
   [AuthContext] Checking user auth with token...
   [AuthContext] User authenticated: { userId: "..." }
   ```
5. UI shows "✅ Authenticated!" with user details

### Step 5: Cold Restart (The Real Test)

1. Kill the app completely (swipe up from app switcher)
2. Wait 3 seconds
3. Reopen the app

**Expected console output after cold restart:**
```
[tokenStorage] Loading token... { isNative: true }
[tokenStorage] Token loaded from native storage: { hasToken: true }
[AuthContext] Token loaded from native storage
[AuthContext] Checking user auth with token...
[AuthContext] User authenticated: { userId: "..." }
```

**Expected UI:** Should show "✅ Authenticated!" without requiring login

---

## Safari Web Inspector Diagnostics

Connect iPhone to Mac, enable Safari Web Inspector, then in console:

### Check Configuration
```javascript
window.diagnoseBase44Config()
```

Expected output:
```
config.appId: "69586539f13402a151c12aa3"  // NOT null
config.hasToken: true                     // After login
environment.isCapacitor: true
```

### Check Token Storage
```javascript
window.diagnoseTokenStorage()
```

Expected output after login:
```
isNative: true
nativeStorageToken: "eyJhbGciOiJIUz..."  // Truncated token
hasToken: true
recommendation: "Token found. Should persist across cold restarts."
```

---

## Troubleshooting

### Problem: Token not loading from native storage

**Check 1:** Is Capacitor Preferences plugin synced?
```bash
npx cap sync ios
```

**Check 2:** Are you on a physical device?
Native storage only works on real iOS devices, not simulators for testing.

**Check 3:** Is `isNative: true` in console?
```javascript
window.diagnoseTokenStorage()
```
If `isNative: false`, the app isn't detecting Capacitor environment correctly.

### Problem: 403 auth_required after cold restart

This means either:
1. Token wasn't saved (check console for save errors)
2. Token expired on server
3. Token storage read failed

Run diagnostics and check for errors in console.

### Problem: "App is loading" stuck

Check Safari console for errors. Run:
```javascript
window.diagnoseBase44Config()
```
Verify `appId` is not null.

---

## Success Criteria (Milestone A)

| Test | Expected | Status |
|------|----------|--------|
| App ID not null | `69586539f13402a151c12aa3` | ✅ Verified |
| `/entities/User/me` returns JSON | `Content-Type: application/json` | ⏳ Roland to verify |
| Token persists after cold restart | `hasToken: true` on reopen | ⏳ Roland to verify |
| Login flow completes | User sees authenticated state | ⏳ Roland to verify |

---

## Files Changed for Token Persistence

| File | Change |
|------|--------|
| `src/lib/tokenStorage.js` | **Created** - Native token storage using Capacitor Preferences |
| `src/context/AuthContext.jsx` | **Modified** - Async token loading on mount, save after OAuth |
| `src/lib/app-params.js` | **Modified** - localStorage fallback for token check |
| `src/main.jsx` | **Modified** - Debug UI showing `hasToken` and `isTokenLoaded` |
| `package.json` | **Modified** - Added `@capacitor/preferences` dependency |

---

## Contact

If issues persist after following these steps, provide:
1. Full Safari console log (copy/paste text)
2. Screenshot of app state
3. Output of `window.diagnoseBase44Config()`
4. Output of `window.diagnoseTokenStorage()`
