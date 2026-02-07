import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { getTestEnv, requireAppId } from './helpers/env.js';
import { writeIssueResults } from './helpers/reporting.js';

const env = getTestEnv();
const issueResults = {};

const recordIssues = (issueIds, status, details) => {
    issueIds.forEach((issueId) => {
        issueResults[issueId] = { status, details };
    });
};

after(() => {
    writeIssueResults('test-results/api-issues.json', issueResults);
});

if (process.env.TEST_API_SKIP === '1') {
    test('API returns JSON content-type for user/me (skipped)', () => {
        recordIssues(['ISSUE-3', 'ISSUE-6'], 'SKIPPED', 'TEST_API_SKIP=1');
    });
} else {
    test('API returns JSON content-type for user/me', async () => {
    const coveredIssues = ['ISSUE-3', 'ISSUE-6'];

    try {
        requireAppId(env);
        const url = new URL(`/api/apps/${env.appId}/entities/User/me`, env.serverUrl).toString();

        const headers = {
            'X-App-Id': env.appId,
            'Accept': 'application/json'
        };

        if (env.authToken) {
            headers.Authorization = `Bearer ${env.authToken}`;
        }

        const response = await fetch(url, { headers });
        const contentType = response.headers.get('content-type') || '';

        assert.ok(
            contentType.includes('application/json'),
            `Expected JSON content-type but got ${contentType}`
        );

        const bodyText = await response.text();
        assert.doesNotThrow(() => JSON.parse(bodyText));

        recordIssues(coveredIssues, 'PASS', 'User/me response is JSON with correct content-type.');
    } catch (error) {
        recordIssues(coveredIssues, 'FAIL', error instanceof Error ? error.message : String(error));
        throw error;
    }
    });
}
