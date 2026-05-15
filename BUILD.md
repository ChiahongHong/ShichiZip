# Building ShichiZip

This document covers building ShichiZip from source. For installing pre-built releases, see the [README #Install](README.md#install).

## Requirements

- Xcode and Command Line Tools matching the version used in [CI](https://github.com/idawnlight/ShichiZip/actions). This project tracks the latest Xcode and adopts new Swift features eagerly, so older Xcode releases are not guaranteed to work.
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen) for generating the Xcode project.
- [`zig >= 0.16.0`](https://ziglang.org/) for building the bundled 7-Zip libraries and Windows SFX modules.
  - If you install `zig` from Homebrew, `zig 0.16.0_1` or newer is required. The `0.16.0` bottle shipped a broken `zig ar`; see [Homebrew/homebrew-core#278849](https://github.com/Homebrew/homebrew-core/issues/278849).
- Python 3 for the localization scripts under `project/scripts/`.

```sh
brew install xcodegen zig
# or any other method you prefer for installing those tools
```

## Getting the source

The repository uses Git submodules for the upstream 7-Zip sources under `vendor/`:

```sh
git clone --recurse-submodules https://github.com/idawnlight/ShichiZip
cd ShichiZip
```

If you already cloned without `--recurse-submodules`, run `git submodule update --init --recursive`.

Alternatively, each tagged release publishes a source tarball on the [Releases](https://github.com/idawnlight/ShichiZip/releases) page. The tarball ships with vendored sources already patched, `ShichiZip.xcodeproj` already generated, and a `.build-metadata` marker file. Building from it skips the patch step in `build.zig` and the `xcodegen generate` step below; jump straight to step 2.

## Build steps

ShichiZip ships in two variants that share the same app code but link against different upstream 7-Zip trees:

- **Mainline** (`ShichiZip`): linked against `vendor/7zip` ([ip7z/7zip](https://github.com/ip7z/7zip)).
- **Zstandard fork** (`ShichiZipZS`): linked against `vendor/7zip-zstd` ([mcmilk/7-Zip-zstd](https://github.com/mcmilk/7-Zip-zstd)), adding Zstandard and a few other codecs.

Each build is two steps: build the C/C++ static library and the Windows SFX modules with Zig, then build the macOS app with Xcode.

### 1. Generate the Xcode project

```sh
xcodegen generate
```

Skip this step when building from a release source tarball; `ShichiZip.xcodeproj` and the generated localization files are already in the tarball.

### 2. Build the upstream library with Zig

Mainline:

```sh
zig build lib -Dvariant=mainline -Dtarget=aarch64-native -Doptimize=ReleaseFast -p build
```

Zstandard fork:

```sh
zig build lib -Dvariant=zs -Dtarget=aarch64-native -Doptimize=ReleaseFast -p build
```

Output goes to `build/lib/`. Substitute `-Dtarget=x86_64-native` for Intel builds.

### 3. Build the Windows SFX modules

The app bundles small Windows SFX stubs used when creating self-extracting archives. These match the current packaging (`x86`):

```sh
zig build sfx -Dvariant=mainline -Dsfx-arch=x86 -Doptimize=ReleaseSmall -p build
zig build sfx -Dvariant=zs -Dsfx-arch=x86 -Doptimize=ReleaseSmall -p build
```

Use `-Dsfx-arch=x86_64` or `-Dsfx-arch=all` to build the other targets. Note that extra architectures are not packaged by the app. They are only intended for testing or exploration.

#### Zig: Building both variants and architectures at once

`-Dvariant=all` fans out to both upstream trees; `zig build all` runs `lib` and `sfx` together. The combined step uses a single optimization mode for everything, which produces larger SFX binaries than the staged commands above.

### 4. Build the app with Xcode

Mainline:

```sh
xcodebuild -project ShichiZip.xcodeproj -scheme ShichiZip -configuration Debug -arch arm64 build
```

Zstandard fork:

```sh
xcodebuild -project ShichiZip.xcodeproj -scheme ShichiZipZS -configuration Debug -arch arm64 build
```

Substitute `-arch x86_64` for Intel builds. Use `-configuration Release` for release builds.

## Testing

The project ships unit and UI test targets for each variant: `ShichiZipTests` / `ShichiZipUITests` for mainline, and `ShichiZipZSTests` / `ShichiZipZSUITests` for the Zstandard fork.

Run the unit tests:

```sh
xcodebuild -project ShichiZip.xcodeproj -scheme ShichiZip -configuration Debug -arch arm64 -only-testing:ShichiZipTests test
xcodebuild -project ShichiZip.xcodeproj -scheme ShichiZipZS -configuration Debug -arch arm64 -only-testing:ShichiZipZSTests test
```

Run the UI tests:

```sh
xcodebuild -project ShichiZip.xcodeproj -scheme ShichiZip -configuration Debug -arch arm64 -only-testing:ShichiZipUITests test
xcodebuild -project ShichiZip.xcodeproj -scheme ShichiZipZS -configuration Debug -arch arm64 -only-testing:ShichiZipZSUITests test
```

Drop `-only-testing` to run both suites together. UI tests automate the real app, so you have to leave the machine alone while they run.

## Project layout

```
ShichiZip/             Swift/Objective-C++ app sources
├── App/               App entry, AppDelegate, top-level windows
├── Bridge/            Swift ↔ C++ bridge to the 7-Zip core
├── Dialogs/           Dialogs and sheets (extraction, compression, settings, etc.)
├── Document/          NSDocument-based Launch Services integration shim
├── FileManager/       Main File Manager UI
├── Model/             Archive entry and filesystem item models
├── QuickActions/      Finder Quick Action extensions
├── Resources/         Assets, Info.plist fragments, localization
└── Utilities/         Shared helpers

ShichiZipTests/        Unit tests
ShichiZipUITests/      UI tests

vendor/                Upstream 7-Zip source (submodules) and patches
├── 7zip/              ip7z/7zip
├── 7zip-zstd/         mcmilk/7-Zip-zstd
├── *.patch            Patches applied before building
├── apply_7zip_patches.sh
└── SZ*.mm             Small Objective-C++ shims linked into the library

project/
├── specs/             XcodeGen specs (base.yml, apps.yml, quick-actions.yml)
├── scripts/           Localization, build metadata, packaging helpers
├── localization/      Source localization data (see README)
└── generated/         Files produced by xcodegen / scripts (gitignored)

build.zig              Zig build script for the static library and SFX modules
build.zig.zon          Zig package manifest
project.yml            XcodeGen entry point (includes project/specs/*.yml)
```

### Flow

- **`build.zig`** patches the vendored 7-Zip tree (via `vendor/apply_7zip_patches.sh`), then compiles the macOS static library (including the Objective-C++ shims in `vendor/SZ*.mm`) and the Windows SFX modules. Source tarballs from release artifacts contain a `.build-metadata` file and will skip the patch step, since their sources are already patched.
- **`xcodegen`** consumes `project.yml` (which includes the specs under `project/specs/`) to generate `ShichiZip.xcodeproj`. It also runs the localization generators in `project/scripts/` to produce the files under `project/generated/` and the `InfoPlist.strings` for Quick Actions. Re-run `xcodegen generate` after editing any spec or localization source. Source tarballs from release artifacts ship with `ShichiZip.xcodeproj` and the generated localization files already in place, so this step can be skipped when building from a tarball.
- **Xcode** builds the app, links against the static library produced by Zig in `build/lib/`, and embeds the Quick Action extensions and the specific SFX module from `build/sfx/`.

## Reference

- CI workflow: [`.github/workflows/build.yml`](.github/workflows/build.yml) is the canonical, always-current build recipe.
- Contribution notes and localization workflow: see [README #Contributing](README.md#contributing).
