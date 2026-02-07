# API Reference

This project uses the Base44 SDK to access data, authentication, and analytics.

## Base44 Client
The client is created in `src/api/base44Client.js` and exposes the full Base44 SDK surface.

Example:
```js
import { base44 } from '@/api/base44Client';

const user = await base44.auth.me();
```

## Auth Context
`src/context/AuthContext.jsx` provides app-level auth state and helpers.

Available values:
- `user`
- `isAuthenticated`
- `isLoadingAuth`
- `isLoadingPublicSettings`
- `authError`
- `appPublicSettings`
- `logout()`
- `navigateToLogin()`
- `checkAppState()`

Example:
```js
import { useAuth } from '@/context/AuthContext';

const { user, isAuthenticated } = useAuth();
```

## Public Settings Endpoint
AuthContext retrieves public settings via:
```
GET /api/apps/public/prod/public-settings/by-id/{appId}
```

Base URL is always absolute and uses `VITE_BASE44_SERVER_URL`.

## Diagnostics
For debugging configuration issues on physical devices, use the global diagnostic tool.

### Safari Web Inspector
```javascript
window.diagnoseBase44Config();
```

### Scripted Verification
```bash
npm run verify:ios
```
