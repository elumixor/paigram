# Paigram

Telegram for iOS with a Pai tab: every thread the assistant runs, what each one is doing right now, and a composer that starts a new one from text or dictation. The Telegram side is untouched; the fork adds `submodules/PaiUI` and one tab in `TelegramRootController`.

The Pai tab talks to the pai daemon over its HTTP API (`/tasks`, `/task`, `/send`, `/answer`, `/transcript`) and follows the `/events` stream, so tool calls appear as they happen. Voice is transcribed on the phone with Apple's speech recognizer and sent as text. Set the server address and token in the tab's settings.

## Build

Bazel builds, driven by Telegram's `build-system/Make/Make.py`. First time: `bun install`, then copy `build-system/paigram.example.json` to `build-system/paigram.json` and `build-system/paigram-sim.json` (api id and hash from my.telegram.org; the simulator file keeps the bundle id `ph.telegra.Telegraph`, which the repo's fake codesigning profiles are bound to).

```sh
bun run sim [--no-build]          # simulator build, installed and launched on an iPhone simulator
bun run testflight [--no-build]   # App Store profile via the API, release build, upload, wait for processing
```

TestFlight needs `.env` with `ASC_KEY_ID`, `ASC_ISSUER_ID`, `TEAM_ID` and the key at `~/.appstoreconnect/private_keys/`. App extensions are left out of both builds (`--//Telegram:disableExtensions=True`), so only the app itself needs a profile. The App Store Connect app record and the app group `group.com.elumixor.paigram` were created by hand in the portal, which the API does not allow.

Upstream pins Xcode 26.2; `--overrideXcodeVersion` lets the installed Xcode build it. Bazel is downloaded to `build-input/` on first run; the disk cache lives in `~/telegram-bazel-cache`.
