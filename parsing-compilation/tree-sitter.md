# Tree-sitter: Parser & Query System

## Overview

Tree-sitter is a parser generator and incremental parsing library that produces Concrete Syntax Trees (CST) from source code, designed for real-time editor integration. This note covers the full stack: AST fundamentals, tree-sitter's GLR parsing engine, grammar DSL, and its S-expression-based query language.

---

## Table of Contents

- [1. AST Fundamentals](#1-ast-fundamentals)
- [2. Parser Architecture](#2-parser-architecture)
  - [Two-Component System](#two-component-system)
  - [GLR Parsing (Multi-Version Stack)](#glr-parsing-multi-version-stack)
  - [Memory Optimization](#memory-optimization)
  - [Incremental Parsing](#incremental-parsing)
  - [Error Recovery](#error-recovery)
- [3. Grammar DSL](#3-grammar-dsl)
  - [Grammar Functions](#grammar-functions)
  - [Named vs Anonymous Nodes](#named-vs-anonymous-nodes)
  - [Parse Table Generation](#parse-table-generation)
- [4. Query Language](#4-query-language)
  - [Basic Pattern Syntax](#basic-pattern-syntax)
  - [Captures](#captures)
  - [Operators](#operators)
  - [Predicates (`#name?`)](#predicates-name)
  - [Directives (`#name!`)](#directives-name)
  - [Special Nodes](#special-nodes)
- [5. Query API & Common Patterns](#5-query-api--common-patterns)
  - [C API](#c-api)
  - [Common Patterns](#common-patterns)
- [6. Tree Traversal](#6-tree-traversal)
- [Reference](#reference)

---

## 1. AST Fundamentals

An **Abstract Syntax Tree (AST)** represents code structure as a tree: root = file, branches = statements/expressions, leaves = identifiers/literals. ASTs are "abstract" because they omit syntactic noise (parentheses, commas, whitespace).

```
        if_statement
           /    |      \
         if   condition  consequence
              /    \         |
             x      >    return_statement
                    |          |
                    0          x
```

---

## 2. Parser Architecture

### Two-Component System

```
grammar.js (JS DSL) → tree-sitter CLI (Rust) → parser.c (Generated C) → TSTree (AST)
                                                    ↕
                                            libtree-sitter.a
```

**Core types** (`tree_sitter/api.h`):

| Type | Role |
|------|------|
| `TSLanguage` | Generated parser definition |
| `TSParser` | Parser instance (stateful) |
| `TSTree` | Immutable parse result |
| `TSNode` | Tree node (weak reference) |
| `TSTreeCursor` | Efficient traversal iterator |

### GLR Parsing (Multi-Version Stack)

Tree-sitter uses **Generalized LR (GLR)** parsing to handle ambiguous grammars by maintaining multiple concurrent stack versions.

**Max versions**: `MAX_VERSION_COUNT = 6`, overflow limit = 4.

```
Ambiguity → Stack v0: [S0..S4_a]  ← Interpretation A
            Stack v1: [S0..S4_b]  ← Interpretation B
```

**Parse actions** (`TSParseAction` tagged union):
- **SHIFT**: Consume lookahead token, transition to new state
- **REDUCE**: Pop N children, create parent node, push result

**Version selection** (when multiple complete):
1. Non-error > error
2. Lower error cost
3. Higher dynamic precedence
4. Fewer nodes (tie-breaker)

### Memory Optimization

Tree-sitter uses a **tagged union** for nodes: inline storage (LSB=1) for small tokens, heap pointer (LSB=0) for parent nodes.

Inline criteria: padding < 255B, size < 255B, rows < 16, lookahead < 16B.

Heap nodes use **atomic reference counting** for thread-safe tree sharing. A **memory pool** (`SubtreePool`, max 32 entries) caches freed subtrees to reduce allocation.

### Incremental Parsing

After an edit, tree-sitter reuses unchanged subtrees from the previous parse:

**Reuse conditions**: no edits within subtree, no errors, not fragile (from ambiguous parse), no range changes, first leaf valid in current state, external scanner state matches.

The edit is propagated by adjusting positions: padding-only → adjust padding; spans padding→content → shrink size; within content → resize.

### Error Recovery

Two strategies with cost-based selection:

| Strategy | Action | Cost |
|----------|--------|------|
| Recover to previous state | Search backward for valid state, wrap skipped content in ERROR node | 500 per recovery |
| Skip invalid token | Wrap current token in ERROR node, continue | 100 per skip + 1/char + 30/line |

---

## 3. Grammar DSL

Languages are defined in JavaScript:

```javascript
module.exports = grammar({
  name: 'my_language',
  extras: $ => [/\s/, $.comment],
  rules: {
    source_file: $ => repeat($._statement),
    if_statement: $ => seq(
      'if', '(',
      field('condition', $.expression), ')',
      field('consequence', $.statement),
      optional(field('alternative', $.else_clause))
    ),
    expression: $ => choice(
      $.identifier, $.number,
      prec.left(seq($.expression, '+', $.expression))
    ),
  }
});
```

### Grammar Functions

| Function | Meaning |
|----------|---------|
| `seq(a, b, ...)` | All must match in order |
| `choice(a, b)` | One must match |
| `repeat(r)` / `repeat1(r)` | Zero-or-more / one-or-more |
| `optional(r)` | Zero or one |
| `prec(n, r)`, `prec.left(r)`, `prec.right(r)` | Precedence & associativity |
| `field(name, r)` | Label child for access by name |
| `alias(r, name)` | Rename node type in tree |
| `token(r)` | Force single token (no children) |

### Named vs Anonymous Nodes

Tree-sitter produces **CSTs** by default — everything including punctuation is a node. "Named" nodes correspond to grammar rules; "anonymous" nodes are literal strings/keywords.

```
if_statement
  ├── "if"          ← anonymous
  ├── "("           ← anonymous
  ├── expression    ← named
  ├── ")"           ← anonymous
  └── statement     ← named
```

Get AST-like behavior by using `ts_node_named_child()` / `ts_node_child_by_field_name()`.

### Parse Table Generation

1. Create initial LR(1) state from start symbol
2. Compute closure (all possible completions) and GOTO transitions
3. Merge states with identical cores (items without lookaheads) → 30-50% fewer states
4. Resolve SHIFT/REDUCE conflicts by precedence; keep both → GLR if ambiguous
5. Table compression via `small_parse_table` + `small_parse_table_map`

---

## 4. Query Language

Tree-sitter queries use **S-expressions** (Lisp-like syntax) to match nodes in the syntax tree.

### Basic Pattern Syntax

```scheme
(node_type)                                    ; Match a node type
(node_type (child_type))                       ; Node with specific child
(field_name: (type))                           ; Match by field name
(assignment_expression left: (id) @var)        ; Capture matched node as @var
```

Anonymous (literal) nodes are quoted: `"if"`, `"!="`, `";"`.

### Captures

`@name` captures a node for later processing. Multiple captures per pattern are allowed.

```scheme
(function_declaration name: (identifier) @function.name)
(class_declaration name: (identifier) @class.name)
```

### Operators

| Operator | Meaning |
|----------|---------|
| `+` / `*` / `?` | One-or-more / zero-or-more / optional |
| `[a b c]` | Alternatives (match any one pattern) |
| `.` | Anchor: `. (child)` = first child, `(child) .` = last child |
| `_` / `(_)` | Match any node (including anonymous) / any named node |
| `!field` | Negated field: match nodes **without** this field |

```scheme
; Alternatives
["if" "else" "for"] @keyword
; First/last child anchors
(array . (identifier) @first)
(block (_) @last .)
; Negated field
(class_declaration name: (id) @name !type_parameters)
```

### Predicates (`#name?`)

Predicates filter captures by conditions during query execution.

| Predicate | Purpose |
|-----------|---------|
| `(#eq? @a "str")` | Capture text equals value |
| `(#eq? @a @b)` | Two captures have same text |
| `(#any-of? @a "x" "y")` | Capture matches one of values |
| `(#match? @a "^regex$")` | Regex match on capture text |
| `(#is? @a named)` | Check node property (e.g., named/local) |
| `(#not-eq? @a "x")` | Negated equality |
| `(#not-match? @a "^rx$")` | Negated regex |

```scheme
; Match SCREAMING_SNAKE_CASE constants
((identifier) @constant
  (#match? @constant "^[A-Z][A-Z_]+$"))
; Match identifiers NOT matching
((identifier) @var
  (#not-match? @var "^[A-Z_]+$"))
```

### Directives (`#name!`)

Directives add metadata or modify capture behavior, applied during match construction.

| Directive | Purpose |
|-----------|---------|
| `(#set! key "val")` | Set arbitrary metadata key-value |
| `(#strip! @c "^prefix")` | Remove text from capture |
| `(#select-adjacent! @a @b)` | Filter to adjacent (neighbor) matches |

```scheme
; Language injection for embedded code
((comment) @injection.content
  (#match? @injection.content "^<!--")
  (#set! injection.language "html"))

; Strip comment prefix
((comment) @doc
  (#strip! @doc "^#\\s*"))
```

### Special Nodes

| Syntax | Meaning |
|--------|---------|
| `(ERROR)` / `(ERROR (_) @c)` | Match error nodes / their children |
| `(MISSING ";")` | Match tokens inserted by error recovery |
| `(expression)` | Supertypes: match any expression subtype |
| `(ERROR) @e` | Standard capturing of special nodes |

---

## 5. Query API & Common Patterns

### C API

```c
// Create
TSQuery *q = ts_query_new(lang, "(call @f)", len, &err_offset, &err_type);
TSQueryCursor *cursor = ts_query_cursor_new();

// Execute
ts_query_cursor_exec(cursor, query, root_node);
ts_query_cursor_set_byte_range(cursor, start, end);  // partial tree

// Iterate matches
TSQueryMatch match;
while (ts_query_cursor_next_match(cursor, &match)) {
  for (uint32_t i = 0; i < match.capture_count; i++) {
    TSQueryCapture c = match.captures[i];
    // c.node, c.index
  }
}

// Cleanup
ts_query_cursor_delete(cursor);
ts_query_delete(query);
```

Key types:

```c
typedef struct { TSNode node; uint32_t index; } TSQueryCapture;
typedef struct {
  uint32_t id; uint16_t pattern_index, capture_count;
  const TSQueryCapture *captures;
} TSQueryMatch;
```

### Common Patterns

```scheme
; Syntax highlighting
["if" "else" "for" "return"] @keyword
(function_declaration name: (identifier) @function)
(string_literal) @string  (comment) @comment

; Code navigation
(function_definition name: (identifier) @name) @definition.function
(class_declaration name: (identifier) @name) @definition.class

; Local variable tracking
(assignment_expression left: (identifier) @definition.var)
(function_parameters (identifier) @definition.param)
(identifier) @reference
(function_definition) @local.scope

; Unused import detection
(import_statement name: (identifier) @import.name)
(identifier) @import.ref
(#eq? @import.name @import.ref)

; Find dangerous calls
(call_expression function: (identifier) @dangerous
  (#any-of? @dangerous "eval" "exec" "system"))
```

**Performance**: queries compile to efficient state machines; use byte range restrictions to limit traversal on large files.

---

## 6. Tree Traversal

Two APIs — **Node** (simple, allocates children array) and **Cursor** (efficient, stateful iterator):

```c
// Node API
TSNode root = ts_tree_root_node(tree);
uint32_t count = ts_node_child_count(node);
for (uint32_t i = 0; i < count; i++) {
  TSNode child = ts_node_child(node, i);
}

// Cursor API (preferred for traversal)
TSTreeCursor cursor = ts_tree_cursor_new(root);
if (ts_tree_cursor_goto_first_child(&cursor)) {
  do {
    TSNode n = ts_tree_cursor_current_node(&cursor);
    const char *fname = ts_tree_cursor_current_field_name(&cursor);
  } while (ts_tree_cursor_goto_next_sibling(&cursor));
}
ts_tree_cursor_delete(&cursor);
```

---

## Reference

| Source File | Purpose |
|-------------|---------|
| `lib/include/tree_sitter/api.h` | Public C API |
| `lib/src/parser.c` | Core LR/GLR parser |
| `lib/src/subtree.h` | Internal tree node (inline/heap) |
| `lib/src/tree_cursor.c` | Traversal implementation |
| `lib/src/query.c` | Query engine (~4.4K LOC) |
| `crates/generate/src/build_tables.rs` | Parse table generation |
| `docs/src/using-parsers/queries/` | Query syntax docs |

---

*Compacted from: ast-and-tree-sitter.md + tree-sitter-query-language.md*
*Based on: tree-sitter v0.26.3 · 2026-05-15*
