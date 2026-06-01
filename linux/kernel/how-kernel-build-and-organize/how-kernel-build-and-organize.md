# how-kernel-build-and-organize

[toc]

## Summary

This note explains how the Linux kernel is organized and built (Kbuild to vmlinux/modules), and how the init/exit conventions fit into that organization.

## Big Picture: What “Build The Kernel” Produces

Common artifacts and what they mean:

- `vmlinux`: uncompressed ELF kernel image (good for symbols/debugging).
- `arch/<arch>/boot/bzImage` (x86) / `Image` / `zImage`: bootable kernel image formats.
- `System.map`: symbol address map for the final linked image.
- `*.ko`: loadable kernel modules.

The build is roughly:

1. Compile each `.c` to `.o` with consistent flags and generated headers.
2. Link objects into built-in archives (`built-in.a`) per directory.
3. Link final `vmlinux` from top-level built-ins + selected objects.
4. Optionally build and link modules into `.ko` with their own sections/relocations.

## Kernel Source Tree Organization (Mental Model)

A useful way to read the tree:

- `init/`: early boot and core init sequencing.
- `kernel/`: core kernel services (scheduling, workqueues, module loader, etc.).
- `mm/`: memory management.
- `fs/`: filesystems and VFS.
- `drivers/`: most hardware drivers.
- `net/`: networking stack.
- `arch/<arch>/`: architecture-specific code (boot, entry, low-level mmu, etc.).
- `include/`: global headers (APIs, macros, attributes, types).
- `scripts/`: Kbuild machinery, tooling, modpost.

Within most directories, Kbuild enforces a pattern:

- `Makefile` describes what is built-in (`obj-y`) vs module (`obj-m`) and config-gated selections.
- The directory produces a `built-in.a` (for built-in objects) which later contributes to `vmlinux`.

## Kbuild Organization: Built-in vs Module

At a high level:

- Built-in (`obj-y`): ends up linked into `vmlinux` and participates in boot-time initcalls.
- Module (`obj-m`): ends up linked into a `.ko` and is loaded by the module loader at runtime.

Kbuild uses the same source with different compilation modes. One consequence is that the same driver source often must work in both modes.

## Init/Exit: Two Different Axes

It helps to separate two concepts:

1. “How does code get called?” (registration/entry points)
2. “Where is the code placed, and can it be discarded later?” (sections/lifetime)

These map to different macros:

- `module_init()` / `module_exit()` decide entry/registration behavior.
- `__init` / `__exit` decide section placement and lifetime semantics.

### `__init` / `__exit` (Section Placement)

Defined in `include/linux/init.h`:

- `__init` places code in `.init.text`.
- `__exit` places code in `.exit.text`.

Why it matters:

- Built-in kernel: `.init.*` is freed after boot; `__init` code must not be referenced afterwards.
- Modules: module `.init.*` is freed after the module’s init succeeds; `__init` code is “load-time only”.

`__exit` is mainly meaningful for modules that support unload; for built-in code, exit paths are usually irrelevant.

### `module_init()` / `module_exit()` (Entry Point / Registration)

Defined in `include/linux/module.h`, the expansion depends on whether you build as a module (`MODULE` defined) or built-in.

Built-in (not `MODULE`):

- `module_init(fn)` becomes `__initcall(fn)` which registers the function into an initcall section. Boot-time code walks these tables and invokes them.
- `module_exit(fn)` becomes `__exitcall(fn)` (but built-in kernels do not “rmmod” drivers; exit sections may be discarded).

Module (`MODULE` defined):

- `module_init(fn)` creates/exports a fixed symbol `init_module` as an alias to `fn`.
- `module_exit(fn)` creates/exports a fixed symbol `cleanup_module` as an alias to `fn`.

So for modules the loader can always look up `init_module` / `cleanup_module` by name, while your real functions can have any name.

## Where The Kernel Actually Calls Module Init/Exit (Runtime Path)

Runtime load/unload is in `kernel/module/main.c`:

- Load syscall: `sys_init_module()` / `sys_finit_module()`
  - Copies and validates ELF
  - Allocates module memory (core vs init)
  - Resolves symbols and relocations
  - Then calls `do_init_module(mod)`

In `do_init_module(mod)`:

- If `mod->init` is set, it runs `do_one_initcall(mod->init)` (this is the module’s `init_module` symbol, often an alias created by `module_init(fn)`).
- On success, it schedules freeing of the module’s init memory (`.init.*`) and transitions the module to `MODULE_STATE_LIVE`.

Unload syscall: `sys_delete_module()`

- After checks, if `mod->exit` is non-NULL, it calls `mod->exit()` (this is the module’s `cleanup_module` symbol, often an alias created by `module_exit(fn)`).

Practical implication:

- Only marking a function `__init` / `__exit` does not register it as an entry point.
- For a module to load, it needs `init_module` (usually via `module_init()`); for unload, it needs `cleanup_module` (usually via `module_exit()`).

## Common Pitfalls

Common mistakes here are usually about mixing up entry-point registration (module_init/module_exit or init_module/cleanup_module) with section lifetime markers (__init/__exit).

## Do __init/__exit Functions Need to Be static in a .ko?

Short answer: not required when you use module_init/module_exit, but required (non-static) if you directly define init_module/cleanup_module.

- __init/__exit only place code into special sections (.init.text/.exit.text). They do not register entry points and do not control ELF symbol visibility by themselves.
- If you use module_init(my_init): the build (with MODULE defined) creates a global symbol init_module as an alias to my_init. The loader looks up init_module, not my_init. Therefore my_init can safely be static (and commonly is).
- If you do NOT use module_init and instead implement int init_module(void) yourself: it must NOT be static, because the loader expects a globally visible symbol named init_module in the module ELF. Same for cleanup_module if the module is unloadable.

Why people add static in practice (even though it is not required with module_init/module_exit):

- Reduce exported symbol surface: keep internal helpers (including my_init/my_exit) private to the translation unit.
- Avoid name collisions across compilation units and across modules.
- Enable better optimization decisions (the compiler knows the function is not referenced from other units; LTO also benefits).

- Using `__init` without `module_init()`:
  - Built-in: the function won’t be called (not registered in initcall tables).
  - Module: load fails because `init_module` symbol is missing.

- Referencing `__init` code/data after init:
  - Built-in: the memory may be freed after boot.
  - Module: module init section is freed after successful init.

- “Built-in module_exit is a no-op” misunderstanding:
  - The macro expands, but there is typically no real runtime path to call it in a non-modular built-in driver scenario.

## A Minimal Template (Works For Both Built-in And Module)

```c
#include <linux/init.h>
#include <linux/module.h>

static int __init mydrv_init(void)
{
    return 0;
}
module_init(mydrv_init);

static void __exit mydrv_exit(void)
{
}
module_exit(mydrv_exit);

MODULE_LICENSE("GPL");
```

## Footnotes / Pointers For Deeper Reading

- `include/linux/init.h`: section markers (`__init`, `__exit`), initcall machinery.
- `include/linux/module.h`: `module_init`, `module_exit` macros (built-in vs module behavior).
- `kernel/module/main.c`: syscalls `init_module`/`finit_module`/`delete_module`, `load_module()`, `do_init_module()`.

<!--
Linux tree: branch arm-module-lds-unwind-group, commit 4db02a472d88a20203595c97f1d2b81b43c659fb
Generated: 2026-06-02T00:35:36+08:00
-->
