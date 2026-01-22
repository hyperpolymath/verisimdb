// SPDX-License-Identifier: PMPL-1.0-or-later
// VQL Slipstream Parser - Untyped AST
// Phase 1: Simple parser for slipstream queries (no dependent types)

// ============================================================================
// AST Types
// ============================================================================

module AST = {
  type modality =
    | Graph
    | Vector
    | Tensor
    | Semantic
    | Document
    | Temporal
    | All

  type source =
    | Hexad(string)  // UUID
    | Federation(string, option<driftPolicy>)  // pattern, drift policy
    | Store(string)  // store ID

  and driftPolicy =
    | Strict
    | Repair
    | Tolerate
    | Latest

  type operator =
    | Eq
    | Neq
    | Gt
    | Lt
    | Gte
    | Lte
    | Like
    | Contains
    | Matches

  type condition =
    | Simple(simpleCondition)
    | And(condition, condition)
    | Or(condition, condition)
    | Not(condition)

  and simpleCondition =
    | FulltextContains(string)
    | FulltextMatches(string)
    | FieldCondition(string, operator, literal)
    | VectorSimilar(array<float>, option<float>)  // embedding, threshold
    | GraphPattern(string)  // SPARQL-like pattern (simplified)

  and literal =
    | String(string)
    | Int(int)
    | Float(float)
    | Bool(bool)
    | Array(array<literal>)

  type query = {
    modalities: array<modality>,
    source: source,
    where: option<condition>,
    proof: option<proofSpec>,
    limit: option<int>,
    offset: option<int>,
  }

  and proofSpec = {
    proofType: proofType,
    contractName: string,
  }

  and proofType =
    | Existence
    | Citation
    | Access
    | Integrity
    | Provenance
    | Custom
}

// ============================================================================
// Parser Combinators
// ============================================================================

module Parser = {
  type parseError = {
    message: string,
    position: int,
  }

  type parseResult<'a> = Result<('a, int), parseError>

  type parser<'a> = string => parseResult<'a>

  // Basic combinators
  let pure = (value: 'a): parser<'a> => {
    input => Ok((value, 0))
  }

  let fail = (message: string): parser<'a> => {
    _input => Error({message, position: 0})
  }

  let map = (p: parser<'a>, f: 'a => 'b): parser<'b> => {
    input => {
      switch p(input) {
      | Ok((value, consumed)) => Ok((f(value), consumed))
      | Error(e) => Error(e)
      }
    }
  }

  let bind = (p: parser<'a>, f: 'a => parser<'b>): parser<'b> => {
    input => {
      switch p(input) {
      | Ok((value, consumed)) => {
          let remaining = Js.String2.sliceToEnd(input, ~from=consumed)
          switch f(value)(remaining) {
          | Ok((value2, consumed2)) => Ok((value2, consumed + consumed2))
          | Error(e) => Error({...e, position: e.position + consumed})
          }
        }
      | Error(e) => Error(e)
      }
    }
  }

  let (<|>) = (p1: parser<'a>, p2: parser<'a>): parser<'a> => {
    input => {
      switch p1(input) {
      | Ok(result) => Ok(result)
      | Error(_) => p2(input)
      }
    }
  }

  // Whitespace handling
  let ws: parser<unit> = input => {
    let trimmed = Js.String2.trimStart(input)
    let consumed = Js.String2.length(input) - Js.String2.length(trimmed)
    Ok(((), consumed))
  }

  let lexeme = (p: parser<'a>): parser<'a> => {
    bind(p, value => map(ws, _ => value))
  }

  // String matching
  let string = (s: string): parser<string> => {
    input => {
      if Js.String2.startsWith(input, s) {
        Ok((s, Js.String2.length(s)))
      } else {
        Error({message: `Expected "${s}"`, position: 0})
      }
    }
  }

  let keyword = (k: string): parser<string> => {
    lexeme(string(k))
  }

  // Regex-based parsers
  let regex = (pattern: string): parser<string> => {
    input => {
      let re = Js.Re.fromStringWithFlags(pattern, ~flags="i")
      switch Js.Re.exec_(re, input) {
      | Some(result) => {
          let matched = Js.Re.captures(result)[0]
          switch Js.Nullable.toOption(matched) {
          | Some(str) => Ok((str, Js.String2.length(str)))
          | None => Error({message: `Regex ${pattern} failed`, position: 0})
          }
        }
      | None => Error({message: `Regex ${pattern} failed`, position: 0})
      }
    }
  }

  let identifier: parser<string> = lexeme(regex("^[a-zA-Z_][a-zA-Z0-9_]*"))

  let uuid: parser<string> = lexeme(
    regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
  )

  let integer: parser<int> = {
    input => {
      let intStr = lexeme(regex("^[0-9]+"))
      switch intStr(input) {
      | Ok((str, consumed)) => {
          switch Belt.Int.fromString(str) {
          | Some(n) => Ok((n, consumed))
          | None => Error({message: "Invalid integer", position: 0})
          }
        }
      | Error(e) => Error(e)
      }
    }
  }

  let float: parser<float> = {
    input => {
      let floatStr = lexeme(regex("^[0-9]+\\.[0-9]+"))
      switch floatStr(input) {
      | Ok((str, consumed)) => {
          switch Belt.Float.fromString(str) {
          | Some(f) => Ok((f, consumed))
          | None => Error({message: "Invalid float", position: 0})
          }
        }
      | Error(e) => Error(e)
      }
    }
  }

  let stringLiteral: parser<string> = {
    input => {
      let quoted = lexeme(regex("^\"([^\"\\\\]|\\\\.)*\""))
      switch quoted(input) {
      | Ok((str, consumed)) => {
          // Remove quotes
          let unquoted = Js.String2.slice(str, ~from=1, ~to_=Js.String2.length(str) - 1)
          Ok((unquoted, consumed))
        }
      | Error(e) => Error(e)
      }
    }
  }

  // Many combinator
  let rec many = (p: parser<'a>): parser<array<'a>> => {
    input => {
      switch p(input) {
      | Ok((value, consumed)) => {
          let remaining = Js.String2.sliceToEnd(input, ~from=consumed)
          switch many(p)(remaining) {
          | Ok((values, consumed2)) => Ok(([value]->Js.Array2.concat(values), consumed + consumed2))
          | Error(_) => Ok(([value], consumed))
          }
        }
      | Error(_) => Ok(([], 0))
      }
    }
  }

  let sepBy = (p: parser<'a>, sep: parser<'b>): parser<array<'a>> => {
    input => {
      switch p(input) {
      | Ok((first, consumed1)) => {
          let remaining = Js.String2.sliceToEnd(input, ~from=consumed1)
          let parseRest = bind(sep, _ => p)
          switch many(parseRest)(remaining) {
          | Ok((rest, consumed2)) => Ok(([first]->Js.Array2.concat(rest), consumed1 + consumed2))
          | Error(_) => Ok(([first], consumed1))
          }
        }
      | Error(e) => Error(e)
      }
    }
  }

  let optional = (p: parser<'a>): parser<option<'a>> => {
    input => {
      switch p(input) {
      | Ok((value, consumed)) => Ok((Some(value), consumed))
      | Error(_) => Ok((None, 0))
      }
    }
  }
}

// ============================================================================
// VQL Grammar Parsers
// ============================================================================

module Grammar = {
  open Parser
  open AST

  // Modality parser
  let modality: parser<modality> = {
    let graph = map(keyword("GRAPH"), _ => Graph)
    let vector = map(keyword("VECTOR"), _ => Vector)
    let tensor = map(keyword("TENSOR"), _ => Tensor)
    let semantic = map(keyword("SEMANTIC"), _ => Semantic)
    let document = map(keyword("DOCUMENT"), _ => Document)
    let temporal = map(keyword("TEMPORAL"), _ => Temporal)
    let all = map(keyword("*"), _ => All)

    graph <|> vector <|> tensor <|> semantic <|> document <|> temporal <|> all
  }

  let modalityList: parser<array<modality>> = sepBy(modality, keyword(","))

  // SELECT clause
  let selectClause: parser<array<modality>> = {
    bind(keyword("SELECT"), _ => modalityList)
  }

  // Drift policy
  let driftPolicy: parser<driftPolicy> = {
    let strict = map(keyword("STRICT"), _ => Strict)
    let repair = map(keyword("REPAIR"), _ => Repair)
    let tolerate = map(keyword("TOLERATE"), _ => Tolerate)
    let latest = map(keyword("LATEST"), _ => Latest)

    bind(keyword("WITH"), _ =>
      bind(keyword("DRIFT"), _ =>
        strict <|> repair <|> tolerate <|> latest
      )
    )
  }

  // Source parser
  let source: parser<source> = {
    let hexadSource = {
      bind(keyword("HEXAD"), _ =>
        map(uuid, id => Hexad(id))
      )
    }

    let federationSource = {
      bind(keyword("FEDERATION"), _ =>
        bind(identifier, pattern =>
          map(optional(driftPolicy), drift =>
            Federation(pattern, drift)
          )
        )
      )
    }

    let storeSource = {
      bind(keyword("STORE"), _ =>
        map(identifier, id => Store(id))
      )
    }

    hexadSource <|> federationSource <|> storeSource
  }

  // FROM clause
  let fromClause: parser<source> = {
    bind(keyword("FROM"), _ => source)
  }

  // Operators
  let operator: parser<operator> = {
    let eq = map(keyword("=="), _ => Eq)
    let neq = map(keyword("!="), _ => Neq)
    let gte = map(keyword(">="), _ => Gte)
    let lte = map(keyword("<="), _ => Lte)
    let gt = map(keyword(">"), _ => Gt)
    let lt = map(keyword("<"), _ => Lt)
    let like = map(keyword("LIKE"), _ => Like)
    let contains = map(keyword("CONTAINS"), _ => Contains)
    let matches = map(keyword("MATCHES"), _ => Matches)

    eq <|> neq <|> gte <|> lte <|> gt <|> lt <|> like <|> contains <|> matches
  }

  // Literals
  let rec literal: parser<literal> = {
    input => {
      let stringLit = map(stringLiteral, s => String(s))
      let intLit = map(integer, i => Int(i))
      let floatLit = map(float, f => Float(f))
      let boolLit = {
        let t = map(keyword("true"), _ => Bool(true))
        let f = map(keyword("false"), _ => Bool(false))
        t <|> f
      }

      let arrayLit = {
        bind(keyword("["), _ =>
          bind(sepBy(literal, keyword(",")), values =>
            map(keyword("]"), _ => Array(values))
          )
        )
      }

      let p = arrayLit <|> floatLit <|> intLit <|> stringLit <|> boolLit
      p(input)
    }
  }

  // Simple conditions
  let simpleCondition: parser<simpleCondition> = {
    let fulltextContains = {
      bind(keyword("FULLTEXT"), _ =>
        bind(keyword("CONTAINS"), _ =>
          map(stringLiteral, text => FulltextContains(text))
        )
      )
    }

    let fulltextMatches = {
      bind(keyword("FULLTEXT"), _ =>
        bind(keyword("MATCHES"), _ =>
          map(stringLiteral, pattern => FulltextMatches(pattern))
        )
      )
    }

    let fieldCondition = {
      bind(keyword("FIELD"), _ =>
        bind(identifier, field =>
          bind(operator, op =>
            map(literal, value => FieldCondition(field, op, value))
          )
        )
      )
    }

    let vectorSimilar = {
      bind(identifier, _field =>
        bind(keyword("SIMILAR"), _ =>
          bind(keyword("TO"), _ =>
            bind(literal, embedding =>
              map(optional(bind(keyword("WITHIN"), _ => float)), threshold => {
                // Extract floats from array literal
                let floats = switch embedding {
                | Array(arr) => arr->Js.Array2.map(lit =>
                    switch lit {
                    | Float(f) => f
                    | Int(i) => Belt.Int.toFloat(i)
                    | _ => 0.0
                    }
                  )
                | _ => []
                }
                VectorSimilar(floats, threshold)
              })
            )
          )
        )
      )
    }

    let graphPattern = {
      // Simplified: just capture the pattern as string for now
      map(stringLiteral, pattern => GraphPattern(pattern))
    }

    fulltextContains <|> fulltextMatches <|> fieldCondition <|> vectorSimilar <|> graphPattern
  }

  // Compound conditions
  let rec condition: parser<condition> = {
    input => {
      let simple = map(simpleCondition, c => Simple(c))

      let andCond = {
        bind(condition, left =>
          bind(keyword("AND"), _ =>
            map(condition, right => And(left, right))
          )
        )
      }

      let orCond = {
        bind(condition, left =>
          bind(keyword("OR"), _ =>
            map(condition, right => Or(left, right))
          )
        )
      }

      let notCond = {
        bind(keyword("NOT"), _ =>
          map(condition, c => Not(c))
        )
      }

      let p = andCond <|> orCond <|> notCond <|> simple
      p(input)
    }
  }

  // WHERE clause
  let whereClause: parser<condition> = {
    bind(keyword("WHERE"), _ => condition)
  }

  // PROOF clause
  let proofType: parser<proofType> = {
    let existence = map(keyword("EXISTENCE"), _ => Existence)
    let citation = map(keyword("CITATION"), _ => Citation)
    let access = map(keyword("ACCESS"), _ => Access)
    let integrity = map(keyword("INTEGRITY"), _ => Integrity)
    let provenance = map(keyword("PROVENANCE"), _ => Provenance)
    let custom = map(keyword("CUSTOM"), _ => Custom)

    existence <|> citation <|> access <|> integrity <|> provenance <|> custom
  }

  let proofSpec: parser<proofSpec> = {
    bind(proofType, pType =>
      bind(keyword("("), _ =>
        bind(identifier, contract =>
          map(keyword(")"), _ => {
            proofType: pType,
            contractName: contract,
          })
        )
      )
    )
  }

  let proofClause: parser<proofSpec> = {
    bind(keyword("PROOF"), _ => proofSpec)
  }

  // LIMIT clause
  let limitClause: parser<int> = {
    bind(keyword("LIMIT"), _ => integer)
  }

  // OFFSET clause
  let offsetClause: parser<int> = {
    bind(keyword("OFFSET"), _ => integer)
  }

  // Full query parser
  let query: parser<query> = {
    input => {
      // Parse in sequence
      let parseQuery = {
        bind(ws, _ =>
          bind(selectClause, modalities =>
            bind(fromClause, src =>
              bind(optional(whereClause), whereCond =>
                bind(optional(proofClause), proof =>
                  bind(optional(limitClause), lim =>
                    map(optional(offsetClause), off => {
                      modalities: modalities,
                      source: src,
                      where: whereCond,
                      proof: proof,
                      limit: lim,
                      offset: off,
                    })
                  )
                )
              )
            )
          )
        )
      }

      parseQuery(input)
    }
  }
}

// ============================================================================
// Public API
// ============================================================================

type parseError = Parser.parseError
type query = AST.query

let parse = (input: string): Result<query, parseError> => {
  switch Grammar.query(input) {
  | Ok((query, _consumed)) => Ok(query)
  | Error(e) => Error(e)
  }
}

let parseSlipstream = (input: string): Result<query, parseError> => {
  // Slipstream path: no proof clause allowed
  switch parse(input) {
  | Ok(query) => {
      if query.proof->Belt.Option.isSome {
        Error({message: "Slipstream queries cannot have PROOF clause", position: 0})
      } else {
        Ok(query)
      }
    }
  | Error(e) => Error(e)
  }
}

let parseDependentType = (input: string): Result<query, parseError> => {
  // Dependent-type path: proof clause required
  switch parse(input) {
  | Ok(query) => {
      if query.proof->Belt.Option.isNone {
        Error({message: "Dependent-type queries require PROOF clause", position: 0})
      } else {
        Ok(query)
      }
    }
  | Error(e) => Error(e)
  }
}

// ============================================================================
// Example Usage
// ============================================================================

/*
// Slipstream query
let slipstreamQuery = `
  SELECT GRAPH, VECTOR
  FROM FEDERATION /universities/*
  WHERE FULLTEXT CONTAINS "machine learning"
  LIMIT 100
`

switch parseSlipstream(slipstreamQuery) {
| Ok(query) => Js.Console.log(query)
| Error(e) => Js.Console.error(e.message)
}

// Dependent-type query
let dependentQuery = `
  SELECT GRAPH, VECTOR
  FROM HEXAD 550e8400-e29b-41d4-a716-446655440000
  WHERE h.embedding SIMILAR TO [0.1, 0.2, 0.3] WITHIN 0.9
    AND FULLTEXT CONTAINS "climate change"
  PROOF CITATION(CitationContract)
  LIMIT 50
`

switch parseDependentType(dependentQuery) {
| Ok(query) => Js.Console.log(query)
| Error(e) => Js.Console.error(e.message)
}
*/
