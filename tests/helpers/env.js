import fs from 'node:fs';
import path from 'node:path';

const parseEnvFile = (filePath) => {
    if (!fs.existsSync(filePath)) return {};
    const content = fs.readFileSync(filePath, 'utf8');
    const result = {};

    for (const rawLine of content.split(/\r?\n/)) {
        const line = rawLine.trim();
        if (!line || line.startsWith('#')) continue;
        const equalsIndex = line.indexOf('=');
        if (equalsIndex === -1) continue;
        const key = line.slice(0, equalsIndex).trim();
        const value = line.slice(equalsIndex + 1).trim();
        if (!key) continue;
        result[key] = value.replace(/^"|"$/g, '').replace(/^'|'$/g, '');
    }

    return result;
};

const normaliseValue = (value) => {
    if (!value) return null;
    const trimmed = String(value).trim();
    if (!trimmed || trimmed === 'undefined' || trimmed === 'null') return null;
    return trimmed;
};

const mergeEnv = (target, source) => {
    Object.entries(source).forEach(([key, value]) => {
        if (!target[key]) {
            target[key] = value;
        }
    });
};

export const getTestEnv = () => {
    const merged = { ...process.env };
    const root = process.cwd();

    mergeEnv(merged, parseEnvFile(path.join(root, '.env.production')));
    mergeEnv(merged, parseEnvFile(path.join(root, '.env')));

    const appId = normaliseValue(merged.PLAYWRIGHT_APP_ID)
        || normaliseValue(merged.VITE_BASE44_APP_ID)
        || normaliseValue(merged.BASE44_APP_ID);

    const serverUrl = normaliseValue(merged.PLAYWRIGHT_SERVER_URL)
        || normaliseValue(merged.VITE_BASE44_SERVER_URL)
        || normaliseValue(merged.VITE_BASE44_APP_BASE_URL)
        || 'https://base44.app';

    const appBaseUrl = normaliseValue(merged.PLAYWRIGHT_APP_BASE_URL)
        || normaliseValue(merged.VITE_BASE44_APP_BASE_URL)
        || serverUrl;

    const baseUrl = normaliseValue(merged.PLAYWRIGHT_BASE_URL)
        || 'http://127.0.0.1:4173';

    const authToken = normaliseValue(merged.TEST_AUTH_TOKEN);
    const testEmail = normaliseValue(merged.TEST_EMAIL);
    const testPassword = normaliseValue(merged.TEST_PASSWORD);
    const loginMode = normaliseValue(merged.TEST_LOGIN_MODE)
        || (authToken ? 'token' : 'ui');

    return {
        baseUrl,
        appId,
        serverUrl,
        appBaseUrl,
        authToken,
        testEmail,
        testPassword,
        loginMode
    };
};

export const requireAppId = (env) => {
    if (!env.appId) {
        throw new Error('Missing appId. Set PLAYWRIGHT_APP_ID or VITE_BASE44_APP_ID.');
    }
};

export const requireAuthConfig = (env) => {
    const mode = (env.loginMode || '').toLowerCase();
    if (mode === 'token') {
        if (!env.authToken) {
            throw new Error('TEST_AUTH_TOKEN is required for token mode.');
        }
    } else if (mode === 'ui') {
        if (!env.testEmail || !env.testPassword) {
            throw new Error('TEST_EMAIL and TEST_PASSWORD are required for UI mode.');
        }
    } else {
        throw new Error(`Unsupported TEST_LOGIN_MODE: ${env.loginMode}`);
    }

    return mode;
};
