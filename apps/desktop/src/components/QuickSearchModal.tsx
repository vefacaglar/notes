import React, { useState, useEffect, useRef } from 'react';
import { ipcClient } from '../ipc/client';
import type { SearchResult } from '../types/notes';

interface QuickSearchModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSelectPage: (pageId: string) => void;
}

export const QuickSearchModal: React.FC<QuickSearchModalProps> = ({
  isOpen,
  onClose,
  onSelectPage,
}) => {
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<SearchResult[]>([]);
  const [selectedIndex, setSelectedIndex] = useState(0);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (isOpen) {
      setQuery('');
      setResults([]);
      setSelectedIndex(0);
      setTimeout(() => inputRef.current?.focus(), 50);
    }
  }, [isOpen]);

  useEffect(() => {
    let active = true;
    if (!query.trim()) {
      setResults([]);
      setSelectedIndex(0);
      return;
    }

    const timer = setTimeout(async () => {
      try {
        const res = await ipcClient.searchNotes(query);
        if (active) {
          setResults(res);
          setSelectedIndex(0);
        }
      } catch (err) {
        console.error('Arama hatası:', err);
      }
    }, 120);

    return () => {
      active = false;
      clearTimeout(timer);
    };
  }, [query]);

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Escape') {
      e.preventDefault();
      onClose();
      return;
    }

    if (results.length > 0) {
      if (e.key === 'ArrowDown') {
        e.preventDefault();
        setSelectedIndex((prev) => (prev + 1) % results.length);
      } else if (e.key === 'ArrowUp') {
        e.preventDefault();
        setSelectedIndex((prev) => (prev - 1 + results.length) % results.length);
      } else if (e.key === 'Enter') {
        e.preventDefault();
        const selected = results[selectedIndex];
        if (selected) {
          onSelectPage(selected.page.id);
          onClose();
        }
      }
    }
  };

  if (!isOpen) return null;

  return (
    <div className="modal-overlay" onClick={onClose}>
      <div className="quick-search-modal" onClick={(e) => e.stopPropagation()}>
        {/* Arama Alanı */}
        <div className="search-input-wrapper">
          <span style={{ fontSize: '18px', color: 'var(--text-muted)' }}>🔍</span>
          <input
            ref={inputRef}
            type="text"
            className="search-input-field"
            placeholder="Sayfa başlıklarında ve not bloklarında ara..."
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            onKeyDown={handleKeyDown}
          />
          <kbd className="kbd-shortcut">ESC</kbd>
        </div>

        {/* Sonuç Listesi */}
        <div className="search-results-list">
          {query.trim() && results.length === 0 ? (
            <div style={{ padding: '24px 16px', textAlign: 'center', color: 'var(--text-muted)' }}>
              "{query}" ile eşleşen bir not veya blok bulunamadı.
            </div>
          ) : results.length > 0 ? (
            results.map((item, idx) => (
              <div
                key={item.page.id + (item.matchedBlockId || '')}
                className={`search-result-item ${idx === selectedIndex ? 'selected' : ''}`}
                onClick={() => {
                  onSelectPage(item.page.id);
                  onClose();
                }}
              >
                <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
                  <span>{item.page.icon || (item.page.is_database ? '🗄️' : '📄')}</span>
                  <span className="search-result-title">{item.page.title}</span>
                </div>
                {item.snippet && (
                  <div className="search-result-snippet">{item.snippet}</div>
                )}
              </div>
            ))
          ) : (
            <div style={{ padding: '16px', color: 'var(--text-muted)', fontSize: '12px' }}>
              İpucu: Sayfa isimlerini, kod parçalarını veya #etiketleri arayabilirsiniz.
            </div>
          )}
        </div>
      </div>
    </div>
  );
};
