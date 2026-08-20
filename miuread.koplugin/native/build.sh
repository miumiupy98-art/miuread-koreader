#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/miucodec.cpp"
MAP="$SCRIPT_DIR/miucodec.map"
OUT_DIR="$SCRIPT_DIR/../libs"

CXXFLAGS="-std=c++11 -O2 -shared -fPIC -fvisibility=hidden -DNDEBUG"

# koxtoolchain targets: folder-name:toolchain-prefix
# See https://github.com/koreader/koxtoolchain (gen-tc.sh / refs/x-compile.sh)
TARGETS=(
    "kindle:arm-kindle-linux-gnueabi"
    "kindle5:arm-kindle5-linux-gnueabi"
    "kindlepw2:arm-kindlepw2-linux-gnueabi"
    "kindlehf:arm-kindlehf-linux-gnueabihf"
    "kobo:arm-kobo-linux-gnueabihf"
    "kobov4:arm-kobov4-linux-gnueabihf"
    "kobov5:arm-kobov5-linux-gnueabihf"
    "nickel:arm-nickel-linux-gnueabihf"
    "cervantes:arm-cervantes-linux-gnueabi"
    "remarkable:arm-remarkable-linux-gnueabihf"
    "remarkable-aarch64:aarch64-remarkable-linux-gnu"
    "pocketbook:arm-pocketbook-linux-gnueabi"
    "pocketbookhf:arm-pocketbookhf-linux-gnueabihf"
    "bookeen:arm-bookeen-linux-gnueabi"
)

target_names() {
    local names=(osx linux)
    for pair in "${TARGETS[@]}"; do
        names+=("${pair%%:*}")
    done
    echo "${names[@]}"
}

find_toolchain_gxx() {
    local toolchain="$1"
    for base in "${HOME}/x-tools" "${HOME}/x-tools/x-tools"; do
        local cxx="${base}/${toolchain}/bin/${toolchain}-g++"
        if [ -x "$cxx" ]; then
            echo "$cxx"
            return 0
        fi
    done
    return 1
}

build_target() {
    local name="$1"
    local toolchain="$2"
    local target_dir="$OUT_DIR/$name"
    mkdir -p "$target_dir"

    local cxx=""
    if ! cxx="$(find_toolchain_gxx "$toolchain")"; then
        echo "SKIP $name: ${toolchain}-g++ not found"
        return
    fi

    echo "BUILD $name ($toolchain)"
    "$cxx" $CXXFLAGS \
        -Wl,--version-script="$MAP" \
        -o "$target_dir/libmiucodec.so" \
        "$SRC"
    echo "  -> $target_dir/libmiucodec.so"
}

build_osx() {
    if [ "$(uname -s)" != "Darwin" ]; then
        echo "SKIP osx: requires macOS host"
        return
    fi
    local target_dir="$OUT_DIR/osx"
    mkdir -p "$target_dir"
    echo "BUILD osx ($(uname -m))"
    c++ $CXXFLAGS \
        -o "$target_dir/libmiucodec.dylib" \
        "$SRC"
    echo "  -> $target_dir/libmiucodec.dylib"
}

build_linux() {
    if [ "$(uname -s)" != "Linux" ]; then
        echo "SKIP linux: requires Linux host"
        return
    fi
    local target_dir="$OUT_DIR/linux"
    mkdir -p "$target_dir"
    echo "BUILD linux ($(uname -m))"
    c++ $CXXFLAGS \
        -Wl,--version-script="$MAP" \
        -o "$target_dir/libmiucodec.so" \
        "$SRC"
    echo "  -> $target_dir/libmiucodec.so"
}

build_native() {
    case "$(uname -s)" in
        Darwin) build_osx ;;
        Linux) build_linux ;;
        *) echo "SKIP native: unsupported host OS $(uname -s)" ;;
    esac
}

# ── main ──────────────────────────────────────────────────────────────

case "${1:-all}" in
    osx)
        build_osx
        ;;
    linux)
        build_linux
        ;;
    all)
        build_native
        for pair in "${TARGETS[@]}"; do
            IFS=: read -r name toolchain <<< "$pair"
            build_target "$name" "$toolchain"
        done
        ;;
    -h|--help)
        echo "Usage: $0 [target|all]"
        echo "Targets: $(target_names)"
        ;;
    *)
        case "$1" in
            osx) build_osx; exit 0 ;;
            linux) build_linux; exit 0 ;;
        esac
        for pair in "${TARGETS[@]}"; do
            IFS=: read -r name toolchain <<< "$pair"
            if [ "$name" = "$1" ]; then
                build_target "$name" "$toolchain"
                exit 0
            fi
        done
        echo "Unknown target: $1"
        echo "Available: $(target_names)"
        exit 1
        ;;
esac

echo "Done."
