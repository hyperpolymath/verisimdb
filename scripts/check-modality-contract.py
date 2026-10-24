#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
"""check-modality-contract.py — keep docs/modality-profile.adoc honest.

WHY THIS EXISTS
  Issue #299 asked for modality-profile *terminology* — no wire change. The risk
  with a pure-prose change is that the prose is wrong from the day it lands:
  somebody adds a ninth modality, or renames one, and the document keeps
  confidently describing the old eight. This checker binds the document's own
  modality lists to the three artefacts that actually define the slots:

    * connectors/shared/json-schema/modality.json  (the modality enum)
    * rust-core/verisim-octad/src/lib.rs           (ModalityStatus, OctadInput)
    * connectors/shared/json-schema/octad-input.json (create/update payload)

  It changes nothing; it only fails when the document and those artefacts
  disagree. It is deliberately *not* a schema validator: validating payloads is
  a separate concern, and this repo has no pinned validator dependency.

WHAT IS CHECKED
  1. The doc's `octad-slots` annotation == the modality enum == ModalityStatus
     boolean fields.
  2. The doc's `payload-fields` annotation == octad-input.json properties
     == the core `OctadInput` struct fields.
  3. octad-input.json stays closed (`additionalProperties: false`) — because the
     document promises there is no ninth modality.
  4. octad-slots - payload-fields == {temporal}, because the document states
     exactly that: every slot except `temporal` is settable through OctadInput.

  Only facts in the document are checked. The divergences the document *reports*
  (OpenAPI vs OctadRequest, client types, duplicate grammar) are deliberately not
  asserted: they are known-broken, and a gate that encodes a known break as
  expected would freeze it in place instead of flagging it.

USAGE
  scripts/check-modality-contract.py             # check this tree
  scripts/check-modality-contract.py <root>      # check an alternate root

EXIT
  0 — doc, schema and Rust agree
  1 — at least one disagreement; every mismatch is printed
  2 — an input file is missing or unparseable (fail closed)
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

DOC = "docs/modality-profile.adoc"
MODALITY_ENUM = "connectors/shared/json-schema/modality.json"
INPUT_SCHEMA = "connectors/shared/json-schema/octad-input.json"
CORE_LIB = "rust-core/verisim-octad/src/lib.rs"

ANNOTATION = re.compile(r"^\s*//\s*modality-contract:\s*([a-z-]+)\s*=\s*(.+?)\s*$")


def fail(message: str) -> "NoReturn":  # noqa: F821 - py3.8-compatible annotation string
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(2)


def read_text(root: Path, rel: str) -> str:
    path = root / rel
    if not path.is_file():
        fail(f"missing required file: {rel}")
    return path.read_text(encoding="utf-8")


def read_json(root: Path, rel: str) -> dict:
    try:
        return json.loads(read_text(root, rel))
    except json.JSONDecodeError as exc:
        fail(f"{rel} is not valid JSON: {exc}")


def doc_annotations(root: Path) -> dict:
    found: dict = {}
    for line in read_text(root, DOC).splitlines():
        match = ANNOTATION.match(line)
        if match:
            key, value = match.group(1), match.group(2)
            if key in found:
                fail(f"{DOC} declares 'modality-contract: {key}' more than once")
            found[key] = [item.strip() for item in value.split(",") if item.strip()]
    for required in ("octad-slots", "payload-fields"):
        if required not in found:
            fail(
                f"{DOC} is missing its '// modality-contract: {required} = …' "
                "annotation; the gate cannot verify a document that does not "
                "declare what it claims"
            )
    return found


def struct_fields(source: str, struct_name: str) -> list:
    """Return the field names of `pub struct <name> { … }` in a Rust source."""
    match = re.search(
        rf"pub struct {struct_name}\b[^{{]*\{{(.*?)\n\}}",
        source,
        re.DOTALL,
    )
    if not match:
        fail(f"could not find `pub struct {struct_name}` in {CORE_LIB}")
    body = match.group(1)
    # Drop attribute/doc lines and use only `pub <field>: <type>,` declarations.
    return re.findall(r"^\s*pub\s+([a-z_][a-z0-9_]*)\s*:", body, re.MULTILINE)


def compare(label: str, left: list, right: list, mismatches: list) -> None:
    left_set, right_set = set(left), set(right)
    if left_set == right_set:
        return
    for only_left in sorted(left_set - right_set):
        mismatches.append(f"{label}: {only_left!r} is on the left side only")
    for only_right in sorted(right_set - left_set):
        mismatches.append(f"{label}: {only_right!r} is on the right side only")


def main(argv: list) -> int:
    root = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parent.parent
    if not root.is_dir():
        fail(f"scan root does not exist: {root}")

    doc = doc_annotations(root)

    enum = read_json(root, MODALITY_ENUM).get("enum")
    if not isinstance(enum, list) or not enum:
        fail(f"{MODALITY_ENUM} has no non-empty 'enum'")

    schema = read_json(root, INPUT_SCHEMA)
    schema_props = list(schema.get("properties", {}))
    if not schema_props:
        fail(f"{INPUT_SCHEMA} has no 'properties'")

    source = read_text(root, CORE_LIB)
    status_fields = struct_fields(source, "ModalityStatus")
    input_fields = struct_fields(source, "OctadInput")

    mismatches: list = []
    compare(f"{DOC} octad-slots  vs  {MODALITY_ENUM} enum", doc["octad-slots"], enum, mismatches)
    compare(f"{DOC} octad-slots  vs  ModalityStatus fields", doc["octad-slots"], status_fields, mismatches)
    compare(f"{DOC} payload-fields  vs  {INPUT_SCHEMA} properties", doc["payload-fields"], schema_props, mismatches)
    compare(f"{DOC} payload-fields  vs  OctadInput fields", doc["payload-fields"], input_fields, mismatches)

    if schema.get("additionalProperties") is not False:
        mismatches.append(
            f"{INPUT_SCHEMA}: 'additionalProperties' must be false — the document "
            "states that no ninth modality is expressible in the schema"
        )

    # The one documented asymmetry: `temporal` is in the slot list but is not
    # settable through OctadInput. Anything else would contradict §5 of the doc.
    not_settable = set(doc["octad-slots"]) - set(doc["payload-fields"])
    if not_settable != {"temporal"}:
        mismatches.append(
            f"{DOC}: slots not settable via OctadInput are {sorted(not_settable)}; "
            "the document states this set is exactly {'temporal'} — update §5 and "
            "this gate together if the contract really changed"
        )

    if mismatches:
        print("FAIL modality-contract: the document and the implementation disagree.", file=sys.stderr)
        for item in mismatches:
            print(f"       - {item}", file=sys.stderr)
        print(
            f"       The document is normative for words only. Fix {DOC}, or, if the "
            "contract itself changed, that is an owner decision that lands with a "
            "versioned schema and tests — see §10 of the document.",
            file=sys.stderr,
        )
        return 1

    print(
        "PASS modality-contract: "
        f"{len(doc['octad-slots'])} octad slots and {len(doc['payload-fields'])} "
        "payload fields agree across doc, modality.json, octad-input.json and the "
        "Rust core"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
