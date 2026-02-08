import { StrictMode, useState, useEffect } from 'react';
import ReactDOM from 'react-dom/client';
import { AuthProvider, useAuth } from '@/context/AuthContext';

/**
 * CRITICAL: Maximum time to wait before ALWAYS showing Login button.
 * This ensures user is never stuck without a way to proceed.
 */
const AUTH_TIMEOUT_MS = 5000;

/** Shared inline styles for consistent native-like appearance */
const containerStyle = {
    padding: '40px 20px',
    fontFamily: '-apple-system, BlinkMacSystemFont, system-ui, sans-serif',
    maxWidth: '400px',
    margin: '0 auto',
    textAlign: 'center',
    minHeight: '100vh',
    display: 'flex',
    flexDirection: 'column',
    justifyContent: 'center',
    backgroundColor: '#0b1f2a',
    color: '#e8dcc8'
};

const buttonStyle = {
    padding: '14px 28px',
    fontSize: '18px',
    marginTop: '20px',
    cursor: 'pointer',
    backgroundColor: '#c9a96e',
    color: '#0b1f2a',
    border: 'none',
    borderRadius: '12px',
    fontWeight: '600',
    width: '100%',
    maxWidth: '280px'
};

/**
 * Offline fallback — shown when the device has no network.
 * Prevents blank white screen, which triggers Guideline 4.2 rejection.
 */
function OfflineScreen() {
    const retry = () => window.location.reload();

    return (
        <div style={containerStyle}>
            <h1 style={{ fontSize: '28px', marginBottom: '8px' }}>Abide &amp; Anchor</h1>
            <p style={{ color: '#c9a96e', fontSize: '16px', marginBottom: '24px' }}>
                No internet connection
            </p>
            <p style={{ fontSize: '14px', opacity: 0.7, lineHeight: '1.5' }}>
                Please check your Wi-Fi or cellular connection and try again.
            </p>
            <button onClick={retry} style={buttonStyle}>
                Retry
            </button>
        </div>
    );
}

/**
 * Main auth UI component.
 * ALWAYS shows Login button after timeout, regardless of loading state.
 */
function AuthDebug() {
    const {
        isLoadingAuth,
        isLoadingPublicSettings,
        isAuthenticated,
        isTokenLoaded,
        user,
        authError,
        navigateToLogin
    } = useAuth();

    const [forceShowLogin, setForceShowLogin] = useState(false);

    useEffect(() => {
        const timer = setTimeout(() => {
            setForceShowLogin(true);
        }, AUTH_TIMEOUT_MS);

        return () => clearTimeout(timer);
    }, []);

    if (isAuthenticated && user) {
        return (
            <div style={containerStyle}>
                <h1 style={{ fontSize: '28px', marginBottom: '8px' }}>Abide &amp; Anchor</h1>
                <p style={{ color: '#4ade80', fontSize: '18px' }}>✅ Authenticated</p>
                <p style={{ fontSize: '14px', opacity: 0.7, marginTop: '16px', lineHeight: '1.5' }}>
                    Token persistence test: Kill the app and reopen.<br />
                    You should remain authenticated.
                </p>
            </div>
        );
    }

    if (authError) {
        return (
            <div style={containerStyle}>
                <h1 style={{ fontSize: '28px', marginBottom: '8px' }}>Abide &amp; Anchor</h1>
                <p style={{ color: '#c9a96e', fontSize: '16px', marginBottom: '16px' }}>
                    {authError.type === 'auth_required' ? 'Please log in to continue' : authError.message}
                </p>
                <button onClick={navigateToLogin} style={buttonStyle}>
                    Log In
                </button>
            </div>
        );
    }

    const isLoading = !isTokenLoaded || isLoadingAuth || isLoadingPublicSettings;
    const showLogin = forceShowLogin || !isLoading;

    return (
        <div style={containerStyle}>
            <h1 style={{ fontSize: '28px', marginBottom: '8px' }}>Abide &amp; Anchor</h1>

            {isLoading && !forceShowLogin ? (
                <p style={{ color: '#c9a96e' }}>Loading...</p>
            ) : (
                <p style={{ color: '#c9a96e' }}>Please log in to continue</p>
            )}

            {showLogin && (
                <button onClick={navigateToLogin} style={buttonStyle}>
                    Log In
                </button>
            )}
        </div>
    );
}

/**
 * Root component with auth provider and offline detection.
 */
function App() {
    const [isOnline, setIsOnline] = useState(navigator.onLine);

    useEffect(() => {
        const handleOnline = () => setIsOnline(true);
        const handleOffline = () => setIsOnline(false);
        window.addEventListener('online', handleOnline);
        window.addEventListener('offline', handleOffline);
        return () => {
            window.removeEventListener('online', handleOnline);
            window.removeEventListener('offline', handleOffline);
        };
    }, []);

    if (!isOnline) {
        return <OfflineScreen />;
    }

    return (
        <AuthProvider>
            <AuthDebug />
        </AuthProvider>
    );
}

ReactDOM.createRoot(document.getElementById('root')).render(
    <StrictMode>
        <App />
    </StrictMode>
);
