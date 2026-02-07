# AGENT.md — Project Rules for Abide & Anchor iOS

## Project Type
Capacitor iOS app wrapping https://abideandanchor.app in WKWebView (same-origin mode).

## Tech Stack
- **Frontend:** React 18, Vite, Tailwind CSS
- **Backend:** Base44 platform (hosted SaaS)
- **iOS:** Capacitor 8.x, Swift, WKWebView
- **Auth:** Base44 OAuth via deep links (abideandanchor://)
- **Token Storage:** Capacitor Preferences (iOS UserDefaults)

## Critical Rules

1. **Never set `ios.scheme`** in `capacitor.config.ts` — it would change the WebView origin and break localStorage persistence.
2. **Always use `server.url: 'https://abideandanchor.app'`** — this is the production remote URL mode.
3. **App ID must never be null** — `VITE_BASE44_APP_ID=69586539f13402a151c12aa3` must be set in `.env.production` and baked into the build.
4. **Token storage must use Capacitor Preferences on iOS** — localStorage alone is unreliable across cold restarts under some WKWebView configurations.
5. **Deep links use custom URL scheme** `abideandanchor://` — NOT universal links.
6. **Bundle ID:** `com.abideandanchor.app` (must match Xcode project, App Store Connect, and provisioning profiles).

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

## Change Protocol
- Read this file before making changes
- Update CHANGELOG.md after changes
- Run `npm run lint && npm run test && npm run build` before committing
- Use "Raouf:" prefix in changelog entries
