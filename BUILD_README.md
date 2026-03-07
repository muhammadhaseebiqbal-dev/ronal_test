---
title: "Abide & Anchor — Build 30"
subtitle: "Subscription Bug Fixes — Setup & TestFlight Guide"
date: "March 5, 2026"
---

# What Changed in Build 30

Four bugs fixed based on real-device testing:

| Bug | Issue | Fix |
|-----|-------|-----|
| A | Purchase doesn't unlock immediately | localStorage update + controlled reload forces React re-mount |
| B | Restore confirms but features blocked | Same as A — controlled reload after server confirms |
| C | Cross-account UI leakage | Logout now clears all injected subscription DOM elements |
| D | Restore button missing on paywall | Visible Restore button injected on every paywall screen |

**Build number: 30**

---

# Setup & Archive

## Prerequisites

- macOS with Xcode 15+
- Node.js 18+ (`node -v` to check)

## Steps

```bash
# 1. Unzip
unzip Roland_Build_30.zip -d Roland_Build_30
cd Roland_Build_30

# 2. Install dependencies
npm install

# 3. Sync Capacitor
npx cap sync ios

# 4. Open in Xcode
open ios/App/App.xcodeproj
```

In Xcode:

- Scheme: **App**, Destination: **Any iOS Device (arm64)**
- Verify: Target → General → Build = **30**
- **Product → Archive**
- Distribute → **App Store Connect** → Upload to TestFlight

---

# Troubleshooting

**"Missing package product CapAppSPM"** → Run `npm install` then re-open Xcode.

**Package resolution errors** → Xcode → File → Packages → Reset Package Caches. Close Xcode, delete `ios/App/CapApp-SPM/.build`, re-open.

---

# Acceptance Checklist

- [ ] Subscribe → features unlock immediately (no logout/login needed)
- [ ] Restore → no payment sheet, features unlock immediately
- [ ] Logout A → Login B → B sees no "Companion Active" messaging
- [ ] Every paywall screen has a visible Restore button
- [ ] Never shows "Active" + "Subscribe" at the same time
- [ ] Kill + relaunch → subscription persists
