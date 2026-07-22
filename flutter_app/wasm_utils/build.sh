#!/bin/bash
set -e

TARGET=wasm32-wasip1
OUT_DIR=../../assets/wasm

build() {
  local crate=$1
  local out_name=$2
  cd "$crate"
  cargo build --release --target "$TARGET"
  cp "target/$TARGET/release/$crate.wasm" "$OUT_DIR/$out_name"
  cd ..
}

build tar_util tar.wasm
build gzip_util gzip.wasm
build zip_util zip.wasm

echo "WASM utilities built into $OUT_DIR"
