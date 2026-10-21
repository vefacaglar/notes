import React, { useState, useEffect, useCallback, useMemo } from 'react';
import { ipcClient } from './ipc/client';
import type {
  Block,
  BlockType,
  DatabaseRow,
  DatabaseSchema,
  Page,
  SyncStatus,
  VaultStatus,
  BacklinkItem,
} from './types/notes';
import { VaultLockScreen } from './components/VaultLockScreen';
import { SidebarTree } from './components/SidebarTree';
import { SlashBlockEditor } from './components/SlashBlockEditor';
import { DatabaseView } from './components/DatabaseView';
import { QuickSearchModal } from './components/QuickSearchModal';
import { BacklinksPanel } from './components/BacklinksPanel';
import { SyncSettingsModal } from './components/SyncSettingsModal';

export const App: React.FC = () => {
  // Vault Kilit Durumu
  const [vaultStatus, setVaultStatus] = useState<VaultStatus>({
    isUnlocked: true,
    isConfigured: true,
    keychainAvailable: true,
  });
  const [isInitializing, setIsInitializing] = useState(true);

  // Sayfa ve İçerik Durumları
  const [pages, setPages] = useState<Page[]>([]);
  const [selectedPageId, setSelectedPageId] = useState<string | null>(null);
  const [blocks, setBlocks] = useState<Block[]>([]);
  const [backlinks, setBacklinks] = useState<BacklinkItem[]>([]);

  // Veritabanı Görünümü Durumları
  const [dbSchema, setDbSchema] = useState<DatabaseSchema | null>(null);
  const [dbRows, setDbRows] = useState<DatabaseRow[]>([]);

  // Modallar ve Arama
  const [isSearchOpen, setIsSearchOpen] = useState(false);
  const [isSyncModalOpen, setIsSyncModalOpen] = useState(false);
  const [selectedTag, setSelectedTag] = useState<string | null>(null);

  // Senkronizasyon Durumu
  const [syncStatus, setSyncStatus] = useState<SyncStatus>({
    connected: true,
    serverUrl: 'https://api.notes.selfhosted.local',
    lastSyncedAt: null,
    pendingOutboxCount: 0,
    deviceId: 'macbook-e2ee',
    isSyncing: false,
    errorMessage: null,
  });

  // 1. Kasa ve İlk Durum Yükleme
  const refreshVaultStatus = useCallback(async () => {
    try {
      const status = await ipcClient.getVaultStatus();
      setVaultStatus(status);
      return status;
    } catch (err) {
      console.error('Kasa durumu alınamadı:', err);
      return null;
    }
  }, []);

  const loadWorkspaceData = useCallback(async () => {
    try {
      const pageList = await ipcClient.getPages();
      setPages(pageList);

      const sync = await ipcClient.getSyncStatus();
      setSyncStatus(sync);

      if (pageList.length > 0 && !selectedPageId) {
        setSelectedPageId(pageList[0].id);
      }
    } catch (err) {
      console.error('Veriler yüklenirken hata oluştu:', err);
    }
  }, [selectedPageId]);

  useEffect(() => {
    const init = async () => {
      const status = await refreshVaultStatus();
      if (status && status.isUnlocked) {
        await loadWorkspaceData();
      }
      setIsInitializing(false);
    };
    init();
  }, [refreshVaultStatus, loadWorkspaceData]);

  // 2. Seçili Sayfa Değiştiğinde Blokları / Veritabanı Verilerini Yükleme
  const loadPageContent = useCallback(async (pageId: string) => {
    const currentPage = pages.find((p) => p.id === pageId);
    if (!currentPage) return;

    try {
      if (currentPage.is_database) {
        const [schema, rows] = await Promise.all([
          ipcClient.getDatabaseSchema(pageId),
          ipcClient.getDatabaseRows(pageId),
        ]);
        setDbSchema(schema);
        setDbRows(rows);
      } else {
        const [loadedBlocks, loadedBacklinks] = await Promise.all([
          ipcClient.getBlocks(pageId),
          ipcClient.getBacklinks(pageId),
        ]);
        setBlocks(loadedBlocks);
        setBacklinks(loadedBacklinks);
      }
    } catch (err) {
      console.error('Sayfa içeriği yüklenemedi:', err);
    }
  }, [pages]);

  useEffect(() => {
    if (selectedPageId) {
      loadPageContent(selectedPageId);
    }
  }, [selectedPageId, loadPageContent]);

  // 3. Global Cmd+K Spotlight Kısayol Dinleyicisi
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') {
        e.preventDefault();
        setIsSearchOpen((prev) => !prev);
      }
    };
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, []);

  // 4. Sayfa Aksiyonları
  const handleCreatePage = async (parentPageId?: string | null, isDatabase: boolean = false) => {
    try {
      const newPage = await ipcClient.createPage(
        isDatabase ? 'Yeni Veritabanı' : 'Başlıksız Not',
        parentPageId,
        isDatabase
      );
      setPages((prev) => [newPage, ...prev]);
      setSelectedPageId(newPage.id);
    } catch (err) {
      console.error('Sayfa oluşturulamadı:', err);
    }
  };

  const handleUpdatePageTitle = async (newTitle: string) => {
    if (!selectedPageId) return;
    try {
      const updated = await ipcClient.updatePage({ id: selectedPageId, title: newTitle });
      setPages((prev) => prev.map((p) => (p.id === updated.id ? updated : p)));
    } catch (err) {
      console.error('Başlık güncellenemedi:', err);
    }
  };

  const handleDeletePage = async (id: string) => {
    try {
      await ipcClient.deletePage(id);
      const remaining = pages.filter((p) => p.id !== id);
      setPages(remaining);
      if (selectedPageId === id) {
        setSelectedPageId(remaining.length > 0 ? remaining[0].id : null);
      }
    } catch (err) {
      console.error('Sayfa silinemedi:', err);
    }
  };

  // 5. Blok Aksiyonları
  const handleSaveBlock = async (blockData: Partial<Block> & { page_id: string; block_type: BlockType }) => {
    try {
      const saved = await ipcClient.saveBlock(blockData);
      setBlocks((prev) => {
        const idx = prev.findIndex((b) => b.id === saved.id);
        if (idx >= 0) {
          const next = [...prev];
          next[idx] = saved;
          return next;
        }
        return [...prev, saved].sort((a, b) => a.sort_order - b.sort_order);
      });

      // Backlink ve etiketleri güncelle
      if (selectedPageId) {
        const bl = await ipcClient.getBacklinks(selectedPageId);
        setBacklinks(bl);
      }
    } catch (err) {
      console.error('Blok kaydedilemedi:', err);
    }
  };

  const handleDeleteBlock = async (blockId: string) => {
    try {
      await ipcClient.deleteBlock(blockId);
      setBlocks((prev) => prev.filter((b) => b.id !== blockId));
    } catch (err) {
      console.error('Blok silinemedi:', err);
    }
  };

  const handleReorderBlocks = async (blockIds: string[]) => {
    if (!selectedPageId) return;
    try {
      await ipcClient.reorderBlocks(selectedPageId, blockIds);
      const map = new Map(blocks.map((b) => [b.id, b]));
      const reordered = blockIds.map((id, index) => {
        const b = map.get(id)!;
        return { ...b, sort_order: index + 1 };
      });
      setBlocks(reordered);
    } catch (err) {
      console.error('Bloklar yeniden sıralanamadı:', err);
    }
  };

  // 6. Veritabanı Aksiyonları
  const handleSaveSchema = async (schema: DatabaseSchema) => {
    try {
      const saved = await ipcClient.saveDatabaseSchema(schema);
      setDbSchema(saved);
    } catch (err) {
      console.error('Şema kaydedilemedi:', err);
    }
  };

  const handleSaveRow = async (row: Partial<DatabaseRow> & { page_id: string }) => {
    try {
      const saved = await ipcClient.saveDatabaseRow(row);
      setDbRows((prev) => {
        const idx = prev.findIndex((r) => r.id === saved.id);
        if (idx >= 0) {
          const next = [...prev];
          next[idx] = saved;
          return next;
        }
        return [...prev, saved];
      });
    } catch (err) {
      console.error('Satır kaydedilemedi:', err);
    }
  };

  const handleDeleteRow = async (rowId: string) => {
    try {
      await ipcClient.deleteDatabaseRow(rowId);
      setDbRows((prev) => prev.filter((r) => r.id !== rowId));
    } catch (err) {
      console.error('Satır silinemedi:', err);
    }
  };

  // 7. Senkronizasyon Aksiyonları
  const handleUpdateSyncSettings = async (serverUrl: string) => {
    const updated = await ipcClient.updateSyncSettings(serverUrl);
    setSyncStatus(updated);
  };

  const handleTriggerSync = async () => {
    const updated = await ipcClient.triggerSync();
    setSyncStatus(updated);
  };

  // 8. Kasa Kilitleme / Kilit Açma
  const handleLockVault = async () => {
    await ipcClient.lockVault();
    setVaultStatus((prev) => ({ ...prev, isUnlocked: false }));
  };

  const handleUnlocked = async () => {
    setVaultStatus((prev) => ({ ...prev, isUnlocked: true }));
    await loadWorkspaceData();
  };

  // 9. Dinamik Etiket Çıkarımı
  const availableTags = useMemo(() => {
    const tagSet = new Set<string>();
    blocks.forEach((b) => {
      const text = b.content.text || '';
      const matches = text.match(/#([a-zA-Z0-9_\-]+)/g);
      if (matches) {
        matches.forEach((m) => tagSet.add(m.substring(1)));
      }
    });
    return Array.from(tagSet);
  }, [blocks]);

  // Filtrelenmiş Sayfalar
  const displayedPages = useMemo(() => {
    if (!selectedTag) return pages;
    return pages.filter((p) => {
      const pageBlocks = blocks.filter((b) => b.page_id === p.id);
      return pageBlocks.some((b) => (b.content.text || '').includes(`#${selectedTag}`));
    });
  }, [pages, blocks, selectedTag]);

  const activePage = pages.find((p) => p.id === selectedPageId);

  if (isInitializing) {
    return (
      <div className="app-container" style={{ alignItems: 'center', justifyContent: 'center' }}>
        <div style={{ color: 'var(--text-secondary)', fontSize: '14px' }}>Kasa başlatılıyor...</div>
      </div>
    );
  }

  return (
    <div className="app-container">
      {/* Kasa Kilit Ekranı */}
      {!vaultStatus.isUnlocked && (
        <VaultLockScreen status={vaultStatus} onUnlocked={handleUnlocked} />
      )}

      {/* Sol Sidebar Ağacı */}
      <SidebarTree
        pages={displayedPages}
        selectedPageId={selectedPageId}
        onSelectPage={(id) => setSelectedPageId(id)}
        onCreatePage={handleCreatePage}
        onDeletePage={handleDeletePage}
        onOpenSearch={() => setIsSearchOpen(true)}
        onOpenSyncSettings={() => setIsSyncModalOpen(true)}
        onLockVault={handleLockVault}
        syncStatus={syncStatus}
        availableTags={availableTags}
        selectedTag={selectedTag}
        onSelectTag={setSelectedTag}
      />

      {/* Ana Çalışma Alanı (Workspace) */}
      <main className="app-workspace">
        {/* Üst Bar */}
        <header className="workspace-header">
          <div className="header-breadcrumbs">
            <span>{activePage?.icon || (activePage?.is_database ? '🗄️' : '📄')}</span>
            <span style={{ fontWeight: 600 }}>{activePage?.title || 'Sayfa Seçin'}</span>
            {activePage?.is_database && (
              <span className="inline-tag" style={{ fontSize: '11px' }}>
                Veritabanı
              </span>
            )}
          </div>

          <div className="header-actions">
            <div className="sync-status-indicator" onClick={() => setIsSyncModalOpen(true)}>
              <span className={`status-dot ${syncStatus.isSyncing ? 'syncing' : ''}`} />
              <span>
                {syncStatus.isSyncing
                  ? 'Eşitleniyor...'
                  : syncStatus.pendingOutboxCount > 0
                  ? `${syncStatus.pendingOutboxCount} zarf bekliyor`
                  : 'E2EE Eşitlendi'}
              </span>
            </div>
          </div>
        </header>

        {/* İçerik Alanı */}
        <section className="workspace-content">
          {activePage ? (
            activePage.is_database ? (
              dbSchema && (
                <DatabaseView
                  page={activePage}
                  schema={dbSchema}
                  rows={dbRows}
                  onSaveSchema={handleSaveSchema}
                  onSaveRow={handleSaveRow}
                  onDeleteRow={handleDeleteRow}
                />
              )
            ) : (
              <div>
                <SlashBlockEditor
                  page={activePage}
                  blocks={blocks}
                  pages={pages}
                  onUpdatePageTitle={handleUpdatePageTitle}
                  onSaveBlock={handleSaveBlock}
                  onDeleteBlock={handleDeleteBlock}
                  onReorderBlocks={handleReorderBlocks}
                  onNavigatePage={(id) => setSelectedPageId(id)}
                />

                {/* Backlinks Bölümü */}
                <BacklinksPanel
                  backlinks={backlinks}
                  onNavigatePage={(id) => setSelectedPageId(id)}
                />
              </div>
            )
          ) : (
            <div style={{ textAlign: 'center', color: 'var(--text-muted)', marginTop: '80px' }}>
              <div style={{ fontSize: '48px', marginBottom: '16px' }}>📝</div>
              <h3>Görüntülenecek Sayfa Yok</h3>
              <p style={{ marginTop: '8px', fontSize: '13px' }}>
                Kenar çubuğundan bir not seçin veya yeni bir sayfa oluşturun.
              </p>
            </div>
          )}
        </section>
      </main>

      {/* Cmd+K Spotlight Hızlı Arama Modalı */}
      <QuickSearchModal
        isOpen={isSearchOpen}
        onClose={() => setIsSearchOpen(false)}
        onSelectPage={(id) => setSelectedPageId(id)}
      />

      {/* Cloud Sync Ayar Modalı */}
      <SyncSettingsModal
        isOpen={isSyncModalOpen}
        onClose={() => setIsSyncModalOpen(false)}
        syncStatus={syncStatus}
        onUpdateSettings={handleUpdateSyncSettings}
        onTriggerSync={handleTriggerSync}
      />
    </div>
  );
};

export default App;
