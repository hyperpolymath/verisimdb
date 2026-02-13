// SPDX-License-Identifier: PMPL-1.0-or-later
//! VeriSimDB API server binary
//!
//! Starts the HTTP API server for VeriSimDB.

use verisim_api::ApiConfig;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Initialize tracing
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let config = ApiConfig {
        host: std::env::var("VERISIM_HOST").unwrap_or_else(|_| "0.0.0.0".to_string()),
        port: std::env::var("VERISIM_PORT")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(8080),
        enable_cors: std::env::var("VERISIM_ENABLE_CORS")
            .map(|v| v != "false" && v != "0")
            .unwrap_or(true),
        version_prefix: std::env::var("VERISIM_API_PREFIX")
            .unwrap_or_else(|_| "/api/v1".to_string()),
        vector_dimension: std::env::var("VERISIM_VECTOR_DIM")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(384),
    };

    tracing::info!(
        "Starting VeriSimDB API server on {}:{}",
        config.host,
        config.port
    );

    verisim_api::serve(config).await?;

    Ok(())
}
