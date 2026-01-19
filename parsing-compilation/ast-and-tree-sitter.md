# AST and Tree-sitter

## Overview

**AST (Abstract Syntax Tree)** is a tree representation of code structure that focuses on logical meaning over syntactic details. **Tree-sitter** is a parser generator tool and incremental parsing library that builds syntax trees from source code, designed for real-time editor integration.

---

## Part 1: AST Fundamentals

### What is an AST?

An Abstract Syntax Tree represents code structure as a tree:
- **Root** = The entire file/program
- **Branches** = Statements and expressions
- **Leaves** = Variables, numbers, operators

### Example: `if (x > 0) { return x; }`

```
        if_statement
           /    |      \
         if   condition  consequence
              /    \         |
             x      >    return_statement
                    |          |
                    0          x
```

### Why "Abstract"?

ASTs are abstract because they:
- **Ignore** unimportant details (parentheses, commas, whitespace)
- **Focus** on logical structure
- **Organize** code into meaningful relationships

---

## Part 2: Tree-sitter Architecture

### Two-Component System

```
                    grammar.js (JavaScript DSL)
                            |
                            v
                    tree-sitter CLI (Rust)
                            |
                    +-------+-------+
                    |               |
                    v               v
            Parse Table      Lexical Analysis
            Generation       (NFA/DFA)
                    |               |
                    +-------+-------+
                            |
                            v
                    parser.c (Generated C)
                            |
                    +-------+-------+
                    |               |
                    v               v
            libtree-sitter.a   Language Parser
                    |               |
                    +-------+-------+
                            |
                            v
                      TSTree (AST)
```

### Core Data Structures

```c
// From /lib/include/tree_sitter/api.h
typedef struct TSLanguage TSLanguage;      // Generated parser definition
typedef struct TSParser TSParser;          // Parser instance
typedef struct TSTree TSTree;              // Parse result (syntax tree)
typedef struct TSNode TSNode;              // Tree node
typedef struct TSTreeCursor TSTreeCursor;  // Tree traversal iterator
```

---

## Part 3: GLR Parsing (Advanced)

### Multi-Version Stack Architecture

Tree-sitter uses **Generalized LR (GLR)** parsing to handle ambiguities:

```
Initial State:
┌─────────────────────────────────────────────────────┐
│  Stack Version 0: [S0, S1, S2, S3]                  │
└─────────────────────────────────────────────────────┘
                    │
                    ▼ Ambiguity Encountered
                    │
┌─────────────────────────────────────────────────────┐
│  Stack Version 0: [S0, S1, S2, S3, S4_a]            │  ← Interpretation A
│  Stack Version 1: [S0, S1, S2, S3, S4_b]            │  ← Interpretation B
│  Stack Version 2: [S0, S1, S2, S3, S4_c]            │  ← Interpretation C
└─────────────────────────────────────────────────────┘
```

**Key Constants**:
- `MAX_VERSION_COUNT = 6` - Maximum concurrent stack versions
- `MAX_VERSION_COUNT_OVERFLOW = 4` - Overflow limit

### Parse Actions

```c
typedef union {
  struct {
    uint8_t type;
    TSStateId state;      // Next state for SHIFT
    bool extra;
    bool repetition;      // GLR ambiguity flag
  } shift;
  struct {
    uint8_t type;
    uint8_t child_count;  // Number of children to pop
    TSSymbol symbol;      // Parent symbol to create
    int16_t dynamic_precedence;
    uint16_t production_id;
  } reduce;
} TSParseAction;
```

**SHIFT**: Push lookahead token, transition to new state
**REDUCE**: Pop N items, create parent node, push result

### Version Selection

When multiple versions complete, selection uses:
1. **Non-error preferred** over error versions
2. **Lower error cost** preferred
3. **Higher dynamic precedence** preferred
4. **Fewer nodes** preferred (tie-breaker)

---

## Part 4: Memory Optimization

### Union Representation

Tree-sitter uses a **tagged union** optimizing for small tokens:

```c
typedef union {
  SubtreeInlineData data;     // Inline - stored in pointer value
  const SubtreeHeapData *ptr; // Heap - pointer to allocated memory
} Subtree;
```

**Inline Encoding**: LSB is used as tag (LSB=1 for inline, LSB=0 for heap pointer)

### Inline Node Structure

For small tokens (identifiers, keywords, operators):

```c
struct SubtreeInlineData {
  bool is_inline : 1;
  bool visible : 1;
  bool named : 1;
  bool extra : 1;
  bool has_changes : 1;
  bool is_missing : 1;
  uint8_t symbol;
  uint16_t parse_state;
  // Size fields (1 byte each)
  uint8_t padding_bytes;
  uint8_t size_bytes;
  // ... more fields
};
```

**Inline criteria**:
- padding.bytes < 255
- size.bytes < 255
- padding.rows < 16
- lookahead_bytes < 16

### Heap Node Structure

For parent nodes and large content:

```c
typedef struct {
  volatile uint32_t ref_count;  // Atomic reference counter
  Length padding;
  Length size;
  uint32_t error_cost;
  uint32_t child_count;
  TSSymbol symbol;
  TSStateId parse_state;
  bool visible : 1;
  bool named : 1;
  bool fragile_left : 1;
  bool fragile_right : 1;
  // ... more flags
} SubtreeHeapData;
```

### Reference Counting

**Atomic reference counting** for thread-safe tree sharing:

```c
void ts_subtree_retain(Subtree self) {
  if (self.data.is_inline) return;  // No ref count for inline
  atomic_inc(&self.ptr->ref_count);
}

void ts_subtree_release(SubtreePool *pool, Subtree self) {
  if (self.data.is_inline) return;
  if (atomic_dec(&self.ptr->ref_count) == 0) {
    // Free iteratively using stack (avoid recursion)
  }
}
```

### Memory Pool

```c
#define TS_MAX_TREE_POOL_SIZE 32

typedef struct {
  MutableSubtreeArray free_trees;  // Free list (max 32)
  MutableSubtreeArray tree_stack;   // Temp for operations
} SubtreePool;
```

---

## Part 5: Incremental Parsing

### Reuse Algorithm

Tree-sitter reuses subtrees from previous parse:

```
Old Tree:         Edit:           New Tree:
┌─────────┐                       ┌─────────┐
│  func()  │       + "42"          │  func()  │  ← Reused!
│  /   \   │       →              │  /   \   │
│ 42    +  │                      │ 42    +  │  ← Reused!
│       3  │                      │     *  3 │  ← Reused!
└──────────┘                      │    / \   │
                                  │   42  7  │  ← New!
                                  └──────────┘
```

**Reuse conditions**:
1. No edits within subtree (`has_changes` flag)
2. No error nodes
3. Not fragile (from ambiguous parse)
4. No included range changes
5. First leaf token valid in current state
6. External scanner state matches

### Edit Propagation

```c
void ts_tree_edit(TSTree *self, const TSInputEdit *edit) {
  // Update included ranges
  for (unsigned i = 0; i < self->included_range_count; i++) {
    ts_range_edit(&self->included_ranges[i], edit);
  }

  // Propagate edit through tree
  SubtreePool pool = ts_subtree_pool_new(0);
  self->root = ts_subtree_edit(self->root, edit, &pool);
}
```

**Position adjustment cases**:
1. Edit entirely in padding → Adjust padding
2. Edit spans padding into content → Shrink size, adjust padding
3. Edit within content → Resize content

---

## Part 6: Error Recovery

### Two Strategies

#### Strategy 1: Recover to Previous State

Search backward for state where current lookahead is valid:

```c
for (unsigned i = 0; i < summary->size; i++) {
  StackSummaryEntry entry = *array_get(summary, i);

  if (ts_language_has_actions(self->language, entry.state, lookahead)) {
    ts_parser__recover_to_state(self, version, entry.depth, entry.state);
    // Wrap skipped content in ERROR node
    Subtree error = ts_subtree_new_error_node(&slice.subtrees, ...);
    ts_stack_push(self->stack, version, error, ...);
  }
}
```

#### Strategy 2: Skip Invalid Token

If no valid previous state, skip current token:

```c
unsigned new_cost = current_error_cost +
  ERROR_COST_PER_SKIPPED_TREE +
  ts_subtree_total_bytes(lookahead) * ERROR_COST_PER_SKIPPED_CHAR +
  ts_subtree_total_size(lookahead).extent.row * ERROR_COST_PER_SKIPPED_LINE;

if (!ts_parser__better_version_exists(self, version, false, new_cost)) {
  // Wrap lookahead in ERROR node
  SubtreeArray children = array_new();
  array_push(&children, lookahead);
  Subtree error_repeat = ts_subtree_new_node(
    ts_builtin_sym_error_repeat, &children, 0, self->language
  );
  ts_stack_push(self->stack, version, error_repeat, false, ERROR_STATE);
}
```

### Error Costs

```c
#define ERROR_COST_PER_RECOVERY 500
#define ERROR_COST_PER_MISSING_TREE 110
#define ERROR_COST_PER_SKIPPED_TREE 100
#define ERROR_COST_PER_SKIPPED_LINE 30
#define ERROR_COST_PER_SKIPPED_CHAR 1
```

Costs guide version selection during ambiguous/error parses.

---

## Part 7: Grammar DSL

### Example Grammar

```javascript
module.exports = grammar({
  name: 'my_language',

  extras: $ => [/\s/, $.comment],  // Whitespace and comments

  rules: {
    source_file: $ => repeat($._statement),

    if_statement: $ => seq(
      'if',
      '(',
      field('condition', $.expression),
      ')',
      field('consequence', $.statement),
      optional(field('alternative', $.else_clause))
    ),

    expression: $ => choice(
      $.identifier,
      $.number,
      prec.left(seq($.expression, '+', $.expression))
    ),

    comment: $ => token(seq('//', /.*/))
  }
});
```

### Grammar Functions

- `seq(rule1, rule2, ...)` - Sequence (all must match)
- `choice(rule1, rule2, ...)` - Alternatives (one must match)
- `repeat(rule)` - Zero or more
- `repeat1(rule)` - One or more
- `optional(rule)` - Zero or one
- `prec(number, rule)` - Precedence for conflict resolution
- `prec.left(rule)` - Left-associative
- `prec.right(rule)` - Right-associative
- `field(name, rule)` - Assign field name
- `alias(rule, name)` - Rename in tree
- `token(rule)` - Single token

---

## Part 8: Named vs Anonymous Nodes

### Concrete vs Abstract Trees

Tree-sitter produces **Concrete Syntax Trees (CST)** by default:

```
if_statement (5 children)
  ├── "if"          ← anonymous
  ├── "("           ← anonymous
  ├── expression    ← named
  ├── ")"           ← anonymous
  └── statement     ← named
```

Get **AST-like** behavior by:
- Using only `*_named_*` functions
- Accessing children by field names

### API Examples

```c
// Check if named
bool ts_node_is_named(TSNode node);

// Get named children
TSNode ts_node_named_child(TSNode node, uint32_t index);
uint32_t ts_node_named_child_count(TSNode node);

// Access by field name
TSNode ts_node_child_by_field_name(
  TSNode node,
  const char *field_name,
  uint32_t field_name_length
);
```

---

## Part 9: Parse Table Generation

### LR(1) State Construction

1. Create initial state from start symbol
2. Compute **closure** (add all possible completions)
3. Compute **GOTO** transitions for each symbol
4. Create new states for unseen transitions
5. Repeat until no new states

### Core State Merging

States with identical "cores" (items without lookaheads) are merged, reducing state count by 30-50%.

### Conflict Resolution

**SHIFT/REDUCE conflicts**: Use precedence and associativity
- Higher precedence wins
- If equal, both kept → GLR parsing

**REDUCE/REDUCE conflicts**: Use dynamic precedence, then production ID

### Table Compression

```c
struct TSLanguage {
  const uint16_t *parse_table;              // Full table
  const uint16_t *small_parse_table;        // Compressed
  const uint32_t *small_parse_table_map;    // Index map
  uint32_t large_state_count;
  uint32_t state_count;
};
```

---

## Part 10: Tree Traversal

### Node API

```c
TSNode root = ts_tree_root_node(tree);
uint32_t count = ts_node_child_count(node);
for (uint32_t i = 0; i < count; i++) {
  TSNode child = ts_node_child(node, i);
  const char *type = ts_node_type(child);
  uint32_t start = ts_node_start_byte(child);
  uint32_t end = ts_node_end_byte(child);
}
```

### Tree Cursor API (More Efficient)

```c
TSTreeCursor cursor = ts_tree_cursor_new(root);
if (ts_tree_cursor_goto_first_child(&cursor)) {
  do {
    TSNode node = ts_tree_cursor_current_node(&cursor);
    const char *field_name = ts_tree_cursor_current_field_name(&cursor);
    // Process node
  } while (ts_tree_cursor_goto_next_sibling(&cursor));
}
ts_tree_cursor_delete(&cursor);
```

---

## Key Takeaways

1. **AST** = Tree representation focusing on code structure and meaning
2. **Tree-sitter** = Parser generator + incremental parsing library
3. **GLR parsing** = Handles ambiguity via multi-version stacks
4. **Memory optimization** = Inline nodes, atomic ref counting, pooling
5. **Incremental parsing** = Reuses unchanged subtrees for fast updates
6. **Error recovery** = Cost-based selection, graceful degradation
7. **Grammar DSL** = JavaScript-based language definition
8. **Named nodes** = Meaningful elements; anonymous = punctuation
9. **Field names** = Labels for accessing specific children
10. **Real-time capable** = Designed for editor integration

## Reference: Source Files

| File | Purpose |
|------|---------|
| `/lib/include/tree_sitter/api.h` | Public C API |
| `/lib/src/parser.c` | Core LR/GLR parser |
| `/lib/src/lexer.c` | Lexical analysis |
| `/lib/src/subtree.h` | Internal tree node structure |
| `/lib/src/node.c` | Public node API |
| `/lib/src/tree_cursor.c` | Tree traversal |
| `/crates/generate/src/build_tables.rs` | Parse table generation |
| `/docs/src/creating-parsers/` | Grammar DSL documentation |
