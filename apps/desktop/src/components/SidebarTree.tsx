import React, { useState } from 'react';
import type { Page, SyncStatus } from '../types/notes';

interface SidebarTreeProps {
  pages: Page[];
  selectedPageId: string | null;
  onSelectPage: (id: string) => void;
  onCreatePage: (parentPageId?: string | null, isDatabase?: boolean) => void;
  onDeletePage: (id: string) => void;
  onOpenSearch: () => void;
  onOpenSyncSettings: () => void;
  onLockVault: () => void;
  syncStatus: SyncStatus;
  availableTags: string[];
  selectedTag: string | null;
  onSelectTag: (tag: string | null) => void;
}

export const SidebarTree: React.FC<SidebarTreeProps> = ({
  pages,
  selectedPageId,
  onSelectPage,
  onCreatePage,
  onDeletePage,
  onOpenSearch,
  onOpenSyncSettings,
  onLockVault,
  syncStatus,
  availableTags,
  selectedTag,
  onSelectTag,
}) => {
  const [expandedPages, setExpandedPages] = useState<Record<string, boolean>>({
    '01918a55-0000-7000-8000-000000000010': true,
  });

  const toggleExpand = (pageId: string, e: React.MouseEvent) => {
    e.stopPropagation();
    setExpandedPages((prev) => ({
      ...prev,
      [pageId]: !prev[pageId],
    }));
  };

  // Hiyerarşik ağaç oluşturma: root sayfalar ve child sayfalar
  const pageMap = new Map<string, Page>();
  const childrenMap = new Map<string, Page[]>();

  pages.forEach((p) => {
    pageMap.set(p.id, p);
    const parentId = p.parent_page_id || 'root';
    if (!childrenMap.has(parentId)) {
      childrenMap.set(parentId, []);
    }
    childrenMap.get(parentId)!.push(p);
  });

  const renderTreeItem = (page: Page, level: number = 0) => {
    const children = childrenMap.get(page.id) || [];
    const hasChildren = children.length > 0;
    const isExpanded = !!expandedPages[page.id];
    const isSelected = selectedPageId === page.id;

    return (
      <div key={page.id} className="tree-item-wrapper" style={{ paddingLeft: `${level * 12}px` }}>
        <div
          className={`tree-item-row ${isSelected ? 'active' : ''}`}
          onClick={() => onSelectPage(page.id)}
        >
          <span
            className="tree-expand-toggle"
            onClick={(e) => hasChildren && toggleExpand(page.id, e)}
            style={{ visibility: hasChildren ? 'visible' : 'hidden' }}
          >
            {isExpanded ? '▼' : '▶'}
          </span>

          <span className="tree-icon">{page.icon || (page.is_database ? '🗄️' : '📄')}</span>

          <span className="tree-title">{page.title || 'Başlıksız'}</span>

          <div className="tree-actions" onClick={(e) => e.stopPropagation()}>
            <button
              className="icon-btn-tiny"
              title="Alt Sayfa Ekle"
              onClick={() => onCreatePage(page.id, false)}
            >
              +
            </button>
            <button
              className="icon-btn-tiny danger"
              title="Sayfayı Sil"
              onClick={() => {
                if (confirm(`"${page.title}" sayfasını silmek istediğinize emin misiniz?`)) {
                  onDeletePage(page.id);
                }
              }}
            >
              ✕
            </button>
          </div>
        </div>

        {hasChildren && isExpanded && (
          <div className="tree-nested-children">
            {children.map((child) => renderTreeItem(child, level + 1))}
          </div>
        )}
      </div>
    );
  };

  const rootPages = childrenMap.get('root') || [];

  return (
    <aside className="app-sidebar">
      {/* macOS Pencere Sürükleme ve Başlık Alanı */}
      <div className="mac-titlebar-drag">
        <span style={{ fontSize: '11px', color: 'var(--text-muted)', fontWeight: 600 }}>
          NOTES E2EE
        </span>
      </div>

      <div className="sidebar-header">
        <div className="workspace-badge">
          <span>🪐</span>
          <span>Kişisel Çalışma Alanı</span>
        </div>
        <button
          className="icon-btn-tiny"
          onClick={onOpenSyncSettings}
          title={`Senkronizasyon: ${syncStatus.connected ? 'Bağlı' : 'Çevrimdışı'}`}
          style={{ position: 'relative' }}
        >
          ☁️
          {syncStatus.pendingOutboxCount > 0 && (
            <span
              style={{
                position: 'absolute',
                top: -2,
                right: -4,
                backgroundColor: 'var(--accent)',
                color: '#fff',
                fontSize: '9px',
                borderRadius: '10px',
                padding: '1px 4px',
              }}
            >
              {syncStatus.pendingOutboxCount}
            </span>
          )}
        </button>
      </div>

      {/* Spotlight Arama Tetikleyici Buton */}
      <button className="search-trigger-btn" onClick={onOpenSearch}>
        <div style={{ display: 'flex', alignItems: 'center', gap: '6px' }}>
          <span>🔍</span>
          <span>Hızlı Arama...</span>
        </div>
        <kbd className="kbd-shortcut">⌘K</kbd>
      </button>

      {/* Sayfalar Ağacı */}
      <div className="sidebar-content">
        <div className="sidebar-section-title">
          <span>Sayfalar</span>
          <div style={{ display: 'flex', gap: '4px' }}>
            <button
              className="icon-btn-tiny"
              onClick={() => onCreatePage(null, false)}
              title="Yeni Sayfa Ekle"
            >
              + Not
            </button>
            <button
              className="icon-btn-tiny"
              onClick={() => onCreatePage(null, true)}
              title="Yeni Veritabanı Ekle"
            >
              + DB
            </button>
          </div>
        </div>

        <div className="sidebar-tree-list">
          {rootPages.map((page) => renderTreeItem(page, 0))}
          {rootPages.length === 0 && (
            <div style={{ padding: '12px 10px', color: 'var(--text-muted)', fontSize: '12px' }}>
              Henüz bir sayfa yok. "+ Not" ile oluşturun.
            </div>
          )}
        </div>

        {/* Etiketler Bölümü */}
        {availableTags.length > 0 && (
          <div style={{ marginTop: '20px' }}>
            <div className="sidebar-section-title">
              <span>Etiketler</span>
              {selectedTag && (
                <button
                  className="icon-btn-tiny"
                  onClick={() => onSelectTag(null)}
                  title="Filtreyi Temizle"
                >
                  Temizle
                </button>
              )}
            </div>
            <div style={{ padding: '4px 6px', display: 'flex', flexWrap: 'wrap' }}>
              {availableTags.map((tag) => (
                <span
                  key={tag}
                  className="tag-list-chip"
                  onClick={() => onSelectTag(selectedTag === tag ? null : tag)}
                  style={{
                    backgroundColor: selectedTag === tag ? 'var(--accent)' : undefined,
                    color: selectedTag === tag ? '#ffffff' : undefined,
                  }}
                >
                  #{tag}
                </span>
              ))}
            </div>
          </div>
        )}
      </div>

      {/* Alt Bar: Kasa Kilitleme ve Durum */}
      <div className="sidebar-footer">
        <button className="lock-vault-btn" onClick={onLockVault}>
          <span>🔒</span>
          <span>Kasayı Kilitle</span>
        </button>
        <div className="sidebar-footer-row" style={{ fontSize: '11px', color: 'var(--text-muted)' }}>
          <span>Argon2id + XChaCha20</span>
          <span>v0.1.0</span>
        </div>
      </div>
    </aside>
  );
};
