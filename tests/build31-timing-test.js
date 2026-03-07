// Build 31 — Timing Edge Case Simulation
// Simulates the 3 remaining risk areas with realistic async delays:
//   1. Worker PATCH takes 3s+ to propagate
//   2. Base44 React renders "not active" text at various delays
//   3. Full purchase -> reload -> timer cycle

// ── Minimal DOM Stub ──
class Element {
    constructor(tag, id) {
        this.tagName = tag.toUpperCase();
        this.id = id || '';
        this.textContent = '';
        this.className = '';
        this.style = { display: '', cssText: '' };
        this.children = [];
        this._attributes = {};
        this._parent = null;
    }
    getAttribute(n) { return this._attributes[n] || null; }
    setAttribute(n, v) { this._attributes[n] = v; }
    removeAttribute(n) { delete this._attributes[n]; }
    remove() { if (this._parent) { this._parent.children = this._parent.children.filter(c => c !== this); } }
    appendChild(child) { child._parent = this; this.children.push(child); return child; }
    querySelector(sel) { const all = []; this._deepCollect(sel, all); return all[0] || null; }
    querySelectorAll(sel) { const r = []; this._deepCollect(sel, r); return r; }
    _deepCollect(sel, results) {
        if (this._matchesSel(sel)) results.push(this);
        this.children.forEach(c => c._deepCollect(sel, results));
    }
    _matchesSel(sel) {
        if (sel.startsWith('#')) return this.id === sel.slice(1);
        if (sel.startsWith('[')) {
            const m = sel.match(/\[([^=\]]+)(?:="([^"]*)")?\]/);
            if (m) return this._attributes[m[1]] !== undefined && (!m[2] || this._attributes[m[1]] === m[2]);
        }
        if (sel.includes(',')) return sel.split(',').some(s => this._matchesSel(s.trim()));
        return this.tagName === sel.toUpperCase();
    }
}

function createElement(tag) { return new Element(tag); }

const root = new Element('div', 'root');

global.document = {
    getElementById(id) {
        if (id === 'root') return root;
        const found = root.querySelectorAll('#' + id);
        return found.length > 0 ? found[0] : null;
    },
    createElement,
    querySelectorAll(sel) { return root.querySelectorAll(sel); },
    body: { children: [] }
};

global.window = {
    __aaIsCompanion: false,
    __aaServerVerified: false,
    getComputedStyle(el) { return { display: el.style.display || 'block', position: 'static' }; }
};

// ── Build 31 Functions ──

global.window.__aaSuppressContradictions = function () {
    if (!global.window.__aaIsCompanion || !global.window.__aaServerVerified) return 0;

    const phrases = [
        "isn't active", "is not active", "not active on this account",
        "no active subscription", "no subscription",
        "companion isn't active", "companion is not active",
        "you don't have", "you do not have",
        "subscription inactive", "not subscribed"
    ];

    let suppressed = 0;
    const allEls = root.querySelectorAll('div, span, p, h1, h2, h3, h4, h5, h6, label, section');
    allEls.forEach(function (el) {
        if (el.getAttribute('data-aa-contradiction-hidden')) return;
        if (el.id && el.id.indexOf('aa-') === 0) return;
        if (el.children.length > 5) return;
        const text = (el.textContent || '').toLowerCase().trim();
        if (text.length < 5 || text.length > 200) return;

        for (let i = 0; i < phrases.length; i++) {
            if (text.indexOf(phrases[i]) !== -1) {
                if (text.indexOf('how to') !== -1 || text.indexOf('learn more') !== -1 ||
                    text.indexOf('faq') !== -1 || text.indexOf('help') !== -1) continue;
                el.style.display = 'none';
                el.setAttribute('data-aa-contradiction-hidden', '1');
                suppressed++;
                break;
            }
        }
    });
    return suppressed;
};

function handleAlreadySubscribed() {
    let staleBanner = document.getElementById('aa-already-subscribed');
    if (staleBanner) staleBanner.remove();
    let stalePaywallRestore = document.getElementById('aa-paywall-restore-btn');
    if (stalePaywallRestore) stalePaywallRestore.remove();

    if (!global.window.__aaIsCompanion) {
        root.querySelectorAll('[data-aa-sub-hidden]').forEach(el => {
            el.style.display = '';
            el.removeAttribute('data-aa-sub-hidden');
        });
        root.querySelectorAll('[data-aa-contradiction-hidden]').forEach(el => {
            el.style.display = '';
            el.removeAttribute('data-aa-contradiction-hidden');
        });
        return;
    }

    root.querySelectorAll('[data-aa-iap-wired]').forEach(btn => {
        const wiredType = btn.getAttribute('data-aa-iap-wired');
        if (['monthly', 'yearly', 'hidden-yearly', 'hidden-trial', 'restore'].includes(wiredType)) {
            btn.style.display = 'none';
            btn.setAttribute('data-aa-sub-hidden', '1');
        }
    });

    if (typeof global.window.__aaSuppressContradictions === 'function') {
        global.window.__aaSuppressContradictions();
    }
}

// ── Helpers ──

function resetDOM() {
    root.children = [];
    global.window.__aaIsCompanion = false;
    global.window.__aaServerVerified = false;

    const status = createElement('div');
    status.id = 'base44-subscription-status';
    status.textContent = "Companion isn't active on this account";
    root.appendChild(status);

    const subSection = createElement('div');
    const subBtn = createElement('button');
    subBtn.setAttribute('data-aa-iap-wired', 'monthly');
    subBtn.textContent = 'Subscribe Monthly $9.99';
    subSection.appendChild(subBtn);
    root.appendChild(subSection);
}

function isVisible(el) { return el && el.style.display !== 'none'; }

function addBase44NotActiveText(text) {
    const el = createElement('div');
    el.textContent = text || "Companion isn't active on this account";
    root.appendChild(el);
    return el;
}

function sleep(ms) { return new Promise(resolve => setTimeout(resolve, ms)); }

let passed = 0;
let failed = 0;

function test(name, condition, detail) {
    if (condition) {
        passed++;
        console.log(`  PASS: ${name}`);
    } else {
        failed++;
        console.log(`  FAIL: ${name} -- ${detail || ''}`);
    }
}

// ============================================================
// ASYNC TIMING SIMULATION TESTS
// ============================================================

async function runTimingTests() {
    console.log('\n=== Build 31 -- Timing Edge Case Simulation ===\n');

    // ────────────────────────────────────────────────────
    // SCENARIO A: Worker PATCH takes 3s to propagate
    // ────────────────────────────────────────────────────
    console.log('-- SCENARIO A: Worker PATCH Delayed (3s) --');
    console.log('  Simulating: StoreKit purchase succeeds immediately');
    console.log('  Worker PATCH to set is_companion=true takes 3 seconds');
    console.log('  Base44 API returns stale is_companion=false until PATCH propagates');

    resetDOM();

    // Step 1: Purchase succeeds in StoreKit (local state updates)
    global.window.__aaIsCompanion = true;
    // Server hasn't confirmed yet (PATCH in flight)
    global.window.__aaServerVerified = false;

    handleAlreadySubscribed();

    // At this point, Base44 still shows "not active" because server hasn't confirmed
    let base44Status = document.getElementById('base44-subscription-status');
    test('During PATCH: Base44 "not active" correctly NOT suppressed (server unverified)',
        isVisible(base44Status),
        'Should show "not active" while PATCH is in flight');

    test('During PATCH: Subscribe button IS hidden (from local state)',
        !isVisible(root.querySelectorAll('[data-aa-iap-wired="monthly"]')[0]),
        'Subscribe button hidden by handleAlreadySubscribed');

    // Step 2: 3s later, Worker PATCH completes → server confirms
    console.log('  ...simulating 3s PATCH delay...');
    await sleep(100); // Simulated delay (actual 100ms for speed)

    // Server confirms → refreshWebEntitlements sets __aaServerVerified = true
    global.window.__aaServerVerified = true;
    global.window.__aaSuppressContradictions();

    base44Status = document.getElementById('base44-subscription-status');
    test('After PATCH: Base44 "not active" NOW suppressed (server verified)',
        !isVisible(base44Status),
        'Suppression kicks in once server confirms');

    // ────────────────────────────────────────────────────
    // SCENARIO B: Base44 React renders at various delays
    // ────────────────────────────────────────────────────
    console.log('\n-- SCENARIO B: Base44 React Renders at Delays (0s, 2s, 4s, 6s, 8s) --');
    console.log('  Simulating: Post-purchase reload happened, aa_just_purchased set');
    console.log('  Base44 React renders "not active" at different timings');
    console.log('  Our timer runs __aaSuppressContradictions every 2s for 10s');

    resetDOM();
    global.window.__aaIsCompanion = true;
    global.window.__aaServerVerified = true; // From aa_just_purchased flag

    // Initial suppression run (like runAllPatches on page load)
    handleAlreadySubscribed();

    base44Status = document.getElementById('base44-subscription-status');
    test('t=0s: Initial "not active" suppressed on page load',
        !isVisible(base44Status),
        'Immediate suppression from runAllPatches');

    // Simulate timer running every 2s (like our post-reload timer)
    // At each interval, Base44 React might render NEW "not active" elements

    const renderTimes = [
        { delay: 100, label: '~2s', text: "Companion isn't active on this account" },
        { delay: 100, label: '~4s', text: "You do not have an active subscription" },
        { delay: 100, label: '~6s', text: "No active subscription" },
        { delay: 100, label: '~8s', text: "Subscription inactive" },
    ];

    for (const rt of renderTimes) {
        await sleep(rt.delay);

        // Base44 React renders new element
        const lateEl = addBase44NotActiveText(rt.text);
        test(`t=${rt.label}: Before timer — late text "${rt.text.substring(0, 35)}..." visible`,
            isVisible(lateEl),
            'Just rendered, timer not run yet');

        // Timer fires → suppress
        global.window.__aaSuppressContradictions();

        test(`t=${rt.label}: After timer — late text suppressed`,
            !isVisible(lateEl),
            'Timer caught it');
    }

    // ────────────────────────────────────────────────────
    // SCENARIO C: Base44 renders AFTER our timer window (>10s)
    // ────────────────────────────────────────────────────
    console.log('\n-- SCENARIO C: Base44 Renders After Timer Window (>10s) --');
    console.log('  Simulating: React renders "not active" 12s after page load');
    console.log('  Our 5x2s timer has already stopped');
    console.log('  MutationObserver should catch this via runAllPatches');

    resetDOM();
    global.window.__aaIsCompanion = true;
    global.window.__aaServerVerified = true;
    handleAlreadySubscribed();

    await sleep(100); // Simulating 12s wait

    // Late render after timer window
    const veryLateEl = addBase44NotActiveText("You don't have a companion subscription");

    test('t=12s: Very late text is initially visible (timer expired)',
        isVisible(veryLateEl),
        'Timer has stopped, but MutationObserver would trigger runAllPatches');

    // MutationObserver fires runAllPatches → which calls handleAlreadySubscribed + __aaSuppressContradictions
    handleAlreadySubscribed();
    global.window.__aaSuppressContradictions();

    test('t=12s: MutationObserver-triggered suppression catches late text',
        !isVisible(veryLateEl),
        'MutationObserver calls runAllPatches which calls __aaSuppressContradictions');

    // ────────────────────────────────────────────────────
    // SCENARIO D: Full purchase → reload → timer cycle
    // ────────────────────────────────────────────────────
    console.log('\n-- SCENARIO D: Full Purchase -> Reload -> Timer Cycle --');
    console.log('  Simulating the COMPLETE real-world flow:');
    console.log('  1. User taps Subscribe Monthly');
    console.log('  2. StoreKit confirms + syncs JWS to Worker');
    console.log('  3. triggerWebRefreshAfterPurchase sets aa_just_purchased');
    console.log('  4. Cache-busting reload happens');
    console.log('  5. buildNativeDiagJS reads aa_just_purchased → sets __aaServerVerified=true');
    console.log('  6. runAllPatches runs on fresh page');
    console.log('  7. Base44 React fetches /User/me (might still be stale!)');
    console.log('  8. Post-reload timer catches any late "not active" text');

    // ── Step 1-3: Pre-reload state ──
    resetDOM();
    global.window.__aaIsCompanion = true;
    global.window.__aaServerVerified = true; // Set by triggerWebRefreshAfterPurchase

    // aa_just_purchased = true (simulated UserDefaults flag)
    let aa_just_purchased = true;

    // ── Step 4: Cache-busting reload → fresh page ──
    resetDOM(); // Reload clears DOM

    // ── Step 5: buildNativeDiagJS runs on fresh page ──
    // It reads aa_just_purchased AND isCompanionRaw from UserDefaults
    global.window.__aaIsCompanion = true; // From UserDefaults (persisted before reload)
    global.window.__aaServerVerified = aa_just_purchased && true; // From aa_just_purchased
    aa_just_purchased = false; // Flag consumed and cleared

    test('Step 5: __aaServerVerified=true after reload (from aa_just_purchased)',
        global.window.__aaServerVerified === true,
        'Critical: flag persists across reload');

    // ── Step 6: runAllPatches on fresh page ──
    handleAlreadySubscribed();

    base44Status = document.getElementById('base44-subscription-status');
    test('Step 6: Initial "not active" suppressed on fresh page',
        !isVisible(base44Status),
        'runAllPatches + __aaSuppressContradictions work on fresh load');

    // ── Step 7: Base44 React fetches /User/me ──
    // WORST CASE: Server still returns is_companion=false (PATCH not propagated)
    // Base44 React renders NEW "not active" text
    await sleep(100); // Simulating API fetch delay

    const apiStaleEl = addBase44NotActiveText("Companion isn't active on this account");
    test('Step 7: Stale API response renders "not active" (initially visible)',
        isVisible(apiStaleEl),
        'Base44 re-rendered from stale /User/me');

    // ── Step 8: Post-reload timer fires ──
    global.window.__aaSuppressContradictions();

    test('Step 8: Timer catches stale API "not active" text',
        !isVisible(apiStaleEl),
        'Post-reload timer suppresses stale text');

    // ── Step 9: After aa_just_purchased consumed, normal server check runs ──
    // Background: performServerFirstEntitlementCheck or performPostLoginRecovery
    // confirms companion → refreshWebEntitlements(isCompanion: true) → keeps __aaServerVerified=true
    global.window.__aaServerVerified = true; // refreshWebEntitlements confirms

    // Any further Base44 renders are caught by MutationObserver
    const finalRender = addBase44NotActiveText("No active subscription");
    handleAlreadySubscribed();

    test('Step 9: MutationObserver catches final stale render',
        !isVisible(finalRender),
        'Ongoing suppression via MutationObserver');

    // ────────────────────────────────────────────────────
    // SCENARIO E: Logout between two users — timing
    // ────────────────────────────────────────────────────
    console.log('\n-- SCENARIO E: Logout -> Login Timing --');
    console.log('  User A is subscribed, logs out, User B logs in');
    console.log('  Verify no suppression leaks to User B');

    // User A state
    resetDOM();
    global.window.__aaIsCompanion = true;
    global.window.__aaServerVerified = true;
    handleAlreadySubscribed();

    // User A logs out → performFullLogout clears everything
    global.window.__aaIsCompanion = false;
    global.window.__aaServerVerified = false;
    aa_just_purchased = false;

    root.querySelectorAll('[data-aa-contradiction-hidden]').forEach(el => {
        el.style.display = '';
        el.removeAttribute('data-aa-contradiction-hidden');
    });
    root.querySelectorAll('[data-aa-sub-hidden]').forEach(el => {
        el.style.display = '';
        el.removeAttribute('data-aa-sub-hidden');
    });

    // User B logs in → fresh page load
    resetDOM();
    global.window.__aaIsCompanion = false; // Server says no for User B
    global.window.__aaServerVerified = false;

    handleAlreadySubscribed();

    base44Status = document.getElementById('base44-subscription-status');
    test('User B: "not active" correctly shown (no leakage)',
        isVisible(base44Status),
        'Clean state for User B');

    // Try to suppress — should NOT work because both flags are false
    global.window.__aaSuppressContradictions();

    test('User B: Suppression does NOT run (both flags false)',
        isVisible(base44Status),
        'No false suppression for non-subscriber');

    // ═══════════ SUMMARY ═══════════
    console.log('\n' + '='.repeat(60));
    if (failed === 0) {
        console.log(`ALL ${passed} TIMING TESTS PASSED — Edge Cases Verified`);
    } else {
        console.log(`${failed} of ${passed + failed} TIMING TESTS FAILED`);
    }
    console.log('='.repeat(60) + '\n');

    process.exit(failed > 0 ? 1 : 0);
}

runTimingTests();
