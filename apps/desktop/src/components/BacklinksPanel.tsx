import React, { useState } from 'react';
import type { BacklinkItem } from '../types/notes';

interface BacklinksPanelProps {
  backlinks: BacklinkItem[];
  onNavigatePage: (pageId: string) => void;
}

export const BacklinksPanel: React.FC<BacklinksPanelProps> = ({ backlinks, onNavigatePage }) => {
  const [isOpen, setIsOpen] = useState(true);

  return (
    <section className="backlinks-section">
      <div className="backlinks-toggle-header" onClick={() => setIsOpen(!isOpen)}>
        <span>{isOpen ? '▼' : '▶'}</span>
        <span>
          <strong>[[Backlinks]]</strong> — Bu Sayfaya Verilen Bağlantılar ({backlinks.length})
        </span>
      </div>

      {isOpen && (
        <div className="backlinks-list">
          {backlinks.length === 0 ? (
            <div style={{ color: 'var(--text-muted)', fontSize: '12.5px', padding: '6px 0' }}>
              Bu sayfaya henüz başka bir sayfadan bağlantı verilmemiş. Başka bir notta <code>[[Bu Sayfanın Adı]]</code> yazarak bağlantı kurabilirsiniz.
            </div>
          ) : (
            backlinks.map((item) => (
              <div
                key={item.blockId + item.pageId}
                className="backlink-card"
                onClick={() => onNavigatePage(item.pageId)}
              >
                <div className="backlink-card-title">
                  <span>📄</span> {item.pageTitle}
                </div>
                <div className="backlink-card-snippet">"{item.snippet}"</div>
              </div>
            ))
          )}
        </div>
      )}
    </section>
  );
};
