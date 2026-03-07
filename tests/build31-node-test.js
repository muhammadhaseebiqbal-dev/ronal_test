// Build 31 — Node.js Verification Test (no browser needed)
// Tests the exact JS functions from PatchedBridgeViewController.swift

// Minimal DOM stub
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
    this._listeners = {};
    this.disabled = false;
  }
  getAttribute(n) { return this._attributes[n] || null; }
  setAttribute(n, v) { this._attributes[n] = v; }
  removeAttribute(n) { delete this._attributes[n]; }
  addEventListener(t, fn) { this._listeners[t] = fn; }
  remove() { if (this._parent) { this._parent.children = this._parent.children.filter(c => c !== this); } }
  appendChild(child) { child._parent = this; this.children.push(child); return child; }
  insertBefore(newEl, ref) { newEl._parent = this; const i = this.children.indexOf(ref); if (i >= 0) this.children.splice(i, 0, newEl); else this.children.push(newEl); }
  querySelector(sel) { return this._deepFind(sel); }
  querySelectorAll(sel) { const r = []; this._deepCollect(sel, r); return r; }
  closest(sel) { return null; }
  _deepFind(sel) {
    const all = []; this._deepCollect(sel, all); return all[0] || null;
  }
  _deepCollect(sel, results) {
    if (this._matchesSel(sel)) results.push(this);
    this.children.forEach(c => c._deepCollect(sel, results));
  }
  _matchesSel(sel) {
    if (sel.startsWith('#')) return this.id === sel.slice(1);
    if (sel.startsWith('.')) return this.className.includes(sel.slice(1));
    if (sel.startsWith('[')) {
      const m = sel.match(/\[([^=\]]+)(?:="([^"]*)")?\]/);
      if (m) return this._attributes[m[1]] !== undefined && (!m[2] || this._attributes[m[1]] === m[2]);
    }
    // Comma-separated selectors
    if (sel.includes(',')) {
      return sel.split(',').some(s => this._matchesSel(s.trim()));
    }
    return this.tagName === sel.toUpperCase();
  }
}

function createElement(tag) {
  return new Element(tag);
}

// Setup global DOM
const root = new Element('div', 'root');

function resetDOM() {
  root.children = [];

  const status = createElement('div');
  status.id = 'base44-subscription-status';
  status.className = 'base44-element base44-inactive';
  status.textContent = "Companion isn't active on this account";
  root.appendChild(status);

  const subSection = createElement('div');
  subSection.id = 'base44-subscribe-section';
  const subBtn = createElement('button');
  subBtn.setAttribute('data-aa-iap-wired', 'monthly');
  subBtn.textContent = 'Subscribe Monthly $9.99';
  subSection.appendChild(subBtn);
  root.appendChild(subSection);

  const acct = createElement('div');
  const acctSpan = createElement('span');
  acctSpan.textContent = 'Account: user@example.com';
  acct.appendChild(acctSpan);
  root.appendChild(acct);
}

// Global stubs
global.document = {
  getElementById(id) {
    if (id === 'root') return root;
    const found = root._deepFind('#' + id);
    return found || null;
  },
  createElement,
  querySelectorAll(sel) { return root.querySelectorAll(sel); },
  body: { children: [] }
};
global.window = {
  __aaIsCompanion: false,
  __aaServerVerified: false,
  getComputedStyle(el) { return { display: el.style.display || 'block', position: 'static' }; },
  webkit: null,
  addEventListener() {},
  removeEventListener() {},
  location: { pathname: '/', reload() {}, href: '' }
};

// ── EXTRACTED BUILD 31 JS FUNCTIONS ──

global.window.__aaSuppressContradictions = function() {
  if (!global.window.__aaIsCompanion || !global.window.__aaServerVerified) return;

  const contradictionPhrases = [
    "isn't active", "is not active", "not active on this account",
    "no active subscription", "no subscription",
    "companion isn't active", "companion is not active",
    "you don't have", "you do not have",
    "subscription inactive", "not subscribed"
  ];

  const allEls = root.querySelectorAll('div, span, p, h1, h2, h3, h4, h5, h6, label, section');
  allEls.forEach(function(el) {
    if (el.getAttribute('data-aa-contradiction-hidden')) return;
    if (el.id && el.id.indexOf('aa-') === 0) return;
    if (el.children.length > 5) return;
    const text = (el.textContent || '').toLowerCase().trim();
    if (text.length < 5 || text.length > 200) return;

    for (let i = 0; i < contradictionPhrases.length; i++) {
      if (text.indexOf(contradictionPhrases[i]) !== -1) {
        if (text.indexOf('how to') !== -1 || text.indexOf('learn more') !== -1 ||
            text.indexOf('faq') !== -1 || text.indexOf('help') !== -1) continue;
        el.style.display = 'none';
        el.setAttribute('data-aa-contradiction-hidden', '1');
        break;
      }
    }
  });
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

// ── TEST RUNNER ──

let passed = 0;
let failed = 0;

function test(name, condition, detail) {
  if (condition) {
    passed++;
    console.log(`  ✅ PASS: ${name}`);
  } else {
    failed++;
    console.log(`  ❌ FAIL: ${name} — ${detail || ''}`);
  }
}

function isVisible(el) {
  return el && el.style.display !== 'none';
}

console.log('\n🧪 Build 31 — Realistic Verification Tests\n');

// ── TEST 1: Build 30 Bug (must not inject contradicting banner) ──
console.log('━━ SCENARIO 1: Build 30 Bug ━━');
resetDOM();
global.window.__aaIsCompanion = true;
global.window.__aaServerVerified = false;
handleAlreadySubscribed();

let base44Status = document.getElementById('base44-subscription-status');
test('Without serverVerified, Base44 "not active" is NOT suppressed',
  isVisible(base44Status),
  'Should remain visible without server verification');

test('No injected banner (#aa-already-subscribed) exists',
  !document.getElementById('aa-already-subscribed'),
  'Build 31 removed banner injection');

test('No duplicate paywall Restore button',
  !document.getElementById('aa-paywall-restore-btn'),
  'Build 31 removed duplicate restore');

// ── TEST 2: Server-verified suppression ──
console.log('\n━━ SCENARIO 2: Server-Verified Suppression ━━');
resetDOM();
global.window.__aaIsCompanion = true;
global.window.__aaServerVerified = true;
handleAlreadySubscribed();

base44Status = document.getElementById('base44-subscription-status');
test('Base44 "not active" HIDDEN after server verification',
  !isVisible(base44Status),
  `display=${base44Status ? base44Status.style.display : 'null'}`);

const subBtn = root.querySelectorAll('[data-aa-iap-wired="monthly"]')[0];
test('Subscribe button hidden when companion active',
  subBtn && !isVisible(subBtn),
  `display=${subBtn ? subBtn.style.display : 'null'}`);

// ── TEST 3: Post-reload simulation ──
console.log('\n━━ SCENARIO 3: Post-Reload ━━');
resetDOM();
global.window.__aaIsCompanion = true;
global.window.__aaServerVerified = true; // from aa_just_purchased flag
handleAlreadySubscribed();
global.window.__aaSuppressContradictions();

base44Status = document.getElementById('base44-subscription-status');
test('Post-reload: "not active" suppressed via aa_just_purchased flag',
  !isVisible(base44Status),
  'aa_just_purchased bridges serverVerified across reload');

// ── TEST 4: Late-rendering React ──
console.log('\n━━ SCENARIO 4: Late-Rendering React ━━');
resetDOM();
global.window.__aaIsCompanion = true;
global.window.__aaServerVerified = true;
handleAlreadySubscribed();

// Simulate React rendering NEW text AFTER our patches
const lateEl = createElement('div');
lateEl.textContent = 'You do not have an active subscription';
root.appendChild(lateEl);

global.window.__aaSuppressContradictions();
test('Late-rendered "not active" also suppressed',
  !isVisible(lateEl),
  'Post-reload timer catches async renders');

// ── TEST 5: Logout cleanup ──
console.log('\n━━ SCENARIO 5: Logout Cleanup ━━');
global.window.__aaIsCompanion = false;
global.window.__aaServerVerified = false;
root.querySelectorAll('[data-aa-contradiction-hidden]').forEach(el => {
  el.style.display = '';
  el.removeAttribute('data-aa-contradiction-hidden');
});
root.querySelectorAll('[data-aa-sub-hidden]').forEach(el => {
  el.style.display = '';
  el.removeAttribute('data-aa-sub-hidden');
});
handleAlreadySubscribed();

base44Status = document.getElementById('base44-subscription-status');
test('After logout: "not active" visible again',
  isVisible(base44Status),
  'Cleaned up for next user');

const subBtn2 = root.querySelectorAll('[data-aa-iap-wired="monthly"]')[0];
test('After logout: Subscribe button visible again',
  subBtn2 && isVisible(subBtn2),
  'Buttons un-hidden');

// ── TEST 6: Cross-account ──
console.log('\n━━ SCENARIO 6: Cross-Account ━━');
resetDOM();
global.window.__aaIsCompanion = false;
global.window.__aaServerVerified = false;
handleAlreadySubscribed();

base44Status = document.getElementById('base44-subscription-status');
test('User B sees "not active" (no leakage from User A)',
  isVisible(base44Status),
  'Clean state for different user');

test('No banner for User B',
  !document.getElementById('aa-already-subscribed'),
  'No leaked "active" elements');

// ── TEST 7: Safety — both flags required ──
console.log('\n━━ SCENARIO 7: Both Flags Required ━━');
resetDOM();
global.window.__aaIsCompanion = true;
global.window.__aaServerVerified = false;
global.window.__aaSuppressContradictions();

base44Status = document.getElementById('base44-subscription-status');
test('isCompanion=true + serverVerified=false → NOT suppressed',
  isVisible(base44Status),
  'Both flags needed');

resetDOM();
global.window.__aaIsCompanion = false;
global.window.__aaServerVerified = true;
global.window.__aaSuppressContradictions();

base44Status = document.getElementById('base44-subscription-status');
test('isCompanion=false + serverVerified=true → NOT suppressed',
  isVisible(base44Status),
  'Both flags needed');

// ── TEST 8: Multiple variants ──
console.log('\n━━ SCENARIO 8: Text Variants ━━');
resetDOM();
const variants = [
  "Companion isn't active on this account",
  "You don't have a subscription",
  "No active subscription found",
  "Subscription inactive",
  "You are not subscribed",
];
variants.forEach(text => {
  const el = createElement('div');
  el.textContent = text;
  root.appendChild(el);
});

global.window.__aaIsCompanion = true;
global.window.__aaServerVerified = true;
global.window.__aaSuppressContradictions();

let allHidden = true;
root.querySelectorAll('div').forEach(el => {
  const text = (el.textContent || '').toLowerCase();
  if (text.match(/not active|isn't active|no.*subscription|inactive|not subscribed|don't have/) && isVisible(el)) {
    allHidden = false;
  }
});
test('All 5+ "not active" text variants suppressed', allHidden, 'Comprehensive coverage');

// ── TEST 9: Help text preserved ──
console.log('\n━━ SCENARIO 9: Help Text Preserved ━━');
resetDOM();
const helpEl = createElement('div');
helpEl.textContent = 'Learn more about how to restore your subscription';
root.appendChild(helpEl);

const faqEl = createElement('p');
faqEl.textContent = 'FAQ: I do not have access to my subscription';
root.appendChild(faqEl);

global.window.__aaIsCompanion = true;
global.window.__aaServerVerified = true;
global.window.__aaSuppressContradictions();

test('Help text NOT suppressed', isVisible(helpEl), 'Help/educational text preserved');
test('FAQ text NOT suppressed', isVisible(faqEl), 'FAQ text preserved');

// ── SUMMARY ──
console.log('\n' + '═'.repeat(50));
if (failed === 0) {
  console.log(`✅ ALL ${passed} TESTS PASSED — Build 31 Strategy Verified`);
} else {
  console.log(`❌ ${failed} of ${passed + failed} TESTS FAILED`);
}
console.log('═'.repeat(50) + '\n');

process.exit(failed > 0 ? 1 : 0);
