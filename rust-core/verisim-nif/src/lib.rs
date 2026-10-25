// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//!
//! Retired conventional NIF transport.
//!
//! This crate intentionally has no FFI exports, native library, runtime or
//! Rustler dependency. Its former operations were unimplemented. The package
//! remains as a migration marker so downstream builds cannot silently revive
//! the retired transport. VeriSim.NifBridge no longer loads native libraries.
//!
//! Use HTTP for store operations. Any future BEAM native-compute integration
//! must use bounded, pure-compute SNIF guests, with no filesystem or network
//! access, a normative Idris2 ABI and Zig FFI implementation. No such kernel
//! is admitted by this change: workload-specific overhead is still unmeasured.

#![forbid(unsafe_code)]
