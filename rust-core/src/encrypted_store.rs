//! SQLCipher-backed native store initialization and legacy-store migration.
//!
//! The Swift layer supplies a random passphrase from the device-only
//! Keychain. This module never falls back to a plaintext open for an existing
//! database: a legacy SQLite header is migrated explicitly, while an
//! unrecognized database is rejected.

use std::fs::{self, File, OpenOptions};
use std::io::{ErrorKind, Read};
use std::path::{Path, PathBuf};

use presage_store_sqlite::{OnNewIdentity, SqliteStore};
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use sqlx::SqlitePool;
use uuid::Uuid;

const SQLITE_HEADER: &[u8; 16] = b"SQLite format 3\0";

/// Open the native store with SQLCipher, migrating a known plaintext store
/// when necessary. The returned store is already configured with the supplied
/// identity policy; callers do not need to retain the passphrase.
pub(crate) async fn open_encrypted(
    db_path: &str,
    passphrase: &str,
) -> Result<SqliteStore, String> {
    if passphrase.is_empty() {
        return Err("native database passphrase is empty".to_string());
    }

    let path = Path::new(db_path);
    if let Ok(metadata) = fs::symlink_metadata(path) {
        if metadata.file_type().is_symlink() {
            return Err("native database path must not be a symlink".to_string());
        }
    }
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            fs::create_dir_all(parent)
                .map_err(|error| format!("create native database directory: {error}"))?;
        }
    }
    match classify_database(path).await? {
        DatabaseKind::Missing => open_with_key(path, passphrase).await,
        DatabaseKind::Plaintext => {
            migrate_plaintext(path, passphrase).await?;
            open_with_key(path, passphrase).await
        }
        DatabaseKind::EncryptedOrUnknown => open_with_key(path, passphrase)
            .await
            .map_err(|error| format!("encrypted native database could not be opened: {error}")),
    }
}

async fn open_with_key(path: &Path, passphrase: &str) -> Result<SqliteStore, String> {
    let store = SqliteStore::open_with_passphrase(
        &path.to_string_lossy(),
        Some(passphrase),
        OnNewIdentity::Reject,
    )
    .await
    .map_err(|error| error.to_string())?;
    set_private_permissions(path)?;
    for suffix in ["-wal", "-shm"] {
        if let Ok(sidecar_path) = std::fs::metadata(sidecar(path, suffix)) {
            if sidecar_path.is_file() {
                set_private_permissions(&sidecar(path, suffix))?;
            }
        }
    }
    Ok(store)
}

enum DatabaseKind {
    Missing,
    Plaintext,
    EncryptedOrUnknown,
}

async fn classify_database(path: &Path) -> Result<DatabaseKind, String> {
    let mut file = match File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == ErrorKind::NotFound => {
            // A missing main file with WAL/SHM state is not a fresh store;
            // opening a new database would silently discard pending rows.
            if sidecar(path, "-wal").exists() || sidecar(path, "-shm").exists() {
                return Ok(DatabaseKind::EncryptedOrUnknown);
            }
            return Ok(DatabaseKind::Missing);
        }
        Err(error) => return Err(format!("inspect native database: {error}")),
    };
    let mut header = [0u8; 16];
    match file.read_exact(&mut header) {
        Ok(()) if &header == SQLITE_HEADER => Ok(DatabaseKind::Plaintext),
        Ok(()) => Ok(DatabaseKind::EncryptedOrUnknown),
        Err(error) if error.kind() == ErrorKind::UnexpectedEof => {
            // An empty/truncated file is not safe to treat as a fresh store.
            Ok(DatabaseKind::EncryptedOrUnknown)
        }
        Err(error) => Err(format!("read native database header: {error}")),
    }
}

async fn migrate_plaintext(source_path: &Path, passphrase: &str) -> Result<(), String> {
    let source = connect_plaintext(source_path).await?;
    let integrity: String = sqlx::query_scalar("PRAGMA integrity_check")
        .fetch_one(&source)
        .await
        .map_err(|error| format!("plaintext integrity check: {error}"))?;
    if integrity != "ok" {
        return Err(format!("plaintext database integrity check failed: {integrity}"));
    }

    // Do not migrate an arbitrary SQLite file. A Presage store has at least
    // these two tables; this also prevents a user-selected file from being
    // silently imported as a Signal account.
    let required_tables: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN ('kv', 'sessions')",
    )
    .fetch_one(&source)
    .await
    .map_err(|error| format!("plaintext schema check: {error}"))?;
    if required_tables != 2 {
        return Err("database is not a recognized Presage plaintext store".to_string());
    }

    // Checkpoint the source before exporting so logical rows are not left in
    // a WAL sidecar that the replacement would accidentally omit.
    sqlx::query("PRAGMA wal_checkpoint(TRUNCATE)")
        .fetch_all(&source)
        .await
        .map_err(|error| format!("checkpoint plaintext database: {error}"))?;

    let stage_path = stage_path(source_path);
    create_private_stage(&stage_path)?;
    let result = export_to_stage(&source, &stage_path, passphrase).await;
    if let Err(error) = result {
        let _ = fs::remove_file(&stage_path);
        let _ = fs::remove_file(sidecar(&stage_path, "-wal"));
        let _ = fs::remove_file(sidecar(&stage_path, "-shm"));
        return Err(error);
    }

    source.close().await;
    remove_sidecars(source_path);
    if let Err(error) = validate_stage(&stage_path, passphrase).await {
        let _ = fs::remove_file(&stage_path);
        let _ = fs::remove_file(sidecar(&stage_path, "-wal"));
        let _ = fs::remove_file(sidecar(&stage_path, "-shm"));
        return Err(error);
    }

    // Both paths are in the same directory. POSIX rename replaces the
    // validated destination atomically, leaving the old plaintext inode out
    // of the active database path.
    if let Err(error) = fs::rename(&stage_path, source_path) {
        let _ = fs::remove_file(&stage_path);
        return Err(format!("replace plaintext native database: {error}"));
    }
    set_private_permissions(source_path)?;
    remove_sidecars(source_path);
    Ok(())
}

async fn connect_plaintext(path: &Path) -> Result<SqlitePool, String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| format!("create native database dir: {error}"))?;
    }
    let options = SqliteConnectOptions::new()
        .filename(path)
        .create_if_missing(false)
        .busy_timeout(std::time::Duration::from_secs(10));
    SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(options)
        .await
        .map_err(|error| format!("open plaintext native database: {error}"))
}

async fn export_to_stage(
    source: &SqlitePool,
    stage_path: &Path,
    passphrase: &str,
) -> Result<(), String> {
    let stage = sql_quote(&stage_path.to_string_lossy());
    let key = sql_quote(passphrase);
    let attach = format!("ATTACH DATABASE {stage} AS encrypted KEY {key}");
    // `stage` and `key` are escaped by `sql_quote` immediately above; SQLite
    // does not accept bind parameters in ATTACH ... KEY.
    sqlx::query(sqlx::AssertSqlSafe(attach))
        .execute(source)
        .await
        .map_err(|error| format!("attach encrypted migration stage: {error}"))?;
    // SQLCipher's export function is a void SQLite function; depending on the
    // bundled version the result column is NULL rather than the string "ok".
    // A successful query is the success signal, followed by DETACH.
    sqlx::query("SELECT sqlcipher_export('encrypted')")
        .fetch_one(source)
        .await
        .map_err(|error| format!("export native database: {error}"))?;
    sqlx::query("DETACH DATABASE encrypted")
        .execute(source)
        .await
        .map_err(|error| format!("detach encrypted migration stage: {error}"))?;
    Ok(())
}

async fn validate_stage(stage_path: &Path, passphrase: &str) -> Result<(), String> {
    let options = SqliteConnectOptions::new()
        .filename(stage_path)
        .create_if_missing(false)
        .pragma("key", format!("'{}'", passphrase.replace('\'', "''")))
        .busy_timeout(std::time::Duration::from_secs(10));
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(options)
        .await
        .map_err(|error| format!("open encrypted migration stage: {error}"))?;

    let cipher_version: Option<String> = sqlx::query_scalar("PRAGMA cipher_version")
        .fetch_optional(&pool)
        .await
        .map_err(|error| format!("encrypted cipher check: {error}"))?;
    if cipher_version.is_none() {
        pool.close().await;
        return Err("migration stage is not SQLCipher encrypted".to_string());
    }
    let integrity: String = sqlx::query_scalar("PRAGMA integrity_check")
        .fetch_one(&pool)
        .await
        .map_err(|error| format!("encrypted integrity check: {error}"))?;
    let cipher_integrity: Option<String> = sqlx::query_scalar("PRAGMA cipher_integrity_check")
        .fetch_optional(&pool)
        .await
        .map_err(|error| format!("encrypted cipher integrity check: {error}"))?;
    let required_tables: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN ('kv', 'sessions')",
    )
    .fetch_one(&pool)
    .await
    .map_err(|error| format!("encrypted migration schema check: {error}"))?;
    pool.close().await;
    if required_tables != 2 {
        return Err("encrypted migration stage is missing the Presage schema".to_string());
    }
    if integrity != "ok"
        || cipher_integrity
            .as_deref()
            .is_some_and(|result| result != "ok")
    {
        return Err(format!(
            "encrypted migration stage failed integrity checks: {integrity}/{cipher_integrity:?}"
        ));
    }
    match read_header(stage_path)? {
        Some(header) if &header != SQLITE_HEADER => {}
        Some(_) => {
            return Err("encrypted migration stage retained a plaintext SQLite header".to_string())
        }
        None => return Err("encrypted migration stage is truncated".to_string()),
    }
    Ok(())
}

fn read_header(path: &Path) -> Result<Option<[u8; 16]>, String> {
    let mut file = File::open(path).map_err(|error| format!("read migration stage: {error}"))?;
    let mut header = [0u8; 16];
    match file.read_exact(&mut header) {
        Ok(()) => Ok(Some(header)),
        Err(error) if error.kind() == ErrorKind::UnexpectedEof => Ok(None),
        Err(error) => Err(format!("read migration stage header: {error}")),
    }
}

fn stage_path(source_path: &Path) -> PathBuf {
    let name = source_path
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("signal.db");
    source_path.with_file_name(format!(".{name}.encrypted-{}", Uuid::new_v4()))
}

fn sidecar(path: &Path, suffix: &str) -> PathBuf {
    PathBuf::from(format!("{}{suffix}", path.to_string_lossy()))
}

fn remove_sidecars(path: &Path) {
    let _ = fs::remove_file(sidecar(path, "-wal"));
    let _ = fs::remove_file(sidecar(path, "-shm"));
    let _ = fs::remove_file(sidecar(path, "-journal"));
}

fn create_private_stage(path: &Path) -> Result<(), String> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let file = options
        .open(path)
        .map_err(|error| format!("create encrypted migration stage: {error}"))?;
    drop(file);
    set_private_permissions(path)
}

fn set_private_permissions(path: &Path) -> Result<(), String> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))
            .map_err(|error| format!("protect native database: {error}"))?;
    }
    #[cfg(not(unix))]
    {
        let _ = path;
    }
    Ok(())
}

fn sql_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_path(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!("cuztom-encrypted-{name}-{}", Uuid::new_v4()))
    }

    #[tokio::test]
    async fn migrates_plaintext_and_reopens_only_with_key() {
        let path = test_path("migration.db");
        File::create(&path).unwrap();
        let pool = connect_plaintext(&path).await.unwrap();
        sqlx::query("CREATE TABLE kv (key TEXT PRIMARY KEY, value BLOB NOT NULL)")
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("CREATE TABLE sessions (id INTEGER PRIMARY KEY, value BLOB)")
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO kv(key, value) VALUES ('x', X'0102')")
            .execute(&pool)
            .await
            .unwrap();
        pool.close().await;

        let store = open_encrypted(path.to_str().unwrap(), "correct-key")
            .await
            .unwrap();
        drop(store);
        let header = read_header(&path).unwrap().unwrap();
        assert_ne!(&header, SQLITE_HEADER);

        let error = open_encrypted(path.to_str().unwrap(), "wrong-key")
            .await
            .unwrap_err();
        assert!(error.contains("could not be opened"));
        let _ = fs::remove_file(path);
    }
}
