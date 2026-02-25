/**
 * Cloudflare Worker — Companion Subscription Validator (Build 11)
 *
 * Validates Apple StoreKit 2 JWS signed transactions server-side,
 * then updates the user's companion status on Base44 so any device
 * (including desktop browsers) can check subscription state.
 *
 * Endpoints:
 *   POST /validate-receipt  — { jws, authToken } → validates JWS, updates Base44 user
 *   GET  /check-companion   — Authorization header → reads user's companion status
 */

const BASE44_APP_ID = '69586539f13402a151c12aa3';
const BASE44_API_BASE = `https://base44.app/api/apps/${BASE44_APP_ID}`;
const EXPECTED_BUNDLE_ID = 'com.abideandanchor.app';

const COMPANION_PRODUCT_IDS = new Set([
  'com.abideandanchor.companion.monthly',
  'com.abideandanchor.companion.yearly',
]);

// Apple's JWKS endpoint for StoreKit 2 signed transactions
const APPLE_JWKS_URL = 'https://appleid.apple.com/auth/keys';

// Cache Apple JWKS for 1 hour
let cachedJWKS = null;
let jwksCachedAt = 0;
const JWKS_CACHE_TTL = 3600_000;

// ── CORS helpers ──

function corsHeaders(origin) {
  return {
    'Access-Control-Allow-Origin': origin || '*',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization',
    'Access-Control-Max-Age': '86400',
  };
}

function jsonResponse(data, status = 200, origin) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      'Content-Type': 'application/json',
      ...corsHeaders(origin),
    },
  });
}

// ── Apple JWKS fetching + JWS verification ──

async function fetchAppleJWKS() {
  const now = Date.now();
  if (cachedJWKS && now - jwksCachedAt < JWKS_CACHE_TTL) {
    return cachedJWKS;
  }
  const res = await fetch(APPLE_JWKS_URL);
  if (!res.ok) throw new Error(`Failed to fetch Apple JWKS: ${res.status}`);
  cachedJWKS = await res.json();
  jwksCachedAt = now;
  return cachedJWKS;
}

function base64urlDecode(str) {
  str = str.replace(/-/g, '+').replace(/_/g, '/');
  while (str.length % 4 !== 0) str += '=';
  const binary = atob(str);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

async function verifyAppleJWS(jws) {
  const parts = jws.split('.');
  if (parts.length !== 3) throw new Error('Invalid JWS format');

  const headerJson = JSON.parse(new TextDecoder().decode(base64urlDecode(parts[0])));
  const kid = headerJson.kid;
  const alg = headerJson.alg;

  if (!kid) throw new Error('JWS header missing kid');

  // Fetch Apple's public keys
  const jwks = await fetchAppleJWKS();
  const key = jwks.keys.find((k) => k.kid === kid);
  if (!key) throw new Error(`No matching Apple key for kid: ${kid}`);

  // Import the public key for verification
  const algMap = {
    ES256: { name: 'ECDSA', namedCurve: 'P-256', hash: 'SHA-256' },
    RS256: { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
  };

  const algConfig = algMap[alg];
  if (!algConfig) throw new Error(`Unsupported algorithm: ${alg}`);

  const importAlg =
    alg === 'ES256'
      ? { name: algConfig.name, namedCurve: algConfig.namedCurve }
      : { name: algConfig.name, hash: algConfig.hash };

  const cryptoKey = await crypto.subtle.importKey('jwk', key, importAlg, false, ['verify']);

  // Verify signature
  const signedData = new TextEncoder().encode(`${parts[0]}.${parts[1]}`);
  let signature = base64urlDecode(parts[2]);

  // For ECDSA, the JWS signature is in raw r||s format, which is what WebCrypto expects
  const verifyAlg =
    alg === 'ES256' ? { name: 'ECDSA', hash: 'SHA-256' } : { name: 'RSASSA-PKCS1-v1_5' };

  const valid = await crypto.subtle.verify(verifyAlg, cryptoKey, signature, signedData);

  if (!valid) throw new Error('JWS signature verification failed');

  // Decode payload
  const payload = JSON.parse(new TextDecoder().decode(base64urlDecode(parts[1])));
  return payload;
}

// ── Base44 API helpers ──

async function getBase44User(authToken) {
  const res = await fetch(`${BASE44_API_BASE}/auth/me`, {
    headers: { Authorization: `Bearer ${authToken}` },
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Base44 /auth/me failed (${res.status}): ${text}`);
  }
  return res.json();
}

async function updateBase44User(userId, data, authToken) {
  const res = await fetch(`${BASE44_API_BASE}/entities/Users/${userId}`, {
    method: 'PATCH',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${authToken}`,
    },
    body: JSON.stringify(data),
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Base44 PATCH user failed (${res.status}): ${text}`);
  }
  return res.json();
}

// ── POST /validate-receipt ──

async function handleValidateReceipt(request, origin) {
  let body;
  try {
    body = await request.json();
  } catch {
    return jsonResponse({ error: 'Invalid JSON body' }, 400, origin);
  }

  const { jws, authToken } = body;
  if (!jws || !authToken) {
    return jsonResponse({ error: 'Missing jws or authToken' }, 400, origin);
  }

  // 1. Verify JWS with Apple's public keys
  let payload;
  try {
    payload = await verifyAppleJWS(jws);
  } catch (err) {
    return jsonResponse({ error: `JWS verification failed: ${err.message}` }, 401, origin);
  }

  // 2. Extract transaction details
  const productId = payload.productId || payload.productID;
  const expirationDate = payload.expiresDate || payload.expirationDate;
  const revocationDate = payload.revocationDate;
  const environment = payload.environment;
  const bundleId = payload.bundleId || payload.bid || payload.appBundleId || null;

  // Reject receipts that do not belong to this app bundle.
  // This prevents accepting a valid Apple-signed transaction from a different app.
  if (!bundleId || bundleId !== EXPECTED_BUNDLE_ID) {
    return jsonResponse(
      {
        error: `Invalid bundleId: ${bundleId || 'missing'}`,
      },
      400,
      origin
    );
  }

  // Reject if not a companion product
  if (!COMPANION_PRODUCT_IDS.has(productId)) {
    return jsonResponse({ error: `Unknown product: ${productId}` }, 400, origin);
  }

  // Reject if revoked
  if (revocationDate) {
    return jsonResponse(
      { isCompanion: false, reason: 'Subscription revoked', productId },
      200,
      origin
    );
  }

  // Reject if expired
  if (expirationDate) {
    const expMs = typeof expirationDate === 'number' ? expirationDate : Date.parse(expirationDate);
    if (expMs < Date.now()) {
      return jsonResponse(
        { isCompanion: false, reason: 'Subscription expired', productId, expiresAt: new Date(expMs).toISOString() },
        200,
        origin
      );
    }
  }

  // 3. Get Base44 user
  let user;
  try {
    user = await getBase44User(authToken);
  } catch (err) {
    return jsonResponse({ error: `Auth failed: ${err.message}` }, 401, origin);
  }

  const userId = user._id || user.id;
  if (!userId) {
    return jsonResponse({ error: 'Could not determine user ID' }, 500, origin);
  }

  // 4. Update user's companion status on Base44
  const expiresAt = expirationDate
    ? new Date(typeof expirationDate === 'number' ? expirationDate : Date.parse(expirationDate)).toISOString()
    : null;

  try {
    await updateBase44User(
      userId,
      {
        is_companion: true,
        companion_product_id: productId,
        companion_expires_at: expiresAt,
        companion_environment: environment || 'Production',
      },
      authToken
    );
  } catch (err) {
    // Log but don't fail — local unlock still works
    console.error('Base44 update failed:', err.message);
    return jsonResponse(
      {
        isCompanion: true,
        productId,
        expiresAt,
        warning: 'Local unlock succeeded but server update failed',
      },
      200,
      origin
    );
  }

  return jsonResponse({ isCompanion: true, productId, expiresAt }, 200, origin);
}

// ── GET /check-companion ──

async function handleCheckCompanion(request, origin) {
  const authHeader = request.headers.get('Authorization');
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return jsonResponse({ error: 'Missing Authorization header' }, 401, origin);
  }

  const authToken = authHeader.slice(7);

  let user;
  try {
    user = await getBase44User(authToken);
  } catch (err) {
    return jsonResponse({ error: `Auth failed: ${err.message}` }, 401, origin);
  }

  const isCompanion = user.is_companion === true;
  const expiresAt = user.companion_expires_at || null;

  // NOTE (Build 16): This endpoint is READ-ONLY. It never writes is_companion: false.
  // Reason: companion_expires_at is from the INITIAL purchase JWS. StoreKit 2
  // auto-renews subscriptions on-device, creating new transactions that are NOT
  // re-posted to this Worker. So companion_expires_at becomes stale after the first
  // renewal period. Checking expiry here and deactivating the subscription would
  // void active auto-renewed subscriptions.
  //
  // Proper deactivation should happen via:
  // 1. Apple Server-to-Server Notifications V2 (DID_CHANGE_RENEWAL_STATUS, EXPIRED, REVOKE)
  // 2. The iOS app's Transaction.updates listener posting a fresh JWS on revocation/expiry
  // 3. Manual admin action
  //
  // The expiry date is returned for informational/diagnostic purposes only.

  return jsonResponse(
    {
      isCompanion,
      expiresAt,
      productId: user.companion_product_id || null,
    },
    200,
    origin
  );
}

// ── Request router ──

export default {
  async fetch(request) {
    const url = new URL(request.url);
    const origin = request.headers.get('Origin') || '*';

    // Handle CORS preflight
    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: corsHeaders(origin) });
    }

    try {
      if (url.pathname === '/validate-receipt' && request.method === 'POST') {
        return await handleValidateReceipt(request, origin);
      }

      if (url.pathname === '/check-companion' && request.method === 'GET') {
        return await handleCheckCompanion(request, origin);
      }

      return jsonResponse({ error: 'Not found' }, 404, origin);
    } catch (err) {
      console.error('Unhandled error:', err);
      return jsonResponse({ error: 'Internal server error' }, 500, origin);
    }
  },
};
