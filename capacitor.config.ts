import type { CapacitorConfig } from '@capacitor/cli';

const config: CapacitorConfig = {
    appId: 'com.abideandanchor.app',
    appName: 'Abide & Anchor',
    webDir: 'dist',
    // Load the live production site directly in WKWebView.
    // This makes the WebView origin https://abideandanchor.app,
    // so localStorage persists across cold restarts (unlike capacitor://localhost).
    // The local dist/ folder is NOT served at runtime — the app is a thin wrapper.
    server: {
        url: 'https://abideandanchor.app',
        cleartext: false
    },
    // iOS-specific configuration
    ios: {
        preferredContentMode: 'mobile',
        allowsLinkPreview: false
        // NOTE: Do NOT set ios.scheme — it would change the WebView origin
        // and collide with the deep link scheme in Info.plist.
    },
    // Plugins configuration
    plugins: {
        Preferences: {}
    }
};

export default config;
