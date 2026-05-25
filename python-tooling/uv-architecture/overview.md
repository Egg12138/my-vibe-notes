# uv — Python Package & Project Manager (Architecture Overview)

## Table of Contents

- [Project Identity](#project-identity)
- [Architecture: Layered Crate Design](#architecture-layered-crate-design)
  - [Binary Entry Points](#binary-entry-points)
  - [CLI & Dispatch Layer](#cli--dispatch-layer)
  - [Core Domain Crates](#core-domain-crates)
  - [Infrastructure & Utility Crates](#infrastructure--utility-crates)
- [Main Subcommands](#main-subcommands)
  - [Project Commands](#project-commands)
  - [Tool Commands (uvx)](#tool-commands-uvx)
  - [Python Management](#python-management)
  - [pip-Compatible Interface](#pip-compatible-interface)
  - [Other Commands](#other-commands)
- [Core Workflow: Command Lifecycle](#core-workflow-command-lifecycle)
- [Key Features](#key-features)
- [Design Decisions](#design-decisions)

## Project Identity

- **What**: A drop-in Rust replacement for pip + pip-tools + virtualenv + poetry + pyenv
- **Repository**: [github.com/astral-sh/uv](https://github.com/astral-sh/uv)
- **Version**: 0.11.16 (as of this note)
- **License**: MIT OR Apache-2.0
- **Language**: Rust (edition 2024, MSRV 1.93.0)

## Architecture: Layered Crate Design

The project is organized as a **Rust workspace** with ~70+ crates under `crates/*`. The architecture follows a layered onion model:

```
┌─────────────────────────────────────────────────────────┐
│                Binary Entry Points                       │
│   uv.rs (main)    uvx.rs (tool run)    uvw.rs (windows) │
└──────────────────────────┬──────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────┐
│           Command Dispatch (crates/uv/src/lib.rs)        │
│                                                          │
│   1. Parse CLI args (clap via uv-cli)                    │
│   2. Set CWD if --project                                │
│   3. Parse PEP 723 scripts if applicable                 │
│   4. Load environment vars                               │
│   5. Discover workspace (uv-workspace)                   │
│   6. Load settings cascade                               │
│   7. Initialize HTTP client & cache                      │
│   8. Dispatch to command handler                         │
└──────────────────────────┬──────────────────────────────┘
                           │
         ┌─────────────────┼─────────────────┐
         ▼                 ▼                  ▼
┌────────────────┐ ┌──────────────┐ ┌──────────────────┐
│   Resolution   │ │ Installation │ │ Package Index    │
│   uv-resolver  │ │ uv-installer │ │ uv-client        │
│   uv-pep440    │ │ uv-install-  │ │ uv-auth          │
│   uv-pep508    │ │   wheel      │ │ uv-keyring       │
│   uv-require-  │ │ uv-virtualenv│ │ uv-publish       │
│   ments        │ │ uv-build-    │ │ uv-pypi-types    │
│   uv-dist-     │ │   frontend   │ │                  │
│   ribution-    │ │ uv-build-    │ │                  │
│   types        │ │   backend    │ │                  │
└────────────────┘ └──────────────┘ └──────────────────┘
```

### Binary Entry Points

| Binary | Location                   | Purpose                         |
| ------ | -------------------------- | ------------------------------- |
| `uv`   | `crates/uv/src/bin/uv.rs`  | Main binary, calls `uv::main()` |
| `uvx`  | `crates/uv/src/bin/uvx.rs` | Alias for `uv tool run`         |
| `uvw`  | `crates/uv/src/bin/uvw.rs` | Windows launcher shim           |

### CLI & Dispatch Layer

- **`uv-cli`**: Clap-based CLI definition (~6200+ lines in `lib.rs`). Defines all `Commands` enums, argument structs, and help text.
- **`crates/uv/src/lib.rs`**: The central `run()` async function that does all bootstrapping and dispatches to command handlers.
- **`crates/uv/src/commands/`**: Implementation of every subcommand, organized by domain.
- **`crates/uv/src/settings.rs`**: Settings resolution — merges CLI args + config files + environment variables.

### Core Domain Crates

**Workspace & Project Model:**

- `uv-workspace` — `Workspace`, `pyproject.toml` parsing, member discovery
- `uv-scripts` — PEP 723 inline script metadata parsing
- `uv-settings` — `uv.toml` configuration model
- `uv-configuration` — Data types for install/link/build options
- `uv-flags` — Environment flags
- `uv-options-metadata` — PEP 621 `[project]` table coercion

**Resolution Engine:**

- `uv-resolver` — Dependency resolution algorithm (SAT-like)
- `uv-pep440` — Version specifiers, sorting, ranges
- `uv-pep508` — Dependency specifier parsing
- `uv-requirements` — Requirements source abstraction
- `uv-requirements-txt` — requirements.txt file parser
- `uv-distribution-types` — Distribution metadata types (name, version, URL, etc.)
- `uv-distribution-filename` — Wheel/sdist filename parsing

**Distribution & Installation:**

- `uv-distribution` — Distribution fetching and building
- `uv-installer` — High-level install orchestration
- `uv-install-wheel` — Wheel unpacking and installation
- `uv-build-frontend` — PEP 517 build frontend
- `uv-build-backend` — PEP 517 build backend (invoked by frontend)
- `uv-extract` — Archive extraction (zip/tar)
- `uv-virtualenv` — Virtual environment creation

**Package Index & Network:**

- `uv-client` — HTTP client (PyPI Simple API, download)
- `uv-auth` — Authentication (login/logout/token management)
- `uv-keyring` — System keyring integration
- `uv-publish` — Package upload to registries
- `uv-pypi-types` — PyPI-specific data types
- `uv-netrc` — .netrc file parsing

**Python Management:**

- `uv-python` — Python discovery, download, installation
- `uv-platform` — Platform detection and properties
- `uv-platform-tags` — Wheel compatibility tagging

**Tool & Utility:**

- `uv-tool` — Tool installation directory management
- `uv-bin-install` — Binary entrypoint linking
- `uv-torch` — PyTorch-specific index handling
- `uv-audit` — Vulnerability database lookup

### Infrastructure & Utility Crates

| Crate                                     | Purpose                                     |
| ----------------------------------------- | ------------------------------------------- |
| `uv-cache`                                | Global cache (HTTP, wheels, git, in-memory) |
| `uv-fs`                                   | Filesystem utilities                        |
| `uv-git` / `uv-git-types`                 | Git cloning and reference management        |
| `uv-state`                                | State directory layout                      |
| `uv-console`                              | Console output (progress bars, spinners)    |
| `uv-shell`                                | Shell activation script generation          |
| `uv-toml`                                 | TOML parsing                                |
| `uv-normalize`                            | String normalization                        |
| `uv-redacted`                             | Redactable strings for safe display         |
| `uv-small-str`                            | Small string optimization                   |
| `uv-once-map`                             | Once-per-key execution tracker              |
| `uv-globfilter`                           | Glob pattern matching                       |
| `uv-macros`                               | Proc macros                                 |
| `uv-version`                              | Version type                                |
| `uv-dirs`                                 | XDG directory paths                         |
| `uv-warnings`                             | Warning infrastructure                      |
| `uv-errors`                               | Error types                                 |
| `uv-logging`                              | Tracing/logging setup                       |
| `uv-fastid`                               | Stable hash ID generation                   |
| `uv-test`                                 | Integration test utilities                  |
| `uv-preview`                              | Preview feature gating                      |
| `uv-trampoline` / `uv-trampoline-builder` | Windows trampoline executables              |
| `uv-unix` / `uv-windows`                  | Platform-specific utilities                 |
| `uv-performance-memory-allocator`         | Custom allocator (mimalloc)                 |

## Main Subcommands

### Project Commands

The primary workflow — all about managing a Python project via `pyproject.toml`:

| Command      | Implementation                | Purpose                                                  |
| ------------ | ----------------------------- | -------------------------------------------------------- |
| `uv init`    | `commands/project/init.rs`    | Bootstrap new project with `pyproject.toml`              |
| `uv add`     | `commands/project/add.rs`     | Add dependency, auto-resolve + lock + sync               |
| `uv remove`  | `commands/project/remove.rs`  | Remove dependency, update lockfile + env                 |
| `uv sync`    | `commands/project/sync.rs`    | Sync `.venv` with lockfile (exact by default)            |
| `uv lock`    | `commands/project/lock.rs`    | Generate/update `uv.lock` without touching env           |
| `uv run`     | `commands/project/run.rs`     | Execute command in project env (supports PEP 723)        |
| `uv export`  | `commands/project/export.rs`  | Export lockfile to requirements.txt / pylock / CycloneDX |
| `uv tree`    | `commands/project/tree.rs`    | Display dependency tree                                  |
| `uv build`   | `commands/build_frontend.rs`  | Build sdist + wheel from source                          |
| `uv version` | `commands/project/version.rs` | Read/update project version                              |
| `uv audit`   | `commands/project/audit.rs`   | Vulnerability audit                                      |
| `uv format`  | `commands/project/format.rs`  | Format Python code                                       |

### Tool Commands (uvx)

Run PyPI packages as CLI tools without permanent installation:

| Command                | Purpose                                |
| ---------------------- | -------------------------------------- |
| `uv tool run` / `uvx`  | Run tool in ephemeral isolated env     |
| `uv tool install`      | Permanently install + link executables |
| `uv tool list`         | Show installed tools                   |
| `uv tool upgrade`      | Upgrade installed tools                |
| `uv tool uninstall`    | Remove tool                            |
| `uv tool update-shell` | Ensure tools dir is on PATH            |
| `uv tool dir`          | Show tools directory                   |

### Python Management

| Command                  | Purpose                                     |
| ------------------------ | ------------------------------------------- |
| `uv python list`         | List available/downloadable Python versions |
| `uv python install`      | Download + install CPython/PyPy             |
| `uv python upgrade`      | Upgrade to latest patch release             |
| `uv python uninstall`    | Remove managed Python                       |
| `uv python find`         | Locate a Python interpreter                 |
| `uv python pin`          | Pin Python version for project              |
| `uv python dir`          | Show Python directory path                  |
| `uv python update-shell` | Update shell for Python path                |

### pip-Compatible Interface

| Command            | pip Equivalent                  |
| ------------------ | ------------------------------- |
| `uv pip compile`   | `pip-compile`                   |
| `uv pip sync`      | N/A (strict sync from lockfile) |
| `uv pip install`   | `pip install`                   |
| `uv pip uninstall` | `pip uninstall`                 |
| `uv pip freeze`    | `pip freeze`                    |
| `uv pip list`      | `pip list`                      |
| `uv pip show`      | `pip show`                      |
| `uv pip tree`      | `pip tree` (via pipdeptree)     |
| `uv pip check`     | `pip check`                     |

### Other Commands

| Command                                | Purpose                                         |
| -------------------------------------- | ----------------------------------------------- |
| `uv venv`                              | Create virtual environment (`.venv` by default) |
| `uv build`                             | Build sdist + wheel                             |
| `uv publish`                           | Upload distributions to index                   |
| `uv cache clean / prune / dir / size`  | Manage global cache                             |
| `uv self update` / `version`           | Update uv itself                                |
| `uv auth login / logout / token / dir` | Registry credential management                  |
| `uv workspace metadata / list / dir`   | Workspace introspection                         |
| `uv help`                              | Command documentation                           |

## Core Workflow: Command Lifecycle

Every `uv` command goes through the same pipeline in `crates/uv/src/lib.rs::run()`:

```
1. Parse CLI args                    (clap from uv-cli)
2. Set CWD if --project              (std::env::set_current_dir)
3. Parse PEP 723 inline metadata     (uv-scripts)
4. Load UV_* environment variables   (EnvironmentOptions)
5. Determine preview features        (uv-preview)
6. Set up logging/tracing            (uv-logging)
7. Determine project directory       (from args or CWD)
8. Discover workspace                (uv-workspace::Workspace::discover)
9. Load configuration cascade        (uv-settings):
   a) --config-file (explicit)
   b) Workspace uv.toml / pyproject.toml
   c) User config (~/.config/uv/uv.toml)
   d) System config (/etc/uv/uv.toml)
10. Resolve Python request           (uv-python)
11. Initialize cache                 (uv-cache)
12. Build HTTP client                (uv-client)
13. Match command + dispatch         (big match on *cli.command)
14. Execute command handler          (commands::*)
15. Return ExitStatus
```

Settings follow a merge pattern: CLI args → filesystem options → env vars, with later sources overriding.

## Key Features

### Performance

- Written in Rust; 10-100x faster than pip/pip-tools
- Aggressive multi-level caching (HTTP → parsed metadata → installed wheels)
- Fully asynchronous (tokio runtime)
- Optional mimalloc allocator

### Modern Standards Compliance

- PEP 517/518/660 — build backend support
- PEP 508 — dependency specifiers
- PEP 440 — version identifiers and ranges
- PEP 723 — inline script metadata (`# /// script`)
- PEP 735 — dependency groups
- PEP 751 — `pylock.toml` export format
- PEP 621 — `[project]` table

### Project Management

- Zero-config workflow: `uv init` + `uv add` + `uv run`
- Automatic `.venv` (no activation needed)
- Universal lockfile (`uv.lock`) — one file across platforms
- Workspace support for monorepos
- Dependency groups (dev/test/docs)
- Per-project Python version pinning

### Tool Execution (`uvx`)

- `npx`-style: `uvx <package>` runs any PyPI tool ephemerally
- Persistent installs with executable linking
- Isolated environments per invocation

### Python Version Management

- Download CPython/PyPy via python-build-standalone
- Debug builds and freethreaded (no-GIL) variants
- Cross-version discovery from PATH, registry (Windows)

### pip Compatibility

- `uv pip install` works with existing requirements.txt workflows
- `uv pip compile` replaces pip-compile
- Adoptable incrementally

### Security

- SHA256 hash verification for all packages
- `uv audit` for vulnerability scanning
- Yanked package warnings
- OIDC / trusted publishing support
- `--break-system-packages` guard

## Design Decisions

- **Async from the ground up**: All I/O is async via tokio for concurrent downloads and resolution
- **No stdlib for wheel install**: `uv-install-wheel` avoids Python's zipfile/tarfile for performance
- **Cancellation-safe**: Cancellation tokens for graceful shutdown
- **Preview features**: New behavior gated behind `--preview`, enabling gradual rollout
- **Single-binary distribution**: Ships as a single static binary with no Python dependency

---

## Deep Dive: Key Data Structures

### Workspace Model (`uv-workspace`)

```
Workspace
├── install_path: PathBuf              (workspace root directory)
├── packages: WorkspaceMembers         (BTreeMap<PackageName, WorkspaceMember>)
├── required_members                   (BTreeMap<PackageName, Editability>)
├── sources                            (BTreeMap<PackageName, Sources>)
├── indexes: Vec<Index>
├── pyproject_toml: PyProjectToml

WorkspaceMember
├── root: PathBuf
├── project: Project                   ([project] table)
├── pyproject_toml: PyProjectToml      (full pyproject.toml)
```

The `VirtualProject` enum wraps either a single-member workspace or specific member. Discovery is done via `Workspace::discover()` which walks up the directory tree looking for `pyproject.toml` with `[tool.uv.workspace]`.

### Resolution Engine (`uv-resolver`)

```
Manifest
├── requirements: Vec<Requirement>     (direct dependencies)
├── constraints: Constraints           (version pins)
├── overrides: Overrides               (forced resolutions)
├── excludes: Excludes                 (excluded packages)
├── preferences: Preferences           (preferred versions from lockfile)
├── project: Option<PackageName>
├── workspace_members: BTreeSet<PackageName>
├── exclusions: Exclusions             (packages to re-resolve)

Resolver<Provider, InstalledPackages>
├── state: ResolverState<InstalledPackages>
│   ├── project: Option<PackageName>
│   ├── requirements: Vec<Requirement>
│   ├── constraints / overrides / excludes / preferences
│   ├── env: ResolverEnvironment       (Specific | Universal)
│   ├── python_requirement: PythonRequirement
│   ├── selector: CandidateSelector
│   ├── index: InMemoryIndex
│   └── dependency_mode: DependencyMode
└── provider: Provider                 (metadata fetching)
```

**`PubGrubPackageInner`** — the fundamental unit the solver reasons about:

```rust
enum PubGrubPackageInner {
    Root(Option<PackageName>),              // singledummy root
    Python(PubGrubPython),                  // Python version constraint
    System(PackageName),                    // non-Python system package
    Package { name, extra, group, marker }, // actual Python package
    Extra { name, extra, marker },          // virtual proxy for extras
    Group { name, group, marker },          // virtual proxy for dep groups
}
```

### Lockfile Model

```
Lock
├── version: LockVersion
├── requires_python: RequiresPython
├── members: Vec<Package>
│   ├── name, version, source
│   ├── dependencies (resolved deps with markers)
│   └── wheels (list of downloadable files)
├── wheels metadata
└── export formats: requirements.txt, pylock.toml, CycloneDX
```

## Deep Dive: Core Function Flows

### `uv sync` — Primary project workflow

```
sync()
├── VirtualProject::discover()          (find pyproject.toml, detect workspace)
├── ProjectEnvironment::get_or_init()   (create .venv if missing)
├── LockOperation::execute()
│   ├── do_lock()
│   │   ├── Manifest::from(target)      (build manifest from workspace)
│   │   ├── Resolver::resolve()         (PubGrub solver)
│   │   │   ├── spawn solver thread     (blocking, CPU-bound)
│   │   │   ├── spawn fetcher async      (IO-bound, parallel)
│   │   │   └── join both via try_join!
│   │   ├── Lock::from_resolution()     (convert to lockfile format)
│   │   └── write lockfile to disk
│   └── return LockResult
├── identify_installation_target()
├── operations::install()
│   ├── download_and_prepare_dists()
│   ├── uninstall_previous()
│   └── install_wheels()
└── write_sync_report()
```

### `uv add` — Dependency insertion

```
add()
├── discover project / script
├── resolve new requirements (parse PEP 508 strings)
├── edit pyproject.toml (PyProjectTomlMut)
│   └── insert into [dependencies] / [optional-dependencies] / [dependency-groups]
├── if !no_sync:
│   ├── LockOperation::execute()
│   │   └── (same as sync flow above)
│   └── operations::install()
└── report changes
```

### `uv run` — Execute in project env

```
run()
├── resolve command / script target
├── VirtualProject::discover()
├── if project: ProjectEnvironment::get_or_init() → auto-sync if stale
├── if script with PEP 723 metadata: ephemeral install to isolated env
├── if no project: use existing .venv or system interpreter
├── build command with environment PATH set to .venv/bin
└── execute via std::process::Command (or exec on Unix)
```

### `uv pip compile` — Pure resolution

```
pip_compile()
├── read requirements.txt / pyproject.toml etc.  (RequirementsSource)
├── build Manifest from requirements + constraints + overrides
├── create Resolver
│   ├── OptionsBuilder::new()
│   │   .resolution_mode()              (highest/lowest)
│   │   .prerelease_mode()              (allow/deny/if-necessary)
│   │   .fork_strategy()                (fewest/requires/python)
│   │   .exclude_newer()                (cutoff date)
│   │   .build()
│   └── Resolver::new(manifest, options, provider)
├── Resolver::resolve()
│   └── (PubGrub algorithm, see below)
└── write output (requirements.txt or pylock.toml)
```

### `uv pip install` — Resolution + installation

```
pip_install()
├── read requirements (from args + files)
├── resolve (same as compile)
├── operations::install()
│   ├── prepare distributions (download, build wheels)
│   ├── uninstall conflicting packages
│   └── link wheels into site-packages
└── post-install checks
```

### `uv pip sync` — Strict sync from lockfile

```
pip_sync()
├── read requirements file
├── operations::install()
│   ├── prepare distributions
│   ├── resolve (if needed)
│   ├── purge extraneous packages
│   └── install exact set
└── report changes
```

### `uv tool run` / `uvx` — Ephemeral tool execution

```
tool_run()
├── parse from / command
├── create ephemeral venv in cache
├── resolve + install package + deps
├── link executable
├── execute with args
└── clean up on exit
```

### `uv python install` — Python version management

```
python_install()
├── determine target version(s)
├── fetch metadata from python-build-standalone
├── download Python distribution archive
├── extract to uv Python directory
├── create minor-version symlinks
└── make discoverable via PATH entry
```

## Deep Dive: The PubGrub Resolution Algorithm

The heart of uv is in `uv-resolver/src/resolver/mod.rs`. The resolver uses the **PubGrub** algorithm (also used by Dart's pub package manager):

```
1. INIT: State::init(Root, MIN_VERSION)
   │  Creates ForkState with initial PubGrub State
   │  Sets up BatchPrefetcher for parallel metadata fetching
   │
2. FORK LOOP: for each forked state
   │
3. UNIT PROPAGATION:
   │  state.pubgrub.unit_propagation(next)
   │  - derives implications from existing incompatibilities
   │  - if conflict: convert_no_solution_err() → nice error message
   │
4. DECISION (pick next package):
   │  partial_solution.pick_highest_priority_pkg()
   │  - uses PubGrubPriorities (tiebreaker ordering)
   │  - batch-prefetches metadata for candidates in parallel
   │
5. VERSION SELECTION:
   │  candidate_selector.select()
   │  - iterates candidates from version map
   │  - filters by: requires-python, platform tags, markers
   │  - prefers versions from lockfile (preferences)
   │  - returns best Candidate or IncompatibleDist
   │
6. ADD DEPENDENCIES:
   │  For selected version, fetch its metadata
   │  → create PubGrubDependency for each transitive dep
   │  → add incompatibilities to PubGrub state
   │
7. LOOP back to step 3 until all packages assigned
   │
8. FORK MERGE:
   │  state.into_resolution()
   │  → ResolutionGraphNode with UniversalMarker edges
   │  → marker_reachability() to annotate which pkgs active where
   │  → push to resolutions vec
   │
9. POST-PROCESS:
   │  merge all fork resolutions into unified ResolverOutput
   │  → universal resolution with marker-conditioned deps
   │  → or single-environment resolution for pip commands
```

**Forking strategy**: When dependencies differ by platform (e.g., `'linux'` vs `'windows'`), uv forks the solver state, solving each environment independently, then merges results into a universal lockfile. This is how `uv.lock` handles cross-platform dependencies.

**Key optimization**: The `BatchPrefetcher` runs asynchronously alongside the solver thread, pre-emptively fetching metadata for packages the solver is likely to visit next, based on priority ordering.

> **Version**: 0.11.16 (commit `9bac00033`) · **Source**: [github.com/astral-sh/uv](https://github.com/astral-sh/uv) · **Date**: 2026-05-25
