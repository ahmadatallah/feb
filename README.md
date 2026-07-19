# feb (free-expo-builds)

**feb** is a script that builds your Expo app **locally** with `eas build --local` — then deploys it to a device, uploads it, or submits it to the stores — with every requirement (EAS CLI, CocoaPods, Fastlane, JDK, ...) checked and installed for you. iOS and Android. No build queue, no EAS build credits, no cloud minutes.

![feb demo](./docs/demo.gif)

## Why

EAS cloud builds are convenient but metered: free-tier builds are limited and queued, and paid plans charge per build. The EAS CLI can run the exact same build pipeline **on your own machine** with `--local` — same profiles, same credentials management, same output artifacts — for free and usually faster.

This script wraps that into a single command:

```bash
feb ios staging
feb android production
feb all preview
```

## What it does

1. **Installs build dependencies** if missing — EAS CLI, CocoaPods, Fastlane, ios-deploy (via Homebrew on macOS), and checks Xcode / Android SDK / Java.
2. **Installs project dependencies** — auto-detects pnpm / yarn / npm / bun from the lockfile, walks up parent directories so monorepos work.
3. **Authenticates with Expo** — uses `EXPO_TOKEN` if set, otherwise `eas login`.
4. **Builds locally** with `eas build --local` for the platform(s) and profile you pass. Artifact names and extensions (`.ipa` / `.apk` / `.aab`) are derived from your `eas.json` profile. Output lands in `build-output/`.
5. **Post-build actions** (interactive prompts, skipped with `--non-interactive` or in CI):
   - Install on a connected iPhone (USB or WiFi via ios-deploy)
   - Install on a connected Android device or emulator (adb)
   - Upload artifacts to any WebDAV server (Fastmail Files, Nextcloud, ownCloud, ...) — a free way to distribute internal builds to your team
   - Submit to TestFlight / Google Play via `eas submit` (store-distribution profiles only)

Prefer submitting manually? The artifacts in `build-output/` are standard store-ready files — upload the `.ipa` to App Store Connect with Apple's [Transporter](https://apps.apple.com/us/app/transporter/id1450874784) app, and the `.aab` through the [Google Play Console](https://play.google.com/console).

## Requirements

- **An Expo project** with an [`eas.json`](https://docs.expo.dev/eas/json/) (see [`eas.example.json`](./eas.example.json))
- **A free Expo account** — `eas build --local` needs authentication but does not consume build credits

### Dependencies

The script checks every tool it needs and installs the missing ones where it safely can:

| Tool                                                    | Needed for                                                  | Auto-installed?                                |
| ------------------------------------------------------- | ----------------------------------------------------------- | ---------------------------------------------- |
| [Node.js](https://nodejs.org) 22.x LTS                  | everything — EAS CLI and the build itself                   | No — install it yourself                       |
| [EAS CLI](https://github.com/expo/eas-cli)              | `eas build --local` / `eas submit`                          | Yes (`npm install -g eas-cli`)                 |
| [Homebrew](https://brew.sh)                             | installing the macOS tools below                            | Yes (macOS only)                               |
| Xcode                                                   | iOS builds                                                  | No — App Store                                 |
| [CocoaPods](https://cocoapods.org)                      | iOS builds                                                  | Yes (brew)                                     |
| [Fastlane](https://fastlane.tools)                      | iOS builds (archive & signing)                              | Yes (brew)                                     |
| [ios-deploy](https://github.com/ios-control/ios-deploy) | installing on a connected iPhone (interactive only)         | Yes (brew; skipped in CI)                      |
| Android SDK (`ANDROID_HOME`)                            | Android builds                                              | No — auto-detected in common install locations |
| JDK 17                                                  | Android builds                                              | Yes on macOS (brew); no on Linux               |
| adb                                                     | installing on a connected Android device (interactive only) | Comes with the Android SDK                     |

Your project's own dependencies are installed with whatever your lockfile says — npm, yarn, pnpm, or bun all work.

**Pinning versions with [mise](https://mise.jdx.dev)**: if your project has a `.mise.toml`, `mise.toml`, or `.tool-versions`, the script runs `mise install` first and uses that toolchain — so Node and JDK come from your pins instead of whatever is on the machine (mise itself is auto-installed if missing):

```toml
# .mise.toml in your Expo project
[tools]
node = "22"
java = "temurin-17"
```

## Setup

Install with [Homebrew](https://github.com/ahmadatallah/homebrew-tap) — the command is `feb` — and run it from your Expo project root:

```bash
brew install ahmadatallah/tap/feb
feb ios staging
```

Or drop `build.sh` into your Expo project root (or a `scripts/` folder inside it):

```bash
curl -o build.sh https://raw.githubusercontent.com/ahmadatallah/feb/main/build.sh
chmod +x build.sh
```

Optionally add npm scripts:

```json
{
  "scripts": {
    "build:local": "./build.sh",
    "build:local:staging:ios": "./build.sh ios staging",
    "build:local:staging:android": "./build.sh android staging",
    "build:local:production:all": "./build.sh all production"
  }
}
```

## Usage

```
feb <platform> <profile> [--non-interactive]      # brew install
./build.sh <platform> <profile> [--non-interactive]  # vendored script

platform: ios | android | all
profile:  any build profile defined in your eas.json
```

### Environment variables (all optional)

| Variable            | Purpose                                                                                              |
| ------------------- | ---------------------------------------------------------------------------------------------------- |
| `APP_NAME`          | Artifact filename prefix. Defaults to the `name` in `app.json` (or `package.json`).                   |
| `EXPO_TOKEN`        | Expo access token for non-interactive auth. Otherwise `eas login` prompts.                            |
| `PRE_BUILD_COMMAND` | Command to run after install, before build — e.g. `pnpm --filter @myorg/lib build` in a monorepo.     |
| `WEBDAV_BASE_URL`   | WebDAV endpoint for artifact uploads, e.g. `https://webdav.fastmail.com/files`.                       |
| `WEBDAV_USERNAME`   | WebDAV username.                                                                                      |
| `WEBDAV_PASSWORD`   | WebDAV password / app-specific password.                                                              |

Anything not set as an env var is prompted for interactively. In `--non-interactive` mode (or when `CI` is set), all post-build prompts are skipped — the script just builds.

### Monorepo example

```bash
PRE_BUILD_COMMAND="pnpm --filter @myorg/shared build" ./build.sh all staging
```

The script finds your workspace root by walking up to the lockfile, runs the install there, then runs your pre-build hook before building the app.

## GitHub Action

This repo doubles as a composite GitHub Action — build in CI without EAS build credits:

```yaml
jobs:
  build:
    runs-on: ubuntu-latest # macos-latest for iOS
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
      - uses: actions/setup-java@v4 # Android only
        with:
          distribution: temurin
          java-version: 17
      - uses: ahmadatallah/feb@v1.1.2
        id: build
        with:
          platform: android
          profile: production
          expo-token: ${{ secrets.EXPO_TOKEN }}
          # working-directory: apps/mobile          # monorepos
          # pre-build-command: pnpm --filter @myorg/lib build
      - uses: actions/upload-artifact@v4
        with:
          name: android-build
          path: ${{ steps.build.outputs.android-artifact }}
```

**Inputs**: `platform`, `profile`, `expo-token` (required); `working-directory`, `pre-build-command`, `app-name` (optional).
**Outputs**: `ios-artifact`, `android-artifact`, `output-dir`.

Full workflow examples in [`examples/`](./examples). iOS builds need `runs-on: macos-latest` (Xcode preinstalled on GitHub-hosted macOS runners).

## Used by

<a href="https://hashcards.app">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://hashcards.app/icon-dark.png">
    <img src="https://hashcards.app/icon.png" alt="Hashcards logo" width="48" align="left">
  </picture>
</a>

**[Hashcards](https://hashcards.app)** — flashcards with free spaced-repetition scheduling (FSRS). Ships its iOS and Android builds with this action.

<br clear="left">

Using free-expo-builds in your app? Open a PR to add it here.

## Notes & gotchas

- **Credentials**: `eas build --local` still uses EAS-managed credentials (signing certs, provisioning profiles, keystores) if you have them configured — or a local `credentials.json`. See the [local builds docs](https://docs.expo.dev/build-reference/local-builds/).
- **Simulator profiles** (`ios.simulator: true`) produce a `.tar.gz` containing an `.app`, not an `.ipa` — the script names artifacts accordingly and skips the device-install prompt.
- **Disk space**: local builds compile the whole native project; expect several GB of intermediate artifacts under the EAS temp directory.
- **Reproducibility**: cloud builds run in a clean container; local builds run on your machine. Pin your toolchain with a `.mise.toml` (see [Dependencies](#dependencies)) and your Node/pnpm versions in `eas.json` (`node`, `pnpm` fields) to keep them close.

## Development

```bash
mise install          # pinned dev toolchain (node, shellcheck) from .mise.toml
bash tests/run-tests.sh
```

Runs the test suite against fixture projects with all external commands (`eas`, `brew`, package managers) stubbed — no network, no real builds. CI runs shellcheck + the suite on every push/PR.

## License

[MIT](./LICENSE)
