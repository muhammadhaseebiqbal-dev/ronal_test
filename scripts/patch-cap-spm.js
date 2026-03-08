import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const packageSwiftPath = path.join(__dirname, '..', 'ios', 'App', 'CapApp-SPM', 'Package.swift');

if (fs.existsSync(packageSwiftPath)) {
    console.log('[Capacitor Post-Sync] Fixing Windows backslashes in CapApp-SPM/Package.swift');
    let content = fs.readFileSync(packageSwiftPath, 'utf8');

    // Replace all backslashes in node_modules paths with forward slashes
    // Only target the path strings to be safe
    const fixedContent = content.replace(/path:\s*"([^"]+)"/g, (match, p1) => {
        return `path: "${p1.replace(/\\\\/g, '/')}"`;
    });

    if (content !== fixedContent) {
        fs.writeFileSync(packageSwiftPath, fixedContent);
        console.log('[Capacitor Post-Sync] Successfully patched Package.swift for macOS compatibility.');
    } else {
        console.log('[Capacitor Post-Sync] No backslashes found (already macOS compatible).');
    }
} else {
    console.warn('[Capacitor Post-Sync] CapApp-SPM/Package.swift not found. Skipping patch.');
}
