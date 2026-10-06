# Paigram

Telegram for iOS with pai built into the bot's chat. The chat with the pai bot is a normal Telegram chat, so its messages forward, search and quote like any other, with three differences: the topic strip is gone and the chat opens on the thread it was on last time; the bot's "Menu" button is a Pai button (a dot on it means a thread is running or waiting) that opens the Pai screen, threads grouped by project with a composer that starts a new one from text or dictation; and the bot's messages render their tool use the way Claude does, one grey line above the answer ("Ran 3 commands, read a file") that expands into a timeline, with the status card showing the current tool and elapsed time while a turn runs.

The bot's avatar in the chat's bar (where Telegram would put the topics menu) opens the Pai settings instead of a profile: threads running, uptime, the Claude limits and what the sessions cost, and what the sessions are given — tools by MCP server, skills, the instructions in their parts, memories — read from the daemon's `/context`, `/usage` and `/health`.

Picking a thread on the Pai screen returns to the chat on that topic. Threads are the bot's Telegram topics; the Pai screen reads their state from the pai daemon (`/tasks`, `/task`, `/m/telegram/info`) and follows `/events`. Dictation runs English, Russian and Ukrainian recognizers on the device at once and keeps the most confident transcript.

Code: `submodules/PaiUI` (the store, the Pai screen, the settings screen, the trailer parser), `submodules/TelegramUI/Components/Chat/ChatMessagePaiToolsBubbleContentNode` (the tools node), and small hooks in `ChatMessageBubbleItemNode`, `ChatMessageTextBubbleContentNode`, `ChatTextInputPanelNode`, `ChatControllerNode`, `ChatController` and `ChatControllerLoadDisplayNode`, `ChatInterfaceStateNavigationButtons` and `ChatControllerNavigationButtonAction`, all keyed on `PaiChat.isBot`. The bot's metadata rides in each message's trailing link (`pai/src/protocol/rich.ts`); pai-telegram fills in the tools, state and timings.

## Build

Bazel builds, driven by Telegram's `build-system/Make/Make.py`. First time: `bun install`, then copy `build-system/paigram.example.json` to `build-system/paigram.json` and `build-system/paigram-sim.json` (api id and hash from my.telegram.org; the simulator file keeps the bundle id `ph.telegra.Telegraph`, which the repo's fake codesigning profiles are bound to). Every build writes `submodules/PaiUI/Sources/PaiSecrets.swift` from `~/.config/pai/box.json` and the box's `/m/telegram/info`, so the app ships with its server, token and bot name; where there is no box file (CI) `PAI_BOX_URL`, `PAI_BOX_TOKEN` and `PAI_BOT_USERNAME` stand in for it.

```sh
bun run sim [--no-build]          # simulator build, installed and launched on the newest iPhone simulator
bun run ci-secrets                # once, on the Mac: fill the GitHub secrets CI needs from the box and the keychain
bun run tag [--minor]             # bump the version, tag it `ios-vX.Y.Z` and push: this Mac (self-hosted runner) builds and uploads to TestFlight
bun run testflight [--no-build] [--no-bump] [--minor]   # the same release from a Mac, locally: version bump, App Store profile via the API, release build, upload, wait
bun run typecheck                 # the scripts
```

TestFlight needs `.env` with `ASC_KEY_ID`, `ASC_ISSUER_ID`, `TEAM_ID` and the key at `~/.appstoreconnect/private_keys/`. The TestFlight build ships everything the official app does: the share, notification service and content, Siri intents, widget and broadcast upload extensions, and the watch app (`Telegram/WatchApp`, built by xcodebuild and embedded with `--embedWatchApp`). `scripts/provision.ts` registers the bundle id of each with its capabilities and writes a fresh App Store profile for every one. The App Store Connect app record and the app group `group.com.elumixor.paigram` have to be created by hand in the portal, and the group attached to each extension's bundle id there, which the API does not allow; provisioning checks the profiles and says which ids still lack it. The same goes for Communication Notifications on the app's own id, which lets a notification carry the sender's photo with the app icon in its corner: tick it on the id in the portal, and provisioning refuses to go on while the profile lacks it. Simulator builds leave the extensions out unless `bun run sim --extensions`.

The icon is `Telegram/Telegram-iOS/Telegram.icon` (Icon Composer: a chat bubble in the shape of a p with a sparkle in its bowl, on a violet to blue gradient). The watch app takes a flat PNG instead, `Telegram/Telegram-iOS/WatchAppIcon.png`, which replaces the snapshot's Telegram icon at build time; after changing the icon, `bun run watch-icon` renders it again from the `.icon` (needs ImageMagick).

Upstream pins Xcode 26.2; `--overrideXcodeVersion` lets the installed Xcode build it. Bazel is downloaded to `build-input/` on first run; the disk cache lives in `~/telegram-bazel-cache`.

### Releasing from CI

`bun run tag` is the whole release and needs no Mac: it bumps `versions.json`, commits, tags `ios-vX.Y.Z` and pushes, and `.github/workflows/testflight.yml` does the rest on a GitHub macOS runner — a real signed release build with the extensions and the watch app, uploaded to TestFlight. The workflow is deliberately thin over the same scripts a Mac runs: `scripts/ci.ts` prepares the runner, then `bun run testflight --no-bump` provisions, builds, uploads and waits. It also runs from the Actions tab (`workflow_dispatch`), which builds whatever `versions.json` currently says and takes the next free build number from App Store Connect.

`scripts/ci.ts` is everything a developer's Mac already has and a bare runner does not: it checks every secret up front — a missing one fails in seconds rather than an hour into Bazel — writes the App Store Connect key to `~/.appstoreconnect/private_keys/`, writes `build-system/paigram.json` from the committed example, and imports the distribution certificate into a throwaway keychain with a partition list so `codesign` never waits for a prompt. It also refuses a tag whose version does not match `versions.json`. `scripts/trim-cache.ts` trims the Bazel disk cache to 8 GB, least recently used first, before `actions/cache` saves it, because GitHub rejects an entry over 10 GB; the cache is saved even when the build fails, so the next attempt starts from the work that did get through. The runner is cleaned first — every Xcode but the selected one and all simulator runtimes go — since GitHub's macOS runners have only 14 GB free and this build plus its cache does not fit beside them.

Once, from the Mac that holds the Apple material:

```sh
bun run ci-secrets [--p12 <path>]
```

`scripts/ci-secrets.ts` sets all eleven repo secrets itself. Eight of the values already live on the box and it reads them over `pai ssh` (the `.env`, `build-system/paigram.json` and `~/pai/data/config.json` there, plus the box's own `/m/telegram/info` for the bot name); the App Store Connect key and the distribution certificate exist nowhere but that Mac, so it reads the key out of `~/.appstoreconnect/private_keys/` and exports the certificate from the login keychain — macOS asks for the login password before it releases a private key, and if more than one distribution identity is in there it asks which one. `security export` cannot be pointed at a single identity, so it exports the keychain's identities and separates the chosen certificate and its key out with openssl; `--p12 <path>` skips all of that and takes a `.p12` exported by hand from Keychain Access instead. Every value goes to `gh secret set` on stdin, so none of them reaches argv or shell history. It needs `gh` logged in with access to the repo, and checks that before it reads anything.

The secrets it sets, for setting them by hand under Settings → Secrets and variables → Actions:

| Secret | What |
| --- | --- |
| `ASC_KEY_ID` | App Store Connect API key id |
| `ASC_ISSUER_ID` | App Store Connect issuer id |
| `ASC_KEY_P8` | base64 of `AuthKey_<id>.p8` (`base64 -i AuthKey_<id>.p8`) |
| `TEAM_ID` | Apple Developer team id |
| `DIST_CERT_P12` | base64 of the Apple Distribution certificate **with its private key** — the same certificate `scripts/provision.ts` picks, which is the newest unexpired one on the account |
| `DIST_CERT_P12_PASSWORD` | the password that `.p12` was exported with |
| `TELEGRAM_API_ID` | `api_id` from my.telegram.org |
| `TELEGRAM_API_HASH` | `api_hash` from my.telegram.org |
| `PAI_BOX_URL` | the box the app talks to |
| `PAI_BOX_TOKEN` | the box's bearer token |
| `PAI_BOT_USERNAME` | the box's bot username, without the `@` (set so the build does not have to reach the box) |

`.github/workflows/build.yml` is upstream Telegram's CI — a full Bazel build with fake codesigning, producing an unsigned ipa on a GitHub release. It no longer runs on pushes to master: macOS runners bill at ten times the Linux rate and that ipa is of no use here, so it is `workflow_dispatch` only and the TestFlight workflow is the only build a push can start.
