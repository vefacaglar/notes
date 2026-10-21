use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use notes_core::model::database::{DatabaseSchema, DatabaseView, ViewType};
use notes_core::model::property::DatabasePropertyDefinition;

use crate::state::{AppError, DesktopAppState};

/// Veritabanı sorgu sonucu satır modeli.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DatabaseRow {
    pub page_id: Uuid,
    pub title: String,
    pub icon: Option<String>,
    pub properties: serde_json::Value,
    pub created_at: i64,
    pub updated_at: i64,
}

/// Veritabanı görünüm sorgulama sonucu.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DatabaseQueryResult {
    pub database_id: Uuid,
    pub view_id: Uuid,
    pub view_type: ViewType,
    pub rows: Vec<DatabaseRow>,
    pub total_count: usize,
}

/// Sayfa üzerinde yeni bir Notion tarzı Database şeması ve varsayılan Table görünümü oluşturur.
pub fn cmd_create_database(
    state: &DesktopAppState,
    page_id: Uuid,
    properties: Vec<DatabasePropertyDefinition>,
) -> Result<DatabaseSchema, AppError> {
    state.require_unlocked()?;

    let store = state.store.lock().map_err(|e| AppError::Internal(e.to_string()))?;
    let conn = store.conn();

    // 1. Sayfayı is_database = 1 olarak güncelle
    conn.execute(
        "UPDATE pages SET is_database = 1, updated_at = ?1 WHERE id = ?2",
        rusqlite::params![Utc::now().timestamp_millis(), page_id.to_string()],
    )
    .map_err(|e| AppError::DatabaseError(format!("Sayfa veritabanı olarak işaretlenemedi: {e}")))?;

    // 2. DatabaseSchema oluştur ve kaydet
    let mut schema = DatabaseSchema::new(page_id);
    for prop in properties {
        schema.add_property(prop);
    }

    let props_json = serde_json::to_string(&schema.properties)
        .map_err(|e| AppError::Internal(e.to_string()))?;

    conn.execute(
        "INSERT INTO databases (id, page_id, properties_json, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5)",
        rusqlite::params![
            schema.id.to_string(),
            schema.page_id.to_string(),
            props_json,
            schema.created_at.timestamp_millis(),
            schema.updated_at.timestamp_millis(),
        ],
    )
    .map_err(|e| AppError::DatabaseError(format!("Veritabanı oluşturulamadı: {e}")))?;

    // 3. Varsayılan Tablo (Table) Görünümünü otomatik ekle
    let default_view = DatabaseView::new(schema.id, "Tablo Görünümü", ViewType::Table);
    save_view_to_db(conn, &default_view)?;

    Ok(schema)
}

/// Sayfa UUID'sine göre veritabanı şemasını getirir.
pub fn cmd_get_database(state: &DesktopAppState, page_id: Uuid) -> Result<DatabaseSchema, AppError> {
    state.require_unlocked()?;

    let store = state.store.lock().map_err(|e| AppError::Internal(e.to_string()))?;
    let conn = store.conn();

    let mut stmt = conn
        .prepare("SELECT id, page_id, properties_json, created_at, updated_at FROM databases WHERE page_id = ?1")
        .map_err(|e| AppError::DatabaseError(e.to_string()))?;

    let mut rows = stmt
        .query(rusqlite::params![page_id.to_string()])
        .map_err(|e| AppError::DatabaseError(e.to_string()))?;

    if let Some(row) = rows.next().map_err(|e| AppError::DatabaseError(e.to_string()))? {
        map_database_row(row)
    } else {
        Err(AppError::NotFound(format!("Bu sayfada veritabanı bulunamadı: {page_id}")))
    }
}

/// Veritabanına yeni bir kolon/özellik (Property: Select, MultiSelect, Date, Checkbox vb.) ekler.
pub fn cmd_add_database_property(
    state: &DesktopAppState,
    database_id: Uuid,
    property: DatabasePropertyDefinition,
) -> Result<DatabaseSchema, AppError> {
    state.require_unlocked()?;

    let store = state.store.lock().map_err(|e| AppError::Internal(e.to_string()))?;
    let conn = store.conn();

    let mut stmt = conn
        .prepare("SELECT id, page_id, properties_json, created_at, updated_at FROM databases WHERE id = ?1")
        .map_err(|e| AppError::DatabaseError(e.to_string()))?;

    let mut rows = stmt
        .query(rusqlite::params![database_id.to_string()])
        .map_err(|e| AppError::DatabaseError(e.to_string()))?;

    let mut schema = if let Some(row) = rows.next().map_err(|e| AppError::DatabaseError(e.to_string()))? {
        map_database_row(row)?
    } else {
        return Err(AppError::NotFound(format!("Veritabanı bulunamadı: {database_id}")));
    };

    schema.add_property(property);

    let props_json = serde_json::to_string(&schema.properties)
        .map_err(|e| AppError::Internal(e.to_string()))?;

    conn.execute(
        "UPDATE databases SET properties_json = ?1, updated_at = ?2 WHERE id = ?3",
        rusqlite::params![
            props_json,
            schema.updated_at.timestamp_millis(),
            schema.id.to_string(),
        ],
    )
    .map_err(|e| AppError::DatabaseError(format!("Kolon eklenemedi: {e}")))?;

    Ok(schema)
}

/// Veritabanı için yeni bir görünüm (Table, Board/Kanban, Calendar, List, Gallery) oluşturur.
pub fn cmd_create_database_view(
    state: &DesktopAppState,
    database_id: Uuid,
    title: String,
    view_type: ViewType,
) -> Result<DatabaseView, AppError> {
    state.require_unlocked()?;

    let trimmed = title.trim();
    if trimmed.is_empty() {
        return Err(AppError::ValidationError("Görünüm başlığı boş olamaz".into()));
    }

    let view = DatabaseView::new(database_id, trimmed, view_type);

    let store = state.store.lock().map_err(|e| AppError::Internal(e.to_string()))?;
    save_view_to_db(store.conn(), &view)?;

    Ok(view)
}

/// Veritabanına ait tüm görünümleri listeler.
pub fn cmd_list_database_views(
    state: &DesktopAppState,
    database_id: Uuid,
) -> Result<Vec<DatabaseView>, AppError> {
    state.require_unlocked()?;

    let store = state.store.lock().map_err(|e| AppError::Internal(e.to_string()))?;
    let conn = store.conn();

    let mut stmt = conn
        .prepare(
            "SELECT id, database_id, title, view_type, filter_groups_json, sort_rules_json, visible_properties_json, created_at, updated_at
             FROM database_views WHERE database_id = ?1 ORDER BY created_at ASC",
        )
        .map_err(|e| AppError::DatabaseError(e.to_string()))?;

    let rows = stmt
        .query_map(rusqlite::params![database_id.to_string()], map_view_row)
        .map_err(|e| AppError::DatabaseError(e.to_string()))?;

    let mut views = Vec::new();
    for v in rows {
        views.push(v.map_err(|e| AppError::DatabaseError(e.to_string()))?);
    }
    Ok(views)
}

/// ID'ye göre görünüm kaydını çeker.
pub fn cmd_get_database_view(state: &DesktopAppState, view_id: Uuid) -> Result<DatabaseView, AppError> {
    state.require_unlocked()?;

    let store = state.store.lock().map_err(|e| AppError::Internal(e.to_string()))?;
    get_database_view_from_conn(store.conn(), view_id)
}

pub(crate) fn get_database_view_from_conn(
    conn: &rusqlite::Connection,
    view_id: Uuid,
) -> Result<DatabaseView, AppError> {
    let mut stmt = conn
        .prepare(
            "SELECT id, database_id, title, view_type, filter_groups_json, sort_rules_json, visible_properties_json, created_at, updated_at
             FROM database_views WHERE id = ?1",
        )
        .map_err(|e| AppError::DatabaseError(e.to_string()))?;

    let mut rows = stmt
        .query(rusqlite::params![view_id.to_string()])
        .map_err(|e| AppError::DatabaseError(e.to_string()))?;

    if let Some(row) = rows.next().map_err(|e| AppError::DatabaseError(e.to_string()))? {
        map_view_row(row).map_err(|e| AppError::DatabaseError(e.to_string()))
    } else {
        Err(AppError::NotFound(format!("Görünüm bulunamadı: {view_id}")))
    }
}

/// Görünüm tipine (Table, Kanban, Calendar) göre veritabanı satırlarını sorgular ve filtreler.
pub fn cmd_query_database_view(
    state: &DesktopAppState,
    database_id: Uuid,
    view_id: Uuid,
) -> Result<DatabaseQueryResult, AppError> {
    state.require_unlocked()?;

    let store = state.store.lock().map_err(|e| AppError::Internal(e.to_string()))?;
    let conn = store.conn();

    // 1. Veritabanı ve view bilgilerini al
    let mut stmt_db = conn
        .prepare("SELECT page_id FROM databases WHERE id = ?1")
        .map_err(|e| AppError::DatabaseError(e.to_string()))?;
    let page_id_str: String = stmt_db
        .query_row(rusqlite::params![database_id.to_string()], |r| r.get(0))
        .map_err(|_| AppError::NotFound(format!("Veritabanı bulunamadı: {database_id}")))?;
    let db_page_id = Uuid::parse_str(&page_id_str).map_err(|e| AppError::Internal(e.to_string()))?;

    let view = get_database_view_from_conn(conn, view_id)?;

    // 2. Alt sayfaları (Database Satırlarını) çek
    let mut stmt_rows = conn
        .prepare(
            "SELECT id, title, icon, created_at, updated_at FROM pages
             WHERE parent_page_id = ?1 AND is_deleted = 0
             ORDER BY created_at ASC",
        )
        .map_err(|e| AppError::DatabaseError(e.to_string()))?;

    let rows_iter = stmt_rows
        .query_map(rusqlite::params![db_page_id.to_string()], |r| {
            let id_str: String = r.get(0)?;
            let title: String = r.get(1)?;
            let icon: Option<String> = r.get(2)?;
            let created_at: i64 = r.get(3)?;
            let updated_at: i64 = r.get(4)?;
            Ok((id_str, title, icon, created_at, updated_at))
        })
        .map_err(|e| AppError::DatabaseError(e.to_string()))?;

    let mut result_rows = Vec::new();
    for item in rows_iter {
        let (id_str, title, icon, created_at, updated_at) =
            item.map_err(|e| AppError::DatabaseError(e.to_string()))?;
        let row_id = Uuid::parse_str(&id_str).unwrap_or_default();

        // Her satırın (sayfanın) bloklarındaki property değerlerini eşleştir
        let mut stmt_props = conn
            .prepare("SELECT properties_json FROM blocks WHERE page_id = ?1 LIMIT 1")
            .map_err(|e| AppError::DatabaseError(e.to_string()))?;
        let props_val: serde_json::Value = stmt_props
            .query_row(rusqlite::params![row_id.to_string()], |r| {
                let s: String = r.get(0)?;
                Ok(serde_json::from_str(&s).unwrap_or(serde_json::json!({})))
            })
            .unwrap_or(serde_json::json!({}));

        result_rows.push(DatabaseRow {
            page_id: row_id,
            title,
            icon,
            properties: props_val,
            created_at,
            updated_at,
        });
    }

    let total_count = result_rows.len();

    Ok(DatabaseQueryResult {
        database_id,
        view_id,
        view_type: view.view_type,
        rows: result_rows,
        total_count,
    })
}

fn save_view_to_db(conn: &rusqlite::Connection, view: &DatabaseView) -> Result<(), AppError> {
    let filter_json = serde_json::to_string(&view.filter_groups)
        .map_err(|e| AppError::Internal(e.to_string()))?;
    let sort_json = serde_json::to_string(&view.sort_rules)
        .map_err(|e| AppError::Internal(e.to_string()))?;
    let vis_json = serde_json::to_string(&view.visible_properties)
        .map_err(|e| AppError::Internal(e.to_string()))?;

    let view_type_str = match view.view_type {
        ViewType::Table => "table",
        ViewType::Board => "board",
        ViewType::Calendar => "calendar",
        ViewType::List => "list",
        ViewType::Gallery => "gallery",
    };

    conn.execute(
        "INSERT INTO database_views (
            id, database_id, title, view_type, filter_groups_json, sort_rules_json,
            visible_properties_json, created_at, updated_at
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        rusqlite::params![
            view.id.to_string(),
            view.database_id.to_string(),
            view.title,
            view_type_str,
            filter_json,
            sort_json,
            vis_json,
            view.created_at.timestamp_millis(),
            view.updated_at.timestamp_millis(),
        ],
    )
    .map_err(|e| AppError::DatabaseError(format!("Görünüm eklenemedi: {e}")))?;

    Ok(())
}

fn map_database_row(row: &rusqlite::Row<'_>) -> Result<DatabaseSchema, AppError> {
    let id_str: String = row.get(0).map_err(|e| AppError::DatabaseError(e.to_string()))?;
    let page_id_str: String = row.get(1).map_err(|e| AppError::DatabaseError(e.to_string()))?;
    let props_json: String = row.get(2).map_err(|e| AppError::DatabaseError(e.to_string()))?;
    let created_at_ms: i64 = row.get(3).map_err(|e| AppError::DatabaseError(e.to_string()))?;
    let updated_at_ms: i64 = row.get(4).map_err(|e| AppError::DatabaseError(e.to_string()))?;

    let id = Uuid::parse_str(&id_str).map_err(|e| AppError::Internal(e.to_string()))?;
    let page_id = Uuid::parse_str(&page_id_str).map_err(|e| AppError::Internal(e.to_string()))?;
    let properties: Vec<DatabasePropertyDefinition> =
        serde_json::from_str(&props_json).unwrap_or_default();

    let created_at = DateTime::from_timestamp_millis(created_at_ms).unwrap_or_else(Utc::now);
    let updated_at = DateTime::from_timestamp_millis(updated_at_ms).unwrap_or_else(Utc::now);

    Ok(DatabaseSchema {
        id,
        page_id,
        properties,
        created_at,
        updated_at,
    })
}

fn map_view_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<DatabaseView> {
    let id_str: String = row.get(0)?;
    let db_id_str: String = row.get(1)?;
    let title: String = row.get(2)?;
    let view_type_str: String = row.get(3)?;
    let filter_json: String = row.get(4)?;
    let sort_json: String = row.get(5)?;
    let vis_json: String = row.get(6)?;
    let created_at_ms: i64 = row.get(7)?;
    let updated_at_ms: i64 = row.get(8)?;

    let id = Uuid::parse_str(&id_str).unwrap_or_default();
    let database_id = Uuid::parse_str(&db_id_str).unwrap_or_default();

    let view_type = match view_type_str.as_str() {
        "board" | "kanban" => ViewType::Board,
        "calendar" => ViewType::Calendar,
        "list" => ViewType::List,
        "gallery" => ViewType::Gallery,
        _ => ViewType::Table,
    };

    let filter_groups = serde_json::from_str(&filter_json).unwrap_or(serde_json::json!([]));
    let sort_rules = serde_json::from_str(&sort_json).unwrap_or(serde_json::json!([]));
    let visible_properties = serde_json::from_str(&vis_json).unwrap_or_default();

    let created_at = DateTime::from_timestamp_millis(created_at_ms).unwrap_or_else(Utc::now);
    let updated_at = DateTime::from_timestamp_millis(updated_at_ms).unwrap_or_else(Utc::now);

    Ok(DatabaseView {
        id,
        database_id,
        title,
        view_type,
        filter_groups,
        sort_rules,
        visible_properties,
        created_at,
        updated_at,
    })
}

/// Veritabanına yeni bir kayıt (satır / alt sayfa) ekler.
pub fn cmd_insert_database_row(
    state: &DesktopAppState,
    db_page_id: Uuid,
    title: &str,
    properties: serde_json::Value,
) -> Result<DatabaseRow, AppError> {
    let row_page = crate::commands::pages::cmd_create_page(
        state,
        title,
        Some(db_page_id),
        Some("📄".to_string()),
        None,
    )?;

    let _block = crate::commands::blocks::cmd_insert_block(
        state,
        row_page.id,
        None,
        notes_core::model::block::BlockType::Paragraph,
        serde_json::json!({ "text": "" }),
        Some(properties.clone()),
        0.0,
    )?;

    Ok(DatabaseRow {
        page_id: row_page.id,
        title: row_page.title,
        icon: row_page.icon,
        properties,
        created_at: row_page.created_at.timestamp_millis(),
        updated_at: row_page.updated_at.timestamp_millis(),
    })
}

/// Veritabanı satırının başlığını veya özelliklerini günceller.
pub fn cmd_update_database_row(
    state: &DesktopAppState,
    row_page_id: Uuid,
    new_title: Option<String>,
    new_properties: Option<serde_json::Value>,
) -> Result<(), AppError> {
    state.require_unlocked()?;
    if let Some(ref title) = new_title {
        let store = state.store.lock().map_err(|e| AppError::Internal(e.to_string()))?;
        let page_repo = notes_core::storage::PageRepo::new(store.conn());
        if let Some(mut p) = page_repo.get_page(row_page_id)? {
            p.title = title.clone();
            p.touch();
            page_repo.update_page(&p)?;
        }
    }

    if let Some(props) = new_properties {
        let blocks = crate::commands::blocks::cmd_list_blocks(state, row_page_id)?;
        if let Some(first_block) = blocks.first() {
            crate::commands::blocks::cmd_update_block(
                state,
                first_block.id,
                None,
                Some(props),
                None,
            )?;
        } else {
            crate::commands::blocks::cmd_insert_block(
                state,
                row_page_id,
                None,
                notes_core::model::block::BlockType::Paragraph,
                serde_json::json!({ "text": "" }),
                Some(props),
                0.0,
            )?;
        }
    }
    Ok(())
}

/// Veritabanı satırını siler.
pub fn cmd_delete_database_row(state: &DesktopAppState, row_page_id: Uuid) -> Result<(), AppError> {
    crate::commands::pages::cmd_soft_delete_page(state, row_page_id)
}
