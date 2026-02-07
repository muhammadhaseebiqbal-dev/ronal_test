import { StrictMode, useState, useEffect } from 'react';
import ReactDOM from 'react-dom/client';
import { AuthProvider, useAuth } from '@/context/AuthContext';

/**
 * CRITICAL: Maximum time to wait before ALWAYS showing Login button.
 * This ensures user is never stuck without a way to proceed.
 */
const AUTH_TIMEOUT_MS = 5000;

/**
 * Main auth UI component.
 * ALWAYS shows Login button after timeout, regardless of loading state.
 */
function AuthDebug() {
    const {
        isLoadingAuth,
        isLoadingPublicSettings,
        isAuthenticated,
        hasToken,
        isTokenLoaded,
        user,
        authError,
        navigateToLogin
    } = useAuth();

    // Force show login button after timeout
    const [forceShowLogin, setForceShowLogin] = useState(false);

    useEffect(() => {
        const timer = setTimeout(() => {
            console.log('[main] Auth timeout - forcing Login button visibility');
            setForceShowLogin(true);
        }, AUTH_TIMEOUT_MS);

        return () => clearTimeout(timer);
    }, []);

    // If authenticated, show success
    if (isAuthenticated && user) {
        return (
            <div style={{ padding: '20px', fontFamily: 'system-ui, sans-serif' }}>
                <h1>Abide & Anchor</h1>
                <p style={{ color: 'green', fontSize: '18px' }}>✅ Authenticated!</p>
                <pre style={{ fontSize: '11px', background: '#f0f0f0', padding: '10px', borderRadius: '5px' }}>
                    {JSON.stringify({
                        userId: user.id,
                        email: user.email,
                        hasToken
                    }, null, 2)}
                </pre>
                <p style={{ fontSize: '13px', color: '#666', marginTop: '20px' }}>
                    Token persistence test: Kill the app and reopen.<br />
                    You should still be authenticated.
                </p>
            </div>
        );
    }

    // If auth error, show error and Login button
    if (authError) {
        return (
            <div style={{ padding: '20px', fontFamily: 'system-ui, sans-serif' }}>
                <h1>Abide & Anchor</h1>
                <p style={{ color: '#cc0000' }}>{authError.message}</p>
                <pre style={{ fontSize: '11px', background: '#fff0f0', padding: '10px', borderRadius: '5px' }}>
                    {JSON.stringify({ type: authError.type, hasToken }, null, 2)}
                </pre>
                <button
                    onClick={navigateToLogin}
                    style={{
                        padding: '14px 28px',
                        fontSize: '18px',
                        marginTop: '15px',
                        cursor: 'pointer',
                        backgroundColor: '#007AFF',
                        color: 'white',
                        border: 'none',
                        borderRadius: '8px',
                        fontWeight: '600'
                    }}
                >
                    Log In
                </button>
            </div>
        );
    }

    // Loading state - but ALWAYS show Login after timeout
    const isLoading = !isTokenLoaded || isLoadingAuth || isLoadingPublicSettings;
    const showLogin = forceShowLogin || !isLoading;

    return (
        <div style={{ padding: '20px', fontFamily: 'system-ui, sans-serif' }}>
            <h1>Abide & Anchor</h1>

            {isLoading && !forceShowLogin ? (
                <p>Loading...</p>
            ) : (
                <p>Please log in to continue</p>
            )}

            <pre style={{ fontSize: '11px', background: '#f0f0f0', padding: '10px', borderRadius: '5px', marginTop: '10px' }}>
                isTokenLoaded: {String(isTokenLoaded)}{'\n'}
                isLoadingAuth: {String(isLoadingAuth)}{'\n'}
                hasToken: {String(hasToken)}{'\n'}
                forceShowLogin: {String(forceShowLogin)}
            </pre>

            {showLogin && (
                <button
                    onClick={navigateToLogin}
                    style={{
                        padding: '14px 28px',
                        fontSize: '18px',
                        marginTop: '15px',
                        cursor: 'pointer',
                        backgroundColor: '#007AFF',
                        color: 'white',
                        border: 'none',
                        borderRadius: '8px',
                        fontWeight: '600'
                    }}
                >
                    Log In
                </button>
            )}
        </div>
    );
}

/**
 * Root component with auth provider.
 */
function App() {
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
