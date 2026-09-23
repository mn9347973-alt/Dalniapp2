import { useState } from 'react';
import { Loader2 } from 'lucide-react';
import { AuthProvider, useAuth } from './auth/AuthContext';
import { ThemeProvider } from './theme/ThemeContext';
import { AppSettingsProvider } from './lib/AppSettingsContext';
import { ToastProvider } from './components/Toast';
import { LoginForm } from './components/LoginForm';
import { AdminLoginForm } from './components/AdminLoginForm';
import { UserApp } from './user/UserApp';
import { AdminApp } from './admin/AdminApp';
import { Logo } from './components/Logo';

function Gate() {
  const { session, loading } = useAuth();
  const [adminLogin, setAdminLogin] = useState(false);

  if (loading) {
    return (
      <div className="flex min-h-screen flex-col items-center justify-center bg-slate-50 dark:bg-slate-950">
        <Logo size={64} />
        <Loader2 className="mt-6 h-7 w-7 animate-spin text-brand-500" />
        <p className="mt-3 text-sm text-slate-400">جارٍ التحميل…</p>
      </div>
    );
  }

  if (!session) {
    return adminLogin
      ? <AdminLoginForm onBack={() => setAdminLogin(false)} />
      : <LoginForm onAdminLogin={() => setAdminLogin(true)} />;
  }

  return session.role === 'admin' ? <AdminApp /> : <UserApp />;
}

export default function App() {
  return (
    <ThemeProvider>
      <AppSettingsProvider>
        <AuthProvider>
          <ToastProvider>
            <Gate />
          </ToastProvider>
        </AuthProvider>
      </AppSettingsProvider>
    </ThemeProvider>
  );
}
