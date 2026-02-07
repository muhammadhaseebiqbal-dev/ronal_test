import test from 'node:test';
import assert from 'node:assert/strict';

/**
 * Advanced App Parameters Tests
 *
 * These tests cover edge cases and advanced scenarios for app parameter handling.
 */

/**
 * Simulates URL search params parsing
 */
const parseSearchParams = (search) => {
    const params = new Map();
    if (!search || search === '') return params;

    const queryString = search.startsWith('?') ? search.slice(1) : search;
    if (!queryString) return params;

    const pairs = queryString.split('&');
    for (const pair of pairs) {
        const [key, value] = pair.split('=');
        if (key) {
            params.set(key, decodeURIComponent(value || ''));
        }
    }
    return params;
};

/**
 * Validates environment variable values
 */
const normalizeEnvValue = (value) => {
    if (!value) return null;
    const trimmed = String(value).trim();
    if (!trimmed || trimmed === 'undefined' || trimmed === 'null') return null;
    return trimmed;
};

/**
 * Strips trailing slashes from URLs
 */
const normalizeUrl = (url) => url.replace(/\/+$/, '');

test.describe('Advanced App Parameters', () => {
    test('should parse URL search parameters correctly', async () => {
        const testCases = [
            { search: '?token=abc123', key: 'token', expected: 'abc123' },
            { search: '?token=abc&functions_version=dev', key: 'functions_version', expected: 'dev' },
            { search: '', key: 'token', expected: undefined },
            { search: '?', key: 'token', expected: undefined },
            { search: '?token=', key: 'token', expected: '' },
            { search: '?token=hello%20world', key: 'token', expected: 'hello world' }
        ];

        for (const { search, key, expected } of testCases) {
            const params = parseSearchParams(search);
            assert.equal(params.get(key), expected, `Failed for search: ${search}`);
        }
    });

    test('should normalize environment values correctly', async () => {
        const testCases = [
            { input: 'valid_value', expected: 'valid_value' },
            { input: '  trimmed  ', expected: 'trimmed' },
            { input: '', expected: null },
            { input: null, expected: null },
            { input: undefined, expected: null },
            { input: 'undefined', expected: null },
            { input: 'null', expected: null },
            { input: 123, expected: '123' },
            { input: '   ', expected: null }
        ];

        for (const { input, expected } of testCases) {
            const result = normalizeEnvValue(input);
            assert.equal(result, expected, `Failed for input: ${JSON.stringify(input)}`);
        }
    });

    test('should normalize URLs correctly', async () => {
        const testCases = [
            { input: 'https://base44.app/', expected: 'https://base44.app' },
            { input: 'https://base44.app//', expected: 'https://base44.app' },
            { input: 'https://base44.app', expected: 'https://base44.app' },
            { input: 'http://localhost:3000/', expected: 'http://localhost:3000' },
            { input: 'https://api.example.com/path/', expected: 'https://api.example.com/path' }
        ];

        for (const { input, expected } of testCases) {
            const result = normalizeUrl(input);
            assert.equal(result, expected, `Failed for input: ${input}`);
        }
    });

    test('should detect Capacitor runtime', async () => {
        // Simulate window with Capacitor object
        const capacitorWindow = {
            Capacitor: { isNativePlatform: () => true },
            location: { protocol: 'https:' }
        };

        // Simulate window with capacitor protocol
        const protocolWindow = {
            location: { protocol: 'capacitor:' }
        };

        // Simulate normal browser window
        const browserWindow = {
            location: { protocol: 'https:' }
        };

        const isCapacitorRuntime = (win) => {
            if (!win) return false;
            return Boolean(win.Capacitor) || win.location?.protocol === 'capacitor:';
        };

        assert.equal(isCapacitorRuntime(capacitorWindow), true);
        assert.equal(isCapacitorRuntime(protocolWindow), true);
        assert.equal(isCapacitorRuntime(browserWindow), false);
        assert.equal(isCapacitorRuntime(undefined), false);
        assert.equal(isCapacitorRuntime(null), false);
    });

    test('should resolve app ID with priority', async () => {
        const resolveAppId = (env, isCapacitor, fallbackId) => {
            const envAppId = normalizeEnvValue(env.VITE_BASE44_APP_ID);
            if (envAppId) return envAppId;

            if (isCapacitor && fallbackId && fallbackId !== 'YOUR_BASE44_APP_ID') {
                return fallbackId;
            }

            return null;
        };

        // Env variable takes priority
        assert.equal(
            resolveAppId({ VITE_BASE44_APP_ID: 'env_app' }, false, 'fallback'),
            'env_app'
        );

        // Fallback used in Capacitor when env is empty
        assert.equal(
            resolveAppId({}, true, 'fallback_app'),
            'fallback_app'
        );

        // Fallback ignored if placeholder value
        assert.equal(
            resolveAppId({}, true, 'YOUR_BASE44_APP_ID'),
            null
        );

        // No fallback in web mode
        assert.equal(
            resolveAppId({}, false, 'fallback_app'),
            null
        );
    });

    test('should resolve server URL with fallback chain', async () => {
        const resolveServerUrl = (env) => {
            const envServerUrl = normalizeEnvValue(env.VITE_BASE44_SERVER_URL);
            const envBaseUrl = normalizeEnvValue(env.VITE_BASE44_APP_BASE_URL);
            const serverUrl = envServerUrl || envBaseUrl || 'https://base44.app';
            return normalizeUrl(serverUrl);
        };

        // SERVER_URL takes priority
        assert.equal(
            resolveServerUrl({
                VITE_BASE44_SERVER_URL: 'https://server.example.com',
                VITE_BASE44_APP_BASE_URL: 'https://base.example.com'
            }),
            'https://server.example.com'
        );

        // APP_BASE_URL used when SERVER_URL missing
        assert.equal(
            resolveServerUrl({
                VITE_BASE44_SERVER_URL: '',
                VITE_BASE44_APP_BASE_URL: 'https://base.example.com'
            }),
            'https://base.example.com'
        );

        // Default fallback
        assert.equal(
            resolveServerUrl({}),
            'https://base44.app'
        );
    });

    test('should validate complete parameter sets', async () => {
        const validateAppParams = (params) => {
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

        // Valid params
        const validParams = {
            appId: 'app_123',
            serverUrl: 'https://base44.app',
            appBaseUrl: 'https://base44.app'
        };
        const validResult = validateAppParams(validParams);
        assert.equal(validResult.valid, true);
        assert.equal(validResult.issues.length, 0);

        // Invalid params - missing all required
        const invalidParams = {
            appId: null,
            serverUrl: '',
            appBaseUrl: ''
        };
        const invalidResult = validateAppParams(invalidParams);
        assert.equal(invalidResult.valid, false);
        assert.equal(invalidResult.issues.length, 3);

        // Partially invalid - missing one field
        const partialParams = {
            appId: 'app_123',
            serverUrl: 'https://base44.app',
            appBaseUrl: ''
        };
        const partialResult = validateAppParams(partialParams);
        assert.equal(partialResult.valid, false);
        assert.equal(partialResult.issues.length, 1);
        assert.ok(partialResult.issues[0].includes('app base URL'));
    });

    test('should handle complete app parameter building', async () => {
        const buildAppParams = ({ env = {}, window = {} }) => {
            const isCapacitor = Boolean(window.Capacitor) || window.location?.protocol === 'capacitor:';
            const searchParams = parseSearchParams(window.location?.search || '');

            const serverUrl = resolveServerUrl(env);
            const appBaseUrl = normalizeUrl(
                normalizeEnvValue(env.VITE_BASE44_APP_BASE_URL) || serverUrl || 'https://base44.app'
            );

            return {
                appId: resolveAppId(env, isCapacitor, 'YOUR_BASE44_APP_ID'),
                token: searchParams.get('token') || null,
                functionsVersion: searchParams.get('functions_version') || 'prod',
                serverUrl,
                appBaseUrl
            };
        };

        const resolveServerUrl = (env) => {
            const envServerUrl = normalizeEnvValue(env.VITE_BASE44_SERVER_URL);
            const envBaseUrl = normalizeEnvValue(env.VITE_BASE44_APP_BASE_URL);
            const serverUrl = envServerUrl || envBaseUrl || 'https://base44.app';
            return normalizeUrl(serverUrl);
        };

        const resolveAppId = (env, isCapacitor, fallbackId) => {
            const envAppId = normalizeEnvValue(env.VITE_BASE44_APP_ID);
            if (envAppId) return envAppId;
            if (isCapacitor && fallbackId !== 'YOUR_BASE44_APP_ID') return fallbackId;
            return null;
        };

        // Test complete parameter building
        const params = buildAppParams({
            env: {
                VITE_BASE44_APP_ID: 'my_app',
                VITE_BASE44_SERVER_URL: 'https://myapp.com/'
            },
            window: {
                location: {
                    search: '?token=secret123&functions_version=dev',
                    protocol: 'https:'
                }
            }
        });

        assert.equal(params.appId, 'my_app');
        assert.equal(params.token, 'secret123');
        assert.equal(params.functionsVersion, 'dev');
        assert.equal(params.serverUrl, 'https://myapp.com');
        assert.equal(params.appBaseUrl, 'https://myapp.com');
    });
});
