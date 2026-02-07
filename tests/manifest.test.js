import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { writeIssueResults } from './helpers/reporting.js';

const issueResults = {};

const recordIssues = (issueIds, status, details) => {
    issueIds.forEach((issueId) => {
        issueResults[issueId] = { status, details };
    });
};

after(() => {
    writeIssueResults('test-results/unit-manifest-issues.json', issueResults);
});

test('manifest.json exists and is referenced by index.html', async () => {
    const coveredIssues = ['ISSUE-7'];

    try {
        const root = process.cwd();
        const manifestPath = path.join(root, 'public', 'manifest.json');
        const indexPath = path.join(root, 'index.html');

        assert.ok(fs.existsSync(manifestPath), 'public/manifest.json is missing');
        assert.ok(fs.existsSync(indexPath), 'index.html is missing');

        const indexHtml = fs.readFileSync(indexPath, 'utf8');
        assert.ok(
            indexHtml.includes('rel="manifest"') && indexHtml.includes('manifest.json'),
            'index.html does not reference manifest.json'
        );

        const manifestContent = fs.readFileSync(manifestPath, 'utf8');
        assert.doesNotThrow(() => JSON.parse(manifestContent));

        recordIssues(coveredIssues, 'PASS', 'manifest.json exists and is referenced.');
    } catch (error) {
        recordIssues(coveredIssues, 'FAIL', error instanceof Error ? error.message : String(error));
        throw error;
    }
});
