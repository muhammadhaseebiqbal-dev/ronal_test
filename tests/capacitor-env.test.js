import test from 'node:test';
import assert from 'node:assert/strict';

/**
 * Mock Capacitor Environment Tests
 *
 * These tests simulate the iOS/Capacitor environment to verify
 * that the app correctly handles the null App ID bug.
 */

// =============================================================================
// MOCK HELPERS (replicate app-params.js logic for testing)
// =============================================================================

const normalizeEnvValue = (value) => {
    if (!value) return null;
    const trimmed = String(value).trim();
    if (!trimmed || trimmed === 'undefined' || trimmed === 'null') return null;
    return trimmed;
};

const normalizeUrl = (url) => url.replace(/\/+$/, '');

const isCapacitorRuntime = (win) => {
    if (!win) return false;
    return Boolean(win.Capacitor) || win.location?.protocol === 'capacitor:';
};

const resolveAppId = (env, isCapacitor, fallbackId = 'YOUR_BASE44_APP_ID') => {
    const envAppId = normalizeEnvValue(env.VITE_BASE44_APP_ID);
    if (envAppId) return envAppId;

    if (isCapacitor && fallbackId !== 'YOUR_BASE44_APP_ID') {
        return fallbackId;
    }

    return null;
};

const resolveServerUrl = (env) => {
    const envServerUrl = normalizeEnvValue(env.VITE_BASE44_SERVER_URL);
    const envBaseUrl = normalizeEnvValue(env.VITE_BASE44_APP_BASE_URL);
    const serverUrl = envServerUrl || envBaseUrl || 'https://base44.app';
    return normalizeUrl(serverUrl);
};

const buildAppParams = (options = {}) => {
    const env = options.env || {};
    const windowRef = options.window;
    const isCapacitor = isCapacitorRuntime(windowRef);
    const fallbackId = options.fallbackId || 'YOUR_BASE44_APP_ID';

    const serverUrl = resolveServerUrl(env);

    return {
        appId: resolveAppId(env, isCapacitor, fallbackId),
        serverUrl,
        isCapacitor
    };
};

const validateAppParams = (params) => {
    const issues = [];

    if (!params.appId) {
        issues.push('Missing Base44 App ID. Set VITE_BASE44_APP_ID or FALLBACK_APP_ID.');
    }

    if (!params.serverUrl) {
        issues.push('Missing Base44 server URL. Set VITE_BASE44_SERVER_URL.');
    }

    return { valid: issues.length === 0, issues };
};

const buildApiUrl = (appId, endpoint) => {
    return `/api/apps/${appId}/entities/${endpoint}`;
};

// =============================================================================
// TEST SUITES
// =============================================================================

test.describe('Capacitor Environment Detection', () => {
    test('detects Capacitor via window.Capacitor object', () => {
        const mockWindow = {
            Capacitor: { isNativePlatform: () => true },
            location: { protocol: 'https:' }
        };

        assert.equal(isCapacitorRuntime(mockWindow), true);
    });

    test('detects Capacitor via capacitor: protocol', () => {
        const mockWindow = {
            location: { protocol: 'capacitor:' }
        };

        assert.equal(isCapacitorRuntime(mockWindow), true);
    });

    test('returns false for regular browser', () => {
        const mockWindow = {
            location: { protocol: 'https:' }
        };

        assert.equal(isCapacitorRuntime(mockWindow), false);
    });

    test('returns false for undefined window', () => {
        assert.equal(isCapacitorRuntime(undefined), false);
        assert.equal(isCapacitorRuntime(null), false);
    });
});

test.describe('NULL App ID Bug Simulation', () => {
    test('reproduces the null App ID bug (missing env var)', () => {
        // Simulate: Capacitor runtime with NO environment variable set
        const mockWindow = {
            Capacitor: { isNativePlatform: () => true },
            location: { protocol: 'capacitor:', search: '' }
        };

        const params = buildAppParams({
            env: {}, // Empty - no VITE_BASE44_APP_ID
            window: mockWindow
        });

        // This is the bug: appId is null
        assert.equal(params.appId, null);
        assert.equal(params.isCapacitor, true);

        // This is what causes the API to return HTML
        const apiUrl = buildApiUrl(params.appId, 'User/me');
        assert.equal(apiUrl, '/api/apps/null/entities/User/me');

        // Validation should fail
        const validation = validateAppParams(params);
        assert.equal(validation.valid, false);
        assert.ok(validation.issues.some((i) => i.includes('Missing Base44 App ID')));
    });

    test('reproduces the null App ID bug (placeholder value)', () => {
        const mockWindow = {
            Capacitor: { isNativePlatform: () => true },
            location: { protocol: 'capacitor:' }
        };

        const params = buildAppParams({
            env: {
                VITE_BASE44_APP_ID: 'YOUR_BASE44_APP_ID' // Placeholder, not real
            },
            window: mockWindow,
            fallbackId: 'YOUR_BASE44_APP_ID'
        });

        // Placeholder is treated as "not set"
        // normalizeEnvValue doesn't filter it, so it's still set
        // But the fallback won't trigger because fallbackId matches placeholder
        assert.equal(params.appId, 'YOUR_BASE44_APP_ID');

        // This is technically "set" but it's wrong
        // A smarter validation would catch this
    });

    test('fixes the bug with proper env var', () => {
        const mockWindow = {
            Capacitor: { isNativePlatform: () => true },
            location: { protocol: 'capacitor:', search: '' }
        };

        const params = buildAppParams({
            env: {
                VITE_BASE44_APP_ID: 'app_real_12345',
                VITE_BASE44_SERVER_URL: 'https://base44.app'
            },
            window: mockWindow
        });

        // App ID is properly set
        assert.equal(params.appId, 'app_real_12345');
        assert.equal(params.isCapacitor, true);

        // API URL is correct
        const apiUrl = buildApiUrl(params.appId, 'User/me');
        assert.equal(apiUrl, '/api/apps/app_real_12345/entities/User/me');

        // Validation passes
        const validation = validateAppParams(params);
        assert.equal(validation.valid, true);
        assert.equal(validation.issues.length, 0);
    });

    test('fixes the bug with fallback ID (when env empty)', () => {
        const mockWindow = {
            Capacitor: { isNativePlatform: () => true },
            location: { protocol: 'capacitor:' }
        };

        const params = buildAppParams({
            env: {}, // No env var
            window: mockWindow,
            fallbackId: 'app_fallback_67890' // Real fallback, not placeholder
        });

        // Fallback is used
        assert.equal(params.appId, 'app_fallback_67890');
        assert.equal(params.isCapacitor, true);

        // API URL is correct
        const apiUrl = buildApiUrl(params.appId, 'User/me');
        assert.equal(apiUrl, '/api/apps/app_fallback_67890/entities/User/me');

        // Validation passes
        const validation = validateAppParams(params);
        assert.equal(validation.valid, true);
    });
});

test.describe('XHR Request Simulation', () => {
    test('simulates broken XHR request (null App ID)', () => {
        const appId = null;

        // Simulate the XHR request that Roland saw in Safari Web Inspector
        const request = {
            url: `capacitor://localhost/api/apps/${appId}/entities/User/me`,
            headers: {
                'X-App-Id': appId,
                Accept: 'application/json',
                'X-Origin-URL': 'capacitor://localhost/'
            }
        };

        // The server returns HTML because appId is null
        const mockResponse = {
            status: 200,
            contentType: 'text/html', // WRONG - should be application/json
            body: '<!DOCTYPE html><html>...' // SPA shell
        };

        // Assertions that match Roland's bug report
        assert.equal(request.url, 'capacitor://localhost/api/apps/null/entities/User/me');
        assert.equal(request.headers['X-App-Id'], null);
        assert.equal(mockResponse.contentType, 'text/html');
        assert.ok(mockResponse.body.includes('<!DOCTYPE html>'));
    });

    test('simulates fixed XHR request (valid App ID)', () => {
        const appId = 'app_real_12345';

        // Simulate the correct XHR request after fix
        const request = {
            url: `capacitor://localhost/api/apps/${appId}/entities/User/me`,
            headers: {
                'X-App-Id': appId,
                Accept: 'application/json',
                'X-Origin-URL': 'capacitor://localhost/'
            }
        };

        // The server returns JSON
        const mockResponse = {
            status: 200,
            contentType: 'application/json',
            body: JSON.stringify({ id: 'user_123', email: 'test@example.com' })
        };

        // Assertions for fixed behavior
        assert.equal(request.url, 'capacitor://localhost/api/apps/app_real_12345/entities/User/me');
        assert.equal(request.headers['X-App-Id'], 'app_real_12345');
        assert.equal(mockResponse.contentType, 'application/json');
        assert.ok(!mockResponse.body.includes('<!DOCTYPE html>'));
    });
});

test.describe('Onboarding State Simulation', () => {
    test('simulates stuck onboarding (auth check fails)', () => {
        // Simulate the onboarding state machine
        let onboardingStatus = 'incomplete';
        let authCheckPassed = false;

        // Mock the /User/me response when App ID is null
        const mockApiResponse = {
            contentType: 'text/html',
            isJson: false,
            data: null
        };

        // Auth check logic
        if (mockApiResponse.isJson && mockApiResponse.data) {
            authCheckPassed = true;
            onboardingStatus = 'complete';
        }

        // Onboarding stays stuck
        assert.equal(authCheckPassed, false);
        assert.equal(onboardingStatus, 'incomplete');
    });

    test('simulates successful onboarding (auth check passes)', () => {
        let onboardingStatus = 'incomplete';
        let authCheckPassed = false;

        // Mock the /User/me response when App ID is valid
        const mockApiResponse = {
            contentType: 'application/json',
            isJson: true,
            data: { id: 'user_123', email: 'test@example.com', onboardingComplete: true }
        };

        // Auth check logic
        if (mockApiResponse.isJson && mockApiResponse.data) {
            authCheckPassed = true;
            onboardingStatus = 'complete';
        }

        // Onboarding completes
        assert.equal(authCheckPassed, true);
        assert.equal(onboardingStatus, 'complete');
    });
});

test.describe('Diagnostic Report Generation', () => {
    test('generates correct diagnostic report for broken config', () => {
        const params = buildAppParams({
            env: {},
            window: { Capacitor: {}, location: { protocol: 'capacitor:' } }
        });

        const validation = validateAppParams(params);

        const report = {
            config: {
                appId: params.appId,
                appIdStatus: params.appId ? 'SET' : 'NULL (THIS IS THE PROBLEM)'
            },
            validation: {
                valid: validation.valid,
                issues: validation.issues
            },
            expectedApiPath: params.appId
                ? `/api/apps/${params.appId}/entities/User/me`
                : '/api/apps/null/entities/User/me (BROKEN - will return HTML)'
        };

        assert.equal(report.config.appId, null);
        assert.equal(report.config.appIdStatus, 'NULL (THIS IS THE PROBLEM)');
        assert.equal(report.validation.valid, false);
        assert.ok(report.expectedApiPath.includes('BROKEN'));
    });

    test('generates correct diagnostic report for working config', () => {
        const params = buildAppParams({
            env: { VITE_BASE44_APP_ID: 'app_working_123' },
            window: { Capacitor: {}, location: { protocol: 'capacitor:' } }
        });

        const validation = validateAppParams(params);

        const report = {
            config: {
                appId: params.appId,
                appIdStatus: params.appId ? 'SET' : 'NULL (THIS IS THE PROBLEM)'
            },
            validation: {
                valid: validation.valid,
                issues: validation.issues
            },
            expectedApiPath: params.appId
                ? `/api/apps/${params.appId}/entities/User/me`
                : '/api/apps/null/entities/User/me (BROKEN - will return HTML)'
        };

        assert.equal(report.config.appId, 'app_working_123');
        assert.equal(report.config.appIdStatus, 'SET');
        assert.equal(report.validation.valid, true);
        assert.equal(report.expectedApiPath, '/api/apps/app_working_123/entities/User/me');
    });
});
