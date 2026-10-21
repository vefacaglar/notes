import type {
  Block,
  BlockType,
  DatabaseRow,
  DatabaseSchema,
  Page,
  SearchResult,
  SyncStatus,
  VaultStatus,
  BacklinkItem,
} from '../types/notes';

// Tauri v2 invoke türü
type InvokeFn = <T>(cmd: string, args?: Record<string, unknown>) => Promise<T>;

declare global {
  interface Window {
    __TAURI_INTERNALS__?: Record<string, unknown>;
    __TAURI__?: {
      core?: {
        invoke: InvokeFn;
      };
    };
  }
}

export const isTauri = (): boolean => {
  return typeof window !== 'undefined' && (!!window.__TAURI_INTERNALS__ || !!window.__TAURI__);
};

// Tauri dinamik invoke çağrısı
async function tauriInvoke<T>(cmd: string, args?: Record<string, unknown>): Promise<T> {
  if (window.__TAURI__?.core?.invoke) {
    return window.__TAURI__.core.invoke<T>(cmd, args);
  }
  try {
    const { invoke } = await import('@tauri-apps/api/core');
    return invoke<T>(cmd, args);
  } catch (err) {
    console.warn(`[Tauri IPC] ${cmd} invoke fallback hatası:`, err);
    throw err;
  }
}

// ==========================================
// MOCK STATE & LOCAL FALLBACK IMPLEMENTATION
// ==========================================

const STORAGE_KEY_PREFIX = 'notes_desktop_v1_';

const SEED_WORKSPACE_ID = '01918a55-0000-7000-8000-000000000001';
const SEED_PAGE_WELCOME_ID = '01918a55-0000-7000-8000-000000000010';
const SEED_PAGE_TASKS_ID = '01918a55-0000-7000-8000-000000000020';
const SEED_PAGE_ARCH_ID = '01918a55-0000-7000-8000-000000000030';

const initialPages: Page[] = [
  {
    id: SEED_PAGE_WELCOME_ID,
    workspace_id: SEED_WORKSPACE_ID,
    parent_page_id: null,
    title: 'Hızlı Başlangıç & Hoş Geldiniz',
    icon: '👋',
    cover_image: null,
    is_database: false,
    is_pinned: true,
    is_deleted: false,
    created_at: new Date(Date.now() - 86400000 * 3).toISOString(),
    updated_at: new Date(Date.now() - 3600000).toISOString(),
  },
  {
    id: SEED_PAGE_ARCH_ID,
    workspace_id: SEED_WORKSPACE_ID,
    parent_page_id: SEED_PAGE_WELCOME_ID,
    title: 'Mimari Tasarım Notları',
    icon: '🏗️',
    cover_image: null,
    is_database: false,
    is_pinned: false,
    is_deleted: false,
    created_at: new Date(Date.now() - 86400000 * 2).toISOString(),
    updated_at: new Date(Date.now() - 7200000).toISOString(),
  },
  {
    id: SEED_PAGE_TASKS_ID,
    workspace_id: SEED_WORKSPACE_ID,
    parent_page_id: null,
    title: 'Sprint Görevleri & Yol Haritası',
    icon: '🚀',
    cover_image: null,
    is_database: true,
    is_pinned: true,
    is_deleted: false,
    created_at: new Date(Date.now() - 86400000 * 5).toISOString(),
    updated_at: new Date(Date.now() - 1800000).toISOString(),
  },
];

const initialBlocks: Record<string, Block[]> = {
  [SEED_PAGE_WELCOME_ID]: [
    {
      id: 'b-101',
      page_id: SEED_PAGE_WELCOME_ID,
      block_type: 'heading1',
      content: { text: 'Notes — Local-First & Uçtan Uca Şifreli Çalışma Alanı' },
      properties: {},
      sort_order: 1,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    },
    {
      id: 'b-102',
      page_id: SEED_PAGE_WELCOME_ID,
      block_type: 'callout',
      content: {
        text: 'Bu not defteri XChaCha20-Poly1305 ve Argon2id ile donatılmıştır. Verileriniz yalnızca cihazınızda çözülür; bulut sunucusu sıfır bilgiye (Zero-Knowledge) sahiptir.',
      },
      properties: { icon: '🛡️' },
      sort_order: 2,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    },
    {
      id: 'b-103',
      page_id: SEED_PAGE_WELCOME_ID,
      block_type: 'paragraph',
      content: {
        text: 'Yeni bir blok eklemek için satır başında / yazabilir veya Markdown kısayollarını kullanabilirsiniz. Detaylar için [[Mimari Tasarım Notları]] sayfasına göz atın. #rehber #guvenlik',
      },
      properties: {},
      sort_order: 3,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    },
    {
      id: 'b-104',
      page_id: SEED_PAGE_WELCOME_ID,
      block_type: 'heading2',
      content: { text: 'Öne Çıkan Özellikler' },
      properties: {},
      sort_order: 4,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    },
    {
      id: 'b-105',
      page_id: SEED_PAGE_WELCOME_ID,
      block_type: 'todo_item',
      content: { text: 'Hiyerarşik sayfa ağacını test et', checked: true },
      properties: {},
      sort_order: 5,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    },
    {
      id: 'b-106',
      page_id: SEED_PAGE_WELCOME_ID,
      block_type: 'todo_item',
      content: { text: 'Cmd+K ile anlık spotlight aramasını dene', checked: true },
      properties: {},
      sort_order: 6,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    },
    {
      id: 'b-107',
      page_id: SEED_PAGE_WELCOME_ID,
      block_type: 'todo_item',
      content: { text: 'Veritabanı Tablo, Kanban ve Takvim görünümlerini keşfet', checked: false },
      properties: {},
      sort_order: 7,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    },
    {
      id: 'b-108',
      page_id: SEED_PAGE_WELCOME_ID,
      block_type: 'code_block',
      content: {
        text: '// Rust tarafındaki CRDT & E2EE motoru\nlet cipher = XChaCha20Poly1305::new(&kek_key);\nprintln!("Notes vault başarıyla açıldı!");',
        language: 'rust',
      },
      properties: {},
      sort_order: 8,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    },
    {
      id: 'b-109',
      page_id: SEED_PAGE_WELCOME_ID,
      block_type: 'quote',
      content: {
        text: 'Gizlilik bir ayrıcalık değil, dijital egemenliğin temel gereksinimidir.',
      },
      properties: {},
      sort_order: 9,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    },
  ],
  [SEED_PAGE_ARCH_ID]: [
    {
      id: 'b-201',
      page_id: SEED_PAGE_ARCH_ID,
      block_type: 'heading1',
      content: { text: 'Sistem Mimarisi & CRDT Protokolü' },
      properties: {},
      sort_order: 1,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    },
    {
      id: 'b-202',
      page_id: SEED_PAGE_ARCH_ID,
      block_type: 'paragraph',
      content: {
        text: 'Tüm not blokları Yrs (Yjs Rust portu) tabanlı LWW-Register ve Text CRDT yapılarıyla saklanır. Bu sayede çevrimdışı değişiklikler çakışmasız birleşir. Bağlantılı sayfa: [[Hızlı Başlangıç & Hoş Geldiniz]]. #mimari #crdt',
      },
      properties: {},
      sort_order: 2,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    },
  ],
};

const initialSchema: DatabaseSchema = {
  id: 'schema-1',
  page_id: SEED_PAGE_TASKS_ID,
  properties: [
    { id: 'prop-title', name: 'Görev Adı', property_type: 'text', position: 0 },
    {
      id: 'prop-status',
      name: 'Durum',
      property_type: 'select',
      position: 1,
      options: [
        { id: 'opt-todo', name: 'Yapılacak', color: '#f59e0b' },
        { id: 'opt-in-progress', name: 'Devam Ediyor', color: '#3b82f6' },
        { id: 'opt-done', name: 'Tamamlandı', color: '#10b981' },
      ],
    },
    {
      id: 'prop-priority',
      name: 'Öncelik',
      property_type: 'select',
      position: 2,
      options: [
        { id: 'opt-p1', name: 'Yüksek', color: '#ef4444' },
        { id: 'opt-p2', name: 'Orta', color: '#f97316' },
        { id: 'opt-p3', name: 'Düşük', color: '#6b7280' },
      ],
    },
    { id: 'prop-date', name: 'Bitiş Tarihi', property_type: 'date', position: 3 },
    { id: 'prop-done', name: 'Tamam', property_type: 'checkbox', position: 4 },
  ],
  created_at: new Date().toISOString(),
  updated_at: new Date().toISOString(),
};

const initialRows: DatabaseRow[] = [
  {
    id: 'row-1',
    page_id: SEED_PAGE_TASKS_ID,
    cells: {
      'prop-title': 'macOS Keychain Entegrasyonunu Test Et',
      'prop-status': 'opt-done',
      'prop-priority': 'opt-p1',
      'prop-date': '2026-10-22',
      'prop-done': true,
    },
    sort_order: 1,
    created_at: new Date(Date.now() - 86400000 * 2).toISOString(),
    updated_at: new Date().toISOString(),
  },
  {
    id: 'row-2',
    page_id: SEED_PAGE_TASKS_ID,
    cells: {
      'prop-title': 'Notion Tarzı Veritabanı Görünümleri (WP-6.3)',
      'prop-status': 'opt-in-progress',
      'prop-priority': 'opt-p1',
      'prop-date': '2026-10-24',
      'prop-done': false,
    },
    sort_order: 2,
    created_at: new Date(Date.now() - 86400000).toISOString(),
    updated_at: new Date().toISOString(),
  },
  {
    id: 'row-3',
    page_id: SEED_PAGE_TASKS_ID,
    cells: {
      'prop-title': 'Slash Komut Editörü Klavye Kısayolları',
      'prop-status': 'opt-done',
      'prop-priority': 'opt-p2',
      'prop-date': '2026-10-21',
      'prop-done': true,
    },
    sort_order: 3,
    created_at: new Date(Date.now() - 86400000).toISOString(),
    updated_at: new Date().toISOString(),
  },
  {
    id: 'row-4',
    page_id: SEED_PAGE_TASKS_ID,
    cells: {
      'prop-title': 'WebSocket Zarfları E2EE Senkronizasyon Testi',
      'prop-status': 'opt-todo',
      'prop-priority': 'opt-p2',
      'prop-date': '2026-10-28',
      'prop-done': false,
    },
    sort_order: 4,
    created_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
  },
];

class LocalMockStore {
  private pages: Page[];
  private blocks: Record<string, Block[]>;
  private schemas: Record<string, DatabaseSchema>;
  private rows: Record<string, DatabaseRow[]>;
  private isUnlocked: boolean = true;
  private isConfigured: boolean = true;
  private syncStatus: SyncStatus = {
    connected: true,
    serverUrl: 'https://api.notes.selfhosted.local',
    lastSyncedAt: new Date(Date.now() - 1000 * 60 * 12).toISOString(),
    pendingOutboxCount: 2,
    deviceId: 'macbook-pro-m3-e2ee',
    isSyncing: false,
    errorMessage: null,
  };

  constructor() {
    this.pages = this.load('pages', initialPages);
    this.blocks = this.load('blocks', initialBlocks);
    this.schemas = this.load('schemas', { [SEED_PAGE_TASKS_ID]: initialSchema });
    this.rows = this.load('rows', { [SEED_PAGE_TASKS_ID]: initialRows });
    const savedConfig = this.load<boolean>('configured', true);
    this.isConfigured = savedConfig;
  }

  private load<T>(key: string, fallback: T): T {
    try {
      const item = localStorage.getItem(STORAGE_KEY_PREFIX + key);
      return item ? JSON.parse(item) : fallback;
    } catch {
      return fallback;
    }
  }

  private save<T>(key: string, value: T): void {
    try {
      localStorage.setItem(STORAGE_KEY_PREFIX + key, JSON.stringify(value));
    } catch (err) {
      console.warn('LocalStorage save error:', err);
    }
  }

  getVaultStatus(): VaultStatus {
    return {
      isUnlocked: this.isUnlocked,
      isConfigured: this.isConfigured,
      keychainAvailable: true,
    };
  }

  unlockVault(password: string): { success: boolean; token?: string; error?: string } {
    if (!password || password.trim().length === 0) {
      return { success: false, error: 'Parola boş bırakılamaz.' };
    }
    // Basit doğrulama veya setup parolası
    this.isUnlocked = true;
    return { success: true, token: 'mock-session-token-e2ee' };
  }

  unlockWithTouchId(): { success: boolean; token?: string; error?: string } {
    this.isUnlocked = true;
    return { success: true, token: 'touchid-keychain-auth-token' };
  }

  setupVault(password: string): { success: boolean } {
    if (password.length < 4) {
      throw new Error('Ana parola en az 4 karakter olmalıdır.');
    }
    this.isConfigured = true;
    this.isUnlocked = true;
    this.save('configured', true);
    return { success: true };
  }

  lockVault(): void {
    this.isUnlocked = false;
  }

  getPages(): Page[] {
    return this.pages.filter((p) => !p.is_deleted);
  }

  getPage(id: string): Page | null {
    return this.pages.find((p) => p.id === id && !p.is_deleted) || null;
  }

  createPage(title: string, parentPageId?: string | null, isDatabase: boolean = false): Page {
    const newPage: Page = {
      id: 'p-' + Date.now().toString(36) + '-' + Math.random().toString(36).substring(2, 6),
      workspace_id: SEED_WORKSPACE_ID,
      parent_page_id: parentPageId || null,
      title: title.trim() || (isDatabase ? 'Yeni Veritabanı' : 'Başlıksız'),
      icon: isDatabase ? '🗄️' : '📄',
      cover_image: null,
      is_database: isDatabase,
      is_pinned: false,
      is_deleted: false,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    };

    this.pages.unshift(newPage);
    this.save('pages', this.pages);

    if (isDatabase) {
      const defaultSchema: DatabaseSchema = {
        id: 'schema-' + newPage.id,
        page_id: newPage.id,
        properties: [
          { id: 'prop-name', name: 'İsim', property_type: 'text', position: 0 },
          {
            id: 'prop-status',
            name: 'Durum',
            property_type: 'select',
            position: 1,
            options: [
              { id: 'opt-1', name: 'Yapılacak', color: '#f59e0b' },
              { id: 'opt-2', name: 'Tamamlandı', color: '#10b981' },
            ],
          },
          { id: 'prop-date', name: 'Tarih', property_type: 'date', position: 2 },
        ],
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      };
      this.schemas[newPage.id] = defaultSchema;
      this.rows[newPage.id] = [
        {
          id: 'row-' + Date.now(),
          page_id: newPage.id,
          cells: {
            'prop-name': 'İlk Kayıt',
            'prop-status': 'opt-1',
            'prop-date': new Date().toISOString().split('T')[0],
          },
          sort_order: 1,
          created_at: new Date().toISOString(),
          updated_at: new Date().toISOString(),
        },
      ];
      this.save('schemas', this.schemas);
      this.save('rows', this.rows);
    } else {
      this.blocks[newPage.id] = [
        {
          id: 'b-' + Date.now(),
          page_id: newPage.id,
          block_type: 'paragraph',
          content: { text: '' },
          properties: {},
          sort_order: 1,
          created_at: new Date().toISOString(),
          updated_at: new Date().toISOString(),
        },
      ];
      this.save('blocks', this.blocks);
    }

    return newPage;
  }

  updatePage(pageUpdates: Partial<Page> & { id: string }): Page {
    const idx = this.pages.findIndex((p) => p.id === pageUpdates.id);
    if (idx === -1) throw new Error('Sayfa bulunamadı');
    const updated = {
      ...this.pages[idx],
      ...pageUpdates,
      updated_at: new Date().toISOString(),
    };
    this.pages[idx] = updated;
    this.save('pages', this.pages);
    return updated;
  }

  deletePage(id: string): void {
    const page = this.pages.find((p) => p.id === id);
    if (page) {
      page.is_deleted = true;
      this.save('pages', this.pages);
    }
  }

  getBlocks(pageId: string): Block[] {
    const list = this.blocks[pageId] || [];
    return [...list].sort((a, b) => a.sort_order - b.sort_order);
  }

  saveBlock(blockData: Partial<Block> & { page_id: string; block_type: BlockType }): Block {
    const pageId = blockData.page_id;
    if (!this.blocks[pageId]) {
      this.blocks[pageId] = [];
    }

    let saved: Block;
    if (blockData.id) {
      const idx = this.blocks[pageId].findIndex((b) => b.id === blockData.id);
      if (idx >= 0) {
        saved = {
          ...this.blocks[pageId][idx],
          ...blockData,
          updated_at: new Date().toISOString(),
        } as Block;
        this.blocks[pageId][idx] = saved;
      } else {
        saved = {
          id: blockData.id,
          page_id: pageId,
          parent_block_id: blockData.parent_block_id ?? null,
          block_type: blockData.block_type,
          content: blockData.content || {},
          properties: blockData.properties || {},
          sort_order: blockData.sort_order ?? this.blocks[pageId].length + 1,
          created_at: new Date().toISOString(),
          updated_at: new Date().toISOString(),
        };
        this.blocks[pageId].push(saved);
      }
    } else {
      saved = {
        id: 'b-' + Date.now().toString(36) + '-' + Math.random().toString(36).substring(2, 6),
        page_id: pageId,
        parent_block_id: blockData.parent_block_id ?? null,
        block_type: blockData.block_type,
        content: blockData.content || {},
        properties: blockData.properties || {},
        sort_order: blockData.sort_order ?? this.blocks[pageId].length + 1,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      };
      this.blocks[pageId].push(saved);
    }

    this.save('blocks', this.blocks);
    return saved;
  }

  deleteBlock(id: string): void {
    for (const pageId in this.blocks) {
      const idx = this.blocks[pageId].findIndex((b) => b.id === id);
      if (idx >= 0) {
        this.blocks[pageId].splice(idx, 1);
        this.save('blocks', this.blocks);
        break;
      }
    }
  }

  reorderBlocks(pageId: string, blockIds: string[]): void {
    const current = this.blocks[pageId] || [];
    const map = new Map(current.map((b) => [b.id, b]));
    const reordered: Block[] = [];

    blockIds.forEach((id, index) => {
      const b = map.get(id);
      if (b) {
        b.sort_order = index + 1;
        b.updated_at = new Date().toISOString();
        reordered.push(b);
      }
    });

    this.blocks[pageId] = reordered;
    this.save('blocks', this.blocks);
  }

  getDatabaseSchema(pageId: string): DatabaseSchema | null {
    return this.schemas[pageId] || null;
  }

  saveDatabaseSchema(schema: DatabaseSchema): DatabaseSchema {
    this.schemas[schema.page_id] = {
      ...schema,
      updated_at: new Date().toISOString(),
    };
    this.save('schemas', this.schemas);
    return this.schemas[schema.page_id];
  }

  getDatabaseRows(pageId: string): DatabaseRow[] {
    return this.rows[pageId] || [];
  }

  saveDatabaseRow(rowData: Partial<DatabaseRow> & { page_id: string }): DatabaseRow {
    const pageId = rowData.page_id;
    if (!this.rows[pageId]) {
      this.rows[pageId] = [];
    }

    let saved: DatabaseRow;
    if (rowData.id) {
      const idx = this.rows[pageId].findIndex((r) => r.id === rowData.id);
      if (idx >= 0) {
        saved = {
          ...this.rows[pageId][idx],
          ...rowData,
          updated_at: new Date().toISOString(),
        } as DatabaseRow;
        this.rows[pageId][idx] = saved;
      } else {
        saved = {
          id: rowData.id,
          page_id: pageId,
          cells: rowData.cells || {},
          sort_order: rowData.sort_order ?? this.rows[pageId].length + 1,
          created_at: new Date().toISOString(),
          updated_at: new Date().toISOString(),
        };
        this.rows[pageId].push(saved);
      }
    } else {
      saved = {
        id: 'r-' + Date.now().toString(36) + '-' + Math.random().toString(36).substring(2, 6),
        page_id: pageId,
        cells: rowData.cells || {},
        sort_order: rowData.sort_order ?? this.rows[pageId].length + 1,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      };
      this.rows[pageId].push(saved);
    }

    this.save('rows', this.rows);
    return saved;
  }

  deleteDatabaseRow(id: string): void {
    for (const pageId in this.rows) {
      const idx = this.rows[pageId].findIndex((r) => r.id === id);
      if (idx >= 0) {
        this.rows[pageId].splice(idx, 1);
        this.save('rows', this.rows);
        break;
      }
    }
  }

  getBacklinks(pageId: string): BacklinkItem[] {
    const targetPage = this.getPage(pageId);
    if (!targetPage) return [];

    const titleRef = `[[${targetPage.title}]]`;
    const results: BacklinkItem[] = [];

    for (const p of this.pages) {
      if (p.id === pageId || p.is_deleted) continue;
      const blocks = this.blocks[p.id] || [];
      for (const b of blocks) {
        const text = b.content.text || '';
        if (text.includes(titleRef) || text.includes(`[[${pageId}]]`)) {
          results.push({
            pageId: p.id,
            pageTitle: p.title,
            snippet: text,
            blockId: b.id,
          });
        }
      }
    }
    return results;
  }

  searchNotes(query: string): SearchResult[] {
    const q = query.trim().toLowerCase();
    if (!q) return [];

    const results: SearchResult[] = [];
    for (const page of this.pages) {
      if (page.is_deleted) continue;

      let matchedSnippet = '';
      let matchedBlockId: string | undefined;

      if (page.title.toLowerCase().includes(q)) {
        matchedSnippet = `Sayfa Başlığı: ${page.title}`;
        results.push({ page, snippet: matchedSnippet });
        continue;
      }

      const blocks = this.blocks[page.id] || [];
      for (const block of blocks) {
        const text = block.content.text || '';
        if (text.toLowerCase().includes(q)) {
          matchedSnippet = text;
          matchedBlockId = block.id;
          break;
        }
      }

      if (matchedSnippet) {
        results.push({ page, snippet: matchedSnippet, matchedBlockId });
      }
    }

    return results;
  }

  getSyncStatus(): SyncStatus {
    return { ...this.syncStatus };
  }

  updateSyncSettings(serverUrl: string): SyncStatus {
    this.syncStatus.serverUrl = serverUrl;
    this.save('sync_status', this.syncStatus);
    return { ...this.syncStatus };
  }

  async triggerSync(): Promise<SyncStatus> {
    this.syncStatus.isSyncing = true;
    await new Promise((resolve) => setTimeout(resolve, 800));
    this.syncStatus.isSyncing = false;
    this.syncStatus.lastSyncedAt = new Date().toISOString();
    this.syncStatus.pendingOutboxCount = 0;
    this.save('sync_status', this.syncStatus);
    return { ...this.syncStatus };
  }
}

const mockStore = new LocalMockStore();

// ==========================================
// EXPORTED DUAL-MODE IPC CLIENT
// ==========================================

export const ipcClient = {
  isTauri,

  async getVaultStatus(): Promise<VaultStatus> {
    if (isTauri()) {
      return tauriInvoke<VaultStatus>('plugin:vault|get_status');
    }
    return mockStore.getVaultStatus();
  },

  async unlockVault(masterPassword: string): Promise<{ success: boolean; token?: string; error?: string }> {
    if (isTauri()) {
      return tauriInvoke('plugin:vault|unlock', { masterPassword });
    }
    return mockStore.unlockVault(masterPassword);
  },

  async unlockWithTouchId(): Promise<{ success: boolean; token?: string; error?: string }> {
    if (isTauri()) {
      return tauriInvoke('plugin:vault|unlock_touch_id');
    }
    return mockStore.unlockWithTouchId();
  },

  async setupVault(masterPassword: string): Promise<{ success: boolean }> {
    if (isTauri()) {
      return tauriInvoke('plugin:vault|setup', { masterPassword });
    }
    return mockStore.setupVault(masterPassword);
  },

  async lockVault(): Promise<void> {
    if (isTauri()) {
      await tauriInvoke('plugin:vault|lock');
      return;
    }
    mockStore.lockVault();
  },

  async getPages(): Promise<Page[]> {
    if (isTauri()) {
      return tauriInvoke<Page[]>('plugin:notes|get_pages');
    }
    return mockStore.getPages();
  },

  async getPage(id: string): Promise<Page | null> {
    if (isTauri()) {
      return tauriInvoke<Page | null>('plugin:notes|get_page', { id });
    }
    return mockStore.getPage(id);
  },

  async createPage(title: string, parentPageId?: string | null, isDatabase: boolean = false): Promise<Page> {
    if (isTauri()) {
      return tauriInvoke<Page>('plugin:notes|create_page', {
        title,
        parentPageId,
        isDatabase,
      });
    }
    return mockStore.createPage(title, parentPageId, isDatabase);
  },

  async updatePage(page: Partial<Page> & { id: string }): Promise<Page> {
    if (isTauri()) {
      return tauriInvoke<Page>('plugin:notes|update_page', { page });
    }
    return mockStore.updatePage(page);
  },

  async deletePage(id: string): Promise<void> {
    if (isTauri()) {
      await tauriInvoke('plugin:notes|delete_page', { id });
      return;
    }
    mockStore.deletePage(id);
  },

  async getBlocks(pageId: string): Promise<Block[]> {
    if (isTauri()) {
      return tauriInvoke<Block[]>('plugin:notes|get_blocks', { pageId });
    }
    return mockStore.getBlocks(pageId);
  },

  async saveBlock(block: Partial<Block> & { page_id: string; block_type: BlockType }): Promise<Block> {
    if (isTauri()) {
      return tauriInvoke<Block>('plugin:notes|save_block', { block });
    }
    return mockStore.saveBlock(block);
  },

  async deleteBlock(id: string): Promise<void> {
    if (isTauri()) {
      await tauriInvoke('plugin:notes|delete_block', { id });
      return;
    }
    mockStore.deleteBlock(id);
  },

  async reorderBlocks(pageId: string, blockIds: string[]): Promise<void> {
    if (isTauri()) {
      await tauriInvoke('plugin:notes|reorder_blocks', { pageId, blockIds });
      return;
    }
    mockStore.reorderBlocks(pageId, blockIds);
  },

  async getDatabaseSchema(pageId: string): Promise<DatabaseSchema | null> {
    if (isTauri()) {
      return tauriInvoke<DatabaseSchema | null>('plugin:database|get_schema', { pageId });
    }
    return mockStore.getDatabaseSchema(pageId);
  },

  async saveDatabaseSchema(schema: DatabaseSchema): Promise<DatabaseSchema> {
    if (isTauri()) {
      return tauriInvoke<DatabaseSchema>('plugin:database|save_schema', { schema });
    }
    return mockStore.saveDatabaseSchema(schema);
  },

  async getDatabaseRows(pageId: string): Promise<DatabaseRow[]> {
    if (isTauri()) {
      return tauriInvoke<DatabaseRow[]>('plugin:database|get_rows', { pageId });
    }
    return mockStore.getDatabaseRows(pageId);
  },

  async saveDatabaseRow(row: Partial<DatabaseRow> & { page_id: string }): Promise<DatabaseRow> {
    if (isTauri()) {
      return tauriInvoke<DatabaseRow>('plugin:database|save_row', { row });
    }
    return mockStore.saveDatabaseRow(row);
  },

  async deleteDatabaseRow(id: string): Promise<void> {
    if (isTauri()) {
      await tauriInvoke('plugin:database|delete_row', { id });
      return;
    }
    mockStore.deleteDatabaseRow(id);
  },

  async getBacklinks(pageId: string): Promise<BacklinkItem[]> {
    if (isTauri()) {
      return tauriInvoke<BacklinkItem[]>('plugin:notes|get_backlinks', { pageId });
    }
    return mockStore.getBacklinks(pageId);
  },

  async searchNotes(query: string): Promise<SearchResult[]> {
    if (isTauri()) {
      return tauriInvoke<SearchResult[]>('plugin:search|query', { query });
    }
    return mockStore.searchNotes(query);
  },

  async getSyncStatus(): Promise<SyncStatus> {
    if (isTauri()) {
      return tauriInvoke<SyncStatus>('plugin:sync|get_status');
    }
    return mockStore.getSyncStatus();
  },

  async updateSyncSettings(serverUrl: string): Promise<SyncStatus> {
    if (isTauri()) {
      return tauriInvoke<SyncStatus>('plugin:sync|update_settings', { serverUrl });
    }
    return mockStore.updateSyncSettings(serverUrl);
  },

  async triggerSync(): Promise<SyncStatus> {
    if (isTauri()) {
      return tauriInvoke<SyncStatus>('plugin:sync|trigger_sync');
    }
    return mockStore.triggerSync();
  },
};
