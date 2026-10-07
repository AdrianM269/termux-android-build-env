# termux-android-build-env

Install a complete **native-Termux Android build environment** — build real, signed
APKs from Termux with **no proot, no chroot, no rootfs, no root**.

```bash
./setup.sh
```

That's it. You get a working Android SDK, build-tools, platform-tools and `sdkmanager`,
wired into Gradle, and you can run `gradle assembleDebug` on a normal Android project.

---

## Why this exists

Google's official Android SDK ships **x86_64** build-tools binaries. On an aarch64
(arm64) Android device those simply will not execute:

```
cannot execute binary file: Exec format error
```

The usual workaround is to run a whole x86_64/Ubuntu environment under `proot` — slow,
fragile, and a lot of moving parts. It isn't necessary.

[AndroidIDEOfficial/androidide-tools](https://github.com/AndroidIDEOfficial/androidide-tools)
publishes **aarch64-patched, statically-linked** build-tools that run directly in Termux.
This script installs those, and nothing else exotic.

Everything else in the chain is already native to Termux: Gradle, OpenJDK, `aapt2`, `adb`.

---

## Requirements

- **Termux** on an **aarch64 / arm64** Android device
- Internet access for the first run (~180 MB of downloads)
- ~1 GB of free storage

32-bit ARM (`armv7l`) is not enabled by default — see [Other architectures](#other-architectures).

---

## Usage

```bash
./setup.sh                        # install to ~/android-sdk (default)
./setup.sh --sdk-dir ~/sdk        # custom install location
./setup.sh --platforms "34 35"    # also fetch extra SDK platforms
./setup.sh --skip-packages        # assume Termux packages are already installed
./setup.sh -y                     # non-interactive
./setup.sh --help                 # full option list
```

The script is **idempotent** — run it as many times as you like. It skips archives that
are already downloaded (after verifying their checksum) and already extracted.

### What it does

1. **Preflight** — confirms Termux, checks architecture, checks network.
2. **Termux packages** — installs `openjdk-21`, `gradle`, `aapt2`, `apksigner`, `git`,
   `wget`, `curl`, `xz-utils`, `unzip`, `tar`, `coreutils`. Uses `nala` if present,
   otherwise `pkg`, otherwise `apt`.
3. **Download** — fetches four archives and **verifies each against a pinned SHA-256**.
   A mismatch aborts the run rather than installing unverified bytes.
4. **Extract** — merges them into the SDK directory. Works with any `--sdk-dir`.
5. **Platforms** — installs the requested `platforms;android-N` via `sdkmanager`.
   Platforms are architecture-independent, so these come from Google directly.
6. **Shell environment** — appends a clearly delimited, idempotent block to `~/.bashrc`.
7. **Verify** — runs every tool and reports pass/fail.

### What it installs

| Component | Version | Source |
|---|---|---|
| Android SDK platform | android-33 (bundled) + android-34 | AndroidIDE repo + Google |
| build-tools | 34.0.4 (aarch64) | AndroidIDE repo |
| platform-tools (`adb`, `fastboot`) | 34.0.4 (aarch64) | AndroidIDE repo |
| cmdline-tools (`sdkmanager`, `avdmanager`) | latest | AndroidIDE repo |
| Gradle | 9.8.0 | Termux |
| OpenJDK | 21 | Termux |

Downloads are cached in `~/.cache/termux-android-build/` (~180 MB). Safe to delete
afterwards; a later run will just re-download.

---

## Using it

After installation, open a new shell (or `source ~/.bashrc`) and confirm:

```bash
sdkmanager --list_installed      # or: sdkmanager --list
gradle --version
java -version
```

### Project setup — three things

**1. `local.properties`** (never commit this):

```properties
sdk.dir=/data/data/com.termux/files/home/android-sdk
```

Only add `ndk.dir` if the project actually uses native code.

**2. `settings.gradle.kts` must declare `google()` in `pluginManagement`:**

```kotlin
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}
```

This is the single most common failure. Without it, Gradle only searches the Gradle
Plugin Portal and reports:

```
Plugin [id: 'com.android.application', version: '8.7.3'] was not found in any of the following sources
```

The Android Gradle Plugin lives on `google()`. The error names the *plugin*, not the
missing repository, so it looks like a broken SDK when it isn't.

**3. Keep the project in app-internal storage** (`~/...`). Shared storage
(`/sdcard`, `/storage/emulated/0`) is mounted `noexec`, so Gradle wrapper scripts
cannot run from there.

### Build

```bash
cd ~/myproject
gradle assembleDebug
# -> app/build/outputs/apk/debug/app-debug.apk
```

Verify the result:

```bash
apksigner verify --verbose app/build/outputs/apk/debug/app-debug.apk
aapt2 dump badging app/build/outputs/apk/debug/app-debug.apk | head
```

Install it (with runtime permissions pre-granted):

```bash
adb install -r -g app/build/outputs/apk/debug/app-debug.apk
```

---

## Verified

Tested on aarch64 Android 16 (Samsung SM-A366B) inside Termux:

- Script run on a clean SDK directory — all tools verified, exit 0
- Re-run — idempotent, skips downloads and extraction, no duplicate shell config
- **Real build**: `gradle assembleDebug` → `BUILD SUCCESSFUL`, signed APK produced
- APK installed on-device and launched without crashes

> The `build` path is verified. The **NDK / native C++** path is **not** verified —
> see below.

---

## Other architectures

The archive names carry an architecture suffix. The default set targets `aarch64`.

For 32-bit ARM, edit the `ARCHIVES` array in `setup.sh` and change each `-aarch64`
suffix to `-arm`:

```
build-tools-34.0.4-arm.tar.xz
platform-tools-34.0.4-arm.tar.xz
```

The `android-sdk.tar.xz` and `cmdline-tools.tar.xz` archives are architecture-independent.
**Note:** you must also supply the correct SHA-256 for the `-arm` archives — compute them
with `sha256sum` after downloading. The pinned hashes in this script are for `aarch64`.

---

## NDK / native C++ (not verified)

Only needed for CPU-bound code or wrapping existing C/C++ libraries — games, codecs,
ML inference, OpenCV/SQLite, cross-platform engines. Most apps never need it.

**Same trap as build-tools:** Google's NDK ships **x86_64 host** toolchains by default,
which will not run on aarch64 Termux. Check before trusting any NDK:

```bash
ls "$NDK/toolchains/llvm/prebuilt/"   # must contain linux-arm64
```

An NDK whose prebuilt directory contains `linux-arm64` is usable. Otherwise, install via
`sdkmanager "ndk;<version>"`, check the host arch, and discard it if only `linux-x86_64`
is present.

Wire a project up only if it has native sources:

```kotlin
android {
    ndkVersion = "<version>"
    externalNativeBuild {
        cmake { path = file("src/main/cpp/CMakeLists.txt") }
    }
}
```

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Plugin [id: 'com.android.application'] was not found` | Missing `google()` in `pluginManagement` — see project setup above |
| `Several environment variables ... contain different paths to the SDK` | `ANDROID_SDK_ROOT` and `ANDROID_HOME` disagree. The script unsets `ANDROID_SDK_ROOT`; make sure nothing else re-exports it |
| `cannot execute binary file` | You have x86_64 build-tools. Use the aarch64 archives this script installs |
| `sdkmanager: Could not create settings` | Ensure `ANDROID_USER_HOME=$HOME/.android` and pass `--sdk_root="$ANDROID_HOME"` |
| Gradle wrapper won't run | Project is on `/sdcard` (`noexec`). Move it to `~/...` |
| Checksum mismatch on download | Upstream changed the archive. Verify manually before trusting it |
| Old Gradle daemon conflict | `pkill -f GradleDaemon` then rebuild |

---

## License

MIT — see [LICENSE](LICENSE).

Upstream SDK archives are published by the
[androidide-tools](https://github.com/AndroidIDEOfficial/androidide-tools) project
(GPL-3.0). This script only downloads and arranges them.
