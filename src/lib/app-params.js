/**
 * App Parameters Configuration
 *
 * Centralizes Base44 app configuration with safe defaults and validation.
 * For iOS/Capacitor builds, Vite environment variables are baked in at build time.
 */

import { isCapacitorRuntime } from './runtime.js';
import { log, warn, error as logError } from './logger.js';

// =============================================================================
// CONFIGURATION - Update these values for your Base44 app
// =============================================================================

// PRODUCTION: Roland's Base44 App ID (from live site network call)
// This serves as a fallback if env vars fail to bake into the iOS build
const FALLBACK_APP_ID = '69586539f13402a151c12aa3';

// PRODUCTION: Roland's custom domain
// Verified working endpoint: https://abideandanchor.app/api/apps/69586539f13402a151c12aa3/entities/User/me
const DEFAULT_SERVER_URL = 'https://abideandanchor.app';

/**
 * Default Base44 app base URL for login redirects.
 */
const DEFAULT_APP_BASE_URL = DEFAULT_SERVER_URL;

// =============================================================================
// INTERNAL HELPERS
// =============================================================================

/**
 * Normalizes environment values by filtering out empty and placeholder values.
 *
 * @param {string | undefined | null} value - Raw environment value.
 * @returns {string | null} Normalized value or null.
 */
const normalizeEnvValue = (value) => {
    if (!value) return null;
    const trimmed = String(value).trim();
    if (!trimmed || trimmed === 'undefined' || trimmed === 'null') return null;
    return trimmed;
};

/**
 * Returns the Vite environment map if available.
 *
 * @returns {Record<string, string | undefined>} Vite environment map.
 */
const getViteEnv = () => {
    if (typeof import.meta !== 'undefined' && import.meta.env) {
        return import.meta.env;
    }
    return {};
};

/**
 * Strips trailing slashes from URLs for consistent concatenation.
 *
 * @param {string} url - URL to normalize.
 * @returns {string} Normalized URL.
 */
const normalizeUrl = (url) => url.replace(/\/+$/, '');

export { isCapacitorRuntime };

const TOKEN_PARAM_KEYS = ['token', 'access_token', 'auth_token', 'id_token'];

const normalizeTokenValue = (value) => {
    if (!value) return null;
    const trimmed = String(value).trim();
    return trimmed ? trimmed : null;
};

const looksLikeQueryString = (value) => {
    if (!value) return false;
    return value.includes('=') || value.includes('&');
};

const getTokenFromParams = (params) => {
    for (const key of TOKEN_PARAM_KEYS) {
        const value = normalizeTokenValue(params.get(key));
        if (value) return value;
    }
    return null;
};

const getParamsFromHash = (hash) => {
    if (!hash) return new URLSearchParams();
    const trimmed = hash.startsWith('#') ? hash.slice(1) : hash;
    if (!trimmed) return new URLSearchParams();

    if (trimmed.includes('?')) {
        const query = trimmed.slice(trimmed.indexOf('?') + 1);
        return new URLSearchParams(query);
    }

    if (!looksLikeQueryString(trimmed)) {
        return new URLSearchParams();
    }

    return new URLSearchParams(trimmed);
};

const stripTokenFromHash = (hash) => {
    if (!hash) return '';
    const trimmed = hash.startsWith('#') ? hash.slice(1) : hash;
    if (!trimmed) return '';

    if (trimmed.includes('?')) {
        const index = trimmed.indexOf('?');
        const prefix = trimmed.slice(0, index);
        const query = trimmed.slice(index + 1);
        const params = new URLSearchParams(query);
        TOKEN_PARAM_KEYS.forEach((key) => params.delete(key));
        const newQuery = params.toString();
        return `#${prefix}${newQuery ? `?${newQuery}` : ''}`;
    }

    if (!looksLikeQueryString(trimmed)) {
        return `#${trimmed}`;
    }

    const params = new URLSearchParams(trimmed);
    TOKEN_PARAM_KEYS.forEach((key) => params.delete(key));
    const newQuery = params.toString();
    return newQuery ? `#${newQuery}` : '';
};

/**
 * Resolves the Base44 App ID using env-first, then fallback (Capacitor only).
 *
 * @param {Record<string, string | undefined>} env - Environment map.
 * @param {boolean} isCapacitor - Whether running in Capacitor.
 * @returns {string | null} Resolved app ID.
 */
export const resolveAppId = (env, isCapacitor) => {
    const envAppId = normalizeEnvValue(env.VITE_BASE44_APP_ID);
    if (envAppId) return envAppId;

    if (isCapacitor && FALLBACK_APP_ID !== 'YOUR_BASE44_APP_ID') {
        warn('[app-params] Using fallback App ID for Capacitor build.');
        return FALLBACK_APP_ID;
    }

    return null;
};

/**
 * Resolves the Base44 server URL for API calls.
 *
 * @param {Record<string, string | undefined>} env - Environment map.
 * @returns {string} Resolved server URL.
 */
export const resolveServerUrl = (env) => {
    const envServerUrl = normalizeEnvValue(env.VITE_BASE44_SERVER_URL);
    const envBaseUrl = normalizeEnvValue(env.VITE_BASE44_APP_BASE_URL);
    const serverUrl = envServerUrl || envBaseUrl || DEFAULT_SERVER_URL;
    return normalizeUrl(serverUrl);
};

/**
 * Resolves the Base44 app base URL for auth redirects.
 *
 * @param {Record<string, string | undefined>} env - Environment map.
 * @param {string} serverUrl - Resolved server URL.
 * @returns {string} Resolved app base URL.
 */
export const resolveAppBaseUrl = (env, serverUrl) => {
    const envAppBaseUrl = normalizeEnvValue(env.VITE_BASE44_APP_BASE_URL);
    const appBaseUrl = envAppBaseUrl || serverUrl || DEFAULT_APP_BASE_URL;
    return normalizeUrl(appBaseUrl);
};

/**
 * Reads the auth token from URL search or hash parameters.
 * Supports common OAuth keys like token/access_token/auth_token/id_token.
 *
 * @param {Window | undefined} win - Window object (optional for testing).
 * @returns {string | null} Auth token.
 */
export const getTokenFromLocation = (win) => {
    const windowRef = win || (typeof window !== 'undefined' ? window : undefined);
    if (!windowRef) return null;

    const searchParams = new URLSearchParams(windowRef.location.search || '');
    const searchToken = getTokenFromParams(searchParams);
    if (searchToken) return searchToken;

    const hashParams = getParamsFromHash(windowRef.location.hash || '');
    const hashToken = getTokenFromParams(hashParams);
    if (hashToken) return hashToken;

    return null;
};

/**
 * Removes auth tokens from URL search and hash parameters.
 * Intended for cleaning OAuth callback URLs after persisting tokens.
 *
 * @param {Window | undefined} win - Window object (optional for testing).
 */
export const clearTokenFromLocation = (win) => {
    const windowRef = win || (typeof window !== 'undefined' ? window : undefined);
    if (!windowRef) return;

    const cleanUrl = new URL(windowRef.location.href);
    TOKEN_PARAM_KEYS.forEach((key) => cleanUrl.searchParams.delete(key));

    if (cleanUrl.hash) {
        cleanUrl.hash = stripTokenFromHash(cleanUrl.hash);
    }

    windowRef.history.replaceState({}, '', cleanUrl.toString());
};

/**
 * Reads the auth token from URL or localStorage.
 * URL token takes priority (for OAuth callback), localStorage for persistence.
 *
 * @param {Window | undefined} win - Window object (optional for testing).
 * @returns {string | null} Auth token.
 */
export const getTokenFromUrl = (win) => {
    const token = getTokenFromLocation(win);
    if (token) {
        log('[app-params] token present in URL:', true);
        return token;
    }

    try {
        const storedToken = localStorage.getItem('base44_auth_token');
        if (storedToken) {
            log('[app-params] token present in localStorage:', true);
            return storedToken;
        }
    } catch {
        // localStorage not available
    }

    return null;
};

/**
 * Reads the functions version from URL query parameters.
 *
 * @param {Window | undefined} win - Window object (optional for testing).
 * @returns {string} Functions version string.
 */
export const getFunctionsVersionFromUrl = (win) => {
    const windowRef = win || (typeof window !== 'undefined' ? window : undefined);
    if (!windowRef) return 'prod';
    const urlParams = new URLSearchParams(windowRef.location.search);
    return urlParams.get('functions_version') || 'prod';
};

/**
 * Builds the app parameters object.
 *
 * @param {{ env?: Record<string, string | undefined>, window?: Window }} options - Build options.
 * @returns {{
 *  appId: string | null,
 *  token: string | null,
 *  functionsVersion: string,
 *  serverUrl: string,
 *  appBaseUrl: string
 * }} App parameters.
 */
export const buildAppParams = (options = {}) => {
    const env = options.env || getViteEnv();
    const windowRef = options.window;
    const isCapacitor = isCapacitorRuntime(windowRef);

    const serverUrl = resolveServerUrl(env);
    const appBaseUrl = resolveAppBaseUrl(env, serverUrl);

    return {
        appId: resolveAppId(env, isCapacitor),
        token: getTokenFromUrl(windowRef),
        functionsVersion: getFunctionsVersionFromUrl(windowRef),
        serverUrl,
        appBaseUrl
    };
};

/**
 * Validates the required app parameters.
 *
 * @param {{ appId: string | null, serverUrl: string, appBaseUrl: string }} params - App params.
 * @returns {{ valid: boolean, issues: string[] }} Validation result.
 */
export const validateAppParams = (params) => {
    const issues = [];

    if (!params.appId) {
        issues.push('Missing Base44 App ID. Set VITE_BASE44_APP_ID or FALLBACK_APP_ID.');
    }

    if (!params.serverUrl) {
        issues.push('Missing Base44 server URL. Set VITE_BASE44_SERVER_URL.');
    }

    if (!params.appBaseUrl) {
        issues.push('Missing Base44 app base URL. Set VITE_BASE44_APP_BASE_URL.');
    }

    return { valid: issues.length === 0, issues };
};

// =============================================================================
// PUBLIC EXPORT
// =============================================================================

/**
 * Exported app parameters used by the Base44 client and auth flow.
 */
export const appParams = buildAppParams();

// =============================================================================
// SAFARI WEB INSPECTOR DIAGNOSTICS
// =============================================================================

/**
 * Generates a comprehensive diagnostic report for Safari Web Inspector.
 * Call this from the console: window.diagnoseBase44Config()
 *
 * @returns {{ config: object, validation: object, environment: object }} Diagnostic report.
 */
export const generateDiagnosticReport = () => {
    const env = getViteEnv();
    const validation = validateAppParams(appParams);

    const report = {
        timestamp: new Date().toISOString(),
        config: {
            appId: appParams.appId,
            appIdStatus: appParams.appId ? 'SET' : 'NULL (THIS IS THE PROBLEM)',
            serverUrl: appParams.serverUrl,
            appBaseUrl: appParams.appBaseUrl,
            hasToken: Boolean(appParams.token),
            functionsVersion: appParams.functionsVersion
        },
        validation: {
            valid: validation.valid,
            issues: validation.issues
        },
        environment: {
            isCapacitor: isCapacitorRuntime(),
            protocol: typeof window !== 'undefined' ? window.location.protocol : 'N/A',
            userAgent: typeof navigator !== 'undefined' ? navigator.userAgent : 'N/A',
            viteEnvKeys: Object.keys(env).filter((k) => k.startsWith('VITE_')),
            rawViteAppId: env.VITE_BASE44_APP_ID || 'NOT SET',
            rawViteServerUrl: env.VITE_BASE44_SERVER_URL || 'NOT SET',
            rawViteAppBaseUrl: env.VITE_BASE44_APP_BASE_URL || 'NOT SET'
        },
        expectedApiPath: appParams.appId
            ? `/api/apps/${appParams.appId}/entities/User/me`
            : '/api/apps/null/entities/User/me (BROKEN - will return HTML)',
        fix: validation.valid
            ? 'Configuration looks good!'
            : [
                '1. Set VITE_BASE44_APP_ID in .env.production',
                '2. Run: npm run build',
                '3. Run: npx cap sync ios',
                '4. Rebuild in Xcode'
            ]
    };

    return report;
};

/**
 * Prints diagnostic report to console in a readable format.
 * Designed for Safari Web Inspector.
 */
export const printDiagnostics = () => {
    const report = generateDiagnosticReport();

    console.group('%c[Base44 Diagnostics]', 'color: #007AFF; font-weight: bold; font-size: 14px;');

    console.log('%cTimestamp:', 'font-weight: bold;', report.timestamp);

    console.group('%cConfiguration', 'color: #34C759; font-weight: bold;');
    console.table(report.config);
    console.groupEnd();

    console.group('%cValidation', report.validation.valid ? 'color: #34C759;' : 'color: #FF3B30; font-weight: bold;');
    console.log('Valid:', report.validation.valid);
    if (report.validation.issues.length > 0) {
        console.warn('Issues:', report.validation.issues);
    }
    console.groupEnd();

    console.group('%cEnvironment', 'color: #5856D6; font-weight: bold;');
    console.table(report.environment);
    console.groupEnd();

    console.log('%cExpected API Path:', 'font-weight: bold;', report.expectedApiPath);

    if (!report.validation.valid) {
        console.group('%cFIX REQUIRED', 'color: #FF3B30; font-weight: bold; font-size: 12px;');
        report.fix.forEach((step) => console.log(step));
        console.groupEnd();
    }

    console.groupEnd();

    return report;
};

// Expose diagnostics only in development
if (typeof window !== 'undefined' && typeof import.meta !== 'undefined' && import.meta.env?.DEV) {
    window.diagnoseBase44Config = printDiagnostics;
    window.getBase44Report = generateDiagnosticReport;
}

// Configuration logging (dev only)
if (typeof import.meta !== 'undefined' && import.meta.env?.DEV) {
    const validation = validateAppParams(appParams);
    log('[app-params] Configuration loaded:', {
        appId: appParams.appId ? `${appParams.appId.substring(0, 8)}...` : 'NULL',
        serverUrl: appParams.serverUrl,
        hasToken: Boolean(appParams.token),
        valid: validation.valid
    });

    if (!validation.valid) {
        logError('[app-params] Configuration issues:', validation.issues);
    }
}
