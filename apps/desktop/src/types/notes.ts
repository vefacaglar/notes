/**
 * Notes Rust Çekirdeği ile tam uyumlu TypeScript Tipleri
 */

export type BlockType =
  | 'paragraph'
  | 'heading1'
  | 'heading2'
  | 'heading3'
  | 'bullet_list_item'
  | 'numbered_list_item'
  | 'todo_item'
  | 'code_block'
  | 'quote'
  | 'callout'
  | 'divider'
  | 'image'
  | 'file'
  | 'database_inline';

export interface BlockContent {
  text?: string;
  checked?: boolean;
  language?: string;
  url?: string;
  caption?: string;
  level?: number;
  [key: string]: unknown;
}

export interface Block {
  id: string;
  page_id: string;
  parent_block_id?: string | null;
  block_type: BlockType;
  content: BlockContent;
  properties: Record<string, unknown>;
  sort_order: number;
  created_at: string;
  updated_at: string;
}

export interface Page {
  id: string;
  workspace_id: string;
  parent_page_id?: string | null;
  title: string;
  icon?: string | null;
  cover_image?: string | null;
  is_database: boolean;
  is_pinned: boolean;
  is_deleted: boolean;
  created_at: string;
  updated_at: string;
}

export type PropertyType =
  | 'text'
  | 'number'
  | 'select'
  | 'multi_select'
  | 'date'
  | 'checkbox'
  | 'url'
  | 'email'
  | 'relation'
  | 'created_time'
  | 'last_edited_time';

export interface SelectOption {
  id: string;
  name: string;
  color?: string;
}

export interface DatabasePropertyDefinition {
  id: string;
  name: string;
  property_type: PropertyType;
  options?: SelectOption[];
  position: number;
}

export interface DatabaseSchema {
  id: string;
  page_id: string;
  properties: DatabasePropertyDefinition[];
  created_at: string;
  updated_at: string;
}

export interface DatabaseRow {
  id: string;
  page_id: string;
  cells: Record<string, unknown>;
  sort_order: number;
  created_at: string;
  updated_at: string;
}

export type ViewType = 'table' | 'board' | 'calendar';

export interface BacklinkItem {
  pageId: string;
  pageTitle: string;
  snippet: string;
  blockId: string;
}

export interface SearchResult {
  page: Page;
  snippet: string;
  matchedBlockId?: string;
}

export interface SyncStatus {
  connected: boolean;
  serverUrl: string;
  lastSyncedAt?: string | null;
  pendingOutboxCount: number;
  deviceId: string;
  isSyncing: boolean;
  errorMessage?: string | null;
}

export interface VaultStatus {
  isUnlocked: boolean;
  isConfigured: boolean;
  keychainAvailable: boolean;
}
