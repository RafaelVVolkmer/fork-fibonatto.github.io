<!--
SPDX-FileCopyrightText: 2026 Sergio Bonatto
SPDX-License-Identifier: MIT
-->

# EHS: Executable Hypermedia System

EHS is a minimalist publishing engine in C. Markdown posts, route metadata, UI
components, and static configuration are embedded into a WebAssembly binary at
build time. The browser receives a self-contained application with no runtime
filesystem, database, or content API.

**Live site:** <https://rafaelvvolkmer.github.io/fork-fibonatto.github.io/>

## Architecture

```text
core + content + assets + site
               |
               v
          make release
               |
               +-- .build/   audited temporary compiler output
               |
               `-- dist/     complete deployable website
```

The compiled application follows an embedded-system model:

- Markdown is serialized into C arrays before compilation.
- Rendering uses a fixed-size static HTML buffer.
- Project runtime sources compiled into WASM do not call `malloc` or `free`.
- They perform no filesystem, database, socket, or content-API I/O.
- Project-authored JavaScript is limited to the browser platform abstraction
  layer for DOM, Canvas, URL, time, and local storage.
- JavaScript, WebAssembly, fonts, and the profile image receive content hashes.

“Executable” describes the application/content model, not a claim that the
deployed website consists of one physical file. Markdown bodies, routes,
labels, and hashed asset paths are materialized at build time and compiled into
the WASM module. The complete browser artifact still contains `index.html`,
Emscripten's minimal JavaScript glue, the WASM module, fonts, images, and
metadata. The browser fetches those immutable static files from the web server,
but the application never fetches content from a runtime backend. Emscripten
and the browser engine may allocate memory internally; the heapless guarantee
applies to the project-owned C runtime.

## Requirements

The host must provide:

- GNU Make
- A C11 host compiler (`cc` by default)
- CMake (used only when the bundled Brotli fallback is needed)
- Terser
- `shasum`
- Git
- Git LFS
- Syft (optional; used to generate the two SBOMs)
- Cosign (optional locally; required and pinned in GitHub Actions)
- ClangFormat, Clang-Tidy, Cppcheck, ShellCheck, yamllint, `jq`, and the
  standalone lint tools pinned in `lint/versions.json`

On Ubuntu or Debian:

```sh
sudo apt-get install \
  build-essential clang-format clang-tidy cmake cppcheck curl git-lfs jq \
  shellcheck yamllint
git lfs install
npm install --global "terser@$(sed -n '1p' .terser-version)"
./lint/install-tools.sh
```

On macOS with Homebrew:

```sh
brew install \
  actionlint cmake cppcheck git-lfs jq llvm lychee rumdl shellcheck shfmt \
  taplo typos yamllint
git lfs install
npm install --global "terser@$(sed -n '1p' .terser-version)"
```

The standalone installer places executables in `.cache/lint/bin`, which the
Makefile automatically adds to the build `PATH`. Its pinned downloads currently
target Linux x86-64. Other platforms can install the equivalent executables
through their package manager.

Emscripten, Binaryen, and the Brotli CLI are optional system dependencies. When
`emcc` or `wasm-opt` is unavailable, Make initializes `tools/emsdk`, installs
the version pinned in `.emscripten-version`, and invokes the repository-local
tools. When `brotli` is unavailable, Make initializes `tools/brotli` and builds
the version pinned in `.brotli-version` with CMake inside
`.cache/toolchains/brotli`. When the system Terser is absent or has another
version, `npm ci` materializes the exact `docker/terser/package-lock.json`
dependency graph inside `.cache/toolchains/terser`.

Each fallback checks its own marker file. If a required submodule is absent or
empty, the corresponding bootstrap runs:

```sh
git submodule update --init --recursive --depth 1 -- tools/<name>
```

Matching system installations are preferred by default. Use
`USE_BUNDLED_EMSDK=1`, `USE_BUNDLED_BROTLI=1`, or `USE_BUNDLED_TERSER=1` to
force a repository-local toolchain.

Clone with the submodules when possible:

```sh
git clone --recurse-submodules https://github.com/RafaelVVolkmer/fork-fibonatto.github.io.git
```

A normal clone also works: the first build initializes any missing submodules
automatically.

Binary images, fonts, office documents, media, archives, and compiled binary
formats are assigned to Git LFS by `.gitattributes`. SVG, Markdown, HTML, and
other diffable text formats remain normal Git objects.

## Release build

```sh
make release
```

This command:

1. Removes all previous project build artifacts.
2. Runs the complete lint suite and records it as `test-linters` evidence.
3. Resolves and validates the Emscripten and Brotli toolchains.
4. Audits every configured compile, link, Emscripten, and `wasm-opt` flag.
5. Builds the host-side Markdown packer with strict warnings.
6. Serializes every post in `content/posts/`.
7. Generates asset paths containing content hashes.
8. Compiles all runtime sources with `-Oz`, LTO, strict diagnostics, and
   WebAssembly-compatible hardening.
9. Runs Binaryen optimization and Terser minification.
10. Assembles and validates the complete website in `dist/`.
11. Generates the sitemap and Brotli sidecar files.
12. Publishes the canonical compilation database in `dist/.metadata/`.
13. Uses local Syft, when available, to generate formatted CycloneDX and SPDX
    JSON inventories.
14. Verifies that the final JavaScript and WebAssembly filename hashes match
    their respective contents, audits the WASM binary with Binaryen and LLVM,
    then runs the reproducibility test.
15. Builds the isolated Compose topology and runs the complete connection,
    security, latency, load-balancing, failover, and bounded-stress suite.
16. Copies the build and passing-test logs into `dist/.metadata`, creates the
    release checksum manifest, and signs it with Cosign when credentials are
    available.

The audit report is written to `.build/audit/release-flags.txt`. A failed flag
stops the release instead of being silently ignored.

`core/sources.sha256` records the expected digest of every project-owned `.c`
and `.h` file, including the packer. Both `make release` and `make audit`
verify this manifest before compiling.

Project-owned C compiles with the supported warning set promoted to errors.
Diagnostics intrinsic to Emscripten's `EM_JS` macro expansion are suppressed
only around those macro declarations. WebAssembly JavaScript imports are
enumerated in `core/wasm-imports.allow`; any undefined symbol outside that
explicit HAL allowlist stops the link.

Other targets:

```sh
make help
make build
make debug
make audit
make audit-sources
make validate
make sbom
make hash-names
make test-binary
make reproducible
make tests
make test-linters
make test-con
make compile-commands
make lint
make clean
make logs-clean
make cache-clean
make sdk
make brotli
make packer release
make packer debug
make sdk-clean
make distclean
make dist-clean
```

`make packer release` and `make packer debug` are routed by the root Makefile
to `tools/packer/Makefile`. They produce independent binaries under
`.build/packer/release/` and `.build/packer/debug/`. The debug profile includes
debug symbols, frame pointers, disabled inlining, automatic-variable
initialization, and sanitizers.

`make build` is the incremental equivalent of the release pipeline. `make
debug` creates an independently audited WebAssembly build in `.build/debug/`
with debug symbols, frame pointers, deterministic path remapping,
ASan/UBSan/LSan/alignment instrumentation, Emscripten assertions, and strict
stack checks. Both profiles reject warnings and unknown or unused flags.
Both also declare the stable bulk-memory, non-trapping float conversion,
sign-extension, multi-value, and reference-types WebAssembly features.

GCC analyzer diagnostics and ELF linker hardening apply to the native packer.
Stack-clash protection, RELRO, CET, `-z` ELF options, GCC-only warnings, and
other flags rejected or ignored by `emcc`/`wasm-ld` are not passed to the WASM
target. Atomics and SIMD are also left disabled because enabling them would
change the browser execution and compatibility contract rather than harden this
application.
`make clean` removes `.build/`, `dist/`, root-level compiler databases, tags,
legacy compiler reports, and previous Make logs, while preserving reusable
caches and locally built toolchains. `make logs-clean` removes only previous
logs; `make cache-clean` removes `.cache/`; `make sdk-clean` removes only
downloads and installed toolchains ignored inside the `tools/emsdk` submodule.
`make distclean` and its `make dist-clean` alias perform all cleanups.

The root `scripts/` directory exposes six modules instead of one file per
operation: `build.sh`, `toolchain.sh`, `release.sh`, `maintenance.sh`,
`runner.sh`, and `lint.sh`. Each module accepts a subcommand—for example,
`toolchain.sh ensure emsdk`, `release.sh validate`, or
`maintenance.sh cache`. The Makefile remains the supported public interface.

Every root Make invocation other than cleanup targets is recorded while its
output is still streamed to the terminal. The requested goals form a profile
such as `make-release`, and the log is stored at:

```text
logs/<profile>/<date>-<time>-<profile>.log
```

Dates and times are UTC ISO 8601 values, for example
`logs/make-release/2026-07-27-16:00:00Z-make-release.log`. Recursive Make
processes belong to the same top-level log and do not create duplicates. A
`clean`, `logs-clean`, `distclean`, or `dist-clean` invocation is intentionally
never logged.

`make sbom` uses the Syft version pinned in `.syft-version` when it is
available on `PATH` (or supplied through `SYFT=/path/to/syft`). If Syft is not
installed, the release prints a warning and continues without SBOMs. A
different installed version also produces a warning. The Pages workflow always
installs the pinned version, so deployed releases always contain both
inventories under `dist/.metadata/`.

After a successful release, the build log and each passing test log from the
same invocation are copied from `logs/` into `dist/.metadata/logs/`. A
`release.sha256` manifest covers the deployed site, SBOMs, and evidence logs.
Cosign signs that manifest with `COSIGN_KEY` when supplied, or keylessly through
GitHub Actions OIDC. Local builds without either identity remain successful and
write a formatted `cosign.status.json` explaining why no signature bundle was
created.

`make tests` first checks that the hexadecimal prefixes in the final
`app.<hash>.js` and `app.<hash>.wasm` names match their respective SHA-256
digests. `make test-binary` then validates the WASM header and structure with
Binaryen, records LLVM object/section/symbol reports, inspects imports, exports,
tables, and memory, and rejects OS/WASI access, growable memory, exported heap
allocators, and release debug/toolchain sections. Finally, the suite treats that
artifact as the reproducibility reference, performs one additional clean
compilation, and compares SHA-256 manifests of the deterministic `dist/` files.
SBOMs are validated but excluded from the comparison because their standards
include per-generation timestamps and identifiers.

`make compile-commands` writes the ignored root-level `compile_commands.json`
from the preprocessing and compilation flags defined by the Makefile. Every
packaged build copies that exact database to
`dist/.metadata/compile_commands.json`.

`make lint` first generates the compilation database required by Clang-Tidy,
then delegates to `scripts/lint.sh`. The lint system uses host-native
executables for ShellCheck, shell formatting, YAML, TOML, JSON, Markdown,
GitHub Actions, links, spelling, Clang formatting/static analysis, and
Cppcheck. It does not use npm, npx, a JavaScript package manifest, or a
project-local Node dependency tree. See `lint/README.md` for individual
selectors and prerequisites.

Build commands can be overridden when tools are installed under different
names:

```sh
make build \
  EMCC=/path/to/emcc \
  WASM_OPT=/path/to/wasm-opt \
  BROTLI=/path/to/brotli
```

To explicitly provision and use the pinned toolchains:

```sh
make sdk
make brotli
make release USE_BUNDLED_EMSDK=1 USE_BUNDLED_BROTLI=1
```

Native ELF and CPU-specific switches such as RELRO, PIE, CET, MTE,
`-fstack-clash-protection`, and host `-march` values are intentionally not
forwarded to WebAssembly. The Makefile instead applies the equivalent controls
available to Emscripten's compiler, runtime settings, `wasm-ld`, and Binaryen.

## Project layout

```text
.
├── core/
│   ├── inc/                Runtime C headers
│   └── src/                Runtime C sources and standalone heart.c
├── content/
│   └── posts/              Markdown source documents
├── assets/
│   ├── fonts/              Canonical, unhashed font files
│   ├── icons/              Canonical icons
│   └── images/             Canonical site and post images
├── site/
│   ├── index.html.tmpl     HTML shell and asset placeholders
│   └── static/             Files copied verbatim to dist/
├── tools/
│   ├── brotli/             Official Google Brotli submodule
│   ├── emsdk/              Pinned Emscripten SDK submodule
│   └── packer/
│       ├── inc/            Packer headers
│       ├── src/            Packer sources
│       └── Makefile        Standalone release/debug build
├── scripts/                Build, audit, packaging, and validation helpers
├── lint/                   Native lint runner, configs, and pinned CI tools
├── logs/                   Ignored per-profile Make invocation logs
├── .github/workflows/      GitHub Pages build and deployment
├── .build/                 Disposable generated headers and intermediates
├── .cache/                 Reusable compiler and toolchain caches
├── dist/                   Final deployable website
└── Makefile                Build entry point
```

`.build/` and `dist/` are generated and intentionally ignored by Git.
`logs/` is generated, ignored, and managed through `make logs-clean`.

The source-integrity manifest covers the runtime sources, host-side packer, and
standalone `heart.c`. The root Makefile selects the runtime translation units
explicitly, delegates `packer.c` to its own Makefile, and does not include
`heart.c` in either target.

## Adding a post

Create a Markdown file directly under `content/posts/`:

```markdown
---
title: "Post title"
date: "2026-07-27"
description: "A short description used by the blog index and metadata."
---

Post body.
```

Then run:

```sh
make build
```

The filename determines the public route. The packer currently converts every
non-ASCII-alphanumeric filename byte to `_`, so renaming an existing post can
break inbound links.

Post images belong in `assets/images/posts/` and should be referenced by their
final public path:

```markdown
![Alternative text](assets/images/posts/example.avif)
```

## Build directories

`.build/` is private build state:

```text
.build/
├── audit/                  Toolchain reports for release and debug flags
├── debug/                  Sanitizer-enabled JavaScript and WebAssembly
├── generated/              Build-generated C headers
├── obj/                    Compiler intermediates
├── packer/                 Host packer release/debug builds
└── sbom/                   Temporary SBOM output
```

It can always be removed safely with `make clean`.

`.cache/` persists across normal clean releases:

```text
.cache/
├── emscripten/             Emscripten compilation cache
└── toolchains/             Repository-local Brotli and tool stamps
```

Use `make cache-clean` or `make distclean` when this state must also be
discarded.

The local `.rumdl_cache/` and `.reuse/` scratch directories are ignored. The
tracked REUSE template copied into releases lives at `site/dist.REUSE.toml`.

`dist/` is the public contract:

```text
dist/
├── .metadata/
│   ├── cosign.status.json
│   ├── compile_commands.json
│   ├── release.cosign.bundle.json  Created when signing is available
│   ├── release.sha256
│   ├── sbom.cyclonedx.json
│   ├── sbom.spdx.json
│   └── logs/
│       ├── build/
│       └── tests/
├── index.html
├── robots.txt
├── sitemap.xml
├── .nojekyll
├── assets/
│   ├── app/
│   ├── fonts/
│   ├── icons/
│   └── images/
├── LICENSES/
│   └── MIT.txt
└── REUSE.toml
```

No source files, object files, or editor caches are copied to `dist/`; the
compilation database is the deliberate metadata exception.

## GitHub Pages

`.github/workflows/pages.yml` checks out both submodules and runs the same
clean, audited release with pinned Terser, Syft, Emscripten, Brotli, runner, and
immutable Action revisions. Cosign is pinned as well, and the build job receives
an OIDC identity to create a keyless signature bundle. Pull requests run the
complete release plus the two-build reproducibility check without deploying.
Pushes to `main` or `develop` upload `dist/` as the Pages artifact and deploy that exact
artifact. The SBOMs are published at
`/.metadata/sbom.cyclonedx.json` and `/.metadata/sbom.spdx.json`.

The canonical public origin is stored in `site/url.txt`. Because `dist/` is the
Pages document root, `dist/sitemap.xml` is published as `/sitemap.xml`; the
local `dist/` directory never appears in the public URL.

In the repository settings, configure **Pages > Build and deployment > Source**
to use **GitHub Actions**.

## Container deployment

The container stack lives entirely under `docker/` and is built through
Compose. Its application image is compiled with the official
`emscripten/emsdk:6.0.4` builder and served by the non-root official
`nginxinc/nginx-unprivileged:1.28.1-alpine-slim` runtime. The default
Emscripten, Alpine, and NGINX references include manifest digests; updating a
base image is therefore an explicit source change.

The final Dockerfile stage is `runtime`, so a target-less build produces the
application rather than the certificate helper:

```sh
docker build --pull --file docker/Dockerfile --tag ehs:local .
```

BuildKit caches apt, apk, npm, and Emscripten downloads. Container-side Terser
and all of its transitive dependencies are frozen by
`docker/terser/package-lock.json`. The verified document root remains owned by
`root:root`, with directories mode `0555` and files mode `0444`; NGINX runs as
`101:101` and can only read it.

The base-image and npm inputs are immutable, but apt and apk still resolve
packages from their live distribution repositories. A bit-for-bit archival
build must additionally use dated snapshot repositories with exact package
versions; the current cache mounts improve rebuild speed, not that last layer of
package immutability.

The default topology contains two identical application instances behind an
edge NGINX. The edge uses least-connections balancing, backend health gates,
automatic retry, a bounded static-response cache, TLS 1.2/1.3, per-client
request and connection limits, short slow-client timeouts, GET-only proxying,
security headers, and an internal-only backend network. Containers run without
Linux capabilities, with `no-new-privileges`, read-only root filesystems,
bounded PIDs, memory and CPU, and explicitly sized `/tmp` filesystems.

Build with reproducible OCI labels:

```sh
VERSION="$(git describe --tags --always)" \
VCS_REF="$(git rev-parse HEAD)" \
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  docker compose -f docker/compose.yml build --pull
```

Start the complete local stack:

```sh
docker compose -f docker/compose.yml up --detach
curl --fail --insecure https://127.0.0.1:8443/healthz
docker compose -f docker/compose.yml ps
```

The one-shot `certgen` service creates a 30-day self-signed localhost
certificate in a named volume; no private key enters the repository or an
image layer. Production deployments must replace that volume with a
certificate managed by the platform or a secret manager, publish the desired
TLS port, and deliberately review digest updates. NGINX rate and connection
limits mitigate application-layer abuse and slow clients, but volumetric DDoS
protection still belongs at the network, CDN, or cloud edge.

The container workflow builds `runtime` and `edge` with Buildx. Main- and develop-branch
images are pushed to GHCR with BuildKit SBOM and `mode=max` provenance
attestations; pull requests build and verify the same targets without
publishing.

Stop the stack with:

```sh
docker compose -f docker/compose.yml down
```

Run the complete local connection and resilience suite with:

```sh
make test-con
```

The test builds and starts an isolated Compose project, exercises only
`127.0.0.1:8080` and `127.0.0.1:8443`, and removes its containers, network, and
certificate volume afterward. It verifies redirects, health bodies, HTTP/2,
TLS 1.3, security headers, content-addressed artifacts, container hardening,
backend-port isolation, corpus-based malformed HTTP and injection probes,
least-connections distribution, failover after stopping each backend, and a
bounded local stress burst that must activate HTTP 429 rate limiting. The
defaults are 120 requests at concurrency 12; local CI may tune them within the
hard safety ceilings with `EHS_TEST_REQUESTS` (40–1000) and
`EHS_TEST_CONCURRENCY` (2–64). It also collects 100 health-request latency
samples independently on ports 8080 and 8443, reports P90/P99, and enforces
default limits of 250/500 ms. Configure these with
`EHS_TEST_LATENCY_SAMPLES` (20–500), `EHS_TEST_P90_MS`, and
`EHS_TEST_P99_MS`. `EHS_TEST_SKIP_BUILD=1` reuses existing local images, and
`EHS_TEST_KEEP_STACK=1` preserves a failed stack for inspection.

The injection check confirms that this static service neither executes the
payloads nor leaks database-style errors; it is not a substitute for a
database-aware scanner because the architecture has no database. Likewise,
the bounded burst tests the NGINX application-layer controls—not volumetric
DDoS capacity, which must be handled upstream.

## Runtime components

- `buffer.c`: fixed-capacity HTML output buffer and escaping.
- `markdown.c`: Markdown parser and article loader.
- `math.c`: LaTeX-to-MathML transpiler.
- `router.c`: hash-based client-side routing.
- `pages.c`: home, blog, article, and error pages.
- `ui.c`: higher-level HTML rendering operations.
- `js_api.c`: browser, DOM, storage, metadata, and canvas bridge.
- `config.c`: themes, labels, text, and shared visual configuration.
- `main.c`: runtime initialization and initial route dispatch.

The generated post index is sorted for display by date and has a separate
slug-sorted index for binary-search lookup.
