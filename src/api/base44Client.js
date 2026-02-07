/**
 * Base44 SDK Client
 *
 * Creates and exports the Base44 client instance with validated configuration.
 */

import { createClient } from '@base44/sdk';
import { appParams, validateAppParams, isCapacitorRuntime } from '@/lib/app-params';

const validation = validateAppParams(appParams);

if (!validation.valid) {
    console.error('[base44Client] Invalid configuration detected.');
    console.error('[base44Client] Fix these issues before building for iOS:', validation.issues);
}

/**
 * Base44 client instance.
 */
export const base44 = createClient({
    appId: appParams.appId || '',
    token: appParams.token || undefined,
    functionsVersion: appParams.functionsVersion,
    serverUrl: appParams.serverUrl,
    appBaseUrl: appParams.appBaseUrl,
    requiresAuth: false
});

if (typeof import.meta !== 'undefined' && (import.meta.env?.DEV || isCapacitorRuntime())) {
    console.log('[base44Client] Client created:', {
        appId: appParams.appId ? 'SET' : 'MISSING',
        hasToken: Boolean(appParams.token),
        functionsVersion: appParams.functionsVersion,
        serverUrl: appParams.serverUrl,
        appBaseUrl: appParams.appBaseUrl
    });
}
