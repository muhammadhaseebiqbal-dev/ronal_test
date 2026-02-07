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
        console.log('[tokenStorage] No window object');
        return false;
    }

    const start = Date.now();

    // Already ready?
    if (window.Capacitor?.isNativePlatform?.()) {
        console.log('[tokenStorage] Capacitor already ready');
        return true;
    }

    // Wait for Capacitor bridge (protocol may be https: with remote URL mode)
    console.log('[tokenStorage] Waiting for Capacitor...', {
        protocol: window.location?.protocol,
        hasCapacitor: Boolean(window.Capacitor)
    });

    if (window.Capacitor) {
        while (Date.now() - start < timeout) {
            if (window.Capacitor?.isNativePlatform?.()) {
                console.log('[tokenStorage] Capacitor bridge ready after', Date.now() - start, 'ms');
                return true;
            }
            // Also check if Capacitor exists without isNativePlatform (older versions)
            if (window.Capacitor && typeof window.Capacitor.isNativePlatform !== 'function') {
                console.log('[tokenStorage] Capacitor detected (legacy mode) after', Date.now() - start, 'ms');
                return true;
            }
            await new Promise(r => setTimeout(r, 100));
        }
        console.error('[tokenStorage] Capacitor bridge TIMEOUT after', timeout, 'ms');
        console.error('[tokenStorage] window.Capacitor =', window.Capacitor);
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
            console.warn('[tokenStorage] Attempted to save null/empty token');
            return false;
        }

        const native = isNativeImpl();
        console.log('[tokenStorage] === SAVING TOKEN ===');
        console.log('[tokenStorage] isNative:', native);
        console.log('[tokenStorage] tokenLength:', token.length);
        console.log('[tokenStorage] tokenPreview:', token.substring(0, 20) + '...');

        if (native) {
            // iOS: ONLY use Capacitor Preferences
            const ready = await waitForCapacitorReady();
            if (!ready) {
                console.error('[tokenStorage] CRITICAL: Capacitor not ready, cannot save token!');
                return false;
            }

            try {
                await PreferencesImpl.set({ key: TOKEN_KEY, value: token });
                console.log('[tokenStorage] ✅ Token SAVED to Capacitor Preferences');

                // Verify it was saved
                const verify = await PreferencesImpl.get({ key: TOKEN_KEY });
                if (verify.value === token) {
                    console.log('[tokenStorage] ✅ Token verified in Preferences');
                    return true;
                } else {
                    console.error('[tokenStorage] ❌ Token verification FAILED!');
                    return false;
                }
            } catch (error) {
                console.error('[tokenStorage] ❌ Failed to save token:', error);
                return false;
            }
        } else {
            // Web: Use localStorage
            try {
                storageImpl?.setItem(TOKEN_KEY, token);
                console.log('[tokenStorage] Token saved to localStorage (web)');
                return true;
            } catch (e) {
                console.warn('[tokenStorage] localStorage save failed:', e);
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
        console.log('[tokenStorage] === LOADING TOKEN ===');
        console.log('[tokenStorage] isNative:', native);

        if (native) {
            // iOS: ONLY use Capacitor Preferences
            const ready = await waitForCapacitorReady();
            if (!ready) {
                console.error('[tokenStorage] CRITICAL: Capacitor not ready, cannot load token!');
                return null;
            }

            try {
                const { value } = await PreferencesImpl.get({ key: TOKEN_KEY });
                console.log('[tokenStorage] Preferences.get result:', {
                    hasValue: Boolean(value),
                    valueLength: value?.length || 0,
                    valuePreview: value ? value.substring(0, 20) + '...' : null
                });

                if (value) {
                    console.log('[tokenStorage] ✅ Token LOADED from Capacitor Preferences');
                    return value;
                } else {
                    console.log('[tokenStorage] No token in Capacitor Preferences');
                    return null;
                }
            } catch (error) {
                console.error('[tokenStorage] ❌ Failed to load token:', error);
                return null;
            }
        } else {
            // Web: Use localStorage
            const token = storageImpl?.getItem(TOKEN_KEY) ?? null;
            console.log('[tokenStorage] Token from localStorage:', { hasToken: Boolean(token) });
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
        console.log('[tokenStorage] === CLEARING TOKEN ===');
        console.log('[tokenStorage] isNative:', native);

        if (native) {
            const ready = await waitForCapacitorReady();
            if (ready) {
                try {
                    await PreferencesImpl.remove({ key: TOKEN_KEY });
                    console.log('[tokenStorage] Token cleared from Capacitor Preferences');
                } catch (error) {
                    console.error('[tokenStorage] Failed to clear token:', error);
                }
            }
        }

        // Also clear localStorage (for web and cleanup)
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
        let nativeToken = null;
        let nativeError = null;
        let localToken = null;
        let bridgeReady = false;

        console.log('[tokenStorage] === DIAGNOSTICS ===');

        if (native) {
            bridgeReady = await waitForCapacitorReady(2000);
            console.log('[tokenStorage] Bridge ready:', bridgeReady);

            if (bridgeReady) {
                try {
                    const result = await PreferencesImpl.get({ key: TOKEN_KEY });
                    nativeToken = result.value;
                    console.log('[tokenStorage] Native token:', nativeToken ? 'EXISTS' : 'NULL');
                } catch (e) {
                    nativeError = e.message;
                    console.error('[tokenStorage] Native error:', e);
                }
            }
        }

        try {
            localToken = storageImpl?.getItem(TOKEN_KEY);
        } catch {
            // Ignore
        }

        const report = {
            isNative: native,
            protocol: typeof window !== 'undefined' ? window.location?.protocol : 'N/A',
            capacitorExists: typeof window !== 'undefined' ? Boolean(window.Capacitor) : false,
            capacitorIsNative: typeof window !== 'undefined' ? window.Capacitor?.isNativePlatform?.() : false,
            bridgeReady,
            nativeToken: nativeToken ? `${nativeToken.substring(0, 20)}... (${nativeToken.length} chars)` : null,
            nativeError,
            localToken: localToken ? `${localToken.substring(0, 20)}... (${localToken.length} chars)` : null,
            hasToken: Boolean(nativeToken || localToken),
            recommendation: native
                ? (nativeToken ? '✅ Token in Preferences - should persist' : '❌ No token in Preferences - need to login')
                : (localToken ? '✅ Token in localStorage (web mode)' : '❌ No token - need to login')
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

// Expose diagnostic function globally
if (typeof window !== 'undefined') {
    window.diagnoseTokenStorage = diagnoseTokenStorage;
}
