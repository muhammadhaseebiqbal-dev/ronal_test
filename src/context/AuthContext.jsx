import { createContext, useState, useContext, useEffect, useCallback } from 'react';
import { createAxiosClient } from '@base44/sdk/dist/utils/axios-client';
import { base44 } from '@/api/base44Client';
import {
    appParams,
    validateAppParams,
    isCapacitorRuntime,
    getTokenFromLocation,
    clearTokenFromLocation
} from '@/lib/app-params';
import { saveToken, loadToken, clearToken } from '@/lib/tokenStorage';
import { initDeepLinkListener, getOAuthCallbackUrl, openOAuthLogin } from '@/lib/deepLinkHandler';
import { log, error as logError } from '@/lib/logger';

const AuthContext = createContext();

/**
 * Builds the Base44 public settings base URL.
 *
 * @param {string} serverUrl - Base44 server URL.
 * @returns {string} Public settings base URL.
 */
const buildPublicBaseUrl = (serverUrl) => {
    return new URL('/api/apps/public', serverUrl).toString();
};

/**
 * Auth provider for the app with native token persistence.
 *
 * @param {{ children: React.ReactNode }} props - Provider props.
 * @returns {JSX.Element} Auth context provider.
 */
export const AuthProvider = ({ children }) => {
    const [user, setUser] = useState(null);
    const [isAuthenticated, setIsAuthenticated] = useState(false);
    const [isLoadingAuth, setIsLoadingAuth] = useState(true);
    const [isLoadingPublicSettings, setIsLoadingPublicSettings] = useState(true);
    const [authError, setAuthError] = useState(null);
    const [appPublicSettings, setAppPublicSettings] = useState(null);
    const [currentToken, setCurrentToken] = useState(null);
    const [isTokenLoaded, setIsTokenLoaded] = useState(false);

    // Token version counter — prevents race condition where an expired token's
    // 401/403 handler clears a newer token that arrived via deep link.
    const [tokenVersion, setTokenVersion] = useState(0);

    // Step 1: Initialize deep link listener and load token on mount
    useEffect(() => {
        // Set up deep link listener for OAuth callback (iOS)
        if (isCapacitorRuntime()) {
            initDeepLinkListener(handleDeepLinkToken);
        }
        initializeAuth();
    }, []);

    /**
     * Handle token received via deep link (OAuth callback on iOS).
     * @param {string} token - The received token.
     */
    const handleDeepLinkToken = async (token) => {
        log('[AuthContext] token received via deep link, len:', token.length);

        setTokenVersion(v => v + 1);

        setCurrentToken(token);
        appParams.token = token;
        base44.setToken(token, !isCapacitorRuntime());

        await checkUserAuthWithToken(token);
    };

    /**
     * Initialize auth by loading token from native storage first.
     * Includes proper error handling and logging for iOS debugging.
     */
    const initializeAuth = async () => {
        const t = localStorage.getItem('base44_access_token') || localStorage.getItem('token') || localStorage.getItem('base44_auth_token');
        log('[app-params] hasToken:', !!t);
        log('[AuthContext] isCapacitor:', isCapacitorRuntime());

        try {
            let token = null;

            const urlToken = getTokenFromLocation(window);

            if (urlToken) {
                log('[AuthContext] token present in URL:', true, 'len:', urlToken.length);
                token = urlToken;

                const saved = await saveToken(token);
                log('[AuthContext] Token save result:', saved);

                clearTokenFromLocation(window);
            } else {
                log('[auth] restoring token');
                token = await loadToken();
                log('[auth] token restored:', !!token);
            }

            setCurrentToken(token);
            setTokenVersion(v => v + 1);
            appParams.token = token || null;

            if (token) {
                base44.setToken(token, !isCapacitorRuntime());
            }

            log('[app-params] hasToken:', Boolean(token));
            log('[AuthContext] hasToken:', Boolean(token));

            await checkAppStateWithToken(token);
        } catch (error) {
            logError('[AuthContext] Init error:', error);
            setAuthError({
                type: 'init_error',
                message: error.message || 'Failed to initialize authentication'
            });
            setIsLoadingPublicSettings(false);
            setIsLoadingAuth(false);
        } finally {
            setIsTokenLoaded(true);
        }
    };

    /**
     * Validates configuration and checks the app and auth state.
     * @param {string | null} token - The auth token to use.
     */
    const checkAppStateWithToken = async (token) => {
        const validation = validateAppParams(appParams);
        if (!validation.valid) {
            setAuthError({
                type: 'config_missing',
                message: validation.issues.join(' ')
            });
            setIsLoadingPublicSettings(false);
            setIsLoadingAuth(false);
            return;
        }

        try {
            setIsLoadingPublicSettings(true);
            setAuthError(null);

            const publicBaseUrl = buildPublicBaseUrl(appParams.serverUrl);

            const appClient = createAxiosClient({
                baseURL: publicBaseUrl,
                headers: {
                    'X-App-Id': appParams.appId
                },
                token: token,
                interceptResponses: true
            });

            try {
                const publicSettings = await appClient.get(`/prod/public-settings/by-id/${appParams.appId}`);
                setAppPublicSettings(publicSettings);

                // If we have a token, check if user is authenticated
                if (token) {
                    await checkUserAuthWithToken(token);
                } else {
                    log('[AuthContext] No token available, user needs to login');
                    setIsLoadingAuth(false);
                    setIsAuthenticated(false);
                }
                setIsLoadingPublicSettings(false);
            } catch (appError) {
                logError('[AuthContext] App state check failed:', appError);
                handleAppError(appError);
            }
        } catch (error) {
            logError('[AuthContext] Unexpected error:', error);
            setAuthError({
                type: 'unknown',
                message: error.message || 'An unexpected error occurred'
            });
            setIsLoadingPublicSettings(false);
            setIsLoadingAuth(false);
        }
    };

    /**
     * Handle app-level errors.
     */
    const handleAppError = (appError) => {
        if (appError.status === 403 && appError.data?.extra_data?.reason) {
            const reason = appError.data.extra_data.reason;
            if (reason === 'auth_required') {
                setAuthError({
                    type: 'auth_required',
                    message: 'Authentication required'
                });
            } else if (reason === 'user_not_registered') {
                setAuthError({
                    type: 'user_not_registered',
                    message: 'User not registered for this app'
                });
            } else {
                setAuthError({
                    type: reason,
                    message: appError.message
                });
            }
        } else {
            setAuthError({
                type: 'unknown',
                message: appError.message || 'Failed to load app'
            });
        }
        setIsLoadingPublicSettings(false);
        setIsLoadingAuth(false);
    };

    /**
     * Checks the current user authentication state.
     * @param {string} token - The auth token.
     */
    const checkUserAuthWithToken = async (token) => {
        const versionAtStart = tokenVersion;
        try {
            setIsLoadingAuth(true);
            log('[AuthContext] Checking user auth...');

            base44.setToken(token, !isCapacitorRuntime());

            const currentUser = await base44.auth.me();
            log('[auth] /User/me status:', 200);
            log('[AuthContext] User authenticated:', { userId: currentUser?.id });

            setUser(currentUser);
            setIsAuthenticated(true);
            setIsLoadingAuth(false);
        } catch (error) {
            const status = error.status || error.response?.status || 'unknown';
            log('[auth] /User/me status:', status);
            logError('[AuthContext] User auth check failed:', error);
            setIsLoadingAuth(false);
            setIsAuthenticated(false);

            if (error.status === 401 || error.status === 403) {
                if (tokenVersion !== versionAtStart) {
                    log('[AuthContext] Token was updated during auth check — skipping clear (race guard)');
                    return;
                }
                log('[AuthContext] Token appears expired, clearing storage');
                await clearToken();
                setCurrentToken(null);
                appParams.token = null;
                setAuthError({
                    type: 'auth_required',
                    message: 'Session expired. Please log in again.'
                });
            }
        }
    };

    /**
     * Legacy check function for compatibility.
     */
    const checkAppState = useCallback(async () => {
        await checkAppStateWithToken(currentToken);
    }, [currentToken]);

    /**
     * Logs the user out and clears stored token.
     *
     * @param {boolean} shouldRedirect - Whether to redirect to login.
     */
    const logout = async (shouldRedirect = true) => {
        log('[AuthContext] Logging out...');
        setUser(null);
        setIsAuthenticated(false);
        setCurrentToken(null);
        appParams.token = null;

        // Clear token from native storage
        await clearToken();

        if (shouldRedirect) {
            base44.auth.logout(window.location.href);
        } else {
            base44.auth.logout();
        }
    };

    /**
     * Redirects the user to the login page.
     * For iOS native apps, opens OAuth in SFSafariViewController via @capacitor/browser.
     * This ensures the deep link redirect (abideandanchor://auth-callback?token=...)
     * triggers appUrlOpen correctly, since it comes from OUTSIDE the WebView.
     */
    const navigateToLogin = () => {
        if (isCapacitorRuntime()) {
            // iOS: Build login URL manually and open in SFSafariViewController
            const callbackUrl = getOAuthCallbackUrl();
            const encodedCallback = encodeURIComponent(callbackUrl);
            const loginUrl = `${appParams.appBaseUrl}/login?from_url=${encodedCallback}`;
            log('[AuthContext] Opening OAuth in SFSafariViewController');
            openOAuthLogin(loginUrl);
        } else {
            // Web: Use SDK's redirectToLogin (navigates in same window)
            base44.auth.redirectToLogin(window.location.href);
        }
    };

    // Log current state for debugging (dev only)
    useEffect(() => {
        if (isCapacitorRuntime()) {
            log('[AuthContext] State update:', {
                isTokenLoaded,
                hasToken: Boolean(currentToken),
                isLoadingAuth,
                isAuthenticated,
                hasUser: Boolean(user),
                authError: authError?.type
            });
        }
    }, [isTokenLoaded, currentToken, isLoadingAuth, isAuthenticated, user, authError]);

    return (
        <AuthContext.Provider
            value={{
                user,
                isAuthenticated,
                isLoadingAuth,
                isLoadingPublicSettings,
                authError,
                appPublicSettings,
                logout,
                navigateToLogin,
                checkAppState,
                hasToken: Boolean(currentToken),
                isTokenLoaded
            }}
        >
            {children}
        </AuthContext.Provider>
    );
};

/**
 * Access the auth context.
 *
 * @returns {object} Auth context value.
 */
export const useAuth = () => {
    const context = useContext(AuthContext);
    if (!context) {
        throw new Error('useAuth must be used within an AuthProvider');
    }
    return context;
};
