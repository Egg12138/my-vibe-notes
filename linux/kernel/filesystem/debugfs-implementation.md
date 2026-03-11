[toc]

# Debugfs Implementation Locations

## Summary

Understanding where debugfs functions are actually implemented in the Linux kernel source tree, and how the `CONFIG_DEBUG_FS` configuration option affects compilation through stub functions.

---

## Core Implementation Files

Debugfs functions declared in `include/linux/debugfs.h` are implemented in **`fs/debugfs/`**:

| File | Key Functions |
|------|---------------|
| **`fs/debugfs/inode.c`** | `debugfs_lookup()`, `debugfs_create_file_full()`, `debugfs_create_file_short()`, `debugfs_create_file_unsafe()`, `debugfs_create_file_size()`, `debugfs_create_dir()`, `debugfs_create_symlink()`, `debugfs_create_automount()`, `debugfs_remove()`, `debugfs_lookup_and_remove()` |
| **`fs/debugfs/file.c`** | `debugfs_file_get()`, `debugfs_file_put()`, `debugfs_get_aux()`, `debugfs_attr_read()`, `debugfs_attr_write()`, `debugfs_attr_write_signed()`, `debugfs_enter_cancellation()`, `debugfs_leave_cancellation()`, plus variable create helpers (`debugfs_create_u8`, `debugfs_create_u32`, `debugfs_create_bool`, `debugfs_create_str`, `debugfs_create_blob`, etc.) |

All implementations are exported via `EXPORT_SYMBOL_GPL()` for module usage.

---

## Conditional Compilation Pattern

### When `CONFIG_DEBUG_FS=y`

Functions are compiled normally from `fs/debugfs/*.c` and exported as real symbols.

### When `CONFIG_DEBUG_FS=n`

The header provides **stub inline functions** (lines 253-467 in `debugfs.h`):

```c
static inline struct dentry *debugfs_create_file(...)
{
    return ERR_PTR(-ENODEV);
}

static inline void debugfs_create_dir(...) { }
```

This allows code using debugfs to compile without `#ifdef` guards everywhere - the stubs provide no-op implementations.

---

## Macro Abstraction

`debugfs_create_file` is not a real function - it's a `_Generic()` macro (lines 125-131):

```c
#define debugfs_create_file(name, mode, parent, data, fops) \
    _Generic(fops, \
         const struct file_operations *: debugfs_create_file_full, \
         const struct debugfs_short_fops *: debugfs_create_file_short, \
         struct file_operations *: debugfs_create_file_full, \
         struct debugfs_short_fops *: debugfs_create_file_short) \
        (name, mode, parent, data, NULL, fops)
```

This dispatches to the appropriate function based on the fops type at compile time.

---

## Key Takeaways

1. **Implementation location**: `fs/debugfs/` directory (primarily `inode.c` and `file.c`)
2. **Export mechanism**: `EXPORT_SYMBOL_GPL()` makes functions available to modules
3. **Stub pattern**: Inline functions return errors when feature is disabled
4. **Type-safe dispatch**: `_Generic()` macro selects correct function based on fops type

---

*Kernel Version: v7.0-rc1 (6de23f8)*
*Generated: 2026-03-11*
