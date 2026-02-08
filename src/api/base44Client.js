/**
 * Base44 SDK Client
 *
 * Creates and exports the Base44 client instance with validated configuration.
 */

import { createClient } from '@base44/sdk';
import { appParams, validateAppParams } from '@/lib/app-params';
import { log, error as logError } from '@/lib/logger';

const validation = validateAppParams(appParams);

if (!validation.valid) {
    logError('[base44Client] Invalid configuration detected.');
    logError('[base44Client] Fix these issues before building for iOS:', validation.issues);
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

if (typeof import.meta !== 'undefined' && import.meta.env?.DEV) {
    log('[base44Client] Client created:', {
        appId: appParams.appId ? 'SET' : 'MISSING',
        hasToken: Boolean(appParams.token),
        serverUrl: appParams.serverUrl
    });
}
