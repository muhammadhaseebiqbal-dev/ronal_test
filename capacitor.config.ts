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
        allowsLinkPreview: false,
        // Disable overscroll bounce — native feel, avoids "web app" appearance
        scrollEnabled: true,
        backgroundColor: '#0b1f2a'
        // NOTE: Do NOT set ios.scheme — it would change the WebView origin
        // and collide with the deep link scheme in Info.plist.
    },
    // Plugins configuration
    plugins: {
        Preferences: {},
        // SplashScreen persists until web content loads — prevents blank white flash
        SplashScreen: {
            launchAutoHide: true,
            launchShowDuration: 0,
            backgroundColor: '#0b1f2a',
            showSpinner: false
        }
    }
};

export default config;
