import React, { useState, useEffect, useRef } from 'react';
import type { Block, BlockType, Page } from '../types/notes';

interface SlashCommandItem {
  type: BlockType;
  label: string;
  description: string;
  icon: string;
}

const SLASH_COMMANDS: SlashCommandItem[] = [
  { type: 'paragraph', label: 'Metin (Paragraph)', description: 'Düz metin veya paragraf', icon: '¶' },
  { type: 'heading1', label: 'Başlık 1', description: 'En büyük ana bölüm başlığı (#)', icon: 'H1' },
  { type: 'heading2', label: 'Başlık 2', description: 'Orta seviye alt başlık (##)', icon: 'H2' },
  { type: 'heading3', label: 'Başlık 3', description: 'Küçük seviye başlık (###)', icon: 'H3' },
  { type: 'todo_item', label: 'Yapılacak Listesi (To-do)', description: 'İşaret kutusu ile görev (- [ ])', icon: '☑️' },
  { type: 'bullet_list_item', label: 'Madde İmli Liste', description: 'Noktalı liste maddesi (- veya *)', icon: '•' },
  { type: 'numbered_list_item', label: 'Numaralı Liste', description: 'Sıralı liste maddesi (1.)', icon: '1.' },
  { type: 'quote', label: 'Alıntı (Quote)', description: 'Vurgulu alıntı metni (>)', icon: '❝' },
  { type: 'callout', label: 'Çağrı Kutusu (Callout)', description: 'Özel dikkat kutusu', icon: '💡' },
  { type: 'code_block', label: 'Kod Bloğu (Code)', description: 'Sözdizimi vurgulu kod (```)', icon: '⟨/⟩' },
  { type: 'divider', label: 'Ayırıcı Çizgi (Divider)', description: 'Yatay ayırıcı çizgi (---)', icon: '—' },
  { type: 'image', label: 'Görsel (Image/Attachment)', description: 'Görsel veya dosya eki', icon: '🖼️' },
];

interface SlashBlockEditorProps {
  page: Page;
  blocks: Block[];
  pages: Page[];
  onUpdatePageTitle: (title: string) => void;
  onSaveBlock: (block: Partial<Block> & { page_id: string; block_type: BlockType }) => void;
  onDeleteBlock: (blockId: string) => void;
  onReorderBlocks: (blockIds: string[]) => void;
  onNavigatePage: (pageId: string) => void;
}

export const SlashBlockEditor: React.FC<SlashBlockEditorProps> = ({
  page,
  blocks,
  pages,
  onUpdatePageTitle,
  onSaveBlock,
  onDeleteBlock,
  onReorderBlocks,
  onNavigatePage,
}) => {
  const [activeSlashBlockId, setActiveSlashBlockId] = useState<string | null>(null);
  const [slashFilter, setSlashFilter] = useState('');
  const [slashIndex, setSlashIndex] = useState(0);

  const [activeWikiBlockId, setActiveWikiBlockId] = useState<string | null>(null);
  const [wikiFilter, setWikiFilter] = useState('');
  const [wikiIndex, setWikiIndex] = useState(0);

  const inputRefs = useRef<Record<string, HTMLTextAreaElement | HTMLInputElement | null>>({});

  useEffect(() => {
    setSlashIndex(0);
  }, [slashFilter]);

  useEffect(() => {
    setWikiIndex(0);
  }, [wikiFilter]);

  // Markdown kısayolları denetleyicisi
  const checkMarkdownShortcuts = (text: string, currentType: BlockType): { matchedType: BlockType; cleanText: string } | null => {
    if (text.startsWith('# ') && currentType !== 'heading1') {
      return { matchedType: 'heading1', cleanText: text.substring(2) };
    }
    if (text.startsWith('## ') && currentType !== 'heading2') {
      return { matchedType: 'heading2', cleanText: text.substring(3) };
    }
    if (text.startsWith('### ') && currentType !== 'heading3') {
      return { matchedType: 'heading3', cleanText: text.substring(4) };
    }
    if ((text.startsWith('- [ ] ') || text.startsWith('[] ')) && currentType !== 'todo_item') {
      const offset = text.startsWith('- [ ] ') ? 6 : 3;
      return { matchedType: 'todo_item', cleanText: text.substring(offset) };
    }
    if ((text.startsWith('- ') || text.startsWith('* ')) && currentType !== 'bullet_list_item') {
      return { matchedType: 'bullet_list_item', cleanText: text.substring(2) };
    }
    if (text.startsWith('> ') && currentType !== 'quote') {
      return { matchedType: 'quote', cleanText: text.substring(2) };
    }
    if (text.startsWith('```') && currentType !== 'code_block') {
      return { matchedType: 'code_block', cleanText: text.replace(/^```[a-z]*\s?/, '') };
    }
    if (text === '---') {
      return { matchedType: 'divider', cleanText: '' };
    }
    return null;
  };

  const handleTextChange = (block: Block, newText: string) => {
    // 1. Markdown kısayol kontrolü
    const mdMatch = checkMarkdownShortcuts(newText, block.block_type);
    if (mdMatch) {
      onSaveBlock({
        ...block,
        block_type: mdMatch.matchedType,
        content: { ...block.content, text: mdMatch.cleanText },
      });
      setActiveSlashBlockId(null);
      setActiveWikiBlockId(null);
      return;
    }

    // 2. Slash komutu kontrolü: son kelime '/' ile başlıyorsa
    const slashMatch = newText.match(/(?:^|\s)\/([a-zA-Z0-9]*)$/);
    if (slashMatch) {
      setActiveSlashBlockId(block.id);
      setSlashFilter(slashMatch[1].toLowerCase());
    } else {
      if (activeSlashBlockId === block.id) {
        setActiveSlashBlockId(null);
      }
    }

    // 3. [[Wiki-link]] kontrolü
    const wikiMatch = newText.match(/\[\[([^\]]*)$/);
    if (wikiMatch) {
      setActiveWikiBlockId(block.id);
      setWikiFilter(wikiMatch[1].toLowerCase());
    } else {
      if (activeWikiBlockId === block.id) {
        setActiveWikiBlockId(null);
      }
    }

    onSaveBlock({
      ...block,
      content: { ...block.content, text: newText },
    });
  };

  const applySlashCommand = (block: Block, type: BlockType) => {
    const currentText = block.content.text || '';
    // Sondaki / ifadesini sil
    const cleanText = currentText.replace(/(?:^|\s)\/[a-zA-Z0-9]*$/, '').trim();

    onSaveBlock({
      ...block,
      block_type: type,
      content: { ...block.content, text: cleanText },
    });

    setActiveSlashBlockId(null);
    setSlashFilter('');

    // Odağı bloğa geri ver
    setTimeout(() => {
      inputRefs.current[block.id]?.focus();
    }, 50);
  };

  const applyWikiLink = (block: Block, targetPage: Page) => {
    const currentText = block.content.text || '';
    const newText = currentText.replace(/\[\[([^\]]*)$/, `[[${targetPage.title}]] `);

    onSaveBlock({
      ...block,
      content: { ...block.content, text: newText },
    });

    setActiveWikiBlockId(null);
    setWikiFilter('');

    setTimeout(() => {
      inputRefs.current[block.id]?.focus();
    }, 50);
  };

  const handleKeyDown = (e: React.KeyboardEvent, block: Block, index: number) => {
    // Slash menüsü açıkken klavye yönetimi
    if (activeSlashBlockId === block.id) {
      const filtered = SLASH_COMMANDS.filter(
        (c) => c.label.toLowerCase().includes(slashFilter) || c.type.toLowerCase().includes(slashFilter)
      );

      if (e.key === 'ArrowDown') {
        e.preventDefault();
        setSlashIndex((prev) => (prev + 1) % (filtered.length || 1));
        return;
      }
      if (e.key === 'ArrowUp') {
        e.preventDefault();
        setSlashIndex((prev) => (prev - 1 + filtered.length) % (filtered.length || 1));
        return;
      }
      if (e.key === 'Enter' && filtered.length > 0) {
        e.preventDefault();
        applySlashCommand(block, filtered[slashIndex].type);
        return;
      }
      if (e.key === 'Escape') {
        e.preventDefault();
        setActiveSlashBlockId(null);
        return;
      }
    }

    // Wiki-link menüsü açıkken klavye yönetimi
    if (activeWikiBlockId === block.id) {
      const filtered = pages.filter(
        (p) => p.id !== page.id && p.title.toLowerCase().includes(wikiFilter)
      );

      if (e.key === 'ArrowDown') {
        e.preventDefault();
        setWikiIndex((prev) => (prev + 1) % (filtered.length || 1));
        return;
      }
      if (e.key === 'ArrowUp') {
        e.preventDefault();
        setWikiIndex((prev) => (prev - 1 + filtered.length) % (filtered.length || 1));
        return;
      }
      if (e.key === 'Enter' && filtered.length > 0) {
        e.preventDefault();
        applyWikiLink(block, filtered[wikiIndex]);
        return;
      }
      if (e.key === 'Escape') {
        e.preventDefault();
        setActiveWikiBlockId(null);
        return;
      }
    }

    // Enter tuşuna basıldığında yeni blok oluşturma
    if (e.key === 'Enter' && !e.shiftKey) {
      if (block.block_type !== 'code_block') {
        e.preventDefault();
        const nextOrder = block.sort_order + 0.5;
        onSaveBlock({
          page_id: page.id,
          block_type: 'paragraph',
          content: { text: '' },
          sort_order: nextOrder,
        });
        return;
      }
    }

    // Boş blokta Backspace tuşuna basıldığında silme
    if (e.key === 'Backspace' && (!block.content.text || block.content.text === '')) {
      if (blocks.length > 1) {
        e.preventDefault();
        onDeleteBlock(block.id);
        const prevBlock = blocks[index - 1];
        if (prevBlock) {
          setTimeout(() => {
            inputRefs.current[prevBlock.id]?.focus();
          }, 30);
        }
      }
    }
  };

  // Render zengin metin (Backlink ve Etiketleri renklendirme)
  const renderFormattedPreview = (text: string) => {
    const parts = text.split(/(\[\[.+?\]\]|#\w+)/g);
    return parts.map((part, i) => {
      if (part.startsWith('[[') && part.endsWith(']]')) {
        const title = part.substring(2, part.length - 2);
        const target = pages.find((p) => p.title.toLowerCase() === title.toLowerCase());
        return (
          <span
            key={i}
            className="inline-backlink"
            onClick={(e) => {
              e.stopPropagation();
              if (target) onNavigatePage(target.id);
            }}
            title={target ? `Sayfaya Git: ${target.title}` : 'Sayfa bulunamadı'}
          >
            {part}
          </span>
        );
      }
      if (part.startsWith('#') && part.length > 1) {
        return (
          <span key={i} className="inline-tag">
            {part}
          </span>
        );
      }
      return <span key={i}>{part}</span>;
    });
  };

  const filteredCommands = SLASH_COMMANDS.filter(
    (c) => c.label.toLowerCase().includes(slashFilter) || c.type.toLowerCase().includes(slashFilter)
  );

  const filteredWikiPages = pages.filter(
    (p) => p.id !== page.id && p.title.toLowerCase().includes(wikiFilter)
  );

  return (
    <div className="editor-container">
      {/* Sayfa Başlığı */}
      <input
        type="text"
        className="page-title-input"
        placeholder="Başlıksız Not"
        value={page.title}
        onChange={(e) => onUpdatePageTitle(e.target.value)}
      />

      {/* Blok Listesi */}
      <div className="blocks-container">
        {blocks.map((block, index) => {
          const isSlashOpen = activeSlashBlockId === block.id;
          const isWikiOpen = activeWikiBlockId === block.id;

          return (
            <div key={block.id} className={`block-row block-type-${block.block_type}`}>
              {/* Blok Taşıma ve Tip Değiştirme Butonu */}
              <div className="block-handle-container">
                <button
                  className="block-drag-handle"
                  title="Yukarı Taşı"
                  disabled={index === 0}
                  onClick={() => {
                    if (index > 0) {
                      const newIds = [...blocks.map((b) => b.id)];
                      [newIds[index - 1], newIds[index]] = [newIds[index], newIds[index - 1]];
                      onReorderBlocks(newIds);
                    }
                  }}
                >
                  ▲
                </button>
                <button
                  className="block-drag-handle"
                  title="Aşağı Taşı"
                  disabled={index === blocks.length - 1}
                  onClick={() => {
                    if (index < blocks.length - 1) {
                      const newIds = [...blocks.map((b) => b.id)];
                      [newIds[index], newIds[index + 1]] = [newIds[index + 1], newIds[index]];
                      onReorderBlocks(newIds);
                    }
                  }}
                >
                  ▼
                </button>
                <button
                  className="block-menu-handle"
                  title="Komut Menüsünü Aç (/)"
                  onClick={() => {
                    setActiveSlashBlockId(block.id);
                    setSlashFilter('');
                  }}
                >
                  ⋮⋮
                </button>
              </div>

              {/* Blok İçeriği Türüne Göre Render */}
              <div className="block-content-area" style={{ position: 'relative' }}>
                {block.block_type === 'todo_item' && (
                  <div style={{ display: 'flex', alignItems: 'center', gap: '8px', width: '100%' }}>
                    <input
                      type="checkbox"
                      className="todo-checkbox"
                      checked={!!block.content.checked}
                      onChange={(e) =>
                        onSaveBlock({
                          ...block,
                          content: { ...block.content, checked: e.target.checked },
                        })
                      }
                    />
                    <input
                      ref={(el) => {
                        inputRefs.current[block.id] = el;
                      }}
                      type="text"
                      className={`block-editable-input ${block.content.checked ? 'todo-text-checked' : ''}`}
                      placeholder="Görev yazın veya / ile komut açın..."
                      value={block.content.text || ''}
                      onChange={(e) => handleTextChange(block, e.target.value)}
                      onKeyDown={(e) => handleKeyDown(e, block, index)}
                    />
                  </div>
                )}

                {block.block_type === 'bullet_list_item' && (
                  <div style={{ display: 'flex', alignItems: 'flex-start', gap: '8px', width: '100%' }}>
                    <span className="bullet-dot">•</span>
                    <input
                      ref={(el) => {
                        inputRefs.current[block.id] = el;
                      }}
                      type="text"
                      className="block-editable-input"
                      placeholder="Madde yazın..."
                      value={block.content.text || ''}
                      onChange={(e) => handleTextChange(block, e.target.value)}
                      onKeyDown={(e) => handleKeyDown(e, block, index)}
                    />
                  </div>
                )}

                {block.block_type === 'numbered_list_item' && (
                  <div style={{ display: 'flex', alignItems: 'flex-start', gap: '8px', width: '100%' }}>
                    <span style={{ fontWeight: 600, color: 'var(--text-muted)', minWidth: '18px' }}>
                      {index + 1}.
                    </span>
                    <input
                      ref={(el) => {
                        inputRefs.current[block.id] = el;
                      }}
                      type="text"
                      className="block-editable-input"
                      placeholder="Sıralı madde..."
                      value={block.content.text || ''}
                      onChange={(e) => handleTextChange(block, e.target.value)}
                      onKeyDown={(e) => handleKeyDown(e, block, index)}
                    />
                  </div>
                )}

                {block.block_type === 'callout' && (
                  <div className="block-type-callout">
                    <span className="callout-icon">{(block.properties.icon as string) || '💡'}</span>
                    <input
                      ref={(el) => {
                        inputRefs.current[block.id] = el;
                      }}
                      type="text"
                      className="block-editable-input"
                      placeholder="Önemli bir not yazın..."
                      value={block.content.text || ''}
                      onChange={(e) => handleTextChange(block, e.target.value)}
                      onKeyDown={(e) => handleKeyDown(e, block, index)}
                    />
                  </div>
                )}

                {block.block_type === 'quote' && (
                  <div className="block-type-quote">
                    <input
                      ref={(el) => {
                        inputRefs.current[block.id] = el;
                      }}
                      type="text"
                      className="block-editable-input"
                      placeholder="Alıntı yazın..."
                      value={block.content.text || ''}
                      onChange={(e) => handleTextChange(block, e.target.value)}
                      onKeyDown={(e) => handleKeyDown(e, block, index)}
                    />
                  </div>
                )}

                {block.block_type === 'code_block' && (
                  <div className="block-type-code_block">
                    <div className="code-header">
                      <span>{(block.content.language as string) || 'Rust'}</span>
                      <button
                        className="icon-btn-tiny"
                        onClick={() => {
                          navigator.clipboard.writeText(block.content.text || '');
                          alert('Kod panoya kopyalandı.');
                        }}
                      >
                        Kopyala
                      </button>
                    </div>
                    <textarea
                      ref={(el) => {
                        inputRefs.current[block.id] = el;
                      }}
                      className="block-editable-input"
                      style={{ minHeight: '80px', fontFamily: 'var(--font-mono)' }}
                      placeholder="Kodunuzu buraya yapıştırın..."
                      value={block.content.text || ''}
                      onChange={(e) => handleTextChange(block, e.target.value)}
                      onKeyDown={(e) => handleKeyDown(e, block, index)}
                    />
                  </div>
                )}

                {block.block_type === 'divider' && (
                  <div className="block-type-divider" onClick={() => applySlashCommand(block, 'paragraph')} />
                )}

                {block.block_type === 'image' && (
                  <div style={{ margin: '8px 0', border: '1px dashed var(--border-color)', borderRadius: '8px', padding: '12px' }}>
                    <div style={{ display: 'flex', gap: '8px', marginBottom: '8px' }}>
                      <input
                        type="text"
                        className="block-editable-input"
                        placeholder="Görsel URL yapıştırın (https://...)"
                        value={block.content.url || ''}
                        onChange={(e) =>
                          onSaveBlock({
                            ...block,
                            content: { ...block.content, url: e.target.value },
                          })
                        }
                      />
                    </div>
                    {block.content.url ? (
                      <img
                        src={block.content.url as string}
                        alt="Ek Görsel"
                        style={{ maxWidth: '100%', maxHeight: '400px', borderRadius: '6px' }}
                        onError={(e) => {
                          (e.target as HTMLElement).style.display = 'none';
                        }}
                      />
                    ) : (
                      <div style={{ color: 'var(--text-muted)', fontSize: '12px' }}>
                        🖼️ Görsel bağlantısı girin
                      </div>
                    )}
                  </div>
                )}

                {/* Standart Paragraf ve Başlıklar */}
                {[
                  'paragraph',
                  'heading1',
                  'heading2',
                  'heading3',
                ].includes(block.block_type) && (
                  <div>
                    <input
                      ref={(el) => {
                        inputRefs.current[block.id] = el;
                      }}
                      type="text"
                      className="block-editable-input"
                      placeholder={
                        block.block_type === 'paragraph'
                          ? "Metin yazın, komutlar için '/' veya sayfa bağlamak için '[['..."
                          : 'Başlık metni...'
                      }
                      value={block.content.text || ''}
                      onChange={(e) => handleTextChange(block, e.target.value)}
                      onKeyDown={(e) => handleKeyDown(e, block, index)}
                    />

                    {/* [[Link]] veya #tag varsa altta küçük önizleme göster */}
                    {block.content.text &&
                      (block.content.text.includes('[[') || block.content.text.includes('#')) && (
                        <div style={{ fontSize: '13px', marginTop: '2px', opacity: 0.85 }}>
                          {renderFormattedPreview(block.content.text)}
                        </div>
                      )}
                  </div>
                )}

                {/* SLASH KOMUT MENÜSÜ POPUP */}
                {isSlashOpen && (
                  <div className="slash-menu-popup">
                    <div style={{ padding: '4px 8px 6px', fontSize: '11px', color: 'var(--text-muted)', fontWeight: 600 }}>
                      BLOK SEÇİN VEYA DÖNÜŞTÜRÜN
                    </div>
                    {filteredCommands.length === 0 ? (
                      <div style={{ padding: '8px', color: 'var(--text-muted)', fontSize: '12px' }}>
                        Eşleşen komut bulunamadı
                      </div>
                    ) : (
                      filteredCommands.map((item, idx) => (
                        <div
                          key={item.type}
                          className={`slash-menu-item ${idx === slashIndex ? 'selected' : ''}`}
                          onClick={() => applySlashCommand(block, item.type)}
                        >
                          <span className="slash-item-icon">{item.icon}</span>
                          <div className="slash-item-text">
                            <span className="slash-item-label">{item.label}</span>
                            <span className="slash-item-desc">{item.description}</span>
                          </div>
                        </div>
                      ))
                    )}
                  </div>
                )}

                {/* WIKI-LINK OTOMATİK TAMAMLAMA POPUP */}
                {isWikiOpen && (
                  <div className="wikilink-popup">
                    <div style={{ padding: '4px 8px', fontSize: '11px', color: 'var(--text-muted)', fontWeight: 600 }}>
                      SAYFAYA BAĞLANTI VER [[...]]
                    </div>
                    {filteredWikiPages.length === 0 ? (
                      <div style={{ padding: '6px 8px', color: 'var(--text-muted)', fontSize: '12px' }}>
                        Eşleşen sayfa yok
                      </div>
                    ) : (
                      filteredWikiPages.map((p, idx) => (
                        <div
                          key={p.id}
                          className="wikilink-item"
                          style={{
                            backgroundColor: idx === wikiIndex ? 'var(--bg-hover)' : undefined,
                            fontWeight: idx === wikiIndex ? 600 : 'normal',
                          }}
                          onClick={() => applyWikiLink(block, p)}
                        >
                          <span>{p.icon || '📄'}</span>
                          <span>{p.title}</span>
                        </div>
                      ))
                    )}
                  </div>
                )}
              </div>
            </div>
          );
        })}
      </div>

      {/* Sayfa sonu hızlı yeni blok ekleme alanı */}
      <div
        style={{ marginTop: '24px', padding: '12px 0', cursor: 'text' }}
        onClick={() => {
          const lastBlock = blocks[blocks.length - 1];
          const nextOrder = lastBlock ? lastBlock.sort_order + 1 : 1;
          onSaveBlock({
            page_id: page.id,
            block_type: 'paragraph',
            content: { text: '' },
            sort_order: nextOrder,
          });
        }}
      >
        <span style={{ color: 'var(--text-muted)', fontSize: '13px' }}>
          + Yeni bir paragraf bloğu eklemek için tıklayın
        </span>
      </div>
    </div>
  );
};
