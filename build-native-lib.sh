#!/usr/bin/env bash
#
# build-native-lib.sh — compile a C/C++ source into an Android JNI library.
#
# Produces a .so in app/src/main/jniLibs/<abi>/ so that Gradle packages it into
# the APK automatically. No full NDK is required: Termux's own clang is built
# from the NDK and already targets Android.
#
# Usage:
#   ./build-native-lib.sh src/main/cpp/native-lib.cpp
#   ./build-native-lib.sh native.c --name libmylib --api 24
#   ./build-native-lib.sh native.cpp --out app/src/main/jniLibs --abi arm64-v8a
#   ./build-native-lib.sh native.cpp --no-stl      # C only / no C++ runtime
#
# Options:
#   --name NAME   output library name (default: lib<nonext of source>)
#   --api N       Android API level / minSdk (default: 24)
#   --abi ABI     target ABI (default: arm64-v8a; see NOTE below)
#   --out DIR     jniLibs root (default: app/src/main/jniLibs)
#   --std STD     C++ standard (default: c++17)
#   --no-stl      do not bundle libc++_shared.so
#   -h, --help    this message
#
# NOTE ON ABIs: only arm64-v8a works with Termux's toolchain. Termux's clang
# ships compiler builtins, libunwind and libc++_shared for aarch64-android only;
# armeabi-v7a / x86_64 fail with "unable to find library -lc++_shared" and
# "cannot open .../libclang_rt.builtins.a". For other ABIs, build on a desktop
# NDK and drop the .so into the same jniLibs directory.
#
set -euo pipefail

SRC=""
NAME=""
API=24
ABI=arm64-v8a
OUT="app/src/main/jniLibs"
STD="c++17"
BUNDLE_STL=1

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }
ok() { printf '  ok %s\n' "$*"; }

usage() { awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^#+ ?/,""); print }' "$0"; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --name)   NAME="${2:?--name needs a value}"; shift 2 ;;
    --api)    API="${2:?--api needs a value}"; shift 2 ;;
    --abi)    ABI="${2:?--abi needs a value}"; shift 2 ;;
    --out)    OUT="${2:?--out needs a value}"; shift 2 ;;
    --std)    STD="${2:?--std needs a value}"; shift 2 ;;
    --no-stl) BUNDLE_STL=0; shift ;;
    -h|--help) usage ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *) [ -z "$SRC" ] || die "only one source file is supported"; SRC="$1"; shift ;;
  esac
done

[ -n "$SRC" ] || die "no source file given (try --help)"
[ -f "$SRC" ] || die "source not found: $SRC"
command -v clang++ >/dev/null 2>&1 || die "clang++ not found — run: pkg install clang ndk-sysroot"

# Map the ABI to a clang target triple.
case "$ABI" in
  arm64-v8a)   TRIPLE="aarch64-linux-android${API}" ;;
  armeabi-v7a) TRIPLE="armv7a-linux-androideabi${API}" ;;
  x86_64)      TRIPLE="x86_64-linux-android${API}" ;;
  x86)         TRIPLE="i686-linux-android${API}" ;;
  *)           die "unknown ABI: $ABI" ;;
esac

case "$ABI" in
  arm64-v8a) : ;;
  *) printf 'warn: %s is not supported by Termux toolchain (arm64-v8a only); the link will likely fail\n' "$ABI" >&2 ;;
esac

# Derive the library name from the source basename when not given.
if [ -z "$NAME" ]; then
  base="$(basename "$SRC")"
  NAME="lib${base%.*}"
fi
case "$NAME" in lib*) : ;; *) NAME="lib$NAME" ;; esac

DEST="${OUT}/${ABI}"
mkdir -p "$DEST"

info "Compiling $SRC"
printf '    target: %s\n    output: %s/%s.so\n' "$TRIPLE" "$DEST" "$NAME"

# -fPIC is mandatory for shared objects; -shared produces the JNI library.
clang++ --target="$TRIPLE" -std="$STD" -shared -fPIC \
  -o "${DEST}/${NAME}.so" "$SRC" \
  || die "compile failed (see errors above)"

ok "built ${DEST}/${NAME}.so"

# Termux ships only libc++_shared.so (no static libc++), so any C++ library that
# uses the STL must ship the runtime next to it or it will fail to load.
if [ "$BUNDLE_STL" -eq 1 ] && readelf -d "${DEST}/${NAME}.so" 2>/dev/null | grep -q 'libc++_shared.so'; then
  STL="$PREFIX/lib/libc++_shared.so"
  if [ -f "$STL" ]; then
    cp -f "$STL" "${DEST}/"
    ok "bundled libc++_shared.so (required by this library)"
  else
    printf 'warn: %s missing — install it or the app will fail at runtime\n' "$STL" >&2
  fi
fi

echo
info "Result"
ls -la "$DEST"
echo
printf 'Gradle will package these automatically. Then run:  gradle assembleDebug\n'
