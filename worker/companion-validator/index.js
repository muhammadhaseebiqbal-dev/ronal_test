/**
 * Cloudflare Worker — Companion Subscription Validator
 *
 * Validates Apple StoreKit 2 JWS signed transactions server-side
 * using x5c certificate chain verification (Apple's official method),
 * then updates the user's companion status on Base44.
 *
 * Security: Verifies the full Apple certificate chain —
 *   leaf → intermediate → Apple Root CA G3 — then uses the leaf
 *   certificate's public key to verify the JWS signature.
 *   Also checks Apple-specific OIDs, certificate dates, bundle ID,
 *   product allowlist, revocation, and expiry.
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
]);

// Apple Root CA - G3 (from https://www.apple.com/certificateauthority/AppleRootCA-G3.cer)
// Subject: CN=Apple Root CA - G3, OU=Apple Certification Authority, O=Apple Inc., C=US
// Key: ECDSA P-384 | Signature: ecdsa-with-SHA384 | Expires: 2039-04-30
// SHA-256 fingerprint (lowercase hex, no colons):
const APPLE_ROOT_CA_G3_SHA256 =
  '63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179';

// Apple OID: 1.2.840.113635.100.6.11.1 (leaf cert — App Store receipt signing)
const APPLE_LEAF_OID_BYTES = new Uint8Array([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x06, 0x0b, 0x01]);
// Apple OID: 1.2.840.113635.100.6.2.1 (intermediate cert — Apple intermediate)
const APPLE_INTERMEDIATE_OID_BYTES = new Uint8Array([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x06, 0x02, 0x01]);

// EC curve OID bytes for key type detection
const P256_OID_BYTES = new Uint8Array([0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07]); // prime256v1
const P384_OID_BYTES = new Uint8Array([0x2b, 0x81, 0x04, 0x00, 0x22]); // secp384r1

// ── CORS helpers ──

const ALLOWED_ORIGINS = new Set([
  'https://abideandanchor.app',
  'capacitor://localhost',    // iOS WKWebView
  'http://localhost',         // local dev
  'http://localhost:5173',    // Vite dev server
]);

function corsHeaders(origin) {
  const allowedOrigin = ALLOWED_ORIGINS.has(origin) ? origin : 'https://abideandanchor.app';
  return {
    'Access-Control-Allow-Origin': allowedOrigin,
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization',
    'Access-Control-Max-Age': '86400',
    Vary: 'Origin',
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

// ── Base64 helpers ──

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

function base64Decode(str) {
  const binary = atob(str);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

// ── ASN.1 DER parsing (minimal — just enough for X.509 certificate parsing) ──

/**
 * Parse a single DER element at the given offset.
 * Returns { tag, headerLength, contentLength, totalLength, contentOffset }.
 */
function parseDER(bytes, offset) {
  const tag = bytes[offset];
  let pos = offset + 1;
  let contentLength;
  const firstLenByte = bytes[pos];
  if (firstLenByte < 0x80) {
    contentLength = firstLenByte;
    pos += 1;
  } else {
    const numLenBytes = firstLenByte & 0x7f;
    contentLength = 0;
    for (let i = 0; i < numLenBytes; i++) {
      contentLength = (contentLength << 8) | bytes[pos + 1 + i];
    }
    pos += 1 + numLenBytes;
  }
  return {
    tag,
    headerLength: pos - offset,
    contentLength,
    totalLength: pos - offset + contentLength,
    contentOffset: pos,
  };
}

/**
 * Parse the children of a constructed DER element (SEQUENCE, SET, etc.)
 */
function parseDERChildren(bytes, contentOffset, contentLength) {
  const children = [];
  let pos = contentOffset;
  const end = contentOffset + contentLength;
  while (pos < end) {
    const elem = parseDER(bytes, pos);
    children.push({ ...elem, offset: pos });
    pos += elem.totalLength;
  }
  return children;
}

/**
 * Parse an ASN.1 time value (UTCTime tag 0x17 or GeneralizedTime tag 0x18)
 */
function parseDERTime(bytes, element) {
  const raw = new TextDecoder().decode(
    bytes.slice(element.contentOffset, element.contentOffset + element.contentLength)
  );
  if (element.tag === 0x17) {
    // UTCTime: YYMMDDHHMMSSZ — 2-digit year (00-49 → 2000s, 50-99 → 1900s)
    let year = parseInt(raw.substring(0, 2), 10);
    year += year < 50 ? 2000 : 1900;
    const month = raw.substring(2, 4);
    const day = raw.substring(4, 6);
    const hour = raw.substring(6, 8);
    const min = raw.substring(8, 10);
    const sec = raw.substring(10, 12);
    return new Date(`${year}-${month}-${day}T${hour}:${min}:${sec}Z`);
  }
  // GeneralizedTime: YYYYMMDDHHMMSSZ
  const year = raw.substring(0, 4);
  const month = raw.substring(4, 6);
  const day = raw.substring(6, 8);
  const hour = raw.substring(8, 10);
  const min = raw.substring(10, 12);
  const sec = raw.substring(12, 14);
  return new Date(`${year}-${month}-${day}T${hour}:${min}:${sec}Z`);
}

// ── X.509 certificate parsing ──

/**
 * Parse an X.509 certificate from DER bytes.
 * Extracts: tbsBytes (signed data), signatureBytes, spkiBytes, notBefore, notAfter.
 *
 * Certificate ::= SEQUENCE {
 *   tbsCertificate       TBSCertificate,
 *   signatureAlgorithm   AlgorithmIdentifier,
 *   signatureValue       BIT STRING
 * }
 * TBSCertificate ::= SEQUENCE {
 *   version         [0] EXPLICIT Version OPTIONAL,
 *   serialNumber    INTEGER,
 *   signature       AlgorithmIdentifier,
 *   issuer          Name,
 *   validity        Validity,
 *   subject         Name,
 *   subjectPKInfo   SubjectPublicKeyInfo,  <-- what we need
 *   ...extensions...
 * }
 */
function parseCertificate(derBytes) {
  const cert = parseDER(derBytes, 0);
  const certChildren = parseDERChildren(derBytes, cert.contentOffset, cert.contentLength);
  if (certChildren.length < 3) throw new Error('Invalid certificate: expected 3 top-level elements');

  const tbsElement = certChildren[0];
  const sigValueElement = certChildren[2];

  // Raw TBSCertificate bytes — this is the data that was signed
  const tbsBytes = derBytes.slice(tbsElement.offset, tbsElement.offset + tbsElement.totalLength);

  // Signature value (BIT STRING — first byte is unused bits count, skip it)
  const sigContent = derBytes.slice(
    sigValueElement.contentOffset,
    sigValueElement.contentOffset + sigValueElement.contentLength
  );
  const signatureBytes = sigContent.slice(1);

  // Parse TBSCertificate children to find SubjectPublicKeyInfo
  const tbsChildren = parseDERChildren(derBytes, tbsElement.contentOffset, tbsElement.contentLength);

  // Version field is optional, tagged [0] explicit (tag byte 0xA0)
  const hasVersion = tbsChildren[0].tag === 0xa0;
  // With version: [0]version, serial, sigAlg, issuer, validity, subject, spki, ...
  // Without:      serial, sigAlg, issuer, validity, subject, spki, ...
  const spkiIndex = hasVersion ? 6 : 5;
  const validityIndex = hasVersion ? 4 : 3;

  if (spkiIndex >= tbsChildren.length) {
    throw new Error('SubjectPublicKeyInfo not found in certificate');
  }

  const spkiElement = tbsChildren[spkiIndex];
  const spkiBytes = derBytes.slice(spkiElement.offset, spkiElement.offset + spkiElement.totalLength);

  // Parse validity dates
  const validityElement = tbsChildren[validityIndex];
  const validityChildren = parseDERChildren(
    derBytes,
    validityElement.contentOffset,
    validityElement.contentLength
  );
  const notBefore = parseDERTime(derBytes, validityChildren[0]);
  const notAfter = parseDERTime(derBytes, validityChildren[1]);

  return { tbsBytes, signatureBytes, spkiBytes, notBefore, notAfter };
}

/**
 * Check if DER bytes contain a structurally valid OID element (tag 0x06 + length + value).
 * Searches for the triple 0x06 <len> <oidValueBytes> rather than raw byte patterns,
 * preventing false positives from coincidental byte sequences in other fields.
 */
function containsOIDBytes(bytes, oidValueBytes) {
  const oidTag = 0x06;
  const oidLen = oidValueBytes.length;
  // Need at least tag + length + value bytes remaining
  for (let i = 0; i <= bytes.length - oidLen - 2; i++) {
    if (bytes[i] === oidTag && bytes[i + 1] === oidLen) {
      let match = true;
      for (let j = 0; j < oidLen; j++) {
        if (bytes[i + 2 + j] !== oidValueBytes[j]) {
          match = false;
          break;
        }
      }
      if (match) return true;
    }
  }
  return false;
}

/**
 * Detect the EC curve from SPKI bytes by searching for known curve OIDs.
 */
function detectCurve(spkiBytes) {
  if (containsOIDBytes(spkiBytes, P256_OID_BYTES)) return 'P-256';
  if (containsOIDBytes(spkiBytes, P384_OID_BYTES)) return 'P-384';
  throw new Error('Unsupported EC curve in certificate SPKI');
}

/**
 * Import a SubjectPublicKeyInfo as a CryptoKey for ECDSA verification.
 */
async function importSPKI(spkiBytes, namedCurve) {
  return crypto.subtle.importKey(
    'spki',
    spkiBytes.buffer ? spkiBytes : new Uint8Array(spkiBytes),
    { name: 'ECDSA', namedCurve },
    false,
    ['verify']
  );
}

/**
 * Convert a DER-encoded ECDSA signature to IEEE P1363 (raw r||s) format.
 * DER format: SEQUENCE { INTEGER r, INTEGER s }
 * IEEE P1363: r bytes (padded to keySize) || s bytes (padded to keySize)
 * Web Crypto expects IEEE P1363 for ECDSA verify.
 */
function derEcdsaToIEEE(derSig, keySize) {
  const seq = parseDER(derSig, 0);
  const children = parseDERChildren(derSig, seq.contentOffset, seq.contentLength);
  if (children.length < 2) throw new Error('Invalid DER ECDSA signature');

  function extractInt(element) {
    let bytes = derSig.slice(element.contentOffset, element.contentOffset + element.contentLength);
    // DER integers have a leading 0x00 if the high bit is set (to stay positive)
    while (bytes.length > keySize && bytes[0] === 0) bytes = bytes.slice(1);
    // Pad to keySize if shorter
    if (bytes.length < keySize) {
      const padded = new Uint8Array(keySize);
      padded.set(bytes, keySize - bytes.length);
      return padded;
    }
    return bytes;
  }

  const r = extractInt(children[0]);
  const s = extractInt(children[1]);
  const raw = new Uint8Array(keySize * 2);
  raw.set(r, 0);
  raw.set(s, keySize);
  return raw;
}

// ── Certificate chain validation ──

/**
 * Compute SHA-256 hex fingerprint of a byte array.
 */
async function sha256Hex(bytes) {
  const hash = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(hash))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

/**
 * Verify that `cert` was signed by `issuerCert`.
 * Uses the issuer's SPKI public key to verify the cert's TBS signature.
 */
async function verifyCertSignature(cert, issuerCert) {
  const issuerCurve = detectCurve(issuerCert.spkiBytes);
  const issuerKey = await importSPKI(issuerCert.spkiBytes, issuerCurve);

  // Apple pairs P-256 → SHA-256, P-384 → SHA-384
  const keySize = issuerCurve === 'P-256' ? 32 : 48;
  const hash = issuerCurve === 'P-256' ? 'SHA-256' : 'SHA-384';

  // Certificate signatures are DER-encoded ECDSA — convert to IEEE P1363 for Web Crypto
  const rawSig = derEcdsaToIEEE(cert.signatureBytes, keySize);

  const valid = await crypto.subtle.verify(
    { name: 'ECDSA', hash },
    issuerKey,
    rawSig,
    cert.tbsBytes
  );

  if (!valid) throw new Error('Certificate chain signature verification failed');
}

/**
 * Validate the Apple x5c certificate chain.
 * 1. Verify root cert fingerprint matches Apple Root CA G3
 * 2. Verify intermediate cert is signed by root
 * 3. Verify leaf cert is signed by intermediate
 * 4. Check certificate date validity
 * 5. Check Apple-specific OIDs
 * Returns the parsed leaf certificate.
 */
async function validateAppleCertChain(x5cBase64Array) {
  if (x5cBase64Array.length < 3) {
    throw new Error('x5c chain must contain at least 3 certificates (leaf, intermediate, root)');
  }

  // Decode certificates from base64 (standard, NOT base64url)
  const certDERs = x5cBase64Array.map((b64) => base64Decode(b64));
  const certs = certDERs.map((der) => parseCertificate(der));
  const [leafCert, intermediateCert, rootCert] = certs;

  // 1. Verify root certificate matches Apple Root CA G3
  const rootFingerprint = await sha256Hex(certDERs[2]);
  if (rootFingerprint !== APPLE_ROOT_CA_G3_SHA256) {
    throw new Error(
      `Root certificate is not Apple Root CA G3 (fingerprint: ${rootFingerprint})`
    );
  }

  // 2. Verify certificate chain signatures
  // Intermediate must be signed by root
  await verifyCertSignature(intermediateCert, rootCert);
  // Leaf must be signed by intermediate
  await verifyCertSignature(leafCert, intermediateCert);

  // 3. Check certificate date validity (60s clock skew tolerance)
  const now = Date.now();
  const CLOCK_SKEW_MS = 60_000;
  for (let i = 0; i < 3; i++) {
    const cert = certs[i];
    const label = ['leaf', 'intermediate', 'root'][i];
    if (now < cert.notBefore.getTime() - CLOCK_SKEW_MS) {
      throw new Error(`${label} certificate not yet valid`);
    }
    if (now > cert.notAfter.getTime() + CLOCK_SKEW_MS) {
      throw new Error(`${label} certificate has expired`);
    }
  }

  // 4. Check Apple-specific OIDs
  if (!containsOIDBytes(certDERs[0], APPLE_LEAF_OID_BYTES)) {
    throw new Error(
      'Leaf certificate missing Apple App Store OID (1.2.840.113635.100.6.11.1)'
    );
  }
  if (!containsOIDBytes(certDERs[1], APPLE_INTERMEDIATE_OID_BYTES)) {
    throw new Error(
      'Intermediate certificate missing Apple intermediate OID (1.2.840.113635.100.6.2.1)'
    );
  }

  return leafCert;
}

// ── Apple JWS verification (x5c certificate chain method) ──

/**
 * Verify an Apple StoreKit 2 JWS signed transaction.
 *
 * Apple's on-device Transaction.jwsRepresentation embeds an x5c certificate
 * chain in the JWS header (leaf, intermediate, root). This function:
 * 1. Validates the certificate chain against Apple Root CA G3
 * 2. Extracts the leaf certificate's public key
 * 3. Verifies the JWS signature with that key
 * 4. Returns the decoded payload
 *
 * Reference: Apple's @apple/app-store-server-library uses the same approach
 * (x5c chain validation, NOT JWKS/kid).
 */
async function verifyAppleJWS(jws) {
  const parts = jws.split('.');
  if (parts.length !== 3) throw new Error('Invalid JWS format');

  const headerJson = JSON.parse(new TextDecoder().decode(base64urlDecode(parts[0])));
  const alg = headerJson.alg;
  const x5c = headerJson.x5c;

  // Apple StoreKit 2 JWS uses x5c certificate chain, not JWKS/kid
  if (!x5c || !Array.isArray(x5c) || x5c.length < 3) {
    throw new Error(
      'JWS header must contain x5c certificate chain with at least 3 certificates'
    );
  }

  if (alg !== 'ES256') {
    throw new Error(`Unsupported JWS algorithm: ${alg}. Apple StoreKit 2 uses ES256.`);
  }

  // 1. Validate the full Apple certificate chain
  const leafCert = await validateAppleCertChain(x5c);

  // 2. Import leaf certificate's public key
  const leafCurve = detectCurve(leafCert.spkiBytes);
  const leafKey = await importSPKI(leafCert.spkiBytes, leafCurve);

  // 3. Verify JWS signature (already in IEEE P1363 format per JWS spec)
  const signedData = new TextEncoder().encode(`${parts[0]}.${parts[1]}`);
  const signature = base64urlDecode(parts[2]);

  // Derive hash from leaf curve: P-256 → SHA-256, P-384 → SHA-384
  const leafHash = leafCurve === 'P-256' ? 'SHA-256' : 'SHA-384';
  const valid = await crypto.subtle.verify(
    { name: 'ECDSA', hash: leafHash },
    leafKey,
    signature,
    signedData
  );

  if (!valid) throw new Error('JWS signature verification failed');

  // 4. Decode and return payload
  return JSON.parse(new TextDecoder().decode(base64urlDecode(parts[1])));
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

  // 1. Verify JWS with Apple's x5c certificate chain
  let payload;
  try {
    payload = await verifyAppleJWS(jws);
  } catch (err) {
    return jsonResponse({ error: `JWS verification failed: ${err.message}` }, 401, origin);
  }

  // 2. Extract transaction details (Apple field names per JWSTransactionDecodedPayload)
  const productId = payload.productId;
  const expiresDate = payload.expiresDate;
  const revocationDate = payload.revocationDate;
  const environment = payload.environment;
  const bundleId = payload.bundleId;

  // Reject non-Production environments (Sandbox, Xcode, etc.)
  if (!environment || environment !== 'Production') {
    return jsonResponse(
      { error: `Invalid environment: ${environment || 'missing'}. Only Production transactions accepted.` },
      400,
      origin
    );
  }

  // Reject receipts not belonging to this app bundle
  if (!bundleId || bundleId !== EXPECTED_BUNDLE_ID) {
    return jsonResponse(
      { error: `Invalid bundleId: ${bundleId || 'missing'}` },
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

  // Reject if expired or missing expiry (required for subscription products)
  if (expiresDate === undefined || expiresDate === null || expiresDate === 0) {
    return jsonResponse(
      { error: 'Missing or invalid expiresDate in transaction payload' },
      400,
      origin
    );
  }
  {
    const expMs = typeof expiresDate === 'number' ? expiresDate : Date.parse(expiresDate);
    if (isNaN(expMs) || expMs < Date.now()) {
      return jsonResponse(
        {
          isCompanion: false,
          reason: 'Subscription expired',
          productId,
          expiresAt: isNaN(expMs) ? null : new Date(expMs).toISOString(),
        },
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
  const expiresAt = expiresDate
    ? new Date(typeof expiresDate === 'number' ? expiresDate : Date.parse(expiresDate)).toISOString()
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
