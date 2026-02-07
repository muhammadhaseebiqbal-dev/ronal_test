import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { writeIssueResults } from './helpers/reporting.js';
import { createTokenStorage } from '../src/lib/tokenStorage.js';

const issueResults = {};

const recordIssues = (issueIds, status, details) => {
    issueIds.forEach((issueId) => {
        issueResults[issueId] = { status, details };
    });
};

after(() => {
    writeIssueResults('test-results/unit-token-storage-issues.json', issueResults);
});

const createLocalStorage = () => {
    const store = new Map();
    return {
        getItem: (key) => (store.has(key) ? store.get(key) : null),
        setItem: (key, value) => {
            store.set(key, String(value));
        },
        removeItem: (key) => {
            store.delete(key);
        }
    };
};

test('tokenStorage uses Capacitor Preferences when available', async () => {
    const coveredIssues = ['ISSUE-12'];

    try {
        const prefStore = new Map();
        const calls = { set: 0, get: 0, remove: 0 };

        const PreferencesImpl = {
            set: async ({ key, value }) => {
                calls.set += 1;
                prefStore.set(key, value);
            },
            get: async ({ key }) => {
                calls.get += 1;
                return { value: prefStore.get(key) ?? null };
            },
            remove: async ({ key }) => {
                calls.remove += 1;
                prefStore.delete(key);
            }
        };

        const storageImpl = createLocalStorage();

        // Setup global window mock so waitForCapacitorReady works
        global.window = {
            Capacitor: {
                isNativePlatform: () => true
            },
            location: { protocol: 'capacitor:' }
        };

        const tokenStorage = createTokenStorage({
            PreferencesImpl,
            isNativeImpl: () => true,
            storageImpl
        });

        await tokenStorage.saveToken('token-123');
        const loaded = await tokenStorage.loadToken();
        await tokenStorage.clearToken();

        // Clean up global window
        delete global.window;

        assert.equal(loaded, 'token-123');
        assert.ok(calls.set >= 1, 'Preferences.set should be called at least once');
        assert.ok(calls.get >= 1, 'Preferences.get should be called at least once');
        assert.ok(calls.remove >= 1, 'Preferences.remove should be called');

        recordIssues(coveredIssues, 'PASS', 'Preferences API used for native storage');
    } catch (error) {
        // Clean up global window on error
        if (typeof global.window !== 'undefined') {
            delete global.window;
        }
        recordIssues(coveredIssues, 'FAIL', error instanceof Error ? error.message : String(error));
        throw error;
    }
});

test('tokenStorage falls back to localStorage when not native', async () => {
    const coveredIssues = ['ISSUE-12'];

    try {
        const calls = { set: 0, get: 0, remove: 0 };

        const PreferencesImpl = {
            set: async () => {
                calls.set += 1;
            },
            get: async () => {
                calls.get += 1;
                return { value: null };
            },
            remove: async () => {
                calls.remove += 1;
            }
        };

        const storageImpl = createLocalStorage();

        const tokenStorage = createTokenStorage({
            PreferencesImpl,
            isNativeImpl: () => false,
            storageImpl
        });

        await tokenStorage.saveToken('token-456');
        const loaded = await tokenStorage.loadToken();

        assert.equal(loaded, 'token-456');
        assert.equal(calls.set, 0, 'Preferences.set should not be called on web');
        assert.equal(calls.get, 0, 'Preferences.get should not be called on web');

        recordIssues(coveredIssues, 'PASS', 'localStorage used for non-native environments.');
    } catch (error) {
        recordIssues(coveredIssues, 'FAIL', error instanceof Error ? error.message : String(error));
        throw error;
    }
});
