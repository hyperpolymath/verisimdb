#!/usr/bin/env -S deno run --allow-read
// SPDX-License-Identifier: PMPL-1.0-or-later
// VQL Parser Port — stdin/stdout JSON bridge for Elixir
//
// Reads JSON messages (one per line) from stdin, parses VQL queries
// using the compiled ReScript VQLParser, and writes JSON results to stdout.
//
// Protocol: newline-delimited JSON
//   Request:  {"id": 1, "action": "parse", "query": "SELECT ..."}
//   Response: {"id": 1, "ok": {...ast...}} or {"id": 1, "error": "..."}

// Import compiled ReScript VQL parser
// The compiled JS output will be at ../src/vql/VQLParser.bs.js (ReScript compiler output)
let VQLParser;
try {
  // Try loading the compiled ReScript module
  VQLParser = await import("../src/vql/VQLParser.bs.js");
} catch (_e) {
  // Fallback: define a minimal parser that mirrors the ReScript AST
  VQLParser = null;
}

/**
 * Minimal VQL parser fallback (when compiled ReScript is unavailable).
 * Produces AST compatible with VQLParser.res types.
 */
function fallbackParse(query) {
  const tokens = query.trim().split(/\s+/);
  let pos = 0;

  function peek() { return tokens[pos] || null; }
  function advance() { return tokens[pos++] || null; }
  function expect(t) {
    const got = advance();
    if (got?.toUpperCase() !== t.toUpperCase()) {
      throw new Error(`Expected "${t}", got "${got}" at position ${pos}`);
    }
    return got;
  }

  // SELECT clause
  expect("SELECT");
  const modalities = [];
  while (peek() && peek().toUpperCase() !== "FROM") {
    const tok = advance().replace(/,/g, "").toUpperCase();
    if (tok === "*") modalities.push("All");
    else if (["GRAPH","VECTOR","TENSOR","SEMANTIC","DOCUMENT","TEMPORAL"].includes(tok)) {
      modalities.push(tok.charAt(0) + tok.slice(1).toLowerCase());
    }
  }

  // FROM clause
  expect("FROM");
  let source;
  const sourceType = advance()?.toUpperCase();
  if (sourceType === "HEXAD") {
    source = { TAG: "Hexad", _0: advance() };
  } else if (sourceType === "FEDERATION") {
    const pattern = advance();
    let driftPolicy = null;
    if (peek()?.toUpperCase() === "WITH") {
      advance(); // WITH
      expect("DRIFT");
      const policy = advance()?.toUpperCase();
      driftPolicy = policy;
    }
    source = { TAG: "Federation", _0: pattern, _1: driftPolicy };
  } else if (sourceType === "STORE") {
    source = { TAG: "Store", _0: advance() };
  } else {
    throw new Error(`Unknown source type: ${sourceType}`);
  }

  // WHERE clause (simplified)
  let whereClause = null;
  if (peek()?.toUpperCase() === "WHERE") {
    advance(); // WHERE
    const condTokens = [];
    while (peek() && !["PROOF","LIMIT","OFFSET"].includes(peek()?.toUpperCase())) {
      condTokens.push(advance());
    }
    whereClause = { TAG: "Raw", _0: condTokens.join(" ") };
  }

  // PROOF clause
  let proof = null;
  if (peek()?.toUpperCase() === "PROOF") {
    advance(); // PROOF
    const proofTokens = [];
    while (peek() && !["LIMIT","OFFSET"].includes(peek()?.toUpperCase())) {
      proofTokens.push(advance());
    }
    proof = { proofType: proofTokens[0], contractName: proofTokens[1]?.replace(/[()]/g, "") };
  }

  // LIMIT
  let limit = null;
  if (peek()?.toUpperCase() === "LIMIT") {
    advance();
    limit = parseInt(advance(), 10);
  }

  // OFFSET
  let offset = null;
  if (peek()?.toUpperCase() === "OFFSET") {
    advance();
    offset = parseInt(advance(), 10);
  }

  return {
    modalities,
    source,
    where: whereClause,
    proof,
    limit,
    offset,
  };
}

/**
 * Parse a VQL query using the ReScript parser or fallback.
 */
function parseQuery(query, action) {
  if (VQLParser) {
    let result;
    switch (action) {
      case "parse_slipstream":
        result = VQLParser.parseSlipstream(query);
        break;
      case "parse_dependent":
        result = VQLParser.parseDependentType(query);
        break;
      default:
        result = VQLParser.parse(query);
    }
    // ReScript Result type: { TAG: "Ok", _0: value } or { TAG: "Error", _0: error }
    if (result.TAG === "Ok") return { ok: result._0 };
    return { error: result._0.message || JSON.stringify(result._0) };
  }

  // Fallback parser
  return { ok: fallbackParse(query) };
}

// ---------------------------------------------------------------------------
// Main loop: read lines from stdin, process, write to stdout
// ---------------------------------------------------------------------------

const decoder = new TextDecoder();
const encoder = new TextEncoder();

// Deno stdin reading
const buf = new Uint8Array(1_048_576);
let buffer = "";

async function main() {
  const stdin = Deno.stdin;
  const stdout = Deno.stdout;

  while (true) {
    const n = await stdin.read(buf);
    if (n === null) break; // EOF

    buffer += decoder.decode(buf.subarray(0, n));

    // Process complete lines
    let newlineIdx;
    while ((newlineIdx = buffer.indexOf("\n")) !== -1) {
      const line = buffer.slice(0, newlineIdx).trim();
      buffer = buffer.slice(newlineIdx + 1);

      if (!line) continue;

      try {
        const request = JSON.parse(line);
        const { id, action, query } = request;

        try {
          const result = parseQuery(query, action);
          const response = JSON.stringify({ id, ...result }) + "\n";
          await stdout.write(encoder.encode(response));
        } catch (e) {
          const response = JSON.stringify({ id, error: e.message }) + "\n";
          await stdout.write(encoder.encode(response));
        }
      } catch (e) {
        // Malformed JSON — skip
        const response = JSON.stringify({ id: 0, error: `Invalid JSON: ${e.message}` }) + "\n";
        await stdout.write(encoder.encode(response));
      }
    }
  }
}

main().catch(console.error);
