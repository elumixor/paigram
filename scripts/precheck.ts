/**
 * `bun run precheck`: the compile errors a release build would only report after an hour of Bazel,
 * found in seconds. Paigram's own Swift for the two targets with the oldest deployment floors — the
 * iOS widget (iOS 15, where the shared `PaiGlance` module and `PaiUsageWidget.swift` have to compile)
 * and the watch app's Pai files (watchOS 26) — is type-checked straight with `swiftc` against the
 * installed SDKs, which is where availability mistakes (`'accessoryCircular' is only available in
 * iOS 16.0 or newer`) surface. The rest of the app is upstream Telegram and is not checked here.
 * `bun run testflight` and `bun run device` run it before provisioning; the GitHub workflow runs it
 * before restoring the Bazel cache. Needs Xcode (`xcrun`); the box cannot run it.
 */
import { $ } from "bun";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { root } from "./repo.ts";

/** Mirrors `minimum_os_version` in Telegram/BUILD and `deploymentTarget` in Telegram/WatchApp/project.yml. */
const iosTarget = "arm64-apple-ios15.0";
const watchTarget = "arm64_32-apple-watchos26.0";

const glanceSources = ["PaiGlance.swift", "PaiGlanceSource.swift", "PaiGlanceStore.swift", "PaiUsageAlerts.swift"].map((file) => `${root}submodules/PaiGlance/Sources/${file}`);
/** The three files prebuilt_watchos_build.sh copies into the watch snapshot's PaiShared/. */
const watchGlanceSources = glanceSources.filter((path) => !path.endsWith("PaiUsageAlerts.swift"));

const sdk = async (name: string) => (await $`xcrun --sdk ${name} --show-sdk-path`.quiet().text()).trim();
const glob = (pattern: string) => Array.from(new Bun.Glob(pattern).scanSync({ cwd: root, absolute: true })).sort();

async function check(name: string, args: string[]) {
  const started = Date.now();
  const result = await $`swiftc ${args}`.cwd(root).nothrow().quiet();
  if (result.exitCode !== 0) {
    const stderr = result.stderr.toString();
    console.error(stderr.trim());
    const errors = stderr.split("\n").filter((line) => /(^|: )error: /.test(line)).length;
    throw new Error(`precheck ${name} failed (${errors} error${errors === 1 ? "" : "s"}); fix them before the release build`);
  }
  console.log(`precheck ${name} ok (${((Date.now() - started) / 1000).toFixed(1)}s)`);
}

export async function precheck() {
  const modules = mkdtempSync(`${tmpdir()}/paigram-precheck-`);
  try {
    const iphoneos = await sdk("iphoneos");
    // The widget imports PaiGlance, so the module is built first and the widget checked against it.
    await check("PaiGlance (iOS 15)", ["-emit-module", "-sdk", iphoneos, "-target", iosTarget, "-module-name", "PaiGlance", "-emit-module-path", `${modules}/PaiGlance.swiftmodule`, "-parse-as-library", ...glanceSources]);
    await check("widget (iOS 15)", ["-typecheck", "-sdk", iphoneos, "-target", iosTarget, "-I", modules, "-parse-as-library", `${root}Telegram/WidgetKitWidget/PaiUsageWidget.swift`]);
    const watchos = await sdk("watchos");
    await check("watch complications (watchOS 26)", ["-typecheck", "-sdk", watchos, "-target", watchTarget, "-parse-as-library", ...glob("Telegram/WatchApp/PaiComplications/*.swift"), ...glob("Telegram/WatchApp/PaiShared/*.swift"), ...watchGlanceSources]);
  } finally {
    rmSync(modules, { recursive: true, force: true });
  }
}

if (import.meta.main) await precheck();
