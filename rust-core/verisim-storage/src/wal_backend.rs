// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Write-Ahead Log (WAL) wrapper for storage backends.
//
// The `WalBackend` provides durability for any `StorageBackend` by recording
// all mutations to a persistent log before they are applied to the inner
// backend.

use async_trait::async_trait;
use chrono::Utc;
use std::sync::Arc;
use tokio::sync::Mutex;

use crate::backend::StorageBackend;
use crate::error::StorageError;
use verisim_wal::{WalEntry, WalModality, WalOperation, WalWriter};

/// A storage backend wrapper that adds write-ahead logging.
///
/// Every mutation (`put`, `delete`, `batch_put`) is first serialized into a
/// [`WalEntry`] and appended to the log. Only after the log append succeeds
/// (and potentially syncs to disk, depending on `SyncMode`) is the operation
/// applied to the inner backend.
pub struct WalBackend<B: StorageBackend> {
    inner: B,
    wal: Arc<Mutex<WalWriter>>,
    modality: WalModality,
}

impl<B: StorageBackend> WalBackend<B> {
    /// Create a new WAL-protected backend.
    ///
    /// # Arguments
    ///
    /// * `inner` - The storage backend to protect.
    /// * `wal` - A shared, mutex-protected [`WalWriter`].
    /// * `modality` - The modality identifier to use for log entries.
    pub fn new(inner: B, wal: Arc<Mutex<WalWriter>>, modality: WalModality) -> Self {
        Self {
            inner,
            wal,
            modality,
        }
    }

    /// Access the inner backend.
    pub fn inner(&self) -> &B {
        &self.inner
    }

    /// Append an operation to the WAL.
    async fn log_op(
        &self,
        operation: WalOperation,
        key: &[u8],
        value: &[u8],
    ) -> Result<(), StorageError> {
        let entry = WalEntry {
            sequence: 0, // Assigned by writer
            timestamp: Utc::now(),
            operation,
            modality: self.modality,
            entity_id: String::from_utf8_lossy(key).to_string(),
            payload: value.to_vec(),
        };

        let mut writer = self.wal.lock().await;
        writer.append(entry).map_err(|e| {
            StorageError::BackendUnavailable(format!("WAL append failed: {e}"))
        })?;

        Ok(())
    }
}

#[async_trait]
impl<B: StorageBackend> StorageBackend for WalBackend<B> {
    async fn get(&self, key: &[u8]) -> Result<Option<Vec<u8>>, StorageError> {
        self.inner.get(key).await
    }

    async fn put(&self, key: &[u8], value: &[u8]) -> Result<(), StorageError> {
        // 1. Log intent to WAL
        self.log_op(WalOperation::Update, key, value).await?;

        // 2. Apply to inner storage
        self.inner.put(key, value).await
    }

    async fn delete(&self, key: &[u8]) -> Result<bool, StorageError> {
        // 1. Log intent to WAL
        self.log_op(WalOperation::Delete, key, b"").await?;

        // 2. Apply to inner storage
        self.inner.delete(key).await
    }

    async fn exists(&self, key: &[u8]) -> Result<bool, StorageError> {
        self.inner.exists(key).await
    }

    async fn scan_prefix(
        &self,
        prefix: &[u8],
        limit: usize,
    ) -> Result<Vec<(Vec<u8>, Vec<u8>)>, StorageError> {
        self.inner.scan_prefix(prefix, limit).await
    }

    async fn multi_get(&self, keys: &[&[u8]]) -> Result<Vec<Option<Vec<u8>>>, StorageError> {
        self.inner.multi_get(keys).await
    }

    async fn batch_put(&self, entries: &[(&[u8], &[u8])]) -> Result<(), StorageError> {
        // For batch puts, we log multiple entries to the WAL.
        // A future optimization could be a single WalOperation::Batch.
        for (key, value) in entries {
            self.log_op(WalOperation::Update, key, value).await?;
        }
        self.inner.batch_put(entries).await
    }

    async fn flush(&self) -> Result<(), StorageError> {
        // Sync the WAL first, then the inner store.
        let mut writer = self.wal.lock().await;
        writer.sync().map_err(|e| {
            StorageError::BackendUnavailable(format!("WAL sync failed: {e}"))
        })?;
        drop(writer);

        self.inner.flush().await
    }

    fn name(&self) -> &str {
        self.inner.name()
    }

    async fn approximate_size(&self) -> Result<Option<u64>, StorageError> {
        self.inner.approximate_size().await
    }
}
