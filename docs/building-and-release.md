# Building and Releasing Tsukiko

This guide explains how to compile, package, code-sign, and release Tsukiko for macOS and Windows.

---

## Quick Reference

| Stage | macOS | Windows |
| :--- | :--- | :--- |
| **ASR Engines (Whisper + NeMo)** | `./tool/engine.sh` | `.\tool\engine-win.ps1` |
| **Audio Processing** | System `afconvert` | `tool/build-ffmpeg.sh` (MSYS2) |
| **Flutter Application** | `flutter build macos --release` | `flutter build windows --release` |
| **Code Signing** | `./tool/sign.sh` | Optional Authenticode signing |
| **Distributable Package** | `./tool/dmg.sh` → `build/tsukiko.dmg` | `.\tool\package-win.ps1` → `tsukiko-setup.exe` |

---

## Build Prerequisites

### macOS

| Requirement | Purpose | Size |
| :--- | :--- | :--- |
| **Xcode & Command Line Tools** | Native compiler, `codesign`, `tiffutil` | ~10 GB |
| **Flutter SDK** (`>=3.12.2`) | UI framework & application runtime | ~3 GB |
| **CMake** (`brew install cmake`) | Building `whisper.cpp` engine | ~120 MB |
| **Apple Code Signing Certificate** | Development or Developer ID certificate | — |

> [!NOTE]
> Neither Python, PyTorch, nor external Whisper runtimes are needed. The C++ engines compile directly to native binaries with built-in Apple Silicon Metal GPU acceleration.

### Windows

| Requirement | Purpose | Size |
| :--- | :--- | :--- |
| **Visual Studio 2022 (C++ Desktop Development)** | MSVC C++ toolchain | ~7 GB |
| **Flutter SDK** (`>=3.12.2`) | Application framework | ~3 GB |
| **CMake** | Build orchestrator (included in Visual Studio) | — |
| **Vulkan SDK** | Shader compilation (`glslc`) for Vulkan GPU acceleration | ~250 MB |
| **Inno Setup 6** | Installer creation (`tsukiko-setup.exe`) | ~20 MB |

> [!NOTE]
> CUDA Toolkit is not required. Tsukiko uses Vulkan, which runs across NVIDIA, AMD, and Intel GPUs out of the box with near-zero binary overhead.

---

## Engine Compilation

Tsukiko compiles pinned releases of `whisper.cpp` and `NeMo-Speech.cpp`:

### macOS
- Compiles a static, universal binary (`arm64` and `x86_64`) with embedded Metal shaders.
- Placed into `Contents/Helpers` under `tsukiko-recognizer` and `tsukiko-dictation`.

### Windows
- Generates two binaries:
  1. `tsukiko-recognizer-vulkan.exe` (used when `vulkan-1.dll` is present in system).
  2. `tsukiko-recognizer-cpu.exe` (fallback when Vulkan is unavailable).
- The application automatically selects the optimal binary on startup (`os.engineNames`).

---

## Headless CLI Tool Compilation

The command-line tool `tsukiko-transcribe` is compiled independently of the Flutter UI:

```sh
# Built directly with the Dart compiler
dart compile exe bin/tsukiko_transcribe.dart -o tsukiko-transcribe
```

Packaging scripts (`tool/sign.sh` on macOS and `tool\package-win.ps1` on Windows) automate this step and bundle `tsukiko-transcribe` into the final application package.

---

## Distribution Packaging

### macOS: Drag-and-Drop DMG

```sh
flutter build macos --release
./tool/sign.sh    # Bundles engines and signs with timestamp
./tool/dmg.sh     # Generates build/tsukiko.dmg
```

- Features a Retina background image (`design/dmg-background.tiff`) with drag-to-Applications layout.
- Finder layout is written directly into the image, without GUI automation. Packaging installs pinned Python dependencies in `build/dmg-tools-venv`; it leaves existing mounted installers connected.
- `python3 tool/test_dmg.py` checks packaging and layout with another `tsukiko` volume already mounted. `build/dmg-tools-venv/bin/python3 tool/verify-dmg.py build/tsukiko.dmg` verifies the actual distributable.
- Signed with `--timestamp` to ensure the signature remains valid beyond certificate expiry.

### Windows: Inno Setup Installer

```powershell
.\tool\engine-win.ps1
.\tool\build-ffmpeg-win.ps1   # Validates ffmpeg presence
.\tool\package-win.ps1        # Generates build\installer\tsukiko-setup.exe
```

- Installs cleanly into the user's profile (`%LOCALAPPDATA%\Programs\tsukiko`) without requiring Administrator privileges.
- Also produces `tsukiko-portable.zip` for portable usage.

---

## Continuous Integration & Automated Builds

GitHub Actions workflows are defined in `.github/workflows/`:
- **`macos.yml`**: Validates versions, runs `flutter analyze` and `flutter test`. Full packaging (`tsukiko.dmg`) triggers when `[build]`, `[build-macos]`, or `[release]` is present in the commit message on `main`.
- **`windows.yml`**: Compiles native C++ engines with Vulkan, runs tests, and builds `tsukiko-setup.exe` when `[build]`, `[build-windows]`, or `[release]` is present.

Both workflows also support manual `workflow_dispatch` on an explicitly selected
branch. A manual run performs the same tests and full distribution build, allowing
validation before merging a pull request. Only successful builds pushed to `main`
reserve version tags; manual candidate builds do not consume the version.

Feature-branch builds use the isolated `candidate` environment and an ad-hoc
signature, without access to the `release` signing certificate. They are test
artifacts: use the existing developer signing identity before replacing an
installed app to preserve its macOS Accessibility permission. Builds from `main`
use the protected `release` environment.

```sh
gh workflow run macos.yml --ref my-branch
gh workflow run windows.yml --ref my-branch
```

---

## Cleaning the Build Directory

To free up disk space after compilation:

```sh
flutter clean                    # Removes Flutter build cache (~2-3 GB)
rm -rf build/engine              # Removes raw engine source trees (~1.5 GB)
```

The compiled binaries in `macos/Engine` and `windows\Engine` (~15-30 MB) can be retained to avoid recompiling on every release.
