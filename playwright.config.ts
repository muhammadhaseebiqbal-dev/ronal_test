import { defineConfig } from '@playwright/test';
import { getTestEnv } from './tests/helpers/env.js';

const env = getTestEnv();
const baseURL = env.baseUrl;
const shouldStartServer = !process.env.PLAYWRIGHT_BASE_URL;

export default defineConfig({
    testDir: 'tests/e2e',
    timeout: 60_000,
    expect: {
        timeout: 15_000
    },
    retries: process.env.CI ? 1 : 0,
    workers: 1,
    use: {
        baseURL,
        trace: 'retain-on-failure',
        screenshot: 'only-on-failure',
        video: 'retain-on-failure'
    },
    reporter: [
        ['list'],
        ['html', { outputFolder: 'test-results/playwright-report', open: 'never' }],
        ['json', { outputFile: 'test-results/playwright-results.json' }]
    ],
    webServer: shouldStartServer
        ? {
            command: 'npm run preview -- --host 127.0.0.1 --port 4173',
            url: baseURL,
            reuseExistingServer: !process.env.CI,
            timeout: 120_000
        }
        : undefined
});
