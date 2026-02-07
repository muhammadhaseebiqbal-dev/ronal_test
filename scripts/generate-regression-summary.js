import fs from 'node:fs';
import path from 'node:path';
import { ISSUE_LIST } from '../tests/helpers/issues.js';

const resultsDir = path.join(process.cwd(), 'test-results');
const summaryPath = path.join(resultsDir, 'summary.md');

const ensureDir = (dirPath) => {
    fs.mkdirSync(dirPath, { recursive: true });
};

const collectIssueFiles = () => {
    if (!fs.existsSync(resultsDir)) return [];
    return fs.readdirSync(resultsDir)
        .filter((file) => file.endsWith('-issues.json'))
        .map((file) => path.join(resultsDir, file));
};

const mergeIssueResults = (files) => {
    const merged = {};

    files.forEach((filePath) => {
        const content = fs.readFileSync(filePath, 'utf8');
        const data = JSON.parse(content);
        const results = data.results || {};

        Object.entries(results).forEach(([issueId, entry]) => {
            if (!merged[issueId]) {
                merged[issueId] = [];
            }
            merged[issueId].push(entry);
        });
    });

    return merged;
};

const determineStatus = (entries) => {
    if (!entries || entries.length === 0) {
        return { status: 'FAIL', details: 'No result recorded' };
    }

    const statuses = entries.map((entry) => entry.status);
    if (statuses.includes('FAIL')) {
        return { status: 'FAIL', details: entries.map((entry) => entry.details).join(' | ') };
    }

    if (statuses.includes('SKIPPED')) {
        return { status: 'SKIPPED', details: entries.map((entry) => entry.details).join(' | ') };
    }

    return { status: 'PASS', details: entries.map((entry) => entry.details).join(' | ') };
};

const buildSummary = (mergedResults) => {
    const timestamp = new Date().toISOString();
    const rows = [];

    let passCount = 0;
    let failCount = 0;
    let skipCount = 0;

    ISSUE_LIST.forEach((issue) => {
        const result = determineStatus(mergedResults[issue.id]);
        if (result.status === 'PASS') passCount += 1;
        if (result.status === 'FAIL') failCount += 1;
        if (result.status === 'SKIPPED') skipCount += 1;

        rows.push(`| ${issue.id} | ${issue.title} | ${result.status} | ${result.details} |`);
    });

    const header = [
        '# Regression Suite Summary',
        '',
        `Generated: ${timestamp}`,
        '',
        `Totals: ${passCount} pass, ${failCount} fail, ${skipCount} skipped`,
        '',
        '| Issue | Description | Status | Details |',
        '| --- | --- | --- | --- |'
    ];

    return `${header.join('\n')}\n${rows.join('\n')}\n`;
};

ensureDir(resultsDir);
const files = collectIssueFiles();
const merged = mergeIssueResults(files);
const summary = buildSummary(merged);

fs.writeFileSync(summaryPath, summary, 'utf8');
