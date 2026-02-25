# Contributing Guide

## Scope
This repository ships the iOS wrapper and runtime patch layer for Abide & Anchor. Contributions must preserve production behavior for authentication, subscription state, and Base44 compatibility.

## Development Setup
1. Install dependencies: `npm ci`
2. Run lint: `npm run lint`
3. Run tests: `npm test`
4. Run build: `npm run build`
5. For iOS validation: `npm run verify:ios`

## Branch and Commit Rules
1. Create focused branches per change.
2. Keep commits small and atomic.
3. Use commit format: `type(scope): imperative summary`.
4. Do not mix unrelated refactors with bug fixes.

## Pull Request Checklist
1. Describe the bug/risk and why the change is correct.
2. Link impacted files and runtime paths.
3. Include validation evidence:
   - `npm run lint`
   - `npm test`
   - `npm run build`
   - `xcodebuild ... build` (when native code changed)
4. Add/update docs for behavior changes.
5. Update `AGENT.md` and `CHANGELOG.md` with a `Raouf:` entry for each edit batch.

## Code Standards
1. Preserve existing architecture and naming patterns.
2. Add comments only where logic is non-obvious.
3. Avoid introducing secrets or environment-specific constants in source.
4. Prefer explicit error handling and logging for network/native paths.

## Testing Expectations
1. Add or update tests for JS-side behavior changes.
2. For native Swift changes, provide reproducible manual validation steps in PR notes.
3. For subscription changes, validate both:
   - subscribed account
   - non-subscribed account
4. Validate logout/login and restore behavior with network on/off conditions.

## Security Expectations
1. Never log tokens, credentials, or PII.
2. Validate external payloads (e.g., Worker inputs, JWS metadata).
3. Keep Base44 `is_companion` as source of truth for gating decisions.
