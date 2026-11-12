# ZigFS Documentation

Official ZigFS documentation site built with [FumaPress](https://press.fumadocs.dev/) on Waku, React, and Fumadocs. Content is maintained as Markdown/MDX under `content/en` and `content/zh` and is statically generated for CDN hosting.

## Development

Requires Node.js 22+ and pnpm.

```sh
./start.sh dev
```

The development server redirects `/` to the default locale and exposes `/en` and `/zh` entry points. Run `./start.sh` without arguments to choose an action from the interactive menu. The script installs dependencies when needed and supports `dev`, `start`, `build`, and `check` commands.

## Build

```sh
./start.sh build
```

The generated static output is written to `dist/` according to the FumaPress template.
