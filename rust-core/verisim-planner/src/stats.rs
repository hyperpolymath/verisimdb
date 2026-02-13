// SPDX-License-Identifier: PMPL-1.0-or-later
//! Store statistics collection and tracking.

use std::collections::HashMap;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::Modality;

/// Statistics for a single modality store.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoreStatistics {
    /// Which modality these stats describe.
    pub modality: Modality,
    /// Total number of rows/entities in this store.
    pub total_rows: u64,
    /// Average query latency in milliseconds (exponential moving average).
    pub avg_latency_ms: f64,
    /// Average number of rows returned per query.
    pub avg_rows_returned: u64,
    /// Total number of queries executed.
    pub query_count: u64,
    /// When statistics were last updated.
    pub last_updated: DateTime<Utc>,
}

impl StoreStatistics {
    /// Create empty statistics for a modality.
    fn new(modality: Modality) -> Self {
        Self {
            modality,
            total_rows: 0,
            avg_latency_ms: 0.0,
            avg_rows_returned: 0,
            query_count: 0,
            last_updated: Utc::now(),
        }
    }
}

/// Collects and maintains statistics across all modality stores.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatisticsCollector {
    stats: HashMap<Modality, StoreStatistics>,
}

impl StatisticsCollector {
    /// Create a new collector with empty statistics for all 6 modalities.
    pub fn new() -> Self {
        let mut stats = HashMap::new();
        for m in Modality::ALL {
            stats.insert(m, StoreStatistics::new(m));
        }
        Self { stats }
    }

    /// Get statistics for a specific modality.
    pub fn get(&self, modality: Modality) -> Option<&StoreStatistics> {
        self.stats.get(&modality)
    }

    /// Get a snapshot of all statistics.
    pub fn snapshot(&self) -> &HashMap<Modality, StoreStatistics> {
        &self.stats
    }

    /// Record a query execution for a modality.
    ///
    /// Uses exponential moving average (alpha=0.1) for latency,
    /// matching the drift detector's approach.
    pub fn record_execution(
        &mut self,
        modality: Modality,
        latency_ms: f64,
        rows_returned: u64,
    ) {
        let entry = self.stats.entry(modality).or_insert_with(|| StoreStatistics::new(modality));
        entry.query_count += 1;

        // Exponential moving average (alpha = 0.1)
        if entry.query_count == 1 {
            entry.avg_latency_ms = latency_ms;
            entry.avg_rows_returned = rows_returned;
        } else {
            entry.avg_latency_ms = 0.1 * latency_ms + 0.9 * entry.avg_latency_ms;
            entry.avg_rows_returned =
                (0.1 * rows_returned as f64 + 0.9 * entry.avg_rows_returned as f64) as u64;
        }

        entry.last_updated = Utc::now();
    }

    /// Update the total row count for a modality.
    pub fn update_row_count(&mut self, modality: Modality, total_rows: u64) {
        if let Some(entry) = self.stats.get_mut(&modality) {
            entry.total_rows = total_rows;
            entry.last_updated = Utc::now();
        }
    }
}

impl Default for StatisticsCollector {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_collector_initializes_all_modalities() {
        let collector = StatisticsCollector::new();
        for m in Modality::ALL {
            let stats = collector.get(m).unwrap();
            assert_eq!(stats.modality, m);
            assert_eq!(stats.query_count, 0);
            assert_eq!(stats.total_rows, 0);
        }
        assert_eq!(collector.snapshot().len(), 6);
    }

    #[test]
    fn test_record_first_execution() {
        let mut collector = StatisticsCollector::new();
        collector.record_execution(Modality::Vector, 42.0, 10);

        let stats = collector.get(Modality::Vector).unwrap();
        assert_eq!(stats.query_count, 1);
        assert!((stats.avg_latency_ms - 42.0).abs() < f64::EPSILON);
        assert_eq!(stats.avg_rows_returned, 10);
    }

    #[test]
    fn test_record_updates_moving_average() {
        let mut collector = StatisticsCollector::new();

        // First execution
        collector.record_execution(Modality::Graph, 100.0, 50);
        assert!((collector.get(Modality::Graph).unwrap().avg_latency_ms - 100.0).abs() < f64::EPSILON);

        // Second execution — EMA: 0.1 * 200 + 0.9 * 100 = 110
        collector.record_execution(Modality::Graph, 200.0, 100);
        let stats = collector.get(Modality::Graph).unwrap();
        assert!((stats.avg_latency_ms - 110.0).abs() < f64::EPSILON);
        assert_eq!(stats.query_count, 2);
    }

    #[test]
    fn test_update_row_count() {
        let mut collector = StatisticsCollector::new();
        collector.update_row_count(Modality::Document, 5000);
        assert_eq!(collector.get(Modality::Document).unwrap().total_rows, 5000);
    }

    #[test]
    fn test_snapshot_returns_all() {
        let collector = StatisticsCollector::new();
        let snap = collector.snapshot();
        assert_eq!(snap.len(), 6);
    }
}
