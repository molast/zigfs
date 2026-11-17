# Repository Guidelines

## Project Structure

- `zigfs/` contains the Zig data plane: S3 and Management APIs, authentication, metadata, object storage, recovery, and garbage collection. Sources are under `zigfs/src/`; Zig tests live beside the modules.
- `zigfs-admin/server/` is the Go + Gin BFF and static host. Go packages and tests are under `zigfs-admin/server/internal/`.
- `zigfs-admin/web/` is the React + TypeScript Admin UI. Features are grouped under `src/features/`, shared UI under `src/components/`, and static assets under `public/`.
- `docs/`, `conformance/`, and `compatibility/` contain API contracts, operational notes, and client validation tools. Brand assets are in `assets/brand/`.

## Build, Test, and Development Commands

Run Zig unit and contract tests with `cd zigfs && zig build test`; build the server with `zig build`. Run the Go BFF checks with `cd zigfs-admin/server && go test ./...`, and start it with `go run ./cmd/admin`. For the web client, run `cd zigfs-admin/web && pnpm install`, `pnpm run dev`, or `pnpm run build` (TypeScript check plus Vite production build). `./start.sh` provides the local service menu; `./docker.sh` manages Docker workflows.

## Coding Style and Readability

Prioritize human readability, maintainability, and clear structure over minimizing lines or typing. These rules apply to all hand-maintained source code, including Zig, Go, TypeScript/TSX, CSS, scripts, and tests. Do not copy compressed formatting merely because nearby code uses it.

### Formatting and Language Conventions

- Zig: follow official formatting and naming conventions, use four-space indentation, and run `zig fmt` on modified Zig files.
- Go: follow standard Go naming conventions and run `gofmt` on modified Go files; use tabs as produced by the formatter.
- TypeScript/TSX: use two-space indentation, single quotes, functional React components, `PascalCase` component filenames, and `camelCase` variables and handlers.
- Follow configured formatters where available. Aim for approximately 100 characters per line, without forcing awkward breaks in URLs, strings, or otherwise readable code.
- Use one statement per line. Expand control-flow blocks, multi-step callbacks, and complex expressions into readable, indented lines.
- Format nested JSX to reveal the component hierarchy. Put nested elements on separate lines and split long prop lists across lines; do not compress entire cards, forms, tables, or component returns onto one line.
- Put CSS declarations on separate lines. Keep script commands and test setup, actions, and assertions readable rather than combining them into dense one-liners.
- Short, straightforward expressions may stay on one line. Generated, vendored, and minified output does not need manual reformatting.

### Structure and Naming

- Keep functions focused on one responsibility. Extract meaningful helpers for complex or repeated logic, without introducing unnecessary abstractions or excessive fragmentation.
- Prefer early returns when they simplify control flow. Avoid deeply nested branches, nested ternaries, and excessively long chains; use named intermediate values or explicit steps instead.
- Separate distinct logical operations with blank lines. Do not combine unrelated operations into one expression.
- Use descriptive variable and function names. Avoid cryptic abbreviations; conventional short names are acceptable in small, obvious scopes.
- Keep API types and route names explicit. Reuse existing CSS variables and shared components before adding new visual tokens.

### Comments and Interfaces

- Explain non-obvious logic, constraints, and design decisions. Avoid comments that merely repeat the code.
- Document public APIs and important interfaces, including assumptions and error behavior where relevant.
- Make memory ownership, allocator lifetimes, cleanup responsibilities, and error handling explicit, especially in Zig. Add comments when these contracts are not apparent from the code.

## Admin UI Design Constraint

The entire Admin UI must follow the shadcn/ui component model and visual language. New or modified Admin pages must reuse or extend components under `zigfs-admin/web/src/components/ui/` for buttons, inputs, cards, dialogs, tabs, badges, and similar controls. Do not introduce one-off control styles or browser-native prompts when a shared shadcn/ui component can provide the interaction. Keep shared components accessible, keyboard-friendly, and consistent across light and dark themes; update the shared primitive when a pattern is needed in more than one feature.

## Testing Guidelines

Add Zig tests beside the implementation or in the relevant `zigfs/src` module. Go tests use the standard `*_test.go` convention and should cover handlers, services, and router behavior. Web changes must pass `pnpm run build`; include focused interaction checks for navigation, forms, and API error states when behavior changes.

Before completing a change, run the appropriate formatters on modified source files and the relevant build and tests. Review the diff for readability, consistency, ownership, and error handling. Expand compressed code in the functions or blocks being changed, while avoiding unrelated formatting churn.

## Commits and Pull Requests

Use concise Conventional Commit-style subjects such as `feat: add policy management` or `fix: preserve bucket configuration`. Pull requests should describe user-visible behavior, identify affected areas, list validation commands, and include screenshots for Admin UI changes. Call out API or storage-format changes and update the relevant OpenAPI or operational documentation.

## Security and Configuration

ZigFS is the source of truth for identities, permissions, metadata, and storage. Admin must communicate through the BFF and must not read or write the ZigFS data directory directly. Keep credentials and local data outside Git; use the documented `ZIGFS_*` environment variables for local configuration.
