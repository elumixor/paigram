# Paigram

Telegram for iOS with pai built into the bot's chat. The chat with the pai bot is a normal Telegram chat, so its messages forward, search and quote like any other, with three differences: the topic strip is gone and the chat opens on the thread it was on last time; the bot's "Menu" button is a Pai button (a dot on it means a thread is running or waiting) that opens the Pai screen, threads grouped by project with a composer that starts a new one from text or dictation; and the bot's messages render their tool use the way Claude does, one grey line above the answer ("Ran 3 commands, read a file") that expands into a timeline, with the status card showing the current tool and elapsed time while a turn runs.

Picking a thread on the Pai screen returns to the chat on that topic. Threads are the bot's Telegram topics; the Pai screen reads their state from the pai daemon (`/tasks`, `/task`, `/m/telegram/info`) and follows `/events`. Dictation runs English, Russian and Ukrainian recognizers on the device at once and keeps the most confident transcript.

Code: `submodules/PaiUI` (the store, the Pai screen, the trailer parser), `submodules/TelegramUI/Components/Chat/ChatMessagePaiToolsBubbleContentNode` (the tools node), and small hooks in `ChatMessageBubbleItemNode`, `ChatMessageTextBubbleContentNode`, `ChatTextInputPanelNode`, `ChatControllerNode`, `ChatController` and `ChatControllerLoadDisplayNode`, all keyed on `PaiChat.isBot`. The bot's metadata rides in each message's trailing link (`pai/src/protocol/rich.ts`); pai-telegram fills in the tools, state and timings.

## Build

Bazel builds, driven by Telegram's `build-system/Make/Make.py`. First time: `bun install`, then copy `build-system/paigram.example.json` to `build-system/paigram.json` and `build-system/paigram-sim.json` (api id and hash from my.telegram.org; the simulator file keeps the bundle id `ph.telegra.Telegraph`, which the repo's fake codesigning profiles are bound to). Every build writes `submodules/PaiUI/Sources/PaiSecrets.swift` from `~/.config/pai/box.json` and the box's `/m/telegram/info`, so the app ships with its server, token and bot name.

```sh
bun run sim [--no-build]          # simulator build, installed and launched on the newest iPhone simulator
bun run testflight [--no-build] [--minor]   # bumps the version (versions.json, committed), App Store profile via the API, release build, upload, wait
```

TestFlight needs `.env` with `ASC_KEY_ID`, `ASC_ISSUER_ID`, `TEAM_ID` and the key at `~/.appstoreconnect/private_keys/`. App extensions are left out of both builds (`--//Telegram:disableExtensions=True`), so only the app itself needs a profile. The App Store Connect app record and the app group `group.com.elumixor.paigram` have to be created by hand in the portal, which the API does not allow.

Upstream pins Xcode 26.2; `--overrideXcodeVersion` lets the installed Xcode build it. Bazel is downloaded to `build-input/` on first run; the disk cache lives in `~/telegram-bazel-cache`.
