import test from 'node:test';
import assert from 'node:assert/strict';
import { buildAppParams, validateAppParams } from '../src/lib/app-params.js';

const createWindow = (search, protocol = 'https:', hash = '') => ({
    location: {
        search,
        protocol,
        hash
    }
});

test('buildAppParams uses env values and parses URL params', () => {
    const params = buildAppParams({
        env: {
            VITE_BASE44_APP_ID: 'app_123',
            VITE_BASE44_SERVER_URL: 'https://base44.app',
            VITE_BASE44_APP_BASE_URL: 'https://base44.app'
        },
        window: createWindow('?token=abc&functions_version=dev')
    });

    assert.equal(params.appId, 'app_123');
    assert.equal(params.token, 'abc');
    assert.equal(params.functionsVersion, 'dev');
    assert.equal(params.serverUrl, 'https://base44.app');
    assert.equal(params.appBaseUrl, 'https://base44.app');
});

test('buildAppParams reports missing appId when env is empty', () => {
    const params = buildAppParams({
        env: {},
        window: createWindow('')
    });

    const validation = validateAppParams(params);
    assert.equal(validation.valid, false);
    assert.ok(validation.issues.some((issue) => issue.includes('Missing Base44 App ID')));
});

test('buildAppParams parses token from hash fragments and alternate keys', () => {
    const env = {
        VITE_BASE44_APP_ID: 'app_123',
        VITE_BASE44_SERVER_URL: 'https://base44.app',
        VITE_BASE44_APP_BASE_URL: 'https://base44.app'
    };

    const hashParams = buildAppParams({
        env,
        window: createWindow('', 'https:', '#access_token=hash_token_123')
    });

    const hashWithPath = buildAppParams({
        env,
        window: createWindow('', 'https:', '#/callback?auth_token=hash_token_456')
    });

    const queryAlt = buildAppParams({
        env,
        window: createWindow('?access_token=query_token_789')
    });

    assert.equal(hashParams.token, 'hash_token_123');
    assert.equal(hashWithPath.token, 'hash_token_456');
    assert.equal(queryAlt.token, 'query_token_789');
});
