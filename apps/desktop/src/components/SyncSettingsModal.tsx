import React, { useState } from 'react';
import type { SyncStatus } from '../types/notes';

interface SyncSettingsModalProps {
  isOpen: boolean;
  onClose: () => void;
  syncStatus: SyncStatus;
  onUpdateSettings: (serverUrl: string) => Promise<void>;
  onTriggerSync: () => Promise<void>;
}

export const SyncSettingsModal: React.FC<SyncSettingsModalProps> = ({
  isOpen,
  onClose,
  syncStatus,
  onUpdateSettings,
  onTriggerSync,
}) => {
  const [serverUrl, setServerUrl] = useState(syncStatus.serverUrl);
  const [isSaving, setIsSaving] = useState(false);
  const [saveSuccess, setSaveSuccess] = useState(false);

  if (!isOpen) return null;

  const handleSave = async (e: React.FormEvent) => {
    e.preventDefault();
    setIsSaving(true);
    setSaveSuccess(false);
    try {
      await onUpdateSettings(serverUrl);
      setSaveSuccess(true);
      setTimeout(() => setSaveSuccess(false), 2000);
    } finally {
      setIsSaving(false);
    }
  };

  return (
    <div className="modal-overlay" onClick={onClose}>
      <div className="sync-modal-card" onClick={(e) => e.stopPropagation()}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
            <span style={{ fontSize: '20px' }}>☁️</span>
            <h3 style={{ fontSize: '17px', fontWeight: 600 }}>E2EE Cloud Sync Ayarları</h3>
          </div>
          <button className="icon-btn-tiny" onClick={onClose}>
            ✕
          </button>
        </div>

        <p style={{ fontSize: '12.5px', color: 'var(--text-secondary)', lineHeight: 1.5 }}>
          Notlarınız yerel olarak saklanır. İsteğe bağlı olarak kendi barındırdığınız (self-hosted) Notes Cloud API sunucusu ile uçtan uca şifreli senkronizasyon yapabilirsiniz.
        </p>

        {/* Durum Göstergesi */}
        <div
          style={{
            backgroundColor: 'var(--bg-sidebar)',
            border: '1px solid var(--border-color)',
            borderRadius: '8px',
            padding: '12px 14px',
            display: 'flex',
            flexDirection: 'column',
            gap: '8px',
            fontSize: '12.5px',
          }}
        >
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <span style={{ color: 'var(--text-secondary)' }}>Bağlantı Durumu:</span>
            <div style={{ display: 'flex', alignItems: 'center', gap: '6px', fontWeight: 600 }}>
              <span
                style={{
                  width: '8px',
                  height: '8px',
                  borderRadius: '50%',
                  backgroundColor: syncStatus.connected ? 'var(--success)' : 'var(--danger)',
                }}
              />
              <span>{syncStatus.connected ? 'Sunucu Aktif' : 'Bağlantı Kesildi'}</span>
            </div>
          </div>

          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <span style={{ color: 'var(--text-secondary)' }}>Cihaz Kimliği:</span>
            <span style={{ fontFamily: 'var(--font-mono)', fontSize: '11px' }}>
              {syncStatus.deviceId}
            </span>
          </div>

          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <span style={{ color: 'var(--text-secondary)' }}>Son Eşitleme:</span>
            <span>
              {syncStatus.lastSyncedAt
                ? new Date(syncStatus.lastSyncedAt).toLocaleTimeString()
                : 'Henüz yapılmadı'}
            </span>
          </div>

          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <span style={{ color: 'var(--text-secondary)' }}>Outbox Bekleyen Zarf:</span>
            <span
              style={{
                backgroundColor: syncStatus.pendingOutboxCount > 0 ? 'var(--warning)' : 'var(--bg-hover)',
                color: syncStatus.pendingOutboxCount > 0 ? '#000' : 'inherit',
                padding: '1px 8px',
                borderRadius: '10px',
                fontWeight: 600,
                fontSize: '11px',
              }}
            >
              {syncStatus.pendingOutboxCount} zarf
            </span>
          </div>
        </div>

        {/* Sunucu Adresi Formu */}
        <form onSubmit={handleSave} style={{ display: 'flex', flexDirection: 'column', gap: '10px' }}>
          <div>
            <label style={{ fontSize: '12px', fontWeight: 500, color: 'var(--text-secondary)' }}>
              Self-Hosted Sunucu Adresi
            </label>
            <input
              type="url"
              className="lockscreen-input"
              style={{ marginTop: '4px', fontSize: '13px' }}
              value={serverUrl}
              onChange={(e) => setServerUrl(e.target.value)}
              placeholder="https://api.notes.selfhosted.com"
            />
          </div>

          <div style={{ display: 'flex', gap: '8px' }}>
            <button type="submit" className="btn-secondary" style={{ flex: 1 }} disabled={isSaving}>
              {isSaving ? 'Kaydediliyor...' : saveSuccess ? '✓ Kaydedildi' : 'Ayarları Kaydet'}
            </button>
            <button
              type="button"
              className="btn-primary"
              style={{ flex: 1 }}
              onClick={onTriggerSync}
              disabled={syncStatus.isSyncing}
            >
              {syncStatus.isSyncing ? 'Eşitleniyor...' : 'Şimdi Senkronize Et ⚡'}
            </button>
          </div>
        </form>

        {/* E2EE Güvenlik Bilgisi */}
        <div
          style={{
            borderTop: '1px solid var(--border-color)',
            paddingTop: '10px',
            fontSize: '11px',
            color: 'var(--text-muted)',
            lineHeight: 1.4,
            display: 'flex',
            alignItems: 'flex-start',
            gap: '6px',
          }}
        >
          <span>🔐</span>
          <span>
            <strong>Zero-Knowledge Garantisi:</strong> Senkronize edilen her zarf, yerel cihazınızdaki anahtar ile şifrelenir. Sunucu verilerinizi deşifre edemez.
          </span>
        </div>
      </div>
    </div>
  );
};
