// SPDX-License-Identifier: MPL-2.0
//! Property-based tests for verisim-spatial.
//!
//! Each property is an invariant that must hold across the full input
//! space.  Generators are constrained to in-range coordinates so we
//! exercise the data-path, not the boundary-rejection path (the
//! boundary tests are in tests/integration.rs).

use std::collections::HashMap;

use proptest::prelude::*;
use tokio::runtime::Runtime;
use verisim_spatial::{
    haversine_distance, Coordinates, GeometryType, InMemorySpatialStore, SpatialData, SpatialStore,
};

fn rt() -> Runtime {
    Runtime::new().expect("tokio runtime")
}

fn lat_strategy() -> impl Strategy<Value = f64> {
    -90.0_f64..=90.0_f64
}

fn lon_strategy() -> impl Strategy<Value = f64> {
    -180.0_f64..=180.0_f64
}

fn coord_strategy() -> impl Strategy<Value = Coordinates> {
    (lat_strategy(), lon_strategy()).prop_filter_map("valid coord", |(lat, lon)| {
        Coordinates::new(lat, lon, None).ok()
    })
}

fn point_strategy() -> impl Strategy<Value = SpatialData> {
    coord_strategy().prop_map(|c| SpatialData {
        coordinates: c,
        geometry_type: GeometryType::Point,
        srid: 4326,
        properties: HashMap::new(),
    })
}

proptest! {
    /// Round-trip: index → get yields a coordinate that's equal to
    /// what was indexed (modulo f64 round-trip exactness, which is
    /// exact for both storage and retrieval since we use the same
    /// values).
    #[test]
    fn prop_index_get_round_trip(entity in "[a-z]{1,16}", data in point_strategy()) {
        let rt = rt();
        let store = InMemorySpatialStore::new();
        let lat = data.coordinates.latitude;
        let lon = data.coordinates.longitude;

        rt.block_on(async {
            store.index(&entity, data).await.unwrap();
            let fetched = store.get(&entity).await.unwrap().unwrap();
            prop_assert_eq!(fetched.coordinates.latitude, lat);
            prop_assert_eq!(fetched.coordinates.longitude, lon);
            Ok(())
        })?;
    }

    /// Symmetry: haversine_distance(a, b) == haversine_distance(b, a).
    #[test]
    fn prop_haversine_symmetric(a in coord_strategy(), b in coord_strategy()) {
        let d1 = haversine_distance(&a, &b);
        let d2 = haversine_distance(&b, &a);
        prop_assert!(
            (d1 - d2).abs() < 1e-9,
            "asymmetry: d(a,b)={} d(b,a)={}",
            d1,
            d2
        );
    }

    /// Identity: distance(p, p) ≈ 0.
    #[test]
    fn prop_haversine_self_zero(p in coord_strategy()) {
        let d = haversine_distance(&p, &p);
        prop_assert!(d.abs() < 1e-6, "non-zero self-distance: {}", d);
    }

    /// Non-negativity: distance is always ≥ 0.
    #[test]
    fn prop_haversine_non_negative(a in coord_strategy(), b in coord_strategy()) {
        let d = haversine_distance(&a, &b);
        prop_assert!(d >= 0.0, "negative distance: {}", d);
        prop_assert!(d.is_finite(), "non-finite distance: {}", d);
    }

    /// Bounded: any two points on Earth are at most ~half the
    /// circumference apart (~20,015 km — pole to pole on opposite
    /// meridians).  Use 20,100 km to give a small numeric cushion.
    #[test]
    fn prop_haversine_bounded(a in coord_strategy(), b in coord_strategy()) {
        let d = haversine_distance(&a, &b);
        prop_assert!(
            d < 20_100.0,
            "distance {} km exceeds half circumference between {:?} and {:?}",
            d,
            a,
            b
        );
    }

    /// Upsert overwrites: indexing the same id twice yields the second
    /// coordinate.
    #[test]
    fn prop_upsert_overwrites(
        entity in "[a-z]{1,16}",
        first in point_strategy(),
        second in point_strategy()
    ) {
        let rt = rt();
        let store = InMemorySpatialStore::new();
        let second_lat = second.coordinates.latitude;

        rt.block_on(async {
            store.index(&entity, first).await.unwrap();
            store.index(&entity, second).await.unwrap();
            let fetched = store.get(&entity).await.unwrap().unwrap();
            prop_assert_eq!(fetched.coordinates.latitude, second_lat);
            Ok(())
        })?;
    }

    /// Delete erases: after delete the entity is no longer fetchable.
    #[test]
    fn prop_delete_erases(entity in "[a-z]{1,16}", data in point_strategy()) {
        let rt = rt();
        let store = InMemorySpatialStore::new();

        rt.block_on(async {
            store.index(&entity, data).await.unwrap();
            store.delete(&entity).await.unwrap();
            prop_assert!(store.get(&entity).await.unwrap().is_none());
            Ok(())
        })?;
    }

    /// k-nearest sorted: distances in result are monotonically
    /// non-decreasing.
    #[test]
    fn prop_nearest_sorted(
        centre in coord_strategy(),
        points in proptest::collection::vec(point_strategy(), 2..20),
        k in 1usize..15
    ) {
        let rt = rt();
        let store = InMemorySpatialStore::new();

        rt.block_on(async {
            for (i, p) in points.iter().enumerate() {
                store.index(&format!("p-{}", i), p.clone()).await.unwrap();
            }
            let results = store.nearest(&centre, k).await.unwrap();
            for window in results.windows(2) {
                prop_assert!(
                    window[0].distance_km <= window[1].distance_km,
                    "nearest violated monotonic order"
                );
            }
            Ok(())
        })?;
    }
}
