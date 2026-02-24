# CLAUDE.md — Abide & Anchor iOS

## What is this project?

Capacitor 8 iOS wrapper for https://abideandanchor.app (Base44 hosted SaaS). The WKWebView loads the live production site — all `src/` JS is **dead code** in production. Runtime fixes live in `ios/App/App/PatchedBridgeViewController.swift` (~3500 lines) via injected `WKUserScript`.

**Client:** Roland L. | **Bundle ID:** `com.abideandanchor.app` | **Current Build:** 19

## Architecture (critical to understand)

```
Remote site (https://abideandanchor.app)
  └── Loaded in WKWebView (same-origin mode)
        └── PatchedBridgeViewController.swift injects CSS+JS patches at runtime
              ├── IAP bridge (StoreKit 2 ↔ JS via WKScriptMessageHandler)
              ├── Button wiring (finds subscribe/restore buttons by text content)
              ├── Subscription UI hiding (yearly, trial, already-subscribed)
              ├── Toast notifications, diagnostics overlay, logout, back buttons
              └── Cookie bridging, token persistence, process recovery
```

- `src/` code compiles to `dist/` but is **never served** — `server.url` overrides it
- ALL runtime behavior changes MUST go in `PatchedBridgeViewController.swift`
- Base44 paywall popups render as React portals on `document.body`, NOT inside `#root`

## Key files

| File | What it does |
|------|-------------|
| `ios/App/App/PatchedBridgeViewController.swift` | THE critical file. All patches, IAP, UI injection |
| `ios/App/App.xcodeproj/project.pbxproj` | Xcode project config, build number lives here |
| `capacitor.config.ts` | Capacitor config — remote URL mode |
| `AGENT.md` | Full project rules, acceptance criteria, change log |
| `CHANGELOG.md` | Detailed build-by-build changelog |
| `worker/companion-validator/index.js` | Cloudflare Worker for cross-device companion sync |
| `.env.production` | Production env vars (VITE_BASE44_APP_ID) |

## Build & verify commands

```bash
npm run lint           # ESLint (quiet mode)
npm run test           # Unit tests (node --test, 42 tests)
npm run build          # Vite production build
npx cap sync ios       # Sync web assets + config to iOS
npm run build:ios      # Full pipeline: build + verify + sync

# Xcode build (no code signing — signing happens on Roland's machine)
xcodebuild -workspace ios/App/App.xcworkspace \
  -scheme App -configuration Release \
  -destination 'generic/platform=iOS' \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO build
```

## Rules you must follow

### Never do these
- **Never set `ios.scheme`** in capacitor.config.ts — breaks localStorage origin
- **Never modify `src/` expecting it to affect the app** — it's dead code in production
- **Never commit `.env` files with real API keys**
- **Never add feature gating logic in iOS** — Base44 `is_companion` is the source of truth
- **Never search only `#root` for buttons** — Base44 popups render on `document.body`

### Always do these
- **Read `AGENT.md` and `CHANGELOG.md`** before making changes (raouf-change-protocol)
- **Update both `AGENT.md` and `CHANGELOG.md`** after changes
- **Bump build number** in `project.pbxproj` (both Debug AND Release configs)
- **Run full verification**: lint, test, build, cap sync, xcodebuild
- **Use `server.url: 'https://abideandanchor.app'`** — remote URL mode always

## IAP architecture

- **StoreKit 2** — `Product.products(for:)`, `product.purchase()`, `AppStore.sync()`
- **Only purchasable product:** `com.abideandanchor.companion.monthly`
- **Yearly recognized for entitlements** but removed from sale (hidden in UI)
- **Purchase flow:** Button click → `aaPurchase` message handler → StoreKit → JWS → Worker POST → `is_companion: true` → `reloadFromOrigin()`
- **Restore flow:** Button click → `AppStore.sync()` → check entitlements → toast result → Worker sync if active
- **Persistence:** `aa_is_companion` in UserDefaults, token in UserDefaults (two-way sync with localStorage)

## Subscription UI rules (Apple requirements)

- Monthly ONLY — no yearly, no trial anywhere
- Trial buttons AND text hidden (`hideTrialTextElements()`)
- Yearly buttons AND text hidden (`hideYearlyTextElements()`)
- Subscribed users see no subscribe/paywall buttons (`handleAlreadySubscribed()`)
- Restore Purchases always shows a toast (success, nothing, or error)

## Common patterns in PatchedBridgeViewController.swift

- **Button finding:** `document.querySelectorAll('button, a, [role="button"]')` on `document.body`
- **Skip own UI:** `.closest('.aa-diag-overlay, #aa-logout-section, ...')` guard
- **Idempotency:** `data-aa-*` attributes prevent double-processing
- **DOM walk:** Walk up parents to find container card, hide parent if all children hidden
- **CSS !important:** `[data-aa-*-hidden] { display: none !important }` as safety net
- **MutationObserver:** Root observer (subtree) + body observer (childList only for portals)
- **Orchestrator:** `runAllPatches()` debounced 250ms, runs all patch functions in order
- **Periodic:** Every 3s for 30s after navigation to catch late-appearing popups

## Gotchas

1. **`src/` is dead code** — the remote site serves its own JS. Don't fix bugs in `src/`.
2. **React portals** — Base44 modals/popups render outside `#root` on `document.body`. Always search `document.body`, not `#root`, for buttons.
3. **StoreKit config format** — Xcode 26.2 requires v4 format. Create `.storekit` files via Xcode wizard, never manually.
4. **Worker must be deployed separately** — `cd worker/companion-validator && wrangler deploy` (Roland does this).
5. **Build number in TWO places** — `CURRENT_PROJECT_VERSION` exists in both Debug and Release sections of `project.pbxproj`. Update both.
6. **`evaluateJavaScript` before page load** — localStorage throws `SecurityError` at `about:blank`. Always guard with `webView.url?.scheme == "https"`.
7. **Auto-renewal stale data** — Worker's `companion_expires_at` doesn't track StoreKit auto-renewals. Native cross-checks StoreKit before accepting server downgrade.

## Acceptance criteria (Milestone B — 14 points)

All must pass or build is rejected:
- **A1-A3:** No yearly, no trial, monthly only
- **B4-B5:** No subscribe buttons when subscribed, no contradictory states
- **C6-C8:** Purchase → Apple sheet → immediate unlock → persists after kill
- **D9-D12:** Restore always visible, clear messages, UI refreshes
- **E13-E14:** Base44 `is_companion` driven, no iOS-only gating
