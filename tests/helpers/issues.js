export const ISSUE_LIST = [
    {
        id: 'ISSUE-1',
        title: 'Onboarding stuck on final screen'
    },
    {
        id: 'ISSUE-2',
        title: 'onboardingStatus remains incomplete'
    },
    {
        id: 'ISSUE-3',
        title: 'User/me returns HTML instead of JSON'
    },
    {
        id: 'ISSUE-4',
        title: 'App ID is null in API requests'
    },
    {
        id: 'ISSUE-5',
        title: 'X-App-Id header is null or missing'
    },
    {
        id: 'ISSUE-6',
        title: 'Base44 HTML shell returned instead of JSON'
    },
    {
        id: 'ISSUE-7',
        title: 'Missing manifest.json'
    },
    {
        id: 'ISSUE-8',
        title: 'hasToken false on boot after login'
    },
    {
        id: 'ISSUE-9',
        title: 'Authenticated /User/me should be 200 JSON'
    },
    {
        id: 'ISSUE-10',
        title: 'App is loading indefinitely'
    },
    {
        id: 'ISSUE-11',
        title: 'Token does not persist after restart'
    },
    {
        id: 'ISSUE-12',
        title: 'Native storage not used on Capacitor'
    }
];

export const ISSUE_MAP = ISSUE_LIST.reduce((acc, issue) => {
    acc[issue.id] = issue;
    return acc;
}, {});
