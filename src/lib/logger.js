/**
 * Production-safe logger.
 *
 * In production builds, only warnings and errors are emitted.
 * Debug/info logging is suppressed to keep console clean for App Store.
 */

const IS_DEV = typeof import.meta !== 'undefined' && import.meta.env?.DEV;

/** Log debug info — suppressed in production */
export const log = (...args) => IS_DEV && console.log(...args);

/** Log warnings — always emitted */
export const warn = (...args) => console.warn(...args);

/** Log errors — always emitted */
export const error = (...args) => console.error(...args);
