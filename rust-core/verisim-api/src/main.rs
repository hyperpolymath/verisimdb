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

    let config = ApiConfig::default();

    tracing::info!(
        "Starting VeriSimDB API server on {}:{}",
        config.host,
        config.port
    );

    verisim_api::serve(config).await?;

    Ok(())
}
