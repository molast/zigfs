# ZigFS CLI

`zc` is the ZigFS command-line client. This package is intentionally small at
the start so the command parser and executable can evolve independently from
the ZigFS server.

## Build and run

Run the build script to create a native ReleaseSafe executable in this directory.
The script can be invoked from any working directory.

```sh
./build.sh
./zc --help
./zc --version
```

For development and tests:

```sh
zig build
zig build run
zig build install
zig-out/bin/zc --version
zig build test
```

The command design reference is in [`../docs/zigfs-zc-cli-rustfs-reference.md`](../docs/zigfs-zc-cli-rustfs-reference.md).
