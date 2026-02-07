# iOS Build Guide — Abide & Anchor

This guide walks you through building the app for iOS after the onboarding fix.

---

## Prerequisites

- macOS with Xcode installed
- Node.js 18+
- Physical iPhone connected to Mac
- [Optional] Safari Web Inspector enabled on iPhone

---

## Quick Build (3 Commands)

```bash
# 1. Install dependencies (if not done)
npm install

# 2. Build and sync to iOS
npm run build
npx cap sync ios

# 3. Open Xcode and build
open ios/App/App.xcworkspace
```

Then in Xcode: Select your iPhone → Press ▶️ Build & Run

---

## Detailed Build Steps

### Step 1: Verify Configuration

Your App ID is already configured:

```bash
npm run verify:ios
```

Expected output:
```
✓ VITE_BASE44_APP_ID is set: 69586539...
✓ App ID 69586539... is baked into the bundle
✓ No null App ID assignments found
✓ All checks passed! Ready to build in Xcode.
```

### Step 2: Build the Web Bundle

```bash
npm run build
```

This creates the `dist/` folder with your App ID baked in.

### Step 3: Sync to iOS

```bash
npx cap sync ios
```

This copies `dist/` into `ios/App/App/public/`.

### Step 4: Build in Xcode

1. Open `ios/App/App.xcworkspace` (not .xcodeproj!)
2. Select your connected iPhone from the device dropdown
3. Click the ▶️ button or press `Cmd+R`
4. Wait for the app to install and launch

---

## Verification on Device

### Using Safari Web Inspector

1. On iPhone: Settings → Safari → Advanced → Enable Web Inspector
2. Connect iPhone to Mac via USB
3. On Mac: Open Safari → Develop menu → [Your iPhone] → Abide & Anchor
4. In the Console tab, run:

```javascript
window.diagnoseBase44Config()
```

### Expected Output

```
[Base44 Diagnostics]
Configuration:
  appId: "69586539f13402a151c12aa3"
  appIdStatus: "SET"
  serverUrl: "https://abideandanchor.app"
  
Validation:
  Valid: true
  
Expected API Path: /api/apps/69586539f13402a151c12aa3/entities/User/me
```

If `appId` shows `NULL`, the build needs to be redone.

---

## Troubleshooting

### Problem: App still stuck on onboarding

**Diagnosis:**
```javascript
window.diagnoseBase44Config()
```

Check if `appId` is `NULL`. If so:

```bash
npm run build
npx cap sync ios
# Rebuild in Xcode
```

### Problem: Xcode won't build

Make sure you're opening the `.xcworkspace` file, not `.xcodeproj`:
```bash
open ios/App/App.xcworkspace
```

### Problem: "Could not find device"

1. Unlock your iPhone
2. Trust this computer when prompted
3. Try unplugging and reconnecting

### Problem: Code signing errors

In Xcode:
1. Select the "App" target
2. Go to "Signing & Capabilities"
3. Select your Team
4. Let Xcode manage signing

---

## One-Command Build

For convenience, use this combined command:

```bash
npm run build:ios
```

This runs: `build` → `verify:ios` → `cap sync ios`

---

## Configuration Reference

### Environment File

`.env.production`:
```env
VITE_BASE44_APP_ID=69586539f13402a151c12aa3
VITE_BASE44_SERVER_URL=https://base44.app
VITE_BASE44_APP_BASE_URL=https://abideandanchor.app
```

### Fallback (Safety Net)

`src/lib/app-params.js`:
```javascript
const FALLBACK_APP_ID = '69586539f13402a151c12aa3';
const DEFAULT_SERVER_URL = 'https://abideandanchor.app';
```

---

## API Endpoints

Once the fix is working, the app will call:

```
GET https://abideandanchor.app/api/apps/69586539f13402a151c12aa3/entities/User/me
Headers:
  X-App-Id: 69586539f13402a151c12aa3
```

This should return JSON (not HTML).

---

## Success Criteria

| Check | Expected |
|-------|----------|
| `window.diagnoseBase44Config()` | Shows appId as SET |
| Network tab | X-App-Id header = `69586539...` |
| API response | `application/json` |
| Onboarding | Completes successfully! |

---

## Need Help?

1. Run `window.diagnoseBase44Config()` in Safari console
2. Check Network tab for failed requests
3. Look at Console for error messages
4. Review `CHANGELOG.md` for fix details
