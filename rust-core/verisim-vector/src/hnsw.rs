// SPDX-License-Identifier: AGPL-3.0-or-later
//! HNSW (Hierarchical Navigable Small World) Index
//!
//! Implementation of the HNSW algorithm for approximate nearest neighbor search.
//! Based on the paper "Efficient and robust approximate nearest neighbor search
//! using Hierarchical Navigable Small World graphs" by Malkov and Yashunin.

use crate::DistanceMetric;
use rand::Rng;
use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use std::collections::{BinaryHeap, HashMap, HashSet};

/// HNSW parameters
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HnswParams {
    /// Maximum number of connections per element (M)
    pub m: usize,
    /// Size of the dynamic candidate list during construction
    pub ef_construction: usize,
    /// Default size of the dynamic candidate list during search
    pub ef_search: usize,
}

impl Default for HnswParams {
    fn default() -> Self {
        Self {
            m: 16,
            ef_construction: 200,
            ef_search: 50,
        }
    }
}

/// A node in the HNSW graph
#[derive(Debug, Clone)]
struct HnswNode {
    /// The vector data
    vector: Vec<f32>,
    /// Neighbors at each level (level -> neighbor indices)
    neighbors: Vec<Vec<usize>>,
}

/// Candidate for search (used in priority queue)
#[derive(Debug, Clone)]
struct Candidate {
    index: usize,
    distance: f32,
}

impl PartialEq for Candidate {
    fn eq(&self, other: &Self) -> bool {
        self.distance == other.distance
    }
}

impl Eq for Candidate {}

impl PartialOrd for Candidate {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for Candidate {
    fn cmp(&self, other: &Self) -> Ordering {
        // Reverse ordering for min-heap behavior (closest first)
        other
            .distance
            .partial_cmp(&self.distance)
            .unwrap_or(Ordering::Equal)
    }
}

/// Max-heap candidate (for keeping track of furthest)
#[derive(Debug, Clone)]
struct MaxCandidate {
    index: usize,
    distance: f32,
}

impl PartialEq for MaxCandidate {
    fn eq(&self, other: &Self) -> bool {
        self.distance == other.distance
    }
}

impl Eq for MaxCandidate {}

impl PartialOrd for MaxCandidate {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for MaxCandidate {
    fn cmp(&self, other: &Self) -> Ordering {
        // Normal ordering for max-heap behavior (furthest first)
        self.distance
            .partial_cmp(&other.distance)
            .unwrap_or(Ordering::Equal)
    }
}

/// HNSW Index for approximate nearest neighbor search
pub struct HnswIndex {
    /// Dimension of vectors
    dimension: usize,
    /// Distance metric
    metric: DistanceMetric,
    /// Parameters
    params: HnswParams,
    /// All nodes in the graph
    nodes: Vec<HnswNode>,
    /// Entry point (index of the highest level node)
    entry_point: Option<usize>,
    /// Maximum level in the graph
    max_level: usize,
    /// Probability multiplier for level generation
    level_mult: f64,
    /// Map from external ID to internal index
    id_to_index: HashMap<usize, usize>,
}

impl HnswIndex {
    /// Create a new HNSW index
    pub fn new(dimension: usize, metric: DistanceMetric, params: HnswParams) -> Self {
        let level_mult = 1.0 / (params.m as f64).ln();
        Self {
            dimension,
            metric,
            params,
            nodes: Vec::new(),
            entry_point: None,
            max_level: 0,
            level_mult,
            id_to_index: HashMap::new(),
        }
    }

    /// Get the maximum level
    pub fn max_level(&self) -> usize {
        self.max_level
    }

    /// Generate a random level for a new node
    fn random_level(&self) -> usize {
        let mut rng = rand::rng();
        let r: f64 = rng.random();
        (-r.ln() * self.level_mult).floor() as usize
    }

    /// Compute distance between two vectors
    fn distance(&self, a: &[f32], b: &[f32]) -> f32 {
        match self.metric {
            DistanceMetric::Cosine => {
                let mut dot = 0.0f32;
                let mut norm_a = 0.0f32;
                let mut norm_b = 0.0f32;
                for (x, y) in a.iter().zip(b.iter()) {
                    dot += x * y;
                    norm_a += x * x;
                    norm_b += y * y;
                }
                let denom = (norm_a * norm_b).sqrt();
                if denom > 0.0 {
                    1.0 - (dot / denom) // Convert similarity to distance
                } else {
                    1.0
                }
            }
            DistanceMetric::Euclidean => {
                a.iter()
                    .zip(b.iter())
                    .map(|(x, y)| (x - y).powi(2))
                    .sum::<f32>()
                    .sqrt()
            }
            DistanceMetric::DotProduct => {
                // Negative dot product as distance (higher dot = lower distance)
                -a.iter().zip(b.iter()).map(|(x, y)| x * y).sum::<f32>()
            }
        }
    }

    /// Insert a vector into the index
    pub fn insert(&mut self, external_id: usize, vector: &[f32]) {
        let node_level = self.random_level();

        // Create the new node
        let new_node = HnswNode {
            vector: vector.to_vec(),
            neighbors: vec![Vec::new(); node_level + 1],
        };

        let new_idx = self.nodes.len();
        self.nodes.push(new_node);
        self.id_to_index.insert(external_id, new_idx);

        // If this is the first node, it becomes the entry point
        if self.entry_point.is_none() {
            self.entry_point = Some(new_idx);
            self.max_level = node_level;
            return;
        }

        let entry_point = self.entry_point.unwrap();

        // Find the entry point's level
        let mut current_idx = entry_point;
        let mut current_dist = self.distance(vector, &self.nodes[current_idx].vector);

        // Traverse from the highest level down to node_level + 1
        for level in (node_level + 1..=self.max_level).rev() {
            let mut changed = true;
            while changed {
                changed = false;
                let neighbors = &self.nodes[current_idx].neighbors;
                if level < neighbors.len() {
                    for &neighbor_idx in &neighbors[level] {
                        let dist = self.distance(vector, &self.nodes[neighbor_idx].vector);
                        if dist < current_dist {
                            current_idx = neighbor_idx;
                            current_dist = dist;
                            changed = true;
                        }
                    }
                }
            }
        }

        // For levels from min(node_level, max_level) down to 0, search and connect
        let top_level = node_level.min(self.max_level);
        for level in (0..=top_level).rev() {
            let candidates = self.search_layer(vector, current_idx, self.params.ef_construction, level);

            // Select neighbors
            let neighbors = self.select_neighbors(&candidates, self.params.m);

            // Connect the new node to its neighbors
            self.nodes[new_idx].neighbors[level] = neighbors.clone();

            // Add reverse connections
            for &neighbor_idx in &neighbors {
                let neighbor_level = self.nodes[neighbor_idx].neighbors.len();
                if level < neighbor_level {
                    self.nodes[neighbor_idx].neighbors[level].push(new_idx);

                    // Prune if too many connections
                    if self.nodes[neighbor_idx].neighbors[level].len() > self.params.m * 2 {
                        let neighbor_vec = self.nodes[neighbor_idx].vector.clone();
                        let neighbor_neighbors: Vec<_> = self.nodes[neighbor_idx].neighbors[level]
                            .iter()
                            .map(|&idx| {
                                let dist = self.distance(&neighbor_vec, &self.nodes[idx].vector);
                                (idx, dist)
                            })
                            .collect();
                        let pruned = self.select_neighbors(&neighbor_neighbors, self.params.m * 2);
                        self.nodes[neighbor_idx].neighbors[level] = pruned;
                    }
                }
            }

            // Update current entry point for next level
            if !candidates.is_empty() {
                current_idx = candidates[0].0;
            }
        }

        // Update entry point if new node has higher level
        if node_level > self.max_level {
            self.entry_point = Some(new_idx);
            self.max_level = node_level;
        }
    }

    /// Search a single layer for nearest neighbors
    fn search_layer(
        &self,
        query: &[f32],
        entry_idx: usize,
        ef: usize,
        level: usize,
    ) -> Vec<(usize, f32)> {
        let entry_dist = self.distance(query, &self.nodes[entry_idx].vector);

        let mut visited = HashSet::new();
        visited.insert(entry_idx);

        let mut candidates: BinaryHeap<Candidate> = BinaryHeap::new();
        candidates.push(Candidate {
            index: entry_idx,
            distance: entry_dist,
        });

        let mut results: BinaryHeap<MaxCandidate> = BinaryHeap::new();
        results.push(MaxCandidate {
            index: entry_idx,
            distance: entry_dist,
        });

        while let Some(current) = candidates.pop() {
            // Get the furthest result
            let furthest_dist = results.peek().map(|r| r.distance).unwrap_or(f32::MAX);

            // If current is further than furthest result, we're done
            if current.distance > furthest_dist {
                break;
            }

            // Explore neighbors
            let neighbors = &self.nodes[current.index].neighbors;
            if level < neighbors.len() {
                for &neighbor_idx in &neighbors[level] {
                    if visited.insert(neighbor_idx) {
                        let dist = self.distance(query, &self.nodes[neighbor_idx].vector);
                        let furthest_dist = results.peek().map(|r| r.distance).unwrap_or(f32::MAX);

                        if dist < furthest_dist || results.len() < ef {
                            candidates.push(Candidate {
                                index: neighbor_idx,
                                distance: dist,
                            });
                            results.push(MaxCandidate {
                                index: neighbor_idx,
                                distance: dist,
                            });

                            // Keep only top ef results
                            while results.len() > ef {
                                results.pop();
                            }
                        }
                    }
                }
            }
        }

        // Convert to sorted vector
        let mut result_vec: Vec<_> = results
            .into_iter()
            .map(|c| (c.index, c.distance))
            .collect();
        result_vec.sort_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(Ordering::Equal));
        result_vec
    }

    /// Select neighbors using simple heuristic
    fn select_neighbors(&self, candidates: &[(usize, f32)], m: usize) -> Vec<usize> {
        candidates
            .iter()
            .take(m)
            .map(|(idx, _)| *idx)
            .collect()
    }

    /// Search for k nearest neighbors
    pub fn search(&self, query: &[f32], k: usize, ef: usize) -> Vec<(usize, f32)> {
        if self.nodes.is_empty() || self.entry_point.is_none() {
            return Vec::new();
        }

        let entry_point = self.entry_point.unwrap();
        let mut current_idx = entry_point;
        let mut current_dist = self.distance(query, &self.nodes[current_idx].vector);

        // Traverse from top level to level 1
        for level in (1..=self.max_level).rev() {
            let mut changed = true;
            while changed {
                changed = false;
                let neighbors = &self.nodes[current_idx].neighbors;
                if level < neighbors.len() {
                    for &neighbor_idx in &neighbors[level] {
                        let dist = self.distance(query, &self.nodes[neighbor_idx].vector);
                        if dist < current_dist {
                            current_idx = neighbor_idx;
                            current_dist = dist;
                            changed = true;
                        }
                    }
                }
            }
        }

        // Search at level 0 with ef
        let candidates = self.search_layer(query, current_idx, ef.max(k), 0);

        // Map internal indices back to external IDs and return top k
        let reverse_map: HashMap<usize, usize> = self
            .id_to_index
            .iter()
            .map(|(&ext, &int)| (int, ext))
            .collect();

        candidates
            .into_iter()
            .take(k)
            .filter_map(|(internal_idx, dist)| {
                reverse_map.get(&internal_idx).map(|&ext_id| (ext_id, dist))
            })
            .collect()
    }

    /// Get the number of nodes in the index
    pub fn len(&self) -> usize {
        self.nodes.len()
    }

    /// Check if the index is empty
    pub fn is_empty(&self) -> bool {
        self.nodes.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_hnsw_basic() {
        let mut index = HnswIndex::new(3, DistanceMetric::Cosine, HnswParams::default());

        // Insert some vectors
        index.insert(0, &[1.0, 0.0, 0.0]);
        index.insert(1, &[0.9, 0.1, 0.0]);
        index.insert(2, &[0.0, 1.0, 0.0]);
        index.insert(3, &[0.0, 0.0, 1.0]);

        // Search
        let results = index.search(&[1.0, 0.0, 0.0], 2, 10);
        assert_eq!(results.len(), 2);
        // First result should be vector 0 (exact match)
        assert_eq!(results[0].0, 0);
        assert!(results[0].1 < 0.01);
    }

    #[test]
    fn test_hnsw_euclidean() {
        let mut index = HnswIndex::new(3, DistanceMetric::Euclidean, HnswParams::default());

        index.insert(0, &[0.0, 0.0, 0.0]);
        index.insert(1, &[1.0, 0.0, 0.0]);
        index.insert(2, &[10.0, 0.0, 0.0]);

        let results = index.search(&[0.5, 0.0, 0.0], 2, 10);
        assert_eq!(results.len(), 2);
        // Should find 0 and 1 as closest
        let ids: Vec<_> = results.iter().map(|(id, _)| *id).collect();
        assert!(ids.contains(&0));
        assert!(ids.contains(&1));
    }

    #[test]
    fn test_hnsw_larger_scale() {
        let params = HnswParams {
            m: 8,
            ef_construction: 100,
            ef_search: 20,
        };
        let mut index = HnswIndex::new(64, DistanceMetric::Cosine, params);

        // Insert 100 vectors
        for i in 0..100 {
            let mut vec = vec![0.0f32; 64];
            vec[i % 64] = 1.0;
            index.insert(i, &vec);
        }

        // Query
        let mut query = vec![0.0f32; 64];
        query[0] = 1.0;

        let results = index.search(&query, 5, 50);
        assert_eq!(results.len(), 5);

        // Vector 0 should be the closest (same direction)
        assert_eq!(results[0].0, 0);
    }

    #[test]
    fn test_hnsw_empty() {
        let index = HnswIndex::new(3, DistanceMetric::Cosine, HnswParams::default());
        let results = index.search(&[1.0, 0.0, 0.0], 5, 10);
        assert!(results.is_empty());
    }
}
