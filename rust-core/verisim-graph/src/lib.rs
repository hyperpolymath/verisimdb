// SPDX-License-Identifier: PMPL-1.0-or-later
//! VeriSim Graph Modality
//!
//! RDF and property graph storage via Oxigraph.
//! Implements Marr's Computational Level: "What relationships exist?"

use async_trait::async_trait;
use oxigraph::model::{GraphName, NamedNode, Quad, Subject, Term};
use oxigraph::store::Store;
use serde::{Deserialize, Serialize};
use std::path::Path;
use thiserror::Error;

/// Graph modality errors
#[derive(Error, Debug)]
pub enum GraphError {
    #[error("Store error: {0}")]
    StoreError(#[from] oxigraph::store::StorageError),

    #[error("Parse error: {0}")]
    ParseError(String),

    #[error("Entity not found: {0}")]
    NotFound(String),

    #[error("Invalid IRI: {0}")]
    InvalidIri(String),
}

/// A node in the graph (entity reference)
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]
pub struct GraphNode {
    /// IRI of the node
    pub iri: String,
    /// Local name (last segment of IRI)
    pub local_name: String,
}

impl GraphNode {
    /// Create a new graph node from an IRI
    pub fn new(iri: impl Into<String>) -> Self {
        let iri = iri.into();
        let local_name = iri
            .rsplit_once('/')
            .or_else(|| iri.rsplit_once('#'))
            .map(|(_, name)| name.to_string())
            .unwrap_or_else(|| iri.clone());
        Self { iri, local_name }
    }
}

/// An edge in the graph (relationship)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GraphEdge {
    /// Subject node
    pub subject: GraphNode,
    /// Predicate (relationship type)
    pub predicate: GraphNode,
    /// Object (target node or literal)
    pub object: GraphObject,
}

/// Object of a triple (can be node or literal)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum GraphObject {
    Node(GraphNode),
    Literal { value: String, datatype: Option<String> },
}

/// Graph store trait for cross-modal consistency
#[async_trait]
pub trait GraphStore: Send + Sync {
    /// Insert a triple
    async fn insert(&self, edge: &GraphEdge) -> Result<(), GraphError>;

    /// Query outgoing edges from a node
    async fn outgoing(&self, node: &GraphNode) -> Result<Vec<GraphEdge>, GraphError>;

    /// Query incoming edges to a node
    async fn incoming(&self, node: &GraphNode) -> Result<Vec<GraphEdge>, GraphError>;

    /// Check if a triple exists
    async fn exists(&self, edge: &GraphEdge) -> Result<bool, GraphError>;

    /// Delete a triple
    async fn delete(&self, edge: &GraphEdge) -> Result<(), GraphError>;

    /// Get all nodes connected to a given node within N hops
    async fn neighborhood(&self, node: &GraphNode, hops: usize) -> Result<Vec<GraphNode>, GraphError>;
}

/// Oxigraph-backed graph store
pub struct OxiGraphStore {
    store: Store,
}

impl OxiGraphStore {
    /// Create a new in-memory store
    pub fn in_memory() -> Result<Self, GraphError> {
        Ok(Self {
            store: Store::new()?,
        })
    }

    /// Open or create a persistent store
    pub fn persistent(path: impl AsRef<Path>) -> Result<Self, GraphError> {
        Ok(Self {
            store: Store::open(path)?,
        })
    }

    /// Convert GraphEdge to Oxigraph Quad
    fn edge_to_quad(&self, edge: &GraphEdge) -> Result<Quad, GraphError> {
        let subject = Subject::NamedNode(
            NamedNode::new(&edge.subject.iri)
                .map_err(|e| GraphError::InvalidIri(e.to_string()))?,
        );
        let predicate = NamedNode::new(&edge.predicate.iri)
            .map_err(|e| GraphError::InvalidIri(e.to_string()))?;
        let object = match &edge.object {
            GraphObject::Node(n) => Term::NamedNode(
                NamedNode::new(&n.iri).map_err(|e| GraphError::InvalidIri(e.to_string()))?,
            ),
            GraphObject::Literal { value, datatype: _ } => {
                Term::Literal(oxigraph::model::Literal::new_simple_literal(value))
            }
        };
        Ok(Quad::new(subject, predicate, object, GraphName::DefaultGraph))
    }
}

#[async_trait]
impl GraphStore for OxiGraphStore {
    async fn insert(&self, edge: &GraphEdge) -> Result<(), GraphError> {
        let quad = self.edge_to_quad(edge)?;
        self.store.insert(&quad)?;
        Ok(())
    }

    async fn outgoing(&self, node: &GraphNode) -> Result<Vec<GraphEdge>, GraphError> {
        let subject = NamedNode::new(&node.iri).map_err(|e| GraphError::InvalidIri(e.to_string()))?;
        let mut edges = Vec::new();

        for quad in self.store.quads_for_pattern(Some(subject.as_ref().into()), None, None, None) {
            let quad = quad?;
            let predicate = GraphNode::new(quad.predicate.as_str());
            let object = match quad.object {
                Term::NamedNode(n) => GraphObject::Node(GraphNode::new(n.as_str())),
                Term::Literal(l) => GraphObject::Literal {
                    value: l.value().to_string(),
                    datatype: Some(l.datatype().as_str().to_string()),
                },
                _ => continue,
            };
            edges.push(GraphEdge {
                subject: node.clone(),
                predicate,
                object,
            });
        }
        Ok(edges)
    }

    async fn incoming(&self, node: &GraphNode) -> Result<Vec<GraphEdge>, GraphError> {
        let object = NamedNode::new(&node.iri).map_err(|e| GraphError::InvalidIri(e.to_string()))?;
        let mut edges = Vec::new();

        for quad in self.store.quads_for_pattern(None, None, Some(object.as_ref().into()), None) {
            let quad = quad?;
            let subject = match quad.subject {
                Subject::NamedNode(n) => GraphNode::new(n.as_str()),
                _ => continue,
            };
            let predicate = GraphNode::new(quad.predicate.as_str());
            edges.push(GraphEdge {
                subject,
                predicate,
                object: GraphObject::Node(node.clone()),
            });
        }
        Ok(edges)
    }

    async fn exists(&self, edge: &GraphEdge) -> Result<bool, GraphError> {
        let quad = self.edge_to_quad(edge)?;
        Ok(self.store.contains(&quad)?)
    }

    async fn delete(&self, edge: &GraphEdge) -> Result<(), GraphError> {
        let quad = self.edge_to_quad(edge)?;
        self.store.remove(&quad)?;
        Ok(())
    }

    async fn neighborhood(&self, node: &GraphNode, hops: usize) -> Result<Vec<GraphNode>, GraphError> {
        use std::collections::HashSet;

        let mut visited = HashSet::new();
        let mut frontier = vec![node.clone()];
        visited.insert(node.iri.clone());

        for _ in 0..hops {
            let mut next_frontier = Vec::new();
            for current in frontier {
                for edge in self.outgoing(&current).await? {
                    if let GraphObject::Node(n) = edge.object {
                        if visited.insert(n.iri.clone()) {
                            next_frontier.push(n);
                        }
                    }
                }
                for edge in self.incoming(&current).await? {
                    if visited.insert(edge.subject.iri.clone()) {
                        next_frontier.push(edge.subject);
                    }
                }
            }
            frontier = next_frontier;
        }

        Ok(visited.into_iter().map(GraphNode::new).collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_insert_and_query() {
        let store = OxiGraphStore::in_memory().unwrap();
        let edge = GraphEdge {
            subject: GraphNode::new("http://example.org/Alice"),
            predicate: GraphNode::new("http://example.org/knows"),
            object: GraphObject::Node(GraphNode::new("http://example.org/Bob")),
        };

        store.insert(&edge).await.unwrap();
        assert!(store.exists(&edge).await.unwrap());

        let outgoing = store.outgoing(&edge.subject).await.unwrap();
        assert_eq!(outgoing.len(), 1);
    }
}
