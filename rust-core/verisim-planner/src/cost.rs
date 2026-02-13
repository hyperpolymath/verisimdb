// SPDX-License-Identifier: PMPL-1.0-or-later
//! Cost model and estimation.
//!
//! Base costs match VQLExplain.res values. Mode multipliers match
//! query_planner_config.ex (conservative=1.5x, balanced=1.0x, aggressive=0.8x).

use serde::{Deserialize, Serialize};

use crate::config::PlannerConfig;
use crate::plan::{ConditionKind, PlanNode};
use crate::stats::StoreStatistics;
use crate::Modality;

/// Base cost parameters for a single modality.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BaseCost {
    /// Base time estimate in milliseconds.
    pub time_ms: f64,
    /// Base selectivity (fraction of rows returned, 0.0–1.0).
    pub selectivity: f64,
    /// Optimization hint for this modality.
    pub hint: &'static str,
}

impl BaseCost {
    /// Get the default base cost for a modality.
    ///
    /// Values match VQLExplain.res:
    /// - Graph: 150ms, 0.2 selectivity
    /// - Vector: 50ms, 0.01 selectivity
    /// - Tensor: 200ms, 0.5 selectivity
    /// - Semantic: 300ms, 0.8 selectivity
    /// - Document: 80ms, 0.05 selectivity
    /// - Temporal: 30ms, 0.1 selectivity
    pub fn for_modality(modality: Modality) -> Self {
        match modality {
            Modality::Graph => BaseCost {
                time_ms: 150.0,
                selectivity: 0.2,
                hint: "Graph traversal — O(E) scan",
            },
            Modality::Vector => BaseCost {
                time_ms: 50.0,
                selectivity: 0.01,
                hint: "HNSW approximate nearest neighbor",
            },
            Modality::Tensor => BaseCost {
                time_ms: 200.0,
                selectivity: 0.5,
                hint: "Tensor reduction — shape dependent",
            },
            Modality::Semantic => BaseCost {
                time_ms: 300.0,
                selectivity: 0.8,
                hint: "ZKP verification — expensive",
            },
            Modality::Document => BaseCost {
                time_ms: 80.0,
                selectivity: 0.05,
                hint: "Tantivy inverted index lookup",
            },
            Modality::Temporal => BaseCost {
                time_ms: 30.0,
                selectivity: 0.1,
                hint: "Version tree lookup — cached",
            },
        }
    }
}

/// Cost estimate for a plan step or the total plan.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CostEstimate {
    /// Estimated wall-clock time in milliseconds.
    pub time_ms: f64,
    /// Estimated number of rows returned.
    pub estimated_rows: u64,
    /// Selectivity (0.0–1.0).
    pub selectivity: f64,
    /// I/O component of cost.
    pub io_cost: f64,
    /// CPU component of cost.
    pub cpu_cost: f64,
}

impl CostEstimate {
    /// Combine two estimates for sequential execution (sum of times).
    pub fn sequential(a: &CostEstimate, b: &CostEstimate) -> CostEstimate {
        CostEstimate {
            time_ms: a.time_ms + b.time_ms,
            estimated_rows: a.estimated_rows.max(b.estimated_rows),
            selectivity: a.selectivity * b.selectivity,
            io_cost: a.io_cost + b.io_cost,
            cpu_cost: a.cpu_cost + b.cpu_cost,
        }
    }

    /// Combine two estimates for parallel execution (max of times).
    pub fn parallel(a: &CostEstimate, b: &CostEstimate) -> CostEstimate {
        CostEstimate {
            time_ms: a.time_ms.max(b.time_ms),
            estimated_rows: a.estimated_rows.max(b.estimated_rows),
            selectivity: a.selectivity * b.selectivity,
            io_cost: a.io_cost + b.io_cost,
            cpu_cost: a.cpu_cost + b.cpu_cost,
        }
    }

    /// Combine a list of estimates according to strategy.
    pub fn combine(estimates: &[CostEstimate], parallel: bool) -> CostEstimate {
        if estimates.is_empty() {
            return CostEstimate {
                time_ms: 0.0,
                estimated_rows: 0,
                selectivity: 1.0,
                io_cost: 0.0,
                cpu_cost: 0.0,
            };
        }
        let mut result = estimates[0].clone();
        for est in &estimates[1..] {
            result = if parallel {
                CostEstimate::parallel(&result, est)
            } else {
                CostEstimate::sequential(&result, est)
            };
        }
        result
    }
}

/// Cost model that estimates execution cost for plan nodes.
pub struct CostModel;

impl CostModel {
    /// Estimate the cost of executing a single plan node.
    ///
    /// Factors:
    /// 1. Base cost for the modality (from VQLExplain.res)
    /// 2. Optimization mode multiplier (from query_planner_config.ex)
    /// 3. Store statistics (if available)
    /// 4. Early limit reduction
    /// 5. Condition-specific adjustments
    pub fn estimate(
        node: &PlanNode,
        config: &PlannerConfig,
        stats: Option<&StoreStatistics>,
    ) -> CostEstimate {
        let base = BaseCost::for_modality(node.modality);
        let mode = config.mode_for(node.modality);

        // Apply mode multipliers (from query_planner_config.ex)
        let cost_mult = mode.cost_multiplier();
        let sel_mult = mode.selectivity_multiplier();

        let mut time_ms = base.time_ms * cost_mult;
        let mut selectivity = (base.selectivity * sel_mult).min(1.0);

        // Adjust for store statistics if available (weighted by statistics_weight)
        if let Some(s) = stats {
            if s.query_count > 0 {
                let w = config.statistics_weight;
                time_ms = time_ms * (1.0 - w) + s.avg_latency_ms * w;
                if s.total_rows > 0 {
                    let empirical_sel = s.avg_rows_returned as f64 / s.total_rows as f64;
                    selectivity = selectivity * (1.0 - w) + empirical_sel * w;
                }
            }
        }

        // Early limit reduces selectivity (fewer rows scanned/returned)
        if let Some(limit) = node.early_limit {
            let limit_factor = (limit as f64 / 1000.0).min(1.0);
            selectivity *= limit_factor;
            time_ms *= 0.5 + 0.5 * limit_factor; // At least 50% of base cost
        }

        // Condition-specific adjustments
        for condition in &node.conditions {
            match condition {
                ConditionKind::Equality { .. } => {
                    selectivity *= 0.1; // Highly selective
                    time_ms *= 0.7;
                }
                ConditionKind::Range { .. } => {
                    selectivity *= 0.3;
                    time_ms *= 0.8;
                }
                ConditionKind::Similarity { k } => {
                    selectivity = (*k as f64 / 10000.0).min(1.0);
                }
                ConditionKind::Fulltext { .. } => {
                    // Tantivy inverted index is fast
                    time_ms *= 0.6;
                }
                ConditionKind::ProofVerification { .. } => {
                    // ZKP is expensive
                    time_ms *= 1.5;
                }
                _ => {}
            }
        }

        let estimated_rows = if let Some(s) = stats {
            (s.total_rows as f64 * selectivity).max(1.0) as u64
        } else {
            (1000.0 * selectivity).max(1.0) as u64
        };

        // Split cost into I/O and CPU components (60/40 default split)
        let io_cost = time_ms * 0.6;
        let cpu_cost = time_ms * 0.4;

        CostEstimate {
            time_ms,
            estimated_rows,
            selectivity,
            io_cost,
            cpu_cost,
        }
    }

    /// Generate an optimization hint string for a plan node.
    pub fn optimization_hint(node: &PlanNode) -> Option<String> {
        let base = BaseCost::for_modality(node.modality);
        let mut hint = base.hint.to_string();

        for condition in &node.conditions {
            match condition {
                ConditionKind::Similarity { k } => {
                    hint = format!("HNSW ANN search (k={})", k);
                }
                ConditionKind::Fulltext { query } => {
                    let preview = if query.len() > 20 {
                        format!("{}...", &query[..20])
                    } else {
                        query.clone()
                    };
                    hint = format!("Tantivy fulltext: \"{}\"", preview);
                }
                ConditionKind::Traversal { predicate, depth } => {
                    hint = format!(
                        "Graph traversal: {} (depth={})",
                        predicate,
                        depth.unwrap_or(1)
                    );
                }
                ConditionKind::ProofVerification { contract } => {
                    hint = format!("ZKP verify: {}", contract);
                }
                ConditionKind::Equality { field, .. } => {
                    hint = format!("Index lookup on {}", field);
                }
                ConditionKind::AtTime { timestamp } => {
                    hint = format!("Temporal snapshot at {}", timestamp);
                }
                _ => {}
            }
        }

        Some(hint)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::PlannerConfig;

    #[test]
    fn test_base_costs_match_vql_explain() {
        assert_eq!(BaseCost::for_modality(Modality::Graph).time_ms, 150.0);
        assert_eq!(BaseCost::for_modality(Modality::Vector).time_ms, 50.0);
        assert_eq!(BaseCost::for_modality(Modality::Tensor).time_ms, 200.0);
        assert_eq!(BaseCost::for_modality(Modality::Semantic).time_ms, 300.0);
        assert_eq!(BaseCost::for_modality(Modality::Document).time_ms, 80.0);
        assert_eq!(BaseCost::for_modality(Modality::Temporal).time_ms, 30.0);
    }

    #[test]
    fn test_base_selectivity_values() {
        assert!((BaseCost::for_modality(Modality::Graph).selectivity - 0.2).abs() < f64::EPSILON);
        assert!((BaseCost::for_modality(Modality::Vector).selectivity - 0.01).abs() < f64::EPSILON);
        assert!((BaseCost::for_modality(Modality::Semantic).selectivity - 0.8).abs() < f64::EPSILON);
    }

    #[test]
    fn test_mode_multipliers_balanced() {
        let config = PlannerConfig::default();
        let node = PlanNode {
            modality: Modality::Graph,
            conditions: vec![],
            projections: vec![],
            early_limit: None,
        };
        // Graph has conservative override by default → cost_mult = 1.5
        let est = CostModel::estimate(&node, &config, None);
        assert!((est.time_ms - 150.0 * 1.5).abs() < f64::EPSILON);
    }

    #[test]
    fn test_mode_multipliers_aggressive() {
        let config = PlannerConfig::default();
        let node = PlanNode {
            modality: Modality::Vector,
            conditions: vec![],
            projections: vec![],
            early_limit: None,
        };
        // Vector has aggressive override by default → cost_mult = 0.8
        let est = CostModel::estimate(&node, &config, None);
        assert!((est.time_ms - 50.0 * 0.8).abs() < f64::EPSILON);
    }

    #[test]
    fn test_early_limit_reduces_selectivity() {
        let config = PlannerConfig::default();
        let node_no_limit = PlanNode {
            modality: Modality::Document,
            conditions: vec![],
            projections: vec![],
            early_limit: None,
        };
        let node_with_limit = PlanNode {
            modality: Modality::Document,
            conditions: vec![],
            projections: vec![],
            early_limit: Some(10),
        };
        let est_no = CostModel::estimate(&node_no_limit, &config, None);
        let est_with = CostModel::estimate(&node_with_limit, &config, None);
        assert!(est_with.selectivity < est_no.selectivity);
        assert!(est_with.time_ms < est_no.time_ms);
    }

    #[test]
    fn test_sequential_combinator() {
        let a = CostEstimate {
            time_ms: 100.0,
            estimated_rows: 50,
            selectivity: 0.5,
            io_cost: 60.0,
            cpu_cost: 40.0,
        };
        let b = CostEstimate {
            time_ms: 200.0,
            estimated_rows: 100,
            selectivity: 0.3,
            io_cost: 120.0,
            cpu_cost: 80.0,
        };
        let combined = CostEstimate::sequential(&a, &b);
        assert!((combined.time_ms - 300.0).abs() < f64::EPSILON);
        assert!((combined.io_cost - 180.0).abs() < f64::EPSILON);
    }

    #[test]
    fn test_parallel_combinator() {
        let a = CostEstimate {
            time_ms: 100.0,
            estimated_rows: 50,
            selectivity: 0.5,
            io_cost: 60.0,
            cpu_cost: 40.0,
        };
        let b = CostEstimate {
            time_ms: 200.0,
            estimated_rows: 100,
            selectivity: 0.3,
            io_cost: 120.0,
            cpu_cost: 80.0,
        };
        let combined = CostEstimate::parallel(&a, &b);
        assert!((combined.time_ms - 200.0).abs() < f64::EPSILON); // max
        assert!((combined.io_cost - 180.0).abs() < f64::EPSILON); // sum
    }
}
