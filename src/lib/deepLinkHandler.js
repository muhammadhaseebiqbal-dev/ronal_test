/**
 * Deep Link Handler for OAuth Callback
 *
 * Handles the custom URL scheme `abideandanchor://` for OAuth callbacks.
 * When the user completes OAuth login in Safari, the browser redirects to:
 *   abideandanchor://auth-callback?token=THE_TOKEN
 *
 * This module captures that deep link and saves the token to Capacitor Preferences.
 */

import { App } from '@capacitor/app';
import { Browser } from '@capacitor/browser';
import { saveToken } from './tokenStorage.js';
import { isCapacitorRuntime } from './runtime.js';
import { log, error as logError, warn } from './logger.js';

/**
 * Custom URL scheme for the app.
 * Must match CFBundleURLSchemes in ios/App/App/Info.plist.
 * NOTE: This is NOT the same as ios.scheme in capacitor.config.ts (which sets the WebView origin).
 */
export const APP_URL_SCHEME = 'abideandanchor';

/**
 * Path for auth callback deep links.
 */
export const AUTH_CALLBACK_PATH = 'auth-callback';

/**
 * Builds the OAuth callback URL for native apps.
 * This URL should be used as the redirect_uri for OAuth.
 *
 * @returns {string} The deep link callback URL.
 */
export const getOAuthCallbackUrl = () => {
    return `${APP_URL_SCHEME}://${AUTH_CALLBACK_PATH}`;
};

/**
 * Parses a deep link URL and extracts the token if present.
 *
 * @param {string} url - The deep link URL.
 * @returns {{ token: string | null, isAuthCallback: boolean }}
 */
export const parseDeepLink = (url) => {
    if (!url) {
        return { token: null, isAuthCallback: false };
    }

    try {
        // Handle both URL formats:
        // - abideandanchor://auth-callback?token=...
        // - abideandanchor://auth-callback#token=...
        const urlObj = new URL(url);

        const isAuthCallback =
            urlObj.protocol === `${APP_URL_SCHEME}:` &&
            (urlObj.hostname === AUTH_CALLBACK_PATH || urlObj.pathname.includes(AUTH_CALLBACK_PATH));

        if (!isAuthCallback) {
            return { token: null, isAuthCallback: false };
        }

        // Try query params first
        let token = urlObj.searchParams.get('token') ||
            urlObj.searchParams.get('access_token') ||
            urlObj.searchParams.get('auth_token');

        // Try hash params if no token in query
        if (!token && urlObj.hash) {
            const hashParams = new URLSearchParams(urlObj.hash.slice(1));
            token = hashParams.get('token') ||
                hashParams.get('access_token') ||
                hashParams.get('auth_token');
        }

        return { token: token || null, isAuthCallback: true };
    } catch (error) {
        logError('[deepLinkHandler] Failed to parse URL:', error);
        return { token: null, isAuthCallback: false };
    }
};

/**
 * Callback type for token received events.
 * @callback TokenReceivedCallback
 * @param {string} token - The received token.
 */

/** @type {TokenReceivedCallback | null} */
let tokenCallback = null;

/** Guard against double-processing the same deep link (e.g., user taps "Open App" twice) */
let lastProcessedUrl = null;

/**
 * Sets the callback to be invoked when a token is received via deep link.
 *
 * @param {TokenReceivedCallback} callback - The callback function.
 */
export const setTokenCallback = (callback) => {
    tokenCallback = callback;
};

/**
 * Handles an incoming deep link URL.
 * If it's an auth callback with a token, saves it and triggers the callback.
 *
 * @param {string} url - The deep link URL.
 * @returns {Promise<boolean>} True if token was handled.
 */
export const handleDeepLink = async (url) => {
    log('[deepLinkHandler] deep link received');

    if (url && url === lastProcessedUrl) {
        log('[deepLinkHandler] Duplicate deep link, skipping');
        return false;
    }

    const { token, isAuthCallback } = parseDeepLink(url);

    if (!isAuthCallback) {
        log('[deepLinkHandler] Not an auth callback, ignoring');
        return false;
    }

    if (!token) {
        warn('[deepLinkHandler] Auth callback but no token found!');
        return false;
    }

    log('[deepLinkHandler] token present:', true, 'len:', token.length);

    lastProcessedUrl = url;

    const saved = await saveToken(token);
    log('[deepLinkHandler] Token save result:', saved);

    try {
        await Browser.close();
        log('[deepLinkHandler] Browser closed');
    } catch {
        // Browser might not be open, ignore
    }

    if (saved && tokenCallback) {
        log('[deepLinkHandler] Triggering token callback');
        tokenCallback(token);
    }

    return saved;
};

/**
 * Initializes the deep link listener.
 * Should be called early in app startup (e.g., in main.jsx or AuthContext).
 *
 * @param {TokenReceivedCallback} [onTokenReceived] - Optional callback for token events.
 * @returns {Promise<void>}
 */
export const initDeepLinkListener = async (onTokenReceived) => {
    if (!isCapacitorRuntime()) {
        log('[deepLinkHandler] Not in Capacitor, skipping deep link setup');
        return;
    }

    log('[deepLinkHandler] Initializing deep link listener...');

    if (onTokenReceived) {
        setTokenCallback(onTokenReceived);
    }

    App.addListener('appUrlOpen', async (event) => {
        log('[deep-link] received');
        await handleDeepLink(event.url);
    });

    try {
        const launchUrl = await App.getLaunchUrl();
        if (launchUrl?.url) {
            log('[deepLinkHandler] App launched with URL');
            await handleDeepLink(launchUrl.url);
        }
    } catch {
        log('[deepLinkHandler] No launch URL (normal cold start)');
    }

    log('[deepLinkHandler] Deep link listener initialized');
};

/**
 * Removes all deep link listeners.
 * Call this on cleanup if needed.
 */
export const removeDeepLinkListener = () => {
    App.removeAllListeners();
    tokenCallback = null;
};

/**
 * Opens the OAuth login page using SFSafariViewController (in-app browser).
 * This is required on iOS because:
 * 1. Using window.location.href navigates the WebView away
 * 2. After OAuth, the server redirects to abideandanchor://auth-callback?token=...
 * 3. SFSafariViewController can trigger the custom URL scheme → appUrlOpen fires
 * 4. If we navigate the WebView instead, the deep link won't fire (it's inside the same app)
 *
 * @param {string} loginUrl - The full OAuth login URL.
 * @returns {Promise<void>}
 */
export const openOAuthLogin = async (loginUrl) => {
    log('[deepLinkHandler] Opening OAuth in SFSafariViewController');
    try {
        await Browser.open({ url: loginUrl, presentationStyle: 'popover' });
    } catch (err) {
        logError('[deepLinkHandler] Failed to open browser, falling back to WebView:', err);
        window.location.href = loginUrl;
    }
};
