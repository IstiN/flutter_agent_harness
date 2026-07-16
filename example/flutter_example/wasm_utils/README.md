# WASM shell utilities

This directory contains small Rust helpers used to build the WASM binaries that
extend the mobile shell sandbox beyond what is bundled in the main uutils
multicall binary.

## Utilities

| Crate      | Output asset | Purpose                                     |
|------------|--------------|---------------------------------------------|
| `tar_util` | `tar.wasm`   | `tar -cf` and `tar -xf -C`                  |
| `gzip_util`| `gzip.wasm`  | `gzip file` and `gzip -d file.gz`           |
| `zip_util` | `zip.wasm`   | `zip archive.zip files...` and `unzip -d`   |

## External utilities

The following assets are built from third-party projects and are **not**
reproduced here. See the corresponding `LICENSE.*` files in `assets/wasm/`.

| Asset        | Source                                              | License |
|--------------|-----------------------------------------------------|---------|
| `coreutils.wasm` | [uutils/coreutils](https://github.com/uutils/coreutils) | MIT     |
| `rg.wasm`        | [BurntSushi/ripgrep](https://github.com/BurntSushi/ripgrep) | MIT   |
| `find.wasm`      | [uutils/findutils](https://github.com/uutils/findutils)   | MIT     |
| `sed.wasm`       | [uutils/sed](https://github.com/uutils/sed)               | MIT     |
| `awk.wasm`       | [benhoyt/goawk](https://github.com/benhoyt/goawk) compiled with TinyGo | MIT |

## Requirements

- [Rust](https://rustup.rs/) toolchain
- `wasm32-wasip1` target:
  ```bash
  rustup target add wasm32-wasip1
  ```

## Build

From this directory run:

```bash
./build.sh
```

The resulting `.wasm` files are copied to `../assets/wasm/`.

## Usage in the sandbox

`lib/wasm_shell.dart` maps shell commands to the correct module name and
arguments:

- `tar` and `gzip` are invoked directly.
- `unzip` is mapped to the `zip_util` module with `-d` so that both `zip` and
  `unzip` share a single binary.
