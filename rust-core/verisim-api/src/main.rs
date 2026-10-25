// SPDX-License-Identifier: MPL-2.0
//! VeriSimDB API server binary
//!
//! Starts the HTTP API server for VeriSimDB.
//! Defaults to IPv6 loopback ([::1]). Set VERISIM_ENABLE_IPV4=true for IPv4 loopback.
//! Set VERISIM_TLS_CERT and VERISIM_TLS_KEY for HTTPS mode.

use verisim_api::ApiConfig;

/// Run the API using environment configuration, with loopback listeners and CORS
/// disabled by default. The binary does not configure authentication.
///
/// With both `VERISIM_TLS_CERT` and `VERISIM_TLS_KEY` set, serve HTTPS only;
/// otherwise serve HTTP and, unless its port is zero, gRPC. A partial TLS pair
/// returns an error. Store initialisation, listener setup and TLS loading errors
/// returned by the selected server are propagated.
#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Install ring as the default crypto provider (pure Rust, no OpenSSL/aws-lc-sys)
    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("failed to install ring crypto provider");

    // Initialize tracing with structured JSON output
    let json_logging = std::env::var("VERISIM_LOG_FORMAT")
        .map(|v| v == "json")
        .unwrap_or(true); // JSON by default in production

    let env_filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"));

    if json_logging {
        tracing_subscriber::fmt()
            .json()
            .with_env_filter(env_filter)
            .init();
    } else {
        tracing_subscriber::fmt().with_env_filter(env_filter).init();
    }

    // Network exposure must be an explicit VERISIM_HOST choice.
    let default_host = loopback_host(
        std::env::var("VERISIM_ENABLE_IPV4")
            .map(|v| v == "true" || v == "1")
            .unwrap_or(false),
    );

    let persist_dir = std::env::var("VERISIM_PERSISTENCE_DIR").ok();

    let config = ApiConfig {
        host: std::env::var("VERISIM_HOST").unwrap_or_else(|_| default_host.to_string()),
        port: std::env::var("VERISIM_PORT")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(8080),
        enable_cors: std::env::var("VERISIM_ENABLE_CORS")
            .map(|v| v != "false" && v != "0")
            .unwrap_or(false),
        version_prefix: std::env::var("VERISIM_API_PREFIX")
            .unwrap_or_else(|_| "/api/v1".to_string()),
        vector_dimension: std::env::var("VERISIM_VECTOR_DIM")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(384),
        persistence_dir: persist_dir.clone(),
        grpc_port: std::env::var("VERISIM_GRPC_PORT")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(50051),
        max_body_size: std::env::var("VERISIM_MAX_BODY_SIZE")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(10 * 1024 * 1024),
        request_timeout_secs: std::env::var("VERISIM_TIMEOUT_SECS")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(30),
        max_connections: std::env::var("VERISIM_MAX_CONNECTIONS")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(1024),
    };

    let storage_mode = if cfg!(feature = "persistent") {
        "persistent"
    } else {
        "in-memory"
    };

    tracing::warn!(
        "Internal API: authentication is not configured by this binary; VERISIM_HOST must name a trusted interface. Do not expose HTTP or gRPC to untrusted clients."
    );

    tracing::info!(
        host = %config.host,
        port = %config.port,
        storage = %storage_mode,
        persistence_dir = ?persist_dir,
        "Starting VeriSimDB API server"
    );

    // Check for TLS configuration
    let tls_cert = std::env::var("VERISIM_TLS_CERT").ok();
    let tls_key = std::env::var("VERISIM_TLS_KEY").ok();

    match (tls_cert, tls_key) {
        (Some(cert_path), Some(key_path)) => {
            tracing::info!(cert = %cert_path, "Starting with TLS enabled");
            verisim_api::serve_tls(config, &cert_path, &key_path).await?;
        }
        (Some(_), None) | (None, Some(_)) => {
            return Err("Both VERISIM_TLS_CERT and VERISIM_TLS_KEY must be set for TLS".into());
        }
        (None, None) => {
            verisim_api::serve(config).await?;
        }
    }

    Ok(())
}

/// Return `127.0.0.1` when IPv4 is enabled, otherwise bracketed IPv6 loopback
/// (`[::1]`), ready to append a port when forming a socket address.
fn loopback_host(enable_ipv4: bool) -> &'static str {
    if enable_ipv4 {
        "127.0.0.1"
    } else {
        "[::1]"
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn both_default_listener_modes_are_loopback() {
        for ipv4 in [false, true] {
            let address: std::net::SocketAddr = format!("{}:8080", super::loopback_host(ipv4))
                .parse()
                .unwrap();
            assert!(address.ip().is_loopback());
        }
    }
}
