/**
 * Runtime environment helpers.
 */

/**
 * Detects if the app is running in a Capacitor environment.
 *
 * @param {Window | undefined} win - Window object (optional for testing).
 * @returns {boolean} True if running in Capacitor.
 */
export const isCapacitorRuntime = (win) => {
    const windowRef = win || (typeof window !== 'undefined' ? window : undefined);
    if (!windowRef) return false;
    // With server.url set to https://abideandanchor.app, the protocol is https:,
    // not capacitor:. Rely solely on the Capacitor bridge object.
    return Boolean(windowRef.Capacitor?.isNativePlatform?.());
};
