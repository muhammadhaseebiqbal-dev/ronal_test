# Abide & Anchor — iOS Onboarding Fix

## 🎯 Summary

This repository contains the production iOS wrapper and runtime patch layer for Abide & Anchor, including auth/session stability and Companion subscription hardening.

**Status:** Production-ready, with current regression coverage and iOS validation workflows.

---

## 🐛 The Problem

The iOS app was making API calls with a **null App ID**:

```
❌ Before: /api/apps/null/entities/User/me
   → Server returned HTML (not JSON)
   → Auth state couldn't resolve
   → Onboarding stuck forever
```

## ✅ The Solution

```
✅ After: /api/apps/69586539f13402a151c12aa3/entities/User/me
   → Server returns JSON
   → Auth state resolves correctly
   → Onboarding completes!
```

---

## 🚀 Quick Start for Roland

### Step 1: Install Dependencies
```bash
npm install
```

### Step 2: Verify the Build (Optional)
```bash
npm run lint      # Should show 0 errors
npm run test      # Should show 42/42 passing
npm run build     # Should succeed
npm run verify:ios  # Should show all green checks
```

### Step 3: Sync to iOS
```bash
npx cap sync ios
```

### Step 4: Build in Xcode
1. Open `ios/App/App.xcworkspace` in Xcode
2. Select your physical iPhone
3. Click **Build & Run**

### Step 5: Verify the Fix
1. Connect iPhone to Mac
2. Open Safari → **Develop** → [Your iPhone] → **Abide & Anchor**
3. In console, run:
   ```javascript
   window.diagnoseBase44Config()
   ```
4. Check that `appId` shows `69586539f13402a151c12aa3` (not `null`)
5. Complete onboarding!

---

## 📁 Project Structure

```
Raouf_Minimum/
├── src/
│   ├── api/base44Client.js      # SDK client
│   ├── context/AuthContext.jsx  # Auth provider
│   ├── lib/app-params.js        # Config (THE FIX IS HERE)
│   └── main.jsx                 # Entry point
├── tests/                       # 42 unit tests
├── scripts/verify-ios-build.js  # Build checker
├── docs/
│   ├── ARCHITECTURE.md
│   ├── API.md
│   └── IOS_BUILD_GUIDE.md
├── .env.production              # App ID configured ✅
└── capacitor.config.ts          # iOS config
```

---

## 🔧 Configuration

Your Base44 App ID is configured in two places:

### 1. `.env.production` (Primary)
```env
VITE_BASE44_APP_ID=69586539f13402a151c12aa3
VITE_BASE44_APP_BASE_URL=https://abideandanchor.app
```

### 2. `src/lib/app-params.js` (Fallback)
```javascript
const FALLBACK_APP_ID = '69586539f13402a151c12aa3';
const DEFAULT_SERVER_URL = 'https://abideandanchor.app';
```

The fallback ensures the App ID works even if environment variables fail to bake in.

---

## 🧪 Verification Results

All automated checks passed:

| Check | Result |
|-------|--------|
| Lint | ✅ 0 errors |
| Tests | ✅ 42/42 passing |
| Build | ✅ Success |
| iOS Verify | ✅ App ID baked in |
| Real Endpoint | ✅ Returns JSON |

### Real API Test
```bash
curl -H "X-App-Id: 69586539f13402a151c12aa3" \
  "https://abideandanchor.app/api/apps/69586539f13402a151c12aa3/entities/User/me"
```

**Response:**
```json
{
  "message": "You must be logged in to access this app",
  "extra_data": {
    "app_id": "69586539f13402a151c12aa3",
    "reason": "auth_required"
  }
}
```
✅ Returns `application/json` — NOT HTML!

---

## Regression Suite for Client Issues

This repository includes a Playwright + API regression suite that validates every reported client issue and generates a short summary report.

### Required environment for authenticated checks
- `TEST_AUTH_TOKEN` (preferred)  
- `TEST_LOGIN_MODE=ui` plus `TEST_EMAIL` and `TEST_PASSWORD` (if using UI login)

Optional configuration:
- `PLAYWRIGHT_BASE_URL` (defaults to `http://127.0.0.1:4173`)
- `PLAYWRIGHT_APP_ID` (falls back to `.env.production`)
- `PLAYWRIGHT_SERVER_URL`
- `PLAYWRIGHT_APP_BASE_URL`
- `TEST_API_SKIP=1` to skip the live API test when offline (the summary will mark it as SKIPPED)

### Commands
1. `npm ci`
2. `npx playwright install --with-deps`
3. `npm run test` (unit + API)
4. `npm run test:e2e`
5. `npm run test:regression` (writes `test-results/summary.md`)

CI note: set `TEST_AUTH_TOKEN` as a repository secret to enable the Playwright job.
Network note: the API test calls Base44 directly and requires outbound DNS access.
Auth note: if no credentials are provided, authenticated Playwright checks are marked as SKIPPED in the summary.

### Issue-to-test matrix
| Issue | Test(s) | Assertion(s) |
| --- | --- | --- |
| Onboarding stuck on final screen | Playwright: unauthenticated boot | Loading screen clears within timeout |
| onboardingStatus remains incomplete | Playwright: unauthenticated boot | App transitions to a stable state (not loading) |
| User/me returns HTML instead of JSON | API test + Playwright | `Content-Type` includes `application/json`, body parses as JSON |
| App ID is null in API requests | Playwright network monitor | No `/api/apps/null`, appId matches env |
| X-App-Id header is null or missing | Playwright network monitor | `X-App-Id` present and matches env |
| Base44 HTML shell returned instead of JSON | API test + Playwright | Response body JSON parseable |
| Missing manifest.json | Unit test | `public/manifest.json` exists and is referenced in `index.html` |
| hasToken false on boot after login | Playwright authenticated boot | `hasToken: true` after login |
| Authenticated /User/me should be 200 JSON | Playwright authenticated boot | `/entities/User/me` returns `200` and JSON |
| App is loading indefinitely | Playwright unauthenticated boot | Loading text not visible after timeout |
| Token does not persist after restart | Playwright persistence | Token retained across context restart |
| Native storage not used on Capacitor | Unit test | Preferences called when Capacitor is available |

### Summary report
After a run, `test-results/summary.md` contains PASS/FAIL per issue with short notes. This is written by `scripts/generate-regression-summary.js`.

---

## 📱 Safari Web Inspector Diagnostics

On the device, open Safari Web Inspector and run:

```javascript
window.diagnoseBase44Config()
```

This shows:
- Current App ID configuration
- Server URLs
- Validation status
- Expected API paths
- Fix instructions if something is wrong

---

## 🔄 If Something Goes Wrong

### Problem: App ID shows NULL
1. Check `.env.production` has the correct App ID
2. Run `npm run build` (rebuilds with env vars)
3. Run `npx cap sync ios`
4. Rebuild in Xcode

### Problem: API returns HTML
1. Check the `X-App-Id` header in Network tab
2. Make sure it shows `69586539f13402a151c12aa3`
3. If it shows `null`, rebuild the app

### Problem: Build fails
```bash
npm run verify:ios  # Shows what's wrong
```

---

## 📚 Additional Resources

- [iOS Build Guide](docs/IOS_BUILD_GUIDE.md) — Detailed build instructions
- [Architecture](docs/ARCHITECTURE.md) — How the fix works
- [API Reference](docs/API.md) — SDK usage
- [Changelog](CHANGELOG.md) — Full change history
- [Agent Rules](AGENT.md) — AI development guidelines
- [Privacy Policy](https://the-right-perspective.com/abide-anchor-privacy-policy/) — App privacy policy

---

## 📞 Support

If you have questions about the fix:
1. Run `window.diagnoseBase44Config()` in Safari console
2. Take a screenshot of the output
3. Check the Network tab for API calls
4. Note any error messages

---

## 📝 License

MIT License — See [LICENSE](LICENSE) for details.
