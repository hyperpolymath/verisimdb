// SPDX-License-Identifier: MPL-2.0
//! Integration tests for verisim-spatial.
//!
//! These tests exercise the InMemorySpatialStore against scenarios that
//! span multiple operations — index → search → delete cycles, geometry
//! variety, edge cases at coordinate boundaries.  Pure unit-level
//! invariants (e.g. Haversine distance correctness) live in the inline
//! `#[cfg(test)]` module of src/lib.rs.

use std::collections::HashMap;
use verisim_spatial::{
    Coordinates, GeometryType, InMemorySpatialStore, SpatialData, SpatialStore,
};

fn point_at(lat: f64, lon: f64) -> SpatialData {
    SpatialData {
        coordinates: Coordinates::new(lat, lon, None).unwrap(),
        geometry_type: GeometryType::Point,
        srid: 4326,
        properties: HashMap::new(),
    }
}

#[tokio::test]
async fn index_get_round_trip_preserves_coordinates() {
    let store = InMemorySpatialStore::new();
    let data = point_at(51.5074, -0.1278);
    store.index("london", data).await.unwrap();

    let fetched = store.get("london").await.unwrap().unwrap();
    assert!((fetched.coordinates.latitude - 51.5074).abs() < 1e-9);
    assert!((fetched.coordinates.longitude - -0.1278).abs() < 1e-9);
    assert_eq!(fetched.srid, 4326);
    assert_eq!(fetched.geometry_type, GeometryType::Point);
}

#[tokio::test]
async fn get_unknown_entity_returns_none() {
    let store = InMemorySpatialStore::new();
    assert!(store.get("nope").await.unwrap().is_none());
}

#[tokio::test]
async fn delete_removes_indexed_entity() {
    let store = InMemorySpatialStore::new();
    store.index("ephemeral", point_at(0.0, 0.0)).await.unwrap();
    assert!(store.get("ephemeral").await.unwrap().is_some());

    store.delete("ephemeral").await.unwrap();
    assert!(store.get("ephemeral").await.unwrap().is_none());
}

#[tokio::test]
async fn delete_is_idempotent() {
    let store = InMemorySpatialStore::new();
    // Should not error on deleting something that isn't there.
    store.delete("never-existed").await.unwrap();
}

#[tokio::test]
async fn search_radius_excludes_points_beyond_distance() {
    let store = InMemorySpatialStore::new();
    // London centre + a point in Paris (~344 km away).
    store
        .index("london", point_at(51.5074, -0.1278))
        .await
        .unwrap();
    store
        .index("paris", point_at(48.8566, 2.3522))
        .await
        .unwrap();

    // 100 km radius from London should only find London.
    let london = Coordinates::new(51.5074, -0.1278, None).unwrap();
    let results = store.search_radius(&london, 100.0, 10).await.unwrap();
    let ids: Vec<&str> = results.iter().map(|r| r.entity_id.as_str()).collect();
    assert!(ids.contains(&"london"));
    assert!(!ids.contains(&"paris"));
}

#[tokio::test]
async fn search_radius_includes_self_with_zero_distance() {
    let store = InMemorySpatialStore::new();
    store
        .index("origin", point_at(0.0, 0.0))
        .await
        .unwrap();

    let origin = Coordinates::new(0.0, 0.0, None).unwrap();
    let results = store.search_radius(&origin, 1.0, 10).await.unwrap();
    assert_eq!(results.len(), 1);
    assert_eq!(results[0].entity_id, "origin");
    assert!(results[0].distance_km < 1e-6);
}

#[tokio::test]
async fn search_radius_respects_limit() {
    let store = InMemorySpatialStore::new();
    // 20 points clustered in central London.
    for i in 0..20 {
        let lat = 51.5074 + (i as f64) * 0.0001;
        let lon = -0.1278;
        store
            .index(&format!("p-{}", i), point_at(lat, lon))
            .await
            .unwrap();
    }

    let centre = Coordinates::new(51.5074, -0.1278, None).unwrap();
    let results = store.search_radius(&centre, 50.0, 5).await.unwrap();
    assert!(results.len() <= 5);
}

#[tokio::test]
async fn nearest_k_returns_at_most_k_results() {
    let store = InMemorySpatialStore::new();
    for i in 0..5 {
        store
            .index(&format!("p-{}", i), point_at(i as f64, 0.0))
            .await
            .unwrap();
    }

    let origin = Coordinates::new(0.0, 0.0, None).unwrap();
    let results = store.nearest(&origin, 3).await.unwrap();
    assert!(results.len() <= 3);
}

#[tokio::test]
async fn nearest_orders_results_by_distance_ascending() {
    let store = InMemorySpatialStore::new();
    // Three points at distinct distances from origin.
    store.index("near", point_at(0.001, 0.0)).await.unwrap();
    store.index("mid", point_at(0.01, 0.0)).await.unwrap();
    store.index("far", point_at(0.1, 0.0)).await.unwrap();

    let origin = Coordinates::new(0.0, 0.0, None).unwrap();
    let results = store.nearest(&origin, 3).await.unwrap();

    let distances: Vec<f64> = results.iter().map(|r| r.distance_km).collect();
    for window in distances.windows(2) {
        assert!(window[0] <= window[1], "nearest results must be ascending");
    }
}

#[tokio::test]
async fn index_with_properties_round_trips_them() {
    let store = InMemorySpatialStore::new();
    let mut props = HashMap::new();
    props.insert("city".to_string(), "London".to_string());
    props.insert("country".to_string(), "GB".to_string());

    let data = SpatialData {
        coordinates: Coordinates::new(51.5, -0.1, None).unwrap(),
        geometry_type: GeometryType::Point,
        srid: 4326,
        properties: props,
    };
    store.index("annotated", data).await.unwrap();

    let fetched = store.get("annotated").await.unwrap().unwrap();
    assert_eq!(fetched.properties.get("city"), Some(&"London".to_string()));
    assert_eq!(fetched.properties.get("country"), Some(&"GB".to_string()));
}

#[tokio::test]
async fn coordinates_reject_out_of_range_latitude() {
    assert!(Coordinates::new(90.0001, 0.0, None).is_err());
    assert!(Coordinates::new(-90.0001, 0.0, None).is_err());
}

#[tokio::test]
async fn coordinates_reject_out_of_range_longitude() {
    assert!(Coordinates::new(0.0, 180.0001, None).is_err());
    assert!(Coordinates::new(0.0, -180.0001, None).is_err());
}

#[tokio::test]
async fn coordinates_accept_exact_boundary_values() {
    // Boundaries are inclusive.
    assert!(Coordinates::new(90.0, 180.0, None).is_ok());
    assert!(Coordinates::new(-90.0, -180.0, None).is_ok());
}

#[tokio::test]
async fn upsert_overwrites_existing_entity() {
    let store = InMemorySpatialStore::new();
    store.index("e", point_at(0.0, 0.0)).await.unwrap();
    store.index("e", point_at(10.0, 10.0)).await.unwrap();

    let fetched = store.get("e").await.unwrap().unwrap();
    assert!((fetched.coordinates.latitude - 10.0).abs() < 1e-9);
}
