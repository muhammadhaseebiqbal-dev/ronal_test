# Build 31 — Release Notes

**Date:** 6 March 2026  
**Build:** 1.0.0 (31)  
**Platform:** iOS 15.0+

---

## What Changed

Build 30 showed contradictory subscription status on the same screen — "Companion Active" alongside "Companion isn't active on this account." This happened because two independent UI systems rendered subscription state from different sources.

**Build 31 fixes this with a strategy overhaul:**

- We no longer inject our own "Active" banner that competed with the app's built-in status text.
- The app now shows **"Checking subscription…"** until the server confirms entitlement, then flips to **"Companion Active"** everywhere at once.
- A new contradiction-suppression layer hides any stale "not active" text that the app's built-in components might render from cached data.

---

## Acceptance Requirements

| # | Requirement | Status | Implementation |
|---|-------------|:------:|----------------|
| 1 | Build number 31 or higher | ✅ | `CURRENT_PROJECT_VERSION = 31` in both Debug and Release |
| 2 | Single source of truth for entitlement | ✅ | Nothing displays "Active" until the server confirms. Before confirmation the UI shows "Checking subscription…" |
| 3 | No screen shows "active" and "not active" at the same time | ✅ | Removed the injected `#aa-already-subscribed` banner entirely. Status text requires server verification before showing "Companion Active." Built-in "not active" text is suppressed only after server confirmation. |
| 4 | After Purchase or Restore, gating immediately matches entitlement | ✅ | After StoreKit confirms, the Worker syncs to the server, a cache-busting reload forces a fresh data fetch, and a 10-second follow-up timer catches any late-rendered stale text. |
| 5 | No "active but locked" state | ✅ | "Companion Active" label only appears after the server has confirmed `is_companion = true`. Before that the UI shows "Checking subscription…" — never "Active" while content is still gated. |
| 6 | Restore in one agreed location only | ✅ | Single Restore button on the Settings page (`#aa-sub-restore-btn`). Duplicate paywall Restore button removed. |

---

## On-Device Test Checklist

Please verify the following on a real device via TestFlight:

| # | Test | Expected Result | Pass / Fail |
|---|------|-----------------|:-----------:|
| A1 | Open Settings page as a **free** user | Status shows **"Free"**. One "Restore Purchases" button visible. No "Companion Active" text. | |
| A2 | Tap **Subscribe Monthly** | StoreKit payment sheet appears. After payment, status updates to **"Companion Active"** within a few seconds. No "not active" text visible anywhere. | |
| A3 | After purchase, navigate to a **Companion-gated** feature | Feature is unlocked and accessible. | |
| B1 | **Kill the app** (swipe from recents) and relaunch | Settings page briefly shows "Checking subscription…" then updates to **"Companion Active"** once server responds. No contradiction at any point. | |
| B2 | Navigate to Companion-gated content after relaunch | Still unlocked. | |
| C1 | Go to Settings → tap **Restore Purchases** | Button shows "Restoring…", then a success toast appears. Status shows "Companion Active." | |
| C2 | Confirm **no other** Restore button appears on any paywall or screen | Only the one in Settings. | |
| D1 | **Log out** of subscribed account | Status resets. No "Companion Active" text remains. | |
| D2 | **Log in** with a **different, non-subscribed** account | Status shows **"Free"**. No "Active" leakage from the previous account. | |
| D3 | **Log back in** to the subscribed account | Status shows **"Companion Active"** after server verification. | |

---

## Files Changed

| File | Change |
|------|--------|
| `PatchedBridgeViewController.swift` | Strategy overhaul — removed competing banner, added server-verified suppression, cache-busting reload, post-reload timer, single-source-of-truth guards |
| `project.pbxproj` | Build number 30 → 31 |
| `CHANGELOG.md` | Build 31 entry added |

---

## Technical Summary

1. **Removed** the injected `#aa-already-subscribed` banner and duplicate `#aa-paywall-restore-btn`
2. **Added** `__aaServerVerified` flag — only set to `true` after the server confirms companion status
3. **Added** `__aaSuppressContradictions()` — hides built-in "not active" text when both `__aaIsCompanion` and `__aaServerVerified` are true
4. **Added** `aa_just_purchased` persistence flag — bridges server verification across the cache-busting page reload
5. **Added** post-reload suppression timer (5 × 2 s) to catch asynchronously rendered stale text
6. **Updated** `updateSubscriptionStatusUI` and `injectSubscriptionStatus` to show "Checking subscription…" until server verifies
7. **Enhanced** logout cleanup — clears all flags and un-suppresses text for the next user
