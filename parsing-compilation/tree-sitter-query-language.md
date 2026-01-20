# Tree-sitter Query Language

## Overview

Tree-sitter query language is an S-expression-based pattern matching language for querying syntax trees. It enables powerful code analysis features like syntax highlighting, code navigation, refactoring tools, and more.

---

## Table of Contents

- [1. Basic Pattern Syntax](#1-basic-pattern-syntax)
  - [Pattern Structure](#pattern-structure)
- [2. Captures](#2-captures)
- [3. Operators](#3-operators)
  - [Quantifiers](#quantifiers)
  - [Alternatives `[]`](#alternatives-)
  - [Anchors `.`](#anchors-)
  - [Wildcards](#wildcards)
- [4. Predicates (end with `?`)](#4-predicates-end-with-)
  - [Text Comparison](#text-comparison)
  - [Regex Matching](#regex-matching)
  - [Node Properties](#node-properties)
  - [Negation](#negation)
- [5. Directives (end with `!`)](#5-directives-end-with-)
  - [`#set!` - Set Metadata](#set---set-metadata)
  - [`#select-adjacent!` - Filter Adjacent Nodes](#select-adjacent---filter-adjacent-nodes)
  - [`#strip!` - Remove Text from Capture](#strip---remove-text-from-capture)
- [6. Special Nodes](#6-special-nodes)
  - [ERROR Nodes](#error-nodes)
  - [MISSING Nodes](#missing-nodes)
  - [Supertypes](#supertypes)
  - [Negated Fields](#negated-fields)
  - [Anonymous Nodes](#anonymous-nodes)
- [7. Query API](#7-query-api)
  - [Creating Queries](#creating-queries)
  - [Query Information](#query-information)
  - [Executing Queries](#executing-queries)
  - [Iterating Captures](#iterating-captures)
  - [Data Structures](#data-structures)
- [8. Common Patterns](#8-common-patterns)
  - [Syntax Highlighting](#syntax-highlighting)
  - [Code Navigation (ctags-style)](#code-navigation-ctags-style)
  - [Local Variable Tracking](#local-variable-tracking)
  - [Language Injection](#language-injection)
  - [Refactoring Helpers](#refactoring-helpers)
- [9. Implementation Notes](#9-implementation-notes)
  - [Query Processing](#query-processing)
  - [Performance Considerations](#performance-considerations)
  - [Error Handling](#error-handling)
- [10. Syntax Reference](#10-syntax-reference)
- [Key Files Reference](#key-files-reference)

---

## 1. Basic Pattern Syntax

Queries use **S-expressions** (Lisp-like syntax) to match nodes:

```scheme
; Match a binary expression with two numbers
(binary_expression (number_literal) (number_literal))

; Match any call expression
(call_expression)

; Match with field names for specificity
(assignment_expression
  left: (identifier) @variable
  right: (function))
```

### Pattern Structure

- `(node_type)` - Match a node type
- `(node_type (child_type))` - Match node with specific child
- `field_name:` - Match by field name
- `@capture_name` - Capture matched node

---

## 2. Captures

Use `@` prefix to name matched nodes for later use:

```scheme
; Capture the function name
(function_declaration
  name: (identifier) @function.name)

; Multiple captures
(class_declaration
  name: (identifier) @class.name
  body: (class_body
    (method_definition
      name: (property_identifier) @method.name)))

; Capture any node inside call
(call (_) @call.inner)
```

---

## 3. Operators

### Quantifiers

| Operator | Meaning |
|----------|---------|
| `+` | One or more |
| `*` | Zero or more |
| `?` | Optional (zero or one) |

```scheme
; One or more comments
(comment)+

; Zero or more decorators before class
(decorator)* @decorator
(class_declaration)

; Optional catch clause
(try_statement
  body: (_)
  (catch_clause)? @catch)
```

### Alternatives `[]`

Match one of several patterns:

```scheme
; Match identifier or member_expression as function
(call_expression
  function: [
    (identifier) @function
    (member_expression
      property: (property_identifier) @method)
  ])

; Match specific keywords
["break" "continue" "return" "throw"] @keyword

; Match multiple literal types
[
  (string_literal)
  (number_literal)
  (true)
  (false)
] @literal
```

### Anchors `.`

Constrain matching to first/last child position:

```scheme
; Match first identifier in array
(array . (identifier) @first)

; Match last expression in block
(block (_) @last .)

; Match consecutive identifiers
(dotted_name
  (identifier) @prev
  .
  (identifier) @next)
```

### Wildcards

```scheme
(_)            ; Match any named node
_              ; Match any node (including anonymous)
(call (_))     ; Match anything inside a call
```

---

## 4. Predicates (end with `?`)

Predicates filter captures based on conditions.

### Text Comparison

```scheme
; Match identifier with specific text
((identifier) @builtin
  (#eq? @builtin "self"))

; Match multiple possible values
((identifier) @special
  (#any-of? @special "undefined" "null" "NaN" "Infinity"))

; Compare two captures (key and value same)
((pair
  key: (identifier) @key
  value: (identifier) @val)
  (#eq? @key @val))
```

### Regex Matching

```scheme
; Match SCREAMING_SNAKE_CASE constants
((identifier) @constant
  (#match? @constant "^[A-Z][A-Z_]+$"))

; Match PascalCase types
((identifier) @type
  (#match? @type "^[A-Z][a-zA-Z0-9]*$"))

; Match documentation comments
((comment) @doc
  (#match? @doc "^///.*"))
```

### Node Properties

```scheme
; Check if node is NOT local
((identifier) @var
  (#is-not? @var local))

; Check if node is named
((identifier) @name
  (#is? @name named))
```

### Negation

```scheme
; Match identifiers NOT matching pattern
((identifier) @var
  (#not-match? @var "^[A-Z_]+$"))

; Text not equal to specific value
((identifier) @name
  (#not-eq? @name "constructor"))
```

---

## 5. Directives (end with `!`)

Directives add metadata or modify capture behavior.

### `#set!` - Set Metadata

```scheme
; Language injection for embedded code
((comment) @injection.content
  (#match? @injection.content "^<!--")
  (#set! injection.language "html"))

; Set capture metadata
((identifier) @definition
  (#set! definition.var.scope "local"))

; Combined with predicates
((comment) @injection.content
  (#match? @injection.content "/[*!/][!*!/]?<?")
  (#set! injection.language "doxygen"))
```

### `#select-adjacent!` - Filter Adjacent Nodes

```scheme
; Select comment immediately before class
((comment) @doc
  .
  (class_declaration) @class
  (#select-adjacent! @doc @class))
```

### `#strip!` - Remove Text from Capture

```scheme
; Remove leading "#" from shell-style comments
((comment) @doc
  (#strip! @doc "^#\\s*"))

; Remove leading/trailing whitespace
((string_literal) @content
  (#strip! @content "^\\s*|\\s*$"))
```

---

## 6. Special Nodes

### ERROR Nodes

Match syntax errors in the tree:

```scheme
(ERROR) @error
(ERROR (_) @error.child)
```

### MISSING Nodes

Match tokens inserted by error recovery:

```scheme
(MISSING ";") @missing-semicolon
(MISSING identifier) @missing-identifier
(MISSING "}") @missing-brace
```

### Supertypes

Match any subtype of a category:

```scheme
; Match any expression type
(expression) @expr

; Match only binary_expression as expression
(expression/binary_expression) @binary

; Match anonymous node as expression
(expression/"()") @empty-parens
```

### Negated Fields

Match nodes **without** a specific field:

```scheme
; Class without type parameters
(class_declaration
  name: (identifier) @name
  !type_parameters)

; Function without body
(function_declaration
  name: (identifier) @name
  !body)
```

### Anonymous Nodes

Match literal tokens/operators with quotes:

```scheme
(binary_expression
  operator: "!="
  right: (null))

; Match specific punctuation
(ternary_expression
  condition: (_)
  "?"
  consequence: (_)
  ":"
  alternative: (_))
```

---

## 7. Query API

### Creating Queries

```c
#include "tree_sitter/api.h"

// Create query from string
uint32_t error_offset;
TSQueryError error_type;
TSQuery *query = ts_query_new(
  language,
  "(call_expression function: (identifier) @name)",
  strlen(source),
  &error_offset,
  &error_type
);

if (error_type != TSQueryErrorNone) {
  printf("Query error at offset %u\n", error_offset);
}
```

### Query Information

```c
// Get pattern and capture counts
uint32_t pattern_count = ts_query_pattern_count(query);
uint32_t capture_count = ts_query_capture_count(query);

// Get capture name
const char *capture_name = ts_query_capture_name_for_id(
  query,
  capture_index,
  &length
);

// Get capture quantifier
TSQuantifier quant = ts_query_capture_quantifier_for_id(
  query,
  pattern_index,
  capture_index
);
```

### Executing Queries

```c
// Create cursor
TSQueryCursor *cursor = ts_query_cursor_new();

// Execute query on tree
ts_query_cursor_exec(cursor, query, root_node);

// Optional: set range for partial tree matching
ts_query_cursor_set_byte_range(cursor, start_byte, end_byte);

// Iterate matches
TSQueryMatch match;
while (ts_query_cursor_next_match(cursor, &match)) {
  for (uint32_t i = 0; i < match.capture_count; i++) {
    TSQueryCapture capture = match.captures[i];
    TSNode node = capture.node;
    uint32_t capture_id = capture.index;

    // Get node text
    uint32_t start = ts_node_start_byte(node);
    uint32_t end = ts_node_end_byte(node);
    const char *text = source + start;
    size_t length = end - start;

    // Process capture
    printf("Capture %d: %.*s\n", capture_id, (int)length, text);
  }
}

// Cleanup
ts_query_cursor_delete(cursor);
ts_query_delete(query);
```

### Iterating Captures

```c
// Alternative: iterate captures in order
TSQueryMatch match;
uint32_t capture_index;
while (ts_query_cursor_next_capture(cursor, &match, &capture_index)) {
  TSQueryCapture capture = match.captures[capture_index];
  // Process capture...
}
```

### Data Structures

```c
// Capture - a single matched node
typedef struct {
  TSNode node;
  uint32_t index;
} TSQueryCapture;

// Match - a pattern match with multiple captures
typedef struct {
  uint32_t id;
  uint16_t pattern_index;
  uint16_t capture_count;
  const TSQueryCapture *captures;
} TSQueryMatch;

// Quantifier enum
typedef enum {
  TSQuantifierZero = 0,
  TSQuantifierZeroOrOne,
  TSQuantifierZeroOrMore,
  TSQuantifierOne,
  TSQuantifierOneOrMore,
} TSQuantifier;
```

---

## 8. Common Patterns

### Syntax Highlighting

```scheme
; Keywords
["if" "else" "for" "while" "return" "function"] @keyword

; Types
(type_identifier) @type
(primitive_type) @type.builtin
(generic_type) @type

; Functions
(function_declaration name: (identifier) @function)
(call_expression function: (identifier) @function.call)

; Literals
(string_literal) @string
(number_literal) @number
(true) @boolean
(false) @boolean

; Comments
(comment) @comment
```

### Code Navigation (ctags-style)

```scheme
; Function definitions
(function_definition
  name: (identifier) @name) @definition.function

; Class definitions
(class_declaration
  name: (identifier) @name) @definition.class

; With documentation
((comment)* @doc
  .
  (class_declaration name: (identifier) @name) @definition.class
  (#select-adjacent! @doc @definition.class)
  (#strip! @doc "^#\\s*"))
```

### Local Variable Tracking

```scheme
; Variable definitions
(assignment_expression
  left: (identifier) @definition.var)

; Function parameters
(function_parameters
  (identifier) @definition.param)

; Variable references
(identifier) @reference

; Scope boundaries
(function_definition) @local.scope
(block) @local.scope
```

### Language Injection

```scheme
; Inject SQL from template strings
((template_string) @injection.content
  (#match? @injection.content ".*SELECT.*FROM.*")
  (#set! injection.language "sql"))

; Inject HTML from JSX
((jsx_element) @injection.content
  (#set! injection.language "html"))

; Inject code from comments
((comment)+ @injection.content
  .
  (import_declaration)
  (#match? @injection.content "^//\\s*include")
  (#set! injection.language "c"))
```

### Refactoring Helpers

```scheme
; Find unused imports
(import_statement
  name: (identifier) @import.name)
(identifier) @import.ref
(#eq? @import.name @import.ref)

; Find console.log statements
(call_expression
  function: (member_expression
    object: (identifier) @_obj
    property: (property_identifier) @_prop)
  (#eq? @_obj "console")
  (#eq? @_prop "log")) @console.log

; Find potentially unsafe code
(call_expression
  function: (identifier) @dangerous
  (#any-of? @dangerous "eval" "exec" "system"))
```

---

## 9. Implementation Notes

### Query Processing

1. **Parsing**: S-expressions parsed into `QueryStep` structures
2. **Analysis**: Patterns analyzed against parse table for optimization
3. **State Machine**: Non-linear state machine with alternatives
4. **Execution**: Depth-first tree traversal with state tracking

### Performance Considerations

- Queries compile to efficient state machines
- Early termination when patterns cannot match
- Capture quantifiers enable batch processing
- Range restrictions limit tree traversal

### Error Handling

```c
typedef enum {
  TSQueryErrorNone = 0,
  TSQueryErrorSyntax,
  TSQueryErrorNodeType,
  TSQueryErrorField,
  TSQueryErrorCapture,
} TSQueryError;
```

---

## 10. Syntax Reference

| Syntax | Meaning |
|--------|---------|
| `(type)` | Match node type |
| `(type (child))` | Match node with child |
| `field:` | Match by field name |
| `@name` | Capture node |
| `+` | One or more |
| `*` | Zero or more |
| `?` | Optional |
| `[a b c]` | Alternatives |
| `.` | Anchor (first/last) |
| `_` | Wildcard |
| `(ERROR)` | Error node |
| `(MISSING x)` | Missing token |
| `!field` | Negated field |
| `#eq?` | Text equal |
| `#match?` | Regex match |
| `#any-of?` | Any of values |
| `#is?` | Property check |
| `#set!` | Set metadata |
| `#strip!` | Strip text |
| `#select-adjacent!` | Filter adjacent |

---

## Key Files Reference

| File | Purpose |
|------|---------|
| `/docs/src/using-parsers/queries/1-syntax.md` | Syntax documentation |
| `/docs/src/using-parsers/queries/2-operators.md` | Operators reference |
| `/docs/src/using-parsers/queries/3-predicates-and-directives.md` | Predicates/directives |
| `/docs/src/using-parsers/queries/4-api.md` | API documentation |
| `/lib/src/query.c` | Query implementation (4,449 lines) |
| `/lib/include/tree_sitter/api.h` | C API header |
| `/lib/binding_web/test/query.test.ts` | Query tests |

---

*Source: tree-sitter v0.26.3*
