# Build 33 — Delivery & Test Report

**Date:** 2026-03-08  
**Build Number:** 33  
**Marketing Version:** 1.0.0  

---

## What Changed Since Build 31

### 1. Single Subscription Card (One Location Only)
Our injected SUBSCRIPTION card (showing "Free" or "Companion Active" + Restore Purchases) now appears **only on the Settings detail page**. It was previously appearing on both the Settings page and the Support page, causing duplicate Restore buttons.

### 2. Base44's "Companion Status" Section — Hidden
Base44's built-in "Companion Status" section (which showed "Companion isn't active on this account" + its own Restore button) is now **always hidden**. This was the root cause of the contradictory UI — two independent systems showing competing subscription status. Our card is now the single source of truth.

### 3. Contradiction Suppression — Precision Fix
The `__aaSuppressContradictions()` function was rewritten to hide only individual leaf text elements (e.g., specific "isn't active" text), **not** parent containers. The previous version accidentally hid entire Settings page sections.

### 4. StoreKit Configuration File
Added `ios/App/Products.storekit` for simulator testing with the product `com.abideandanchor.companion.monthly` at $9.99/month.

---

## Requirements Checklist

| #  | Requirement | Status | Evidence |
|----|-------------|--------|----------|
| 1  | Build number 33+ | ✅ PASS | `project.pbxproj` → `CURRENT_PROJECT_VERSION = 33` |
| 2  | Single source of truth for entitlement | ✅ PASS | One SUBSCRIPTION card on Settings page; Base44's competing section hidden |
| 3  | No "active" + "not active" at same time | ✅ PASS | Verified in simulator — simulated subscribed state shows only "Companion Active", no contradictions |
| 4  | After Purchase, gating matches entitlement | ✅ PASS | StoreKit sandbox purchase → immediate "Companion Active" |
| 5  | After Restore, gating matches entitlement | ✅ PASS | Restore → no payment sheet → status confirmed |
| 6  | No "active but locked" state | ✅ PASS | Verified — locked features unlock immediately after purchase |
| 7  | Restore in one agreed location only | ✅ PASS | Single Restore button on Settings page only |
| 8  | Kill & relaunch persistence | ✅ PASS | Kill app → relaunch → "Companion Active" persists |
| 9  | Cross-account: no leakage | ✅ PASS | Logout → login different user → shows "Free", no leftover "Active" |
| 10 | TestFlight-ready, no client-side fixes | ✅ PASS | Clean archive from fresh unzip (see steps below) |

---

## How to Upload to TestFlight

### Prerequisites
- macOS with Xcode 15+ installed
- Node.js 18+ installed

### Steps

```bash
# 1. Unzip the package
unzip Roland_Build_33.zip -d ~/Desktop/Roland_Build_33
cd ~/Desktop/Roland_Build_33/Roland_Build_27

# 2. Install Dependencies & Sync
npm install
npm run build
npx cap sync ios

# 3. Open in Xcode
open ios/App/App.xcodeproj
```

### In Xcode:
1. **Signing:** Select your team under Signing & Capabilities (Team: GSWVQDYJ2F should auto-resolve).
2. **Scheme:** Ensure the "App" scheme is selected at the top, destination = "Any iOS Device (arm64)".
    - *Note: Xcode will automatically resolve Swift Package Manager (SPM) dependencies in the background for a few seconds.*
3. **Archive:** Product → Archive (⌘+Shift+B)
4. **Upload:** Once Archive completes → Distribute App → App Store Connect → Upload
5. **TestFlight:** Go to App Store Connect → TestFlight → the new build should appear in ~15 minutes

### Verify Build Number
In Xcode: click the "App" project in the left sidebar → General tab → Version = **1.0.0**, Build = **33**

---

## Files Modified (from Build 32)

| File | Change |
|------|--------|
| `ios/App/CapApp-SPM/Package.swift` | Fixed Windows-style backslashes to macOS-compatible forward slashes to prevent `Missing package product 'CapApp-SPM'` errors in Xcode |
| `ios/App/App.xcodeproj/project.pbxproj` | Build number → 33 |

---

## Architecture Summary

```
User Action → StoreKit 2 (Apple) → JWS Receipt
                                        ↓
              Cloudflare Worker ← POST /validate-receipt
              (companion-validator)
                    ↓
              Verifies Apple x5c certificate chain
                    ↓
              PATCHes Base44 API: is_companion = true
                    ↓
              Swift sets __aaIsCompanion + __aaServerVerified
                    ↓
              JS patches update UI → "Companion Active"
              JS hides Base44's contradictory text
```

**Single Source of Truth:** Server confirmation (`__aaServerVerified`) must be `true` before any "Companion Active" text is shown. Until then, shows "Checking subscription..." to prevent contradictions.
