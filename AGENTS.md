# Repository Guidelines

## Project Structure

- `zigfs/` contains the Zig data plane: S3 and Management APIs, authentication, metadata, object storage, recovery, and garbage collection. Sources are under `zigfs/src/`; Zig tests live beside the modules.
- `zigfs-admin/server/` is the Go + Gin BFF and static host. Go packages and tests are under `zigfs-admin/server/internal/`.
- `zigfs-admin/web/` is the React + TypeScript Admin UI. Features are grouped under `src/features/`, shared UI under `src/components/`, and static assets under `public/`.
- `docs/`, `conformance/`, and `compatibility/` contain API contracts, operational notes, and client validation tools. Brand assets are in `assets/brand/`.

## Build, Test, and Development Commands

Run Zig unit and contract tests with `cd zigfs && zig build test`; build the server with `zig build`. Run the Go BFF checks with `cd zigfs-admin/server && go test ./...`, and start it with `go run ./cmd/admin`. For the web client, run `cd zigfs-admin/web && pnpm install`, `pnpm run dev`, or `pnpm run build` (TypeScript check plus Vite production build). `./start.sh` provides the local service menu; `./docker.sh` manages Docker workflows.

## Coding Style and Naming

Use four-space indentation in Zig and tabs/gofmt formatting in Go. Run `gofmt` on changed Go files. TypeScript uses two-space indentation, single quotes, functional React components, and `PascalCase` component filenames; use `camelCase` for variables and handlers. Keep API types and route names explicit, and reuse existing CSS variables and shared components before adding new visual tokens.

## Admin UI Design Constraint

The entire Admin UI must follow the shadcn/ui component model and visual language. New or modified Admin pages must reuse or extend components under `zigfs-admin/web/src/components/ui/` for buttons, inputs, cards, dialogs, tabs, badges, and similar controls. Do not introduce one-off control styles or browser-native prompts when a shared shadcn/ui component can provide the interaction. Keep shared components accessible, keyboard-friendly, and consistent across light and dark themes; update the shared primitive when a pattern is needed in more than one feature.

## Testing Guidelines

Add Zig tests beside the implementation or in the relevant `zigfs/src` module. Go tests use the standard `*_test.go` convention and should cover handlers, services, and router behavior. Web changes must pass `pnpm run build`; include focused interaction checks for navigation, forms, and API error states when behavior changes.

## Commits and Pull Requests

Use concise Conventional Commit-style subjects such as `feat: add policy management` or `fix: preserve bucket configuration`. Pull requests should describe user-visible behavior, identify affected areas, list validation commands, and include screenshots for Admin UI changes. Call out API or storage-format changes and update the relevant OpenAPI or operational documentation.

## Security and Configuration

ZigFS is the source of truth for identities, permissions, metadata, and storage. Admin must communicate through the BFF and must not read or write the ZigFS data directory directly. Keep credentials and local data outside Git; use the documented `ZIGFS_*` environment variables for local configuration.
