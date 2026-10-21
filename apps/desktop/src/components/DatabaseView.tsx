import React, { useState } from 'react';
import type {
  DatabasePropertyDefinition,
  DatabaseRow,
  DatabaseSchema,
  Page,
  PropertyType,
  ViewType,
} from '../types/notes';

interface DatabaseViewProps {
  page: Page;
  schema: DatabaseSchema;
  rows: DatabaseRow[];
  onSaveSchema: (schema: DatabaseSchema) => void;
  onSaveRow: (row: Partial<DatabaseRow> & { page_id: string }) => void;
  onDeleteRow: (rowId: string) => void;
}

export const DatabaseView: React.FC<DatabaseViewProps> = ({
  page,
  schema,
  rows,
  onSaveSchema,
  onSaveRow,
  onDeleteRow,
}) => {
  const [activeView, setActiveView] = useState<ViewType>('table');
  const [showAddPropertyModal, setShowAddPropertyModal] = useState(false);
  const [newPropName, setNewPropName] = useState('');
  const [newPropType, setNewPropType] = useState<PropertyType>('text');

  // Takvim ayı seçimi
  const [calendarDate, setCalendarDate] = useState(() => new Date());

  // Birincil metin ve select property tespiti
  const titleProp = schema.properties.find((p) => p.property_type === 'text') || schema.properties[0];
  const selectProp = schema.properties.find((p) => p.property_type === 'select');
  const dateProp = schema.properties.find((p) => p.property_type === 'date');

  // Yeni property ekleme
  const handleAddProperty = (e: React.FormEvent) => {
    e.preventDefault();
    if (!newPropName.trim()) return;

    const newPropId = 'prop-' + Date.now().toString(36);
    const newProperty: DatabasePropertyDefinition = {
      id: newPropId,
      name: newPropName.trim(),
      property_type: newPropType,
      position: schema.properties.length,
      options:
        newPropType === 'select'
          ? [
              { id: 'opt-a', name: 'Seçenek 1', color: '#3b82f6' },
              { id: 'opt-b', name: 'Seçenek 2', color: '#10b981' },
            ]
          : undefined,
    };

    onSaveSchema({
      ...schema,
      properties: [...schema.properties, newProperty],
    });

    setNewPropName('');
    setShowAddPropertyModal(false);
  };

  // Yeni satır oluşturma
  const handleAddNewRow = (initialCells: Record<string, unknown> = {}) => {
    const defaultCells: Record<string, unknown> = {};
    if (titleProp) {
      defaultCells[titleProp.id] = 'Yeni Kayıt';
    }
    if (selectProp && selectProp.options && selectProp.options.length > 0) {
      defaultCells[selectProp.id] = selectProp.options[0].id;
    }
    if (dateProp) {
      defaultCells[dateProp.id] = new Date().toISOString().split('T')[0];
    }

    onSaveRow({
      page_id: page.id,
      cells: { ...defaultCells, ...initialCells },
      sort_order: rows.length + 1,
    });
  };

  // Hücre güncelleme
  const handleCellChange = (row: DatabaseRow, propId: string, value: unknown) => {
    onSaveRow({
      ...row,
      cells: {
        ...row.cells,
        [propId]: value,
      },
    });
  };

  // ==========================================
  // TABLO GÖRÜNÜMÜ RENDER
  // ==========================================
  const renderTableView = () => (
    <div className="table-scroll-container">
      <table className="notion-table">
        <thead>
          <tr>
            <th style={{ width: '40px', textAlign: 'center' }}>#</th>
            {schema.properties.map((prop) => (
              <th key={prop.id}>
                <div style={{ display: 'flex', alignItems: 'center', gap: '6px' }}>
                  <span>
                    {prop.property_type === 'text' && '📝'}
                    {prop.property_type === 'select' && '🏷️'}
                    {prop.property_type === 'date' && '📅'}
                    {prop.property_type === 'checkbox' && '☑️'}
                    {prop.property_type === 'number' && '🔢'}
                  </span>
                  <span>{prop.name}</span>
                </div>
              </th>
            ))}
            <th style={{ width: '60px' }}>
              <button
                className="icon-btn-tiny"
                title="Yeni Kolon Ekle"
                onClick={() => setShowAddPropertyModal(true)}
              >
                + Kolon
              </button>
            </th>
          </tr>
        </thead>
        <tbody>
          {rows.map((row, idx) => (
            <tr key={row.id}>
              <td style={{ textAlign: 'center', color: 'var(--text-muted)', fontSize: '11px' }}>
                {idx + 1}
              </td>
              {schema.properties.map((prop) => {
                const val = row.cells[prop.id];

                return (
                  <td key={prop.id}>
                    {prop.property_type === 'checkbox' ? (
                      <input
                        type="checkbox"
                        checked={!!val}
                        onChange={(e) => handleCellChange(row, prop.id, e.target.checked)}
                      />
                    ) : prop.property_type === 'select' ? (
                      <select
                        value={(val as string) || ''}
                        onChange={(e) => handleCellChange(row, prop.id, e.target.value)}
                        style={{
                          background: 'transparent',
                          border: 'none',
                          color: 'inherit',
                          outline: 'none',
                          cursor: 'pointer',
                        }}
                      >
                        <option value="">(Seçilmedi)</option>
                        {prop.options?.map((opt) => (
                          <option key={opt.id} value={opt.id}>
                            {opt.name}
                          </option>
                        ))}
                      </select>
                    ) : prop.property_type === 'date' ? (
                      <input
                        type="date"
                        className="table-cell-input"
                        value={(val as string) || ''}
                        onChange={(e) => handleCellChange(row, prop.id, e.target.value)}
                      />
                    ) : (
                      <input
                        type="text"
                        className="table-cell-input"
                        value={(val as string) || ''}
                        placeholder="Boş..."
                        onChange={(e) => handleCellChange(row, prop.id, e.target.value)}
                      />
                    )}
                  </td>
                );
              })}
              <td style={{ textAlign: 'center' }}>
                <button
                  className="icon-btn-tiny danger"
                  title="Satırı Sil"
                  onClick={() => onDeleteRow(row.id)}
                >
                  ✕
                </button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      <button className="table-add-row-btn" onClick={() => handleAddNewRow()}>
        <span>+</span>
        <span>Yeni Satır Ekle</span>
      </button>
    </div>
  );

  // ==========================================
  // KANBAN (BOARD) GÖRÜNÜMÜ RENDER
  // ==========================================
  const renderBoardView = () => {
    if (!selectProp || !selectProp.options || selectProp.options.length === 0) {
      return (
        <div style={{ padding: '24px', textAlign: 'center', color: 'var(--text-muted)' }}>
          Kanban panosu için en az bir 'Select' (Durum) kolonu gereklidir. Kolon eklemek için Tablo görünümünü kullanabilirsiniz.
        </div>
      );
    }

    return (
      <div className="kanban-board-container">
        {selectProp.options.map((option) => {
          const colRows = rows.filter((r) => r.cells[selectProp.id] === option.id);

          return (
            <div key={option.id} className="kanban-column">
              <div className="kanban-column-header">
                <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
                  <span
                    style={{
                      width: '10px',
                      height: '10px',
                      borderRadius: '50%',
                      backgroundColor: option.color || 'var(--accent)',
                    }}
                  />
                  <span>{option.name}</span>
                </div>
                <span style={{ color: 'var(--text-muted)', fontSize: '11px' }}>
                  {colRows.length}
                </span>
              </div>

              <div className="kanban-cards-list">
                {colRows.map((card) => {
                  const title = (card.cells[titleProp?.id || ''] as string) || 'Başlıksız Kayıt';
                  const dateVal = dateProp ? (card.cells[dateProp.id] as string) : null;
                  const isChecked = card.cells['prop-done'] as boolean;

                  return (
                    <div key={card.id} className="kanban-card">
                      <div className="kanban-card-title">{title}</div>
                      <div className="kanban-card-meta">
                        {dateVal && <span>📅 {dateVal}</span>}
                        {isChecked && <span>✓ Tamamlandı</span>}
                      </div>

                      {/* Hızlı durum değiştirme */}
                      <div style={{ marginTop: '4px', display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                        <select
                          value={option.id}
                          onChange={(e) => handleCellChange(card, selectProp.id, e.target.value)}
                          style={{
                            fontSize: '11px',
                            background: 'var(--bg-hover)',
                            border: '1px solid var(--border-color)',
                            borderRadius: '4px',
                            color: 'var(--text-secondary)',
                            padding: '2px 4px',
                          }}
                        >
                          {selectProp.options?.map((opt) => (
                            <option key={opt.id} value={opt.id}>
                              → {opt.name}
                            </option>
                          ))}
                        </select>
                        <button
                          className="icon-btn-tiny danger"
                          title="Kartı Sil"
                          onClick={() => onDeleteRow(card.id)}
                        >
                          ✕
                        </button>
                      </div>
                    </div>
                  );
                })}
              </div>

              <button
                className="btn-secondary"
                style={{ fontSize: '12px', padding: '6px' }}
                onClick={() => handleAddNewRow({ [selectProp.id]: option.id })}
              >
                + Kart Ekle
              </button>
            </div>
          );
        })}
      </div>
    );
  };

  // ==========================================
  // TAKVİM GÖRÜNÜMÜ RENDER
  // ==========================================
  const renderCalendarView = () => {
    const year = calendarDate.getFullYear();
    const month = calendarDate.getMonth();

    const monthNames = [
      'Ocak', 'Şubat', 'Mart', 'Nisan', 'Mayıs', 'Haziran',
      'Temmuz', 'Ağustos', 'Eylül', 'Ekim', 'Kasım', 'Aralık',
    ];

    const firstDay = new Date(year, month, 1).getDay(); // 0 is Sunday
    const adjustedFirstDay = (firstDay + 6) % 7; // 0 is Monday
    const daysInMonth = new Date(year, month + 1, 0).getDate();

    const cells = [];
    for (let i = 0; i < adjustedFirstDay; i++) {
      cells.push({ day: null, dateStr: '' });
    }
    for (let day = 1; day <= daysInMonth; day++) {
      const dayStr = day < 10 ? `0${day}` : `${day}`;
      const monthStr = month + 1 < 10 ? `0${month + 1}` : `${month + 1}`;
      const dateStr = `${year}-${monthStr}-${dayStr}`;
      cells.push({ day, dateStr });
    }

    return (
      <div className="calendar-view-container">
        <div className="calendar-header">
          <h3 style={{ fontSize: '16px', fontWeight: 600 }}>
            {monthNames[month]} {year}
          </h3>
          <div style={{ display: 'flex', gap: '6px' }}>
            <button
              className="btn-secondary"
              style={{ padding: '4px 8px', fontSize: '12px' }}
              onClick={() => setCalendarDate(new Date(year, month - 1, 1))}
            >
              ‹ Önceki
            </button>
            <button
              className="btn-secondary"
              style={{ padding: '4px 8px', fontSize: '12px' }}
              onClick={() => setCalendarDate(new Date())}
            >
              Bugün
            </button>
            <button
              className="btn-secondary"
              style={{ padding: '4px 8px', fontSize: '12px' }}
              onClick={() => setCalendarDate(new Date(year, month + 1, 1))}
            >
              Sonraki ›
            </button>
          </div>
        </div>

        <div className="calendar-grid">
          {['Pzt', 'Sal', 'Çar', 'Per', 'Cum', 'Cmt', 'Paz'].map((d) => (
            <div key={d} className="calendar-day-header">
              {d}
            </div>
          ))}

          {cells.map((cell, idx) => {
            if (!cell.day) {
              return <div key={`empty-${idx}`} className="calendar-day-cell other-month" />;
            }

            const dayRows = rows.filter((r) => {
              if (!dateProp) return false;
              const d = r.cells[dateProp.id] as string;
              return d === cell.dateStr;
            });

            return (
              <div
                key={cell.dateStr}
                className="calendar-day-cell"
                onClick={() => {
                  if (dateProp) {
                    handleAddNewRow({ [dateProp.id]: cell.dateStr });
                  }
                }}
              >
                <div className="calendar-day-number">{cell.day}</div>
                {dayRows.map((r) => {
                  const title = (r.cells[titleProp?.id || ''] as string) || 'Kayıt';
                  return (
                    <div key={r.id} className="calendar-event-chip" title={title}>
                      {title}
                    </div>
                  );
                })}
              </div>
            );
          })}
        </div>
      </div>
    );
  };

  return (
    <div className="database-wrapper">
      {/* Görünüm Sekmeleri */}
      <div className="database-view-tabs">
        <button
          className={`view-tab-btn ${activeView === 'table' ? 'active' : ''}`}
          onClick={() => setActiveView('table')}
        >
          <span>📋</span>
          <span>Tablo (Table)</span>
        </button>
        <button
          className={`view-tab-btn ${activeView === 'board' ? 'active' : ''}`}
          onClick={() => setActiveView('board')}
        >
          <span>📊</span>
          <span>Kanban Panosu (Board)</span>
        </button>
        <button
          className={`view-tab-btn ${activeView === 'calendar' ? 'active' : ''}`}
          onClick={() => setActiveView('calendar')}
        >
          <span>📅</span>
          <span>Takvim (Calendar)</span>
        </button>
      </div>

      {/* Aktif Görünüm */}
      {activeView === 'table' && renderTableView()}
      {activeView === 'board' && renderBoardView()}
      {activeView === 'calendar' && renderCalendarView()}

      {/* YENİ KOLON EKLEME MODALI */}
      {showAddPropertyModal && (
        <div className="modal-overlay">
          <div className="sync-modal-card" style={{ width: '380px' }}>
            <h3 style={{ fontSize: '16px', fontWeight: 600 }}>Yeni Kolon (Property) Ekle</h3>
            <form onSubmit={handleAddProperty} style={{ display: 'flex', flexDirection: 'column', gap: '12px' }}>
              <div>
                <label style={{ fontSize: '12px', color: 'var(--text-secondary)' }}>Kolon Adı</label>
                <input
                  type="text"
                  className="lockscreen-input"
                  style={{ marginTop: '4px' }}
                  placeholder="örn: Öncelik, Kategori, Bitiş..."
                  value={newPropName}
                  onChange={(e) => setNewPropName(e.target.value)}
                  autoFocus
                />
              </div>

              <div>
                <label style={{ fontSize: '12px', color: 'var(--text-secondary)' }}>Veri Türü</label>
                <select
                  className="lockscreen-input"
                  style={{ marginTop: '4px' }}
                  value={newPropType}
                  onChange={(e) => setNewPropType(e.target.value as PropertyType)}
                >
                  <option value="text">Metin (Text)</option>
                  <option value="select">Seçim (Select)</option>
                  <option value="date">Tarih (Date)</option>
                  <option value="checkbox">Onay Kutusu (Checkbox)</option>
                  <option value="number">Sayı (Number)</option>
                </select>
              </div>

              <div style={{ display: 'flex', gap: '8px', marginTop: '12px' }}>
                <button
                  type="button"
                  className="btn-secondary"
                  onClick={() => setShowAddPropertyModal(false)}
                >
                  İptal
                </button>
                <button type="submit" className="btn-primary">
                  Ekle
                </button>
              </div>
            </form>
          </div>
        </div>
      )}
    </div>
  );
};
