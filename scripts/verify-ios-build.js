#!/usr/bin/env node

/**
 * iOS Build Verification Script
 *
 * Verifies that environment variables are correctly baked into the iOS build.
 * Run this AFTER `npm run build` and BEFORE `npx cap sync ios`.
 *
 * Usage:
 *   node scripts/verify-ios-build.js
 *   npm run verify:ios
 */

import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = fileURLToPath(new URL('.', import.meta.url));
const projectRoot = resolve(__dirname, '..');

// ANSI color codes for terminal output
const colors = {
    reset: '\x1b[0m',
    red: '\x1b[31m',
    green: '\x1b[32m',
    yellow: '\x1b[33m',
    blue: '\x1b[34m',
    cyan: '\x1b[36m',
    bold: '\x1b[1m'
};

const log = {
    info: (msg) => console.log(`${colors.blue}ℹ${colors.reset} ${msg}`),
    success: (msg) => console.log(`${colors.green}✓${colors.reset} ${msg}`),
    warn: (msg) => console.log(`${colors.yellow}⚠${colors.reset} ${msg}`),
    error: (msg) => console.log(`${colors.red}✗${colors.reset} ${msg}`),
    header: (msg) => console.log(`\n${colors.bold}${colors.cyan}${msg}${colors.reset}\n`)
};

/**
 * Checks if the dist directory exists
 */
function checkDistExists() {
    const distPath = join(projectRoot, 'dist');
    if (!existsSync(distPath)) {
        log.error('dist/ directory not found. Run `npm run build` first.');
        return false;
    }
    log.success('dist/ directory exists');
    return true;
}

/**
 * Checks if iOS directory exists
 */
function checkIosExists() {
    const iosPath = join(projectRoot, 'ios');
    if (!existsSync(iosPath)) {
        log.warn('ios/ directory not found. Run `npx cap add ios` if needed.');
        return false;
    }
    log.success('ios/ directory exists');
    return true;
}

/**
 * Finds all JS files in the dist/assets directory
 */
function findBundleFiles() {
    const assetsPath = join(projectRoot, 'dist', 'assets');
    if (!existsSync(assetsPath)) {
        log.error('dist/assets/ directory not found.');
        return [];
    }

    const files = readdirSync(assetsPath).filter((f) => f.endsWith('.js'));
    log.info(`Found ${files.length} JS bundle file(s) in dist/assets/`);
    return files.map((f) => join(assetsPath, f));
}

/**
 * Searches for patterns in the bundle files
 */
function searchInBundles(bundleFiles, patterns) {
    const results = {};

    for (const pattern of patterns) {
        results[pattern.name] = {
            pattern: pattern.regex,
            found: false,
            matches: [],
            isPlaceholder: false
        };
    }

    for (const filePath of bundleFiles) {
        const content = readFileSync(filePath, 'utf-8');

        for (const pattern of patterns) {
            const matches = content.match(pattern.regex);
            if (matches) {
                results[pattern.name].found = true;
                results[pattern.name].matches.push(...matches);

                // Check if it's a placeholder value
                if (pattern.placeholders) {
                    for (const placeholder of pattern.placeholders) {
                        if (matches.some((m) => m.includes(placeholder))) {
                            results[pattern.name].isPlaceholder = true;
                        }
                    }
                }
            }
        }
    }

    return results;
}

/**
 * Checks .env.production file
 */
function checkEnvFile() {
    const envPath = join(projectRoot, '.env.production');
    if (!existsSync(envPath)) {
        log.error('.env.production file not found.');
        return { exists: false, values: {} };
    }

    const content = readFileSync(envPath, 'utf-8');
    const values = {};

    const appIdMatch = content.match(/VITE_BASE44_APP_ID=(.+)/);
    const serverUrlMatch = content.match(/VITE_BASE44_SERVER_URL=(.+)/);
    const appBaseUrlMatch = content.match(/VITE_BASE44_APP_BASE_URL=(.+)/);

    values.VITE_BASE44_APP_ID = appIdMatch ? appIdMatch[1].trim() : null;
    values.VITE_BASE44_SERVER_URL = serverUrlMatch ? serverUrlMatch[1].trim() : null;
    values.VITE_BASE44_APP_BASE_URL = appBaseUrlMatch ? appBaseUrlMatch[1].trim() : null;

    return { exists: true, values };
}

/**
 * Checks iOS public assets if synced
 */
function checkIosSyncedAssets() {
    const iosPublicPath = join(projectRoot, 'ios', 'App', 'App', 'public', 'assets');
    if (!existsSync(iosPublicPath)) {
        log.warn('iOS synced assets not found. Run `npx cap sync ios` after fixing.');
        return [];
    }

    const files = readdirSync(iosPublicPath).filter((f) => f.endsWith('.js'));
    log.info(`Found ${files.length} JS file(s) in ios/App/App/public/assets/`);
    return files.map((f) => join(iosPublicPath, f));
}

/**
 * Main verification function
 */
function verify() {
    log.header('🔍 Base44 iOS Build Verification');

    let allPassed = true;
    const issues = [];

    // Step 1: Check directories
    log.header('Step 1: Directory Check');
    const distExists = checkDistExists();
    const iosExists = checkIosExists();

    if (!distExists) {
        issues.push('Run `npm run build` to create dist/');
        allPassed = false;
    }

    // Step 2: Check .env.production
    log.header('Step 2: Environment File Check');
    const envCheck = checkEnvFile();

    if (!envCheck.exists) {
        issues.push('Create .env.production with VITE_BASE44_APP_ID');
        allPassed = false;
    } else {
        log.success('.env.production file exists');

        const appId = envCheck.values.VITE_BASE44_APP_ID;
        if (!appId || appId === 'YOUR_BASE44_APP_ID') {
            log.error(`VITE_BASE44_APP_ID is ${appId ? 'placeholder' : 'missing'}`);
            issues.push('Set VITE_BASE44_APP_ID to your actual Base44 App ID');
            allPassed = false;
        } else {
            log.success(`VITE_BASE44_APP_ID is set: ${appId.substring(0, 8)}...`);
        }

        if (envCheck.values.VITE_BASE44_SERVER_URL) {
            log.success(`VITE_BASE44_SERVER_URL: ${envCheck.values.VITE_BASE44_SERVER_URL}`);
        }
        if (envCheck.values.VITE_BASE44_APP_BASE_URL) {
            log.success(`VITE_BASE44_APP_BASE_URL: ${envCheck.values.VITE_BASE44_APP_BASE_URL}`);
        }
    }

    // Step 3: Check bundle contents
    if (distExists) {
        log.header('Step 3: Bundle Content Check');
        const bundleFiles = findBundleFiles();

        if (bundleFiles.length > 0) {
            // Read the actual App ID from .env.production
            const expectedAppId = envCheck.values?.VITE_BASE44_APP_ID;

            let appIdBakedIn = false;
            let hasNullPattern = false;

            for (const filePath of bundleFiles) {
                const content = readFileSync(filePath, 'utf-8');

                // Check if the actual App ID is in the bundle
                if (expectedAppId && expectedAppId !== 'YOUR_BASE44_APP_ID') {
                    if (content.includes(expectedAppId)) {
                        appIdBakedIn = true;
                    }
                }

                // Check for the actual null pattern in API calls (not in error messages)
                // Look for patterns like: /api/apps/"+null or appId:null or similar
                const nullPatterns = [
                    /appId:\s*null/g,
                    /appId:\s*"null"/g,
                    /"appId":\s*null/g
                ];
                for (const pattern of nullPatterns) {
                    if (pattern.test(content)) {
                        hasNullPattern = true;
                    }
                }
            }

            // Report results
            if (appIdBakedIn) {
                log.success(`App ID ${expectedAppId.substring(0, 8)}... is baked into the bundle`);
            } else if (expectedAppId && expectedAppId !== 'YOUR_BASE44_APP_ID') {
                log.error(`App ID ${expectedAppId.substring(0, 8)}... NOT found in bundle - rebuild needed`);
                issues.push('App ID not found in bundle - run npm run build');
                allPassed = false;
            }

            if (hasNullPattern) {
                log.error('Bundle may contain null App ID assignments');
                issues.push('Null App ID detected in bundle');
                allPassed = false;
            } else {
                log.success('No null App ID assignments found');
            }

            // Show server URL
            const content = readFileSync(bundleFiles[0], 'utf-8');
            if (content.includes('https://abideandanchor.app')) {
                log.success('Found https://abideandanchor.app in bundle');
            }
            if (content.includes('https://base44.app')) {
                log.info('Found https://base44.app in bundle');
            }
        }
    }

    // Step 4: Check iOS synced assets
    if (iosExists) {
        log.header('Step 4: iOS Synced Assets Check');
        const iosFiles = checkIosSyncedAssets();

        if (iosFiles.length > 0) {
            const patterns = [
                {
                    name: 'Null App ID',
                    regex: /\/api\/apps\/null\//g,
                    placeholders: []
                }
            ];

            const results = searchInBundles(iosFiles, patterns);

            if (results['Null App ID'].found) {
                log.error('iOS bundle contains null App ID - run `npx cap sync ios` after fixing');
                issues.push('iOS bundle is stale - rebuild and sync');
                allPassed = false;
            } else {
                log.success('iOS bundle does not contain null App ID pattern');
            }
        }
    }

    // Final summary
    log.header('📋 Summary');

    if (allPassed) {
        log.success('All checks passed! Ready to build in Xcode.');
        console.log(`
${colors.green}Next steps:${colors.reset}
  1. Open ios/App/App.xcworkspace in Xcode
  2. Build and run on your device
  3. Check Safari Web Inspector for diagnostics
  4. Run window.diagnoseBase44Config() in console
`);
    } else {
        log.error('Some checks failed. Fix the issues below:');
        console.log('');
        issues.forEach((issue, i) => {
            console.log(`  ${colors.yellow}${i + 1}.${colors.reset} ${issue}`);
        });
        console.log(`
${colors.cyan}After fixing:${colors.reset}
  1. npm run build
  2. npx cap sync ios
  3. node scripts/verify-ios-build.js (run this again)
  4. Build in Xcode
`);
        process.exit(1);
    }
}

// Run verification
verify();
