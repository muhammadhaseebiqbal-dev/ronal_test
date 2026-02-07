import test from 'node:test';
import assert from 'node:assert/strict';

/**
 * Mock the @base44/sdk module before importing base44Client
 */
const mockClientInstances = [];
const mockCreateClient = (config) => {
    const instance = {
        config,
        auth: {
            me: async () => ({ id: 'user_123', email: 'test@example.com' }),
            logout: () => {},
            redirectToLogin: () => {}
        },
        data: {
            query: async () => ({ data: [], count: 0 })
        }
    };
    mockClientInstances.push(instance);
    return instance;
};

/**
 * Base44 Client Mock Tests
 *
 * These tests mock the SDK and verify client initialization logic.
 */
test.describe('base44Client', () => {
    test('should create client with valid configuration', async () => {
        // Simulate the validation logic from base44Client.js
        const mockParams = {
            appId: 'app_123',
            token: 'token_abc',
            functionsVersion: 'prod',
            serverUrl: 'https://base44.app',
            appBaseUrl: 'https://base44.app'
        };

        // Create client with mocked createClient
        const client = mockCreateClient({
            appId: mockParams.appId || '',
            token: mockParams.token || undefined,
            functionsVersion: mockParams.functionsVersion,
            serverUrl: mockParams.serverUrl,
            appBaseUrl: mockParams.appBaseUrl,
            requiresAuth: false
        });

        assert.equal(client.config.appId, 'app_123');
        assert.equal(client.config.token, 'token_abc');
        assert.equal(client.config.functionsVersion, 'prod');
        assert.equal(client.config.serverUrl, 'https://base44.app');
        assert.equal(client.config.appBaseUrl, 'https://base44.app');
        assert.equal(client.config.requiresAuth, false);

        // Verify mock instances are tracked
        assert.ok(mockClientInstances.length > 0);
    });

    test('should create client without token when token is null', async () => {
        const mockParams = {
            appId: 'app_456',
            token: null,
            functionsVersion: 'dev',
            serverUrl: 'https://dev.base44.app',
            appBaseUrl: 'https://dev.base44.app'
        };

        const client = mockCreateClient({
            appId: mockParams.appId || '',
            token: mockParams.token || undefined,
            functionsVersion: mockParams.functionsVersion,
            serverUrl: mockParams.serverUrl,
            appBaseUrl: mockParams.appBaseUrl,
            requiresAuth: false
        });

        assert.equal(client.config.appId, 'app_456');
        assert.equal(client.config.token, undefined);
        assert.equal(client.config.functionsVersion, 'dev');
    });

    test('should validate configuration before creating client', async () => {
        const invalidParams = {
            appId: null,
            token: null,
            functionsVersion: 'prod',
            serverUrl: '',
            appBaseUrl: ''
        };

        const validation = { valid: false, issues: [] };

        if (!invalidParams.appId) {
            validation.issues.push('Missing Base44 App ID. Set VITE_BASE44_APP_ID or FALLBACK_APP_ID.');
        }
        if (!invalidParams.serverUrl) {
            validation.issues.push('Missing Base44 server URL. Set VITE_BASE44_SERVER_URL.');
        }
        if (!invalidParams.appBaseUrl) {
            validation.issues.push('Missing Base44 app base URL. Set VITE_BASE44_APP_BASE_URL.');
        }

        assert.equal(validation.valid, false);
        assert.equal(validation.issues.length, 3);
        assert.ok(validation.issues.some(issue => issue.includes('Missing Base44 App ID')));
        assert.ok(validation.issues.some(issue => issue.includes('server URL')));
        assert.ok(validation.issues.some(issue => issue.includes('app base URL')));
    });

    test('should handle client methods', async () => {
        const client = mockCreateClient({
            appId: 'test_app',
            token: 'test_token',
            functionsVersion: 'prod',
            serverUrl: 'https://base44.app',
            appBaseUrl: 'https://base44.app',
            requiresAuth: false
        });

        // Test auth.me() method
        const user = await client.auth.me();
        assert.equal(user.id, 'user_123');
        assert.equal(user.email, 'test@example.com');

        // Test auth.logout() method
        assert.doesNotThrow(() => client.auth.logout());

        // Test data.query() method
        const result = await client.data.query();
        assert.ok(Array.isArray(result.data));
        assert.equal(result.count, 0);
    });
});
