import https from 'https';

const ENDPOINTS = [
    { name: 'Base44 Server (App Info)', url: 'https://base44.app/api/apps/69586539f13402a151c12aa3', method: 'GET' },
    { name: 'Base44 Auth Check', url: 'https://base44.app/api/auth/me', method: 'GET' },
    { name: 'Cloudflare Worker (Check)', url: 'https://companion-validator.abideandanchor.workers.dev/check-companion', method: 'POST' },
    { name: 'Cloudflare Worker (Validate)', url: 'https://companion-validator.abideandanchor.workers.dev/validate-receipt', method: 'POST' }
];

console.log('================================================');
console.log('🚀 BASE44 API ENDPOINT TESTER 🚀');
console.log('================================================\n');

async function testEndpoint({ name, url, method }) {
    console.log(`Testing [${name}]`);
    console.log(`→ ${method} ${url}`);

    return new Promise((resolve) => {
        const start = Date.now();
        const req = https.request(url, { method, headers: { 'Content-Type': 'application/json' } }, (res) => {
            const ms = Date.now() - start;
            const statusColor = res.statusCode >= 200 && res.statusCode < 400 ? '\x1b[32m' : (res.statusCode === 404 ? '\x1b[31m' : '\x1b[33m');
            console.log(`← ${statusColor}${res.statusCode} ${res.statusMessage}\x1b[0m (${ms}ms)`);
            resolve(true);
        });

        req.on('error', (e) => {
            console.log(`← \x1b[31mERROR: ${e.message}\x1b[0m`);
            resolve(false);
        });

        if (method === 'POST') {
            req.write('{}');
        }

        req.end();
    });
}

async function runTests() {
    let passed = 0;
    for (const endpoint of ENDPOINTS) {
        const success = await testEndpoint(endpoint);
        if (success) passed++;
        console.log('------------------------------------------------');
    }

    console.log(`\n✅ Finished testing ${ENDPOINTS.length} endpoints.`);
    console.log(passed === ENDPOINTS.length ? '\x1b[32mAll endpoints reachable.\x1b[0m' : '\x1b[31mSome endpoints failed.\x1b[0m');
}

runTests();
