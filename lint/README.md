<!--
SPDX-FileCopyrightText: 2026 Sergio Bonatto
SPDX-License-Identifier: MIT
-->

# Lint system

The repository uses native command-line tools from the host system. No Node
package manager, JavaScript package manifest, or project-local dependency tree
is required.

Run every check:

```sh
./scripts/lint.sh
```

Run one or more checks:

```sh
./scripts/lint.sh shellcheck shell-format
./scripts/lint.sh clang-tidy cppcheck
```

List all selectors with `./scripts/lint.sh --list`. Missing tools are reported as
failures, and the complete run continues so that one invocation reports every
missing prerequisite and every validation error.

Install the pinned standalone executables locally with:

```sh
./lint/install-tools.sh
```

They are written to `.cache/lint/bin`, which the root Make entry point adds to
its `PATH`. The script verifies the configured SHA-256 digest of every download.
The current inventory targets Linux x86-64; other platforms should provide the
same executable names through their package manager.

`clang-tidy` consumes the generated `compile_commands.json`. Generate it from
the preprocessing and compilation flags in the Make fragments with:

```sh
make compile-commands
```

The `clang-format` configuration enforces the project style across every C/H
file under `core/`, `tests/`, and `tools/packer/`. The vendored Emscripten and
Brotli submodules remain outside the project-owned formatting boundary.

Repository documentation uses the configured Markdown rule set. Existing
published posts retain their original typography and are checked against a
smaller syntax-safety rule set so linting cannot silently rewrite article
prose.

## Tools

| Selector | Executable | Purpose |
|---|---|---|
| `shellcheck` | `shellcheck` | Shell static analysis |
| `shell-format` | `shfmt` | Shell formatting |
| `yamllint` | `yamllint` | YAML syntax and style |
| `tomllint` | `taplo` | TOML syntax |
| `jsonlint` | `jq` | JSON syntax |
| `markdownlint` | `rumdl` | Markdownlint-compatible Markdown rules |
| `actionlint` | `actionlint` | GitHub Actions semantics |
| `lychee` | `lychee` | Links in Markdown and HTML |
| `typos` | `typos` | Source-code spelling |
| `clang-format` | `clang-format` | C/H formatting contract |
| `clang-tidy` | `clang-tidy` | Clang static analysis |
| `cppcheck` | `cppcheck` | Independent C static analysis |

The lint workflow downloads pinned Linux x86-64 release binaries into the
runner's temporary directory and verifies every SHA-256 digest from
`versions.json`. Nothing is installed globally.
