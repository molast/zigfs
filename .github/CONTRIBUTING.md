# Contributing to ZigFS

Contributions are welcome: bug reports, documentation, tests, compatibility fixes, performance
improvements, and code changes. Keep discussions respectful, constructive, and focused on the work.
Follow the [Code of Conduct](CODE_OF_CONDUCT.md) in project spaces, and consult the
[accessibility guidelines](ACCESSIBILITY.md) when contributing user-facing changes.

## Before you start

Search existing issues and pull requests, then use the appropriate
[issue form](https://github.com/molast/zigfs/issues/new/choose): bug report, feature request,
performance issue, or S3 compatibility issue. Include reproducible examples and remove credentials
and private data from logs, screenshots, and configuration.

Discuss substantial changes to storage formats, API behavior, dependencies, or architecture in an
issue before starting a large implementation. Explain the use case, expected behavior, alternatives,
and compatibility constraints.

For vulnerabilities, follow the [security policy](SECURITY.md) instead of posting technical details
publicly.

## Repository layout and architecture

| Path | Responsibility |
| --- | --- |
| `zigfs/` | Zig data plane: S3 and Management APIs, authentication, storage, recovery, and GC |
| `pkg/metadata-engine/` | Shared metadata engine, transactions, WAL, and snapshots |
| `zigfs-admin/server/` | Go + Gin BFF and static host |
| `zigfs-admin/web/` | React + TypeScript Admin UI |
| `zigfs-cli/` | ZigFS CLI (`zc`) and its validation tools |
| `docs/` | API contracts, configuration, deployment, and operational documentation |
| `zigfs-docs/` | Documentation site |
| `compatibility/` | External S3 client compatibility checks |
| `conformance/` | SDK and API conformance checks |
| `tools/diagnostics/` | Local memory, sanitizer, and runtime diagnostics |

ZigFS is the source of truth for identities, permissions, metadata, and object data. Admin Web calls
the BFF, which communicates with ZigFS through APIs. Admin must not read or write the ZigFS data
directory directly. File clients and SDKs use the S3/Data API; avoid introducing a second file protocol.

Read the root [repository guidelines](../AGENTS.md) and any directory-specific guidelines before
editing. The Admin UI has [additional guidance](../zigfs-admin/web/AGENTS.md).

## Development setup

Use the toolchain versions documented in the [README](../README.md) and component configuration.
The data-plane server and CLI require Zig 0.17.0. The Admin BFF/gateway require
Go 1.27 or newer; the web UI requires Node.js 24 or a compatible version.
The data-plane build statically links hash-pinned Mbed TLS and does not require Go.
Use the pnpm version declared in `zigfs-admin/web/package.json`. Docker is optional for native development.

Fork and clone the repository, then create a focused branch, such as `fix/metadata-recovery` or
`feat/bucket-policy`. Keep local credentials and data outside Git, and configure services through
the documented `ZIGFS_*` environment variables. Use a dedicated test data directory.

From the repository root, `./start.sh` opens the native service menu; Windows users can use
`start.cmd`. Start ZigFS before starting Admin. The local Admin option does not start ZigFS for you.
Install the web dependencies before starting Admin for the first time:

```sh
cd zigfs-admin/web
pnpm install
```

Use `./docker.sh` for Docker development workflows. See the
[Docker deployment guide](../docs/deployment/docker.md) for published images and Compose deployment.

## Build and validation commands

Run each command block from the repository root in a separate shell, or return to the root between
blocks. Run checks for the components affected by your change.

### ZigFS data plane

```sh
cd zigfs
zig build test
zig build
```

### Admin BFF

```sh
cd zigfs-admin/server
go test ./...
go build ./cmd/admin
```

### Admin Web

```sh
cd zigfs-admin/web
pnpm install
pnpm run build
```

The web build includes TypeScript checking and a Vite production build. For UI behavior changes,
check the affected navigation, forms, and API error states in the browser. Include keyboard access
and light and dark themes when changing shared controls.

### ZigFS CLI

```sh
cd zigfs-cli
zig build test
zig build
```

The CLI uses native Zig HTTP/TLS and requires only Zig to build. See the [CLI guide](../zigfs-cli/README.md) for platform prerequisites
and integration validation instructions.

### Compatibility, conformance, and performance

For changes affecting S3 behavior or SDK contracts, consult the runner prerequisites before using:

```sh
./compatibility/run.sh
./conformance/run.sh
```

See the [compatibility guide](../compatibility/README.md) and
[conformance guide](../conformance/README.md) for supported clients, configuration, and report output.
Use isolated test instances and synthetic data. A skipped or unsupported check is not a passed check.

For performance changes, follow the [benchmark guide](../zigfs/bench/README.md). Record build mode,
hardware, filesystem, configuration, workload, and before/after results. Keep comparison conditions
consistent; Debug and diagnostic builds are not representative production baselines. Validate
correctness and recovery as well as throughput and latency.

## Code style and design

Prioritize readability and maintainability over minimizing lines. Expand compressed code in the
functions or blocks you change while avoiding unrelated formatting churn.

- **Zig:** Use official naming conventions, four-space indentation, and `zig fmt` on modified files.
  Make allocator lifetimes, ownership, cleanup, and error handling explicit.
- **Go:** Use standard naming conventions and run `gofmt` on modified files.
- **TypeScript / TSX:** Use two-space indentation, single quotes, functional React components,
  PascalCase component filenames, and camelCase variables and handlers.
- Keep one statement per line. Expand control flow, multi-step callbacks, nested JSX, and CSS
  declarations into readable blocks. Aim for roughly 100 characters per line where practical.
- Keep functions focused, prefer descriptive names and early returns, and reuse existing helpers
  without adding unnecessary abstractions.
- Explain non-obvious constraints, invariants, and design choices in comments. Document important
  interfaces and their failure behavior.

The entire Admin UI follows the shadcn/ui component model. Reuse or extend components under
`zigfs-admin/web/src/components/ui/` for controls and interactions. Avoid one-off control styles and
browser-native prompts where shared components apply. Preserve accessibility, keyboard behavior,
and consistency across light and dark themes.

## Tests and correctness

Add focused regression coverage for bug fixes and meaningful tests for behavior changes. Zig tests
live beside the relevant modules; Go tests use `*_test.go`. Do not weaken existing checks just to
make a change pass.

Pay particular attention to the following boundaries:

- **S3:** Request validation, status and error codes, headers, signatures, and client compatibility.
- **Storage and metadata:** Data integrity, transaction consistency, partial failures, concurrent
  access, crash recovery, and cleanup.
- **Multipart uploads:** Part validation, completion, abort behavior, and abandoned upload cleanup.
- **Authentication and IAM:** Allowed and denied operations, resource scope, and privilege boundaries.
- **Admin:** API error handling, permissions, navigation, forms, and session behavior.

Run formatters, relevant builds and tests, and `git diff --check` before submitting. Review the diff
for readability, ownership, and error handling. Report commands and actual outcomes; state clearly
which checks were not run and why. Documentation-only changes generally need link and example
verification rather than a full application build.

## Commits and pull requests

Choose the PR template that fits your change:
[bug fix](PULL_REQUEST_TEMPLATE/bugfix.md), [feature](PULL_REQUEST_TEMPLATE/feature.md),
[documentation](PULL_REQUEST_TEMPLATE/documentation.md), or
[performance](PULL_REQUEST_TEMPLATE/performance.md).
GitHub selects these named templates through the `template` query parameter on a PR creation URL,
for example `&template=bugfix.md` when the URL already has a query string, or `?template=bugfix.md`
otherwise. Alternatively, copy the relevant template into the PR description. These templates do
not create an automatic template chooser or a default PR body.

Use concise [Conventional Commit](https://www.conventionalcommits.org/) subjects, for example:

```text
fix(metadata): preserve committed records during recovery
feat(admin): add policy management
docs: clarify Docker deployment
```

Keep commits and pull requests focused. A pull request should explain:

1. The concrete problem and resulting user-visible behavior.
2. The affected components and any design decisions needed to review the change.
3. Related issues and the validation commands actually run, with results.
4. API, configuration, dependency, or storage-format changes and their compatibility implications.
5. Upgrade, rollback, or migration requirements when applicable.

Include screenshots for Admin UI changes. Update the relevant [API contracts](../docs/api/README.md),
OpenAPI documents, configuration references, and operational guidance when behavior changes.
Keep examples reproducible and free of real credentials. For storage-format changes, explicitly
document backup and recovery requirements rather than implying that in-place upgrades are safe.

## License

ZigFS is licensed under [Apache License 2.0](../LICENSE). By submitting a contribution, you agree
that it may be distributed under that license. Preserve applicable copyright and license notices
when adding or adapting third-party code.
