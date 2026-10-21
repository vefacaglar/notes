import React, { useState } from 'react';
import { ipcClient } from '../ipc/client';
import type { VaultStatus } from '../types/notes';

interface VaultLockScreenProps {
  status: VaultStatus;
  onUnlocked: () => void;
}

export const VaultLockScreen: React.FC<VaultLockScreenProps> = ({ status, onUnlocked }) => {
  const [password, setPassword] = useState('');
  const [isSetupMode, setIsSetupMode] = useState(!status.isConfigured);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const handleUnlock = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!password) {
      setError('Lütfen ana parolanızı girin.');
      return;
    }
    setLoading(true);
    setError(null);

    try {
      if (isSetupMode) {
        await ipcClient.setupVault(password);
        onUnlocked();
      } else {
        const res = await ipcClient.unlockVault(password);
        if (res.success) {
          onUnlocked();
        } else {
          setError(res.error || 'Hatalı parola, kasa açılamadı.');
        }
      }
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Kasa açma işlemi başarısız.');
    } finally {
      setLoading(false);
    }
  };

  const handleTouchId = async () => {
    setLoading(true);
    setError(null);
    try {
      const res = await ipcClient.unlockWithTouchId();
      if (res.success) {
        onUnlocked();
      } else {
        setError(res.error || 'Touch ID doğrulaması başarısız oldu.');
      }
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Keychain / Touch ID hatası.');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="modal-overlay" style={{ backdropFilter: 'blur(20px)' }}>
      <div className="lockscreen-card">
        <div className="lockscreen-icon">🔒</div>

        <div>
          <h2 style={{ fontSize: '20px', fontWeight: 600, marginBottom: '6px' }}>
            {isSetupMode ? 'Güvenli Kasa Kurulumu' : 'Kasa Kilitli'}
          </h2>
          <p style={{ fontSize: '13px', color: 'var(--text-secondary)', lineHeight: 1.5 }}>
            {isSetupMode
              ? 'Notlarınızı XChaCha20-Poly1305 ve Argon2id ile şifrelemek için güçlü bir ana parola belirleyin.'
              : 'Verilerinize erişmek için ana parolanızı girin veya macOS Touch ID kullanın.'}
          </p>
        </div>

        {error && (
          <div
            style={{
              width: '100%',
              padding: '8px 12px',
              backgroundColor: 'rgba(255, 59, 48, 0.1)',
              border: '1px solid var(--danger)',
              borderRadius: '6px',
              color: 'var(--danger)',
              fontSize: '12.5px',
            }}
          >
            {error}
          </div>
        )}

        <form onSubmit={handleUnlock} style={{ width: '100%', display: 'flex', flexDirection: 'column', gap: '12px' }}>
          <input
            type="password"
            className="lockscreen-input"
            placeholder={isSetupMode ? 'Yeni Ana Parola Belirleyin' : 'Ana Parola'}
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            autoFocus
          />

          <button type="submit" className="btn-primary" disabled={loading}>
            {loading ? 'İşleniyor...' : isSetupMode ? 'Kasayı Oluştur ve Başlat' : 'Kasayı Aç'}
          </button>
        </form>

        {!isSetupMode && status.keychainAvailable && (
          <button
            type="button"
            className="btn-secondary"
            onClick={handleTouchId}
            disabled={loading}
            style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', gap: '8px' }}
          >
            <span></span> macOS Keychain / Touch ID ile Aç
          </button>
        )}

        <div style={{ display: 'flex', alignItems: 'center', gap: '6px', fontSize: '11px', color: 'var(--text-muted)' }}>
          <span>🛡️</span>
          <span>E2EE Zero-Knowledge Şifreleme Devrede</span>
        </div>

        {status.isConfigured && (
          <button
            type="button"
            onClick={() => setIsSetupMode(!isSetupMode)}
            style={{
              background: 'none',
              border: 'none',
              color: 'var(--text-muted)',
              fontSize: '11.5px',
              cursor: 'pointer',
              textDecoration: 'underline',
            }}
          >
            {isSetupMode ? 'Vazgeç (Mevcut Parolayla Aç)' : 'Parolayı Yeniden Belirle'}
          </button>
        )}
      </div>
    </div>
  );
};
