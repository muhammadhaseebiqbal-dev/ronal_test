import { test, expect } from '@playwright/test';
import { getTestEnv, requireAppId, requireAuthConfig } from '../helpers/env.js';
import { writeIssueResults } from '../helpers/reporting.js';

const env = getTestEnv();
const issueResults = {} as Record<string, { status: string; details: string }>;
const hasAuthConfig = Boolean(env.authToken || (env.testEmail && env.testPassword));
const authSkipReason = 'Missing TEST_AUTH_TOKEN or TEST_EMAIL/TEST_PASSWORD';

const recordIssues = (issueIds: string[], status: string, details: string) => {
    issueIds.forEach((issueId) => {
        issueResults[issueId] = { status, details };
    });
};

test.afterAll(() => {
    writeIssueResults('test-results/e2e-issues.json', issueResults);
});

test('Unauthenticated boot does not hang and uses valid app configuration', async ({ page }) => {
    const coveredIssues = [
        'ISSUE-1',
        'ISSUE-2',
        'ISSUE-3',
        'ISSUE-4',
        'ISSUE-5',
        'ISSUE-6',
        'ISSUE-10'
    ];

    try {
        requireAppId(env);

        const requestProblems: string[] = [];
        const expectedAppId = env.appId;

        page.on('request', (request) => {
            const url = request.url();
            if (!url.includes('/api/apps/')) return;

            if (url.includes('/api/apps/null') || url.includes('/api/apps/undefined')) {
                requestProblems.push(`Null appId in request URL: ${url}`);
                return;
            }

            const match = url.match(/\/api\/apps\/([^/]+)/);
            const appIdFromUrl = match?.[1];

            if (!appIdFromUrl || appIdFromUrl === 'null' || appIdFromUrl === 'undefined') {
                requestProblems.push(`Missing appId in request URL: ${url}`);
            }

            if (expectedAppId && appIdFromUrl && appIdFromUrl !== expectedAppId) {
                requestProblems.push(`Unexpected appId in request URL: ${appIdFromUrl}`);
            }

            const headers = request.headers();
            const xAppId = headers['x-app-id'];
            if (!xAppId || xAppId === 'null' || xAppId === 'undefined') {
                requestProblems.push(`Missing X-App-Id header for ${url}`);
            }

            if (expectedAppId && xAppId && xAppId !== expectedAppId) {
                requestProblems.push(`Unexpected X-App-Id header: ${xAppId}`);
            }
        });

        await page.goto(env.baseUrl, { waitUntil: 'domcontentloaded' });

        const loadingIndicator = page.getByText(/Loading token from storage|Checking authentication|App is loading/i);
        await expect(loadingIndicator).toBeHidden({ timeout: 15_000 });

        const userMeResponse = await page.waitForResponse((response) => (
            response.url().includes('/entities/User/me')
        ), { timeout: 15_000 });

        const contentType = userMeResponse.headers()['content-type'] || '';
        if (!contentType.includes('application/json')) {
            throw new Error(`User/me returned non-JSON content-type: ${contentType}`);
        }

        const responseBody = await userMeResponse.text();
        try {
            JSON.parse(responseBody);
        } catch (error) {
            throw new Error('User/me response body is not valid JSON');
        }

        if (requestProblems.length > 0) {
            throw new Error(requestProblems.join('\n'));
        }

        recordIssues(coveredIssues, 'PASS', 'Boot completed, JSON response verified, appId/header validated.');
    } catch (error) {
        recordIssues(coveredIssues, 'FAIL', error instanceof Error ? error.message : String(error));
        throw error;
    }
});

if (!hasAuthConfig) {
    test('Authenticated session returns 200 JSON and persists after restart (skipped)', async () => {
        recordIssues(['ISSUE-8', 'ISSUE-9', 'ISSUE-11'], 'SKIPPED', authSkipReason);
    });
} else {
    test('Authenticated session returns 200 JSON and persists after restart', async ({ browser }) => {
    const coveredIssues = [
        'ISSUE-8',
        'ISSUE-9',
        'ISSUE-11'
    ];

    try {
        requireAppId(env);
        const authMode = requireAuthConfig(env);

        const storageStatePath = test.info().outputPath('storageState.json');

        const context = await browser.newContext();

        if (authMode === 'token') {
            await context.addInitScript((token) => {
                window.localStorage.setItem('base44_auth_token', token);
            }, env.authToken as string);
        }

        const page = await context.newPage();
        await page.goto(env.baseUrl, { waitUntil: 'domcontentloaded' });

        if (authMode === 'ui') {
            const loginButton = page.getByRole('button', { name: /log in/i });
            await expect(loginButton).toBeVisible({ timeout: 15_000 });
            await loginButton.click();

            const popup = await Promise.race([
                page.waitForEvent('popup', { timeout: 5_000 }).catch(() => null),
                page.waitForTimeout(5_000).then(() => null)
            ]);

            const authPage = popup ?? page;
            await authPage.waitForLoadState('domcontentloaded');

            const emailInput = authPage.locator('input[type="email"], input[name="email"], input[placeholder*="Email" i]');
            const passwordInput = authPage.locator('input[type="password"], input[name="password"], input[placeholder*="Password" i]');

            if (await emailInput.count() === 0 || await passwordInput.count() === 0) {
                throw new Error('Login form not detected. Use TEST_AUTH_TOKEN for token mode.');
            }

            await emailInput.first().fill(env.testEmail as string);
            await passwordInput.first().fill(env.testPassword as string);

            const submitButton = authPage.locator('button[type="submit"], button:has-text("Log In"), button:has-text("Sign In")');
            await submitButton.first().click();

            if (popup) {
                await popup.waitForEvent('close', { timeout: 15_000 }).catch(() => null);
            }
        }

        const userMeResponse = await page.waitForResponse((response) => (
            response.url().includes('/entities/User/me')
        ), { timeout: 20_000 });

        const contentType = userMeResponse.headers()['content-type'] || '';
        if (!contentType.includes('application/json')) {
            throw new Error(`Authenticated user/me returned non-JSON content-type: ${contentType}`);
        }

        const bodyText = await userMeResponse.text();
        try {
            JSON.parse(bodyText);
        } catch (error) {
            throw new Error('Authenticated user/me response body is not valid JSON');
        }

        if (userMeResponse.status() !== 200) {
            throw new Error(`Authenticated user/me returned ${userMeResponse.status()}`);
        }

        await expect(page.getByText(/Authenticated!/i)).toBeVisible({ timeout: 15_000 });
        await expect(page.getByText(/hasToken: true/i)).toBeVisible({ timeout: 15_000 });

        await context.storageState({ path: storageStatePath });
        await context.close();

        const restoredContext = await browser.newContext({ storageState: storageStatePath });
        const restoredPage = await restoredContext.newPage();
        await restoredPage.goto(env.baseUrl, { waitUntil: 'domcontentloaded' });

        await expect(restoredPage.getByText(/hasToken: true/i)).toBeVisible({ timeout: 15_000 });
        await expect(restoredPage.getByText(/Authenticated!/i)).toBeVisible({ timeout: 15_000 });

        await restoredContext.close();

        recordIssues(coveredIssues, 'PASS', 'Authenticated session persisted and returned 200 JSON.');
    } catch (error) {
        recordIssues(coveredIssues, 'FAIL', error instanceof Error ? error.message : String(error));
        throw error;
    }
    });
}
