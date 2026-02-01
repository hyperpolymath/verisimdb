;; SPDX-License-Identifier: AGPL-3.0-or-later
;; ECOSYSTEM.scm - Ecosystem relationships for verisimdb
;; Media-Type: application/vnd.ecosystem+scm

(ecosystem
  (version "1.0.0")
  (name "verisimdb")
  (type "library")  ;; or: application, tool, specification, template
  (purpose "Hyperpolymath ecosystem component")

  (position-in-ecosystem
    "Part of the hyperpolymath ecosystem of 500+ repositories "
    "following Rhodium Standard Repository (RSR) conventions.")

  (related-projects
    (potential-federation-target
      (project "formbd")
      (relationship "potential-federation-target")
      (description "Narrative-first, reversible, audit-grade database")
      (note "FormBD could be one of many databases VeriSimDB federates to (like PostgreSQL, MongoDB, etc.). Completely distinct architectures and purposes."))

    (dependency
      (project "proven")
      (relationship "dependency")
      (description "Zero-knowledge proof system")
      (usage "VeriSimDB's semantic modality uses proven for ZKP verification"))

    (dependency
      (project "sactify-php")
      (relationship "dependency")
      (description "PHP integration for ZKP verification")
      (usage "Enables VeriSimDB to verify claims without data access"))

    (potential-consumer
      (project "hypatia")
      (relationship "potential-consumer")
      (description "Neurosymbolic CI/CD intelligence platform")
      (usage "Could use VeriSimDB as knowledge store for scan results and learning")))

  (what-this-is
    "A multimodal database with 6 modalities (Graph, Vector, Tensor, Semantic, Document, Temporal)"
    "A federated coordinator for distributed knowledge stores across institutions"
    "A drift-aware system that detects and repairs cross-modal inconsistencies"
    "A universal namespace (UUID → modality mappings) with KRaft-inspired consensus"
    "A Zero-Trust database integrating ZKP verification (proven + sactify-php)"
    "Deployable as standalone database, federated coordinator, or hybrid")

  (what-this-is-not
    "A single-consistency-model database (supports 6 modalities with different guarantees)"
    "A drop-in replacement for PostgreSQL or MongoDB (different architecture)"
    "A pure federation system without local storage (hybrid deployment supported)"
    "A centralized system (federation is a first-class deployment mode)"))
