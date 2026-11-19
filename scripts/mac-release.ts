/**
 * `bun scripts/mac-release.ts [tag]`: what the TestFlight workflow runs on this Mac (a self-hosted runner,
 * `paigram-mac`), so a tag dispatched from pai's build card builds here, from the warm Bazel disk cache, in a
 * fraction of a hosted runner's time. It runs in the runner's own checkout of the tag (the workflow's
 * `actions/checkout`), never in `~/dev`, whose synced files carry other sessions' work in progress; the
 * workflow has already run `scripts/ci.ts`, so signing comes from its throwaway keychain and the App Store
 * Connect key from the repo secrets. The build runs under `caffeinate`, so the Mac does not doze off halfway.
 *
 * When this script fails the run fails; nothing builds elsewhere unless `testflight-hosted.yml` is dispatched by hand, so it fails loudly.
 */
import { $ } from "bun";
import { root } from "./repo.ts";

// The disk cache grows with every build and this disk is small: the runner's checkout keeps a Bazel output
// base of its own (~20 GB for a release build) next to it, so the cache is held well under that.
await $`bun scripts/trim-cache.ts ${process.env.HOME}/telegram-bazel-cache 15`.cwd(root);
// -i: no idle sleep while the build runs; -s: no system sleep either, honoured on AC power only
// (on battery with the lid closed the Mac sleeps regardless, the job stalls, and GitHub fails it after
// ten minutes without a heartbeat; dispatch it again).
await $`caffeinate -ims bun run testflight --no-bump --once`.cwd(root);

