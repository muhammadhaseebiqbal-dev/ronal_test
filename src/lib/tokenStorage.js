/**
 * Token Storage Module for Capacitor (iOS/Android)
 *
 * CRITICAL FOR iOS: With remote URL mode (server.url), localStorage at https://
 * origin DOES persist in WKWebView. This module still provides Capacitor Preferences
 * as a robust alternative backed by iOS UserDefaults.
 *
 * Key: base44_auth_token
 */

import { Preferences } from '@capacitor/preferences';
import { isCapacitorRuntime } from './runtime.js';
import { log, error as logError, warn } from './logger.js';

const TOKEN_KEY = 'base44_auth_token';

/**
 * Check if we're running in a native Capacitor environment.
 * @returns {boolean}
 */
const isNative = () => isCapacitorRuntime();

/**
 * Wait for Capacitor to be fully ready.
 * The Capacitor bridge initializes asynchronously on iOS cold start.
 *
 * @param {number} timeout - Max wait time in ms (default 5000).
 * @returns {Promise<boolean>} True if ready, false if timeout.
 */
const waitForCapacitorReady = async (timeout = 5000) => {
    if (typeof window === 'undefined') {
        log('[tokenStorage] No window object');
        return false;
    }

    const start = Date.now();

    if (window.Capacitor?.isNativePlatform?.()) {
        log('[tokenStorage] Capacitor already ready');
        return true;
    }

    log('[tokenStorage] Waiting for Capacitor...');

    if (window.Capacitor) {
        while (Date.now() - start < timeout) {
            if (window.Capacitor?.isNativePlatform?.()) {
                log('[tokenStorage] Capacitor bridge ready after', Date.now() - start, 'ms');
                return true;
            }
            if (window.Capacitor && typeof window.Capacitor.isNativePlatform !== 'function') {
                log('[tokenStorage] Capacitor detected (legacy mode) after', Date.now() - start, 'ms');
                return true;
            }
            await new Promise(r => setTimeout(r, 100));
        }
        logError('[tokenStorage] Capacitor bridge TIMEOUT after', timeout, 'ms');
        return false;
    }

    return false;
};

/**
 * Creates a token storage instance with injectable dependencies for testing.
 */
export const createTokenStorage = ({
    PreferencesImpl = Preferences,
    isNativeImpl = isNative,
    storageImpl = typeof localStorage !== 'undefined' ? localStorage : null
} = {}) => {

    /**
     * Save auth token to persistent storage.
     * iOS: Uses Capacitor Preferences (UserDefaults) - ONLY this persists on cold restart
     * Web: Uses localStorage
     *
     * @param {string} token - The auth token to save.
     * @returns {Promise<boolean>} True if saved successfully.
     */
    const saveToken = async (token) => {
        if (!token) {
            warn('[tokenStorage] Attempted to save null/empty token');
            return false;
        }

        const native = isNativeImpl();
        log('[tokenStorage] saveToken: isNative:', native, 'len:', token.length);

        if (native) {
            const ready = await waitForCapacitorReady();
            if (!ready) {
                logError('[tokenStorage] CRITICAL: Capacitor not ready, cannot save token!');
                return false;
            }

            try {
                await PreferencesImpl.set({ key: TOKEN_KEY, value: token });
                log('[tokenStorage] ✅ Token SAVED to Capacitor Preferences');

                const verify = await PreferencesImpl.get({ key: TOKEN_KEY });
                if (verify.value === token) {
                    log('[tokenStorage] ✅ Token verified in Preferences');
                    return true;
                } else {
                    logError('[tokenStorage] ❌ Token verification FAILED!');
                    return false;
                }
            } catch (err) {
                logError('[tokenStorage] ❌ Failed to save token:', err);
                return false;
            }
        } else {
            try {
                storageImpl?.setItem(TOKEN_KEY, token);
                log('[tokenStorage] Token saved to localStorage (web)');
                return true;
            } catch (e) {
                warn('[tokenStorage] localStorage save failed:', e);
                return false;
            }
        }
    };

    /**
     * Load auth token from persistent storage.
     * iOS: Uses Capacitor Preferences (UserDefaults)
     * Web: Uses localStorage
     *
     * @returns {Promise<string | null>} The stored token or null.
     */
    const loadToken = async () => {
        const native = isNativeImpl();
        log('[tokenStorage] loadToken: isNative:', native);

        if (native) {
            const ready = await waitForCapacitorReady();
            if (!ready) {
                logError('[tokenStorage] CRITICAL: Capacitor not ready, cannot load token!');
                return null;
            }

            try {
                const { value } = await PreferencesImpl.get({ key: TOKEN_KEY });
                log('[tokenStorage] token present:', !!value, 'len:', value?.length ?? 0);
                return value || null;
            } catch (err) {
                logError('[tokenStorage] ❌ Failed to load token:', err);
                return null;
            }
        } else {
            const token = storageImpl?.getItem(TOKEN_KEY) ?? null;
            log('[tokenStorage] token present:', !!token);
            return token;
        }
    };

    /**
     * Clear auth token from persistent storage.
     *
     * @returns {Promise<void>}
     */
    const clearToken = async () => {
        const native = isNativeImpl();
        log('[tokenStorage] clearToken: isNative:', native);

        if (native) {
            const ready = await waitForCapacitorReady();
            if (ready) {
                try {
                    await PreferencesImpl.remove({ key: TOKEN_KEY });
                    log('[tokenStorage] Token cleared from Capacitor Preferences');
                } catch (err) {
                    logError('[tokenStorage] Failed to clear token:', err);
                }
            }
        }

        try {
            storageImpl?.removeItem(TOKEN_KEY);
        } catch {
            // Ignore
        }
    };

    /**
     * Check if a token exists in storage.
     *
     * @returns {Promise<boolean>}
     */
    const hasStoredToken = async () => {
        const token = await loadToken();
        return Boolean(token);
    };

    /**
     * Diagnostic function to check token storage state.
     * Call from Safari console: window.diagnoseTokenStorage()
     *
     * @returns {Promise<object>}
     */
    const diagnoseTokenStorage = async () => {
        const native = isNativeImpl();
        let hasNativeToken = false;
        let nativeError = null;
        let hasLocalToken = false;
        let bridgeReady = false;

        if (native) {
            bridgeReady = await waitForCapacitorReady(2000);
            if (bridgeReady) {
                try {
                    const result = await PreferencesImpl.get({ key: TOKEN_KEY });
                    hasNativeToken = Boolean(result.value);
                } catch (e) {
                    nativeError = e.message;
                }
            }
        }

        try {
            hasLocalToken = Boolean(storageImpl?.getItem(TOKEN_KEY));
        } catch {
            // Ignore
        }

        const report = {
            isNative: native,
            protocol: typeof window !== 'undefined' ? window.location?.protocol : 'N/A',
            bridgeReady,
            hasNativeToken,
            nativeError,
            hasLocalToken,
            hasToken: hasNativeToken || hasLocalToken,
            recommendation: native
                ? (hasNativeToken ? '✅ Token in Preferences - should persist' : '❌ No token in Preferences - need to login')
                : (hasLocalToken ? '✅ Token in localStorage (web mode)' : '❌ No token - need to login')
        };

        console.log('%c[Token Storage Diagnostics]', 'color: #007AFF; font-weight: bold;');
        console.table(report);
        return report;
    };

    return {
        saveToken,
        loadToken,
        clearToken,
        hasStoredToken,
        diagnoseTokenStorage
    };
};

const defaultStorage = createTokenStorage();

export const saveToken = defaultStorage.saveToken;
export const loadToken = defaultStorage.loadToken;
export const clearToken = defaultStorage.clearToken;
export const hasStoredToken = defaultStorage.hasStoredToken;
export const diagnoseTokenStorage = defaultStorage.diagnoseTokenStorage;

// Expose diagnostic function only in development
if (typeof window !== 'undefined' && typeof import.meta !== 'undefined' && import.meta.env?.DEV) {
    window.diagnoseTokenStorage = diagnoseTokenStorage;
}
