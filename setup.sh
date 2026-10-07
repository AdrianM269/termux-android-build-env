#!/usr/bin/env bash
#
# setup.sh — Install a complete native-Termux Android build environment.
#
# Sets up everything needed to run `gradle assembleDebug` and produce a signed
# APK inside Termux, with NO proot / chroot / rootfs.
#
# Why this exists: Google's official Android SDK build-tools are x86_64 binaries
# and will not execute on aarch64 Android. This script installs the community
# aarch64-patched SDK from AndroidIDEOfficial/androidide-tools instead.
#
# Usage:
#   ./setup.sh                      # install to ~/android-sdk
#   ./setup.sh --sdk-dir ~/sdk      # custom location
#   ./setup.sh --platforms "34 35"  # extra platforms to fetch via sdkmanager
#   ./setup.sh --skip-packages      # assume Termux packages already installed
#   ./setup.sh -y                   # non-interactive (no prompt)
#
set -euo pipefail

# ─────────────────────────────── configuration ────────────────────────────────

SDK_DIR_DEFAULT="${HOME}/android-sdk"
CACHE_DIR_DEFAULT="${HOME}/.cache/termux-android-build"
PLATFORMS_DEFAULT="34"
BUILD_TOOLS_VERSION="34.0.4"

BASE_URL="https://github.com/AndroidIDEOfficial/androidide-tools/releases/download"

# Termux packages required to build. openjdk-21 + gradle are the build engine;
# aapt2/apksigner are useful native fallbacks; the rest are download/extract tools.
TERMUX_PACKAGES="openjdk-21 gradle aapt2 apksigner git wget curl xz-utils unzip tar coreutils"

# Archives: "filename|url|sha256|check_path"
#   check_path is relative to SDK_DIR; if it exists the archive is already
#   extracted and is skipped. This keeps re-runs fast and idempotent.
ARCHIVES=(
  "android-sdk.tar.xz|${BASE_URL}/sdk/android-sdk.tar.xz|253fab4ff1263ebf78bf89245acde98450ddae83d20ce7fa9d369b3f68f62d9e|platforms/android-33"
  "cmdline-tools.tar.xz|${BASE_URL}/sdk/cmdline-tools.tar.xz|aca602848ff3d6044ffa908efd134300d99623327fee06a7886b990b94049bfa|cmdline-tools/latest/bin/sdkmanager"
  "build-tools-${BUILD_TOOLS_VERSION}-aarch64.tar.xz|${BASE_URL}/v${BUILD_TOOLS_VERSION}/build-tools-${BUILD_TOOLS_VERSION}-aarch64.tar.xz|4bbbdeee608ff8d3a2c1534d0a5270305a02b1f200403a536c75ac84c41e52fa|build-tools/${BUILD_TOOLS_VERSION}"
  "platform-tools-${BUILD_TOOLS_VERSION}-aarch64.tar.xz|${BASE_URL}/v${BUILD_TOOLS_VERSION}/platform-tools-${BUILD_TOOLS_VERSION}-aarch64.tar.xz|08b5b5c9899201081586f8f8682882784458ff67e6421cef65b1d6a0da877236|platform-tools/adb"
)

BASHRC_BLOCK_BEGIN="# >>> termux-android-build-env >>>"
BASHRC_BLOCK_END="# <<< termux-android-build-env <<<"

# ─────────────────────────────────── helpers ──────────────────────────────────

if [ -t 1 ]; then
  C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YLW=$'\033[0;33m'
  C_BLU=$'\033[0;34m'; C_DIM=$'\033[2m';  C_RST=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YLW=''; C_BLU=''; C_DIM=''; C_RST=''
fi

info() { printf '%s==>%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_GRN" "$C_RST" "$*"; }
skip() { printf '%s skip%s %s\n' "$C_DIM" "$C_RST" "$*"; }
warn() { printf '%swarn%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
die()  { printf '%sFAIL%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# ─────────────────────────────── argument parsing ─────────────────────────────

SDK_DIR="$SDK_DIR_DEFAULT"
CACHE_DIR="$CACHE_DIR_DEFAULT"
PLATFORMS="$PLATFORMS_DEFAULT"
DO_PACKAGES=1
ASSUME_YES=0

usage() {
  sed -n '2,20p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --sdk-dir)       SDK_DIR="${2:?--sdk-dir needs a path}"; shift 2 ;;
    --cache-dir)     CACHE_DIR="${2:?--cache-dir needs a path}"; shift 2 ;;
    --platforms)     PLATFORMS="${2-}"; shift 2 ;;
    --skip-packages) DO_PACKAGES=0; shift ;;
    -y|--yes)        ASSUME_YES=1; shift ;;
    -h|--help)       usage ;;
    *) die "unknown option: $1  (try --help)" ;;
  esac
done

SDK_DIR="${SDK_DIR/#\~/$HOME}"
CACHE_DIR="${CACHE_DIR/#\~/$HOME}"

# ──────────────────────────────── preflight ───────────────────────────────────

info "Preflight checks"

[ -n "${PREFIX:-}" ] && [ -d "${PREFIX:-}" ] \
  || die "This does not look like Termux (\$PREFIX unset). Run inside Termux."

case "$(uname -m)" in
  aarch64|arm64) ARCH_OK=1 ;;
  armv7l|armv8l|arm)
    die "32-bit ARM detected. This script ships aarch64 archives; swap the
     '-aarch64' suffixes for '-arm' in ARCHIVES to use 32-bit ARM." ;;
  *) die "Unsupported architecture: $(uname -m) (expected aarch64)" ;;
esac
ok "architecture: $(uname -m)"

if ! curl -sSfIL -o /dev/null --max-time 20 "${BASE_URL}/sdk/android-sdk.tar.xz" 2>/dev/null; then
  warn "could not reach $BASE_URL — downloads may fail"
else
  ok "network: reachable"
fi

mkdir -p "$SDK_DIR" "$CACHE_DIR"
ok "sdk dir:   $SDK_DIR"
ok "cache dir: $CACHE_DIR"

# ─────────────────────────── step 1: Termux packages ──────────────────────────

if [ "$DO_PACKAGES" -eq 1 ]; then
  info "Installing Termux packages"
  if have nala; then
    PKG=nala
  elif have pkg; then
    PKG=pkg
  else
    PKG=apt
  fi
  ok "package manager: $PKG"

  # shellcheck disable=SC2086
  "$PKG" install -y $TERMUX_PACKAGES \
    || die "package installation failed"
  ok "packages installed"
else
  skip "Termux packages (--skip-packages)"
fi

for c in curl xz tar sha256sum; do
  have "$c" || die "required command missing after install: $c"
done

# ─────────────────────────── step 2: download SDK ─────────────────────────────

info "Downloading Android SDK archives"

fetch_verified() {
  # $1=filename $2=url $3=sha256
  local file="$1" url="$2" want="$3"
  local dest="${CACHE_DIR}/${file}"

  if [ -f "$dest" ]; then
    local got
    got="$(sha256sum "$dest" | awk '{print $1}')"
    if [ "$got" = "$want" ]; then
      skip "$file (cached, checksum ok)"
      return 0
    fi
    warn "$file cached but checksum mismatch — re-downloading"
    rm -f "$dest"
  fi

  printf '    %sdownloading%s %s\n' "$C_DIM" "$C_RST" "$file"
  # Show progress on a terminal, suppress the meter when output is redirected.
  local prog=""
  [ -t 2 ] || prog="--no-progress-meter"
  # shellcheck disable=SC2086
  curl -fSL $prog --retry 3 --retry-delay 2 -o "${dest}.part" "$url" \
    || die "download failed: $url"
  mv "${dest}.part" "$dest"

  local got
  got="$(sha256sum "$dest" | awk '{print $1}')"
  if [ "$got" != "$want" ]; then
    rm -f "$dest"
    die "checksum mismatch for $file
     expected: $want
     got:      $got
     Upstream may have changed. Verify before trusting the contents."
  fi
  ok "$file (checksum verified)"
}

for entry in "${ARCHIVES[@]}"; do
  IFS='|' read -r name url sha _target <<<"$entry"
  fetch_verified "$name" "$url" "$sha"
done

# ────────────────────────── step 3: extract into place ────────────────────────

info "Extracting SDK"

# Extract into a staging dir, then merge into SDK_DIR. This flattens the
# 'android-sdk/' wrapper in the archive and makes --sdk-dir work for any path.
STAGE="$(mktemp -d "${CACHE_DIR}/stage.XXXXXX")"
trap 'rm -rf "${STAGE:-}"' EXIT

for entry in "${ARCHIVES[@]}"; do
  IFS='|' read -r name _url _sha check <<<"$entry"
  src="${CACHE_DIR}/${name}"

  if [ -e "${SDK_DIR}/${check}" ]; then
    skip "$name (already extracted)"
    continue
  fi

  printf '    %sextracting%s %s\n' "$C_DIM" "$C_RST" "$name"
  rm -rf "${STAGE:?}"/* 2>/dev/null || true
  tar xf "$src" -C "$STAGE" || die "extraction failed: $name"

  if [ -d "$STAGE/android-sdk" ]; then
    cp -a "$STAGE/android-sdk/." "$SDK_DIR/" || die "merge failed: $name"
  fi
  for d in "$STAGE"/*/; do
    [ -d "$d" ] || continue
    b="$(basename "$d")"
    [ "$b" = "android-sdk" ] && continue
    cp -a "$d" "$SDK_DIR/" || die "merge failed: $b"
  done
done
ok "extracted"

# ─────────────────────── step 4: extra SDK platforms ──────────────────────────

SDKMANAGER="${SDK_DIR}/cmdline-tools/latest/bin/sdkmanager"

if [ -n "$PLATFORMS" ] && [ -x "$SDKMANAGER" ]; then
  info "Installing extra platforms: $PLATFORMS"
  export ANDROID_HOME="$SDK_DIR"
  export ANDROID_USER_HOME="$HOME/.android"
  unset ANDROID_SDK_ROOT || true
  mkdir -p "$ANDROID_USER_HOME"

  # Platforms are architecture-independent, so fetching from Google is safe here.
  for p in $PLATFORMS; do
    if [ -d "${SDK_DIR}/platforms/android-${p}" ]; then
      skip "platforms;android-${p} (already present)"
      continue
    fi
    printf '    %sinstalling%s platforms;android-%s\n' "$C_DIM" "$C_RST" "$p"
    set +o pipefail   # `yes` exits via SIGPIPE when sdkmanager finishes
    yes | "$SDKMANAGER" --sdk_root="$SDK_DIR" "platforms;android-${p}" >/dev/null 2>&1
    set -o pipefail
    if [ -d "${SDK_DIR}/platforms/android-${p}" ]; then
      ok "platforms;android-${p} installed"
    else
      warn "could not install platforms;android-${p} (continuing)"
    fi
  done
  ok "platforms: $(ls "$SDK_DIR/platforms" 2>/dev/null | tr '\n' ' ')"
else
  skip "extra platforms"
fi

# ──────────────────────────── step 5: shell env ───────────────────────────────

info "Configuring shell environment"

BASHRC="$HOME/.bashrc"
touch "$BASHRC"

# Remove any previous block so re-running is idempotent.
if grep -qF "$BASHRC_BLOCK_BEGIN" "$BASHRC"; then
  awk -v b="$BASHRC_BLOCK_BEGIN" -v e="$BASHRC_BLOCK_END" '
    $0==b {inblk=1; next} $0==e {inblk=0; next} !inblk {print}
  ' "$BASHRC" > "${BASHRC}.tmp" && mv "${BASHRC}.tmp" "$BASHRC"
  skip "removed previous env block"
fi

cat >>"$BASHRC" <<EOF
${BASHRC_BLOCK_BEGIN}
export ANDROID_HOME="${SDK_DIR}"
export ANDROID_USER_HOME="\$HOME/.android"
unset ANDROID_SDK_ROOT
export JAVA_HOME="\$PREFIX/lib/jvm/java-21-openjdk"
export PATH="\$PATH:${SDK_DIR}/cmdline-tools/latest/bin:${SDK_DIR}/platform-tools:${SDK_DIR}/build-tools/${BUILD_TOOLS_VERSION}"
${BASHRC_BLOCK_END}
EOF
ok "env block written to $BASHRC"

# ─────────────────────────────── step 6: verify ───────────────────────────────

info "Verifying installation"

export ANDROID_HOME="$SDK_DIR"
export ANDROID_USER_HOME="$HOME/.android"
unset ANDROID_SDK_ROOT || true
BT="${SDK_DIR}/build-tools/${BUILD_TOOLS_VERSION}"
export PATH="$PATH:${SDK_DIR}/cmdline-tools/latest/bin:${SDK_DIR}/platform-tools:${BT}"

FAILED=0
# Deliberately does NOT gate on exit status: some tools exit non-zero for
# harmless invocations (e.g. `zipalign` with no args) and piping to `head` can
# raise SIGPIPE. We verify the binary exists and is runnable instead.
check() {
  local label="$1"; shift
  local path
  path="$(command -v "$1" 2>/dev/null || true)"
  if [ -z "$path" ]; then
    printf '%s  !!%s %-12s NOT FOUND\n' "$C_RED" "$C_RST" "$label"
    FAILED=1
    return
  fi
  local out
  out="$("$@" 2>&1 | grep -m1 . || true)"
  printf '%s  ok%s %-12s %s\n' "$C_GRN" "$C_RST" "$label" "${out:-present}"
}

check_present() {
  local label="$1" path="$2"
  if [ -x "$path" ]; then
    printf '%s  ok%s %-12s %s\n' "$C_GRN" "$C_RST" "$label" "present"
  else
    printf '%s  !!%s %-12s NOT FOUND\n' "$C_RED" "$C_RST" "$label"
    FAILED=1
  fi
}

check aapt2  "$BT/aapt2" version
check zipalign "$BT/zipalign"
check d8     "$BT/d8" --version
check apksigner "$BT/apksigner" version
check adb    "${SDK_DIR}/platform-tools/adb" version
check java   java -version
check_present aidl "$BT/aidl"
printf '%s  ok%s %-12s %s\n' "$C_GRN" "$C_RST" gradle \
  "$(gradle --version 2>/dev/null | grep -m1 -E '^Gradle ' || echo present)"

printf '    %splatforms:%s %s\n' "$C_DIM" "$C_RST" "$(ls "$SDK_DIR/platforms" 2>/dev/null | tr '\n' ' ')"
printf '    %sbuild-tools:%s %s\n' "$C_DIM" "$C_RST" "$(ls "$SDK_DIR/build-tools" 2>/dev/null | tr '\n' ' ')"

# ───────────────────────────────── summary ────────────────────────────────────

echo
if [ "$FAILED" -ne 0 ]; then
  warn "Installation finished but some tools did not verify. Review output above."
  exit 1
fi

printf '%sDone.%s Android build environment is ready.\n\n' "$C_GRN" "$C_RST"
cat <<EOF
  SDK:    $SDK_DIR
  Cache:  $CACHE_DIR   ($(du -sh "$CACHE_DIR" 2>/dev/null | cut -f1) of archives, safe to delete)

  Open a new shell, or run:  source ~/.bashrc
  Then build an app with:    gradle assembleDebug

  Next steps for a project:
    1. local.properties  ->  sdk.dir=$SDK_DIR
    2. settings.gradle.kts must declare google() in pluginManagement:
         pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
       (without this, Gradle cannot find the Android Gradle Plugin)
    3. Keep the project in app-internal storage (~/...), never /sdcard (noexec).

  Verify an APK:  apksigner verify --verbose app/build/outputs/apk/debug/app-debug.apk
EOF
