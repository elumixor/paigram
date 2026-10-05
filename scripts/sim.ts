/**
 * `bun run sim [--no-build] [--extensions]`: build Paigram for the simulator, install it on a booted (or the first
 * available) iPhone, launch it. Uses the repo's fake codesigning, so the bundle id is Telegram's.
 * Extensions (share, notifications, widget, intents) are left out unless `--extensions`: they add minutes to every build.
 */
import { $ } from "bun";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { writeSecrets } from "./secrets.ts";
import { root } from "./repo.ts";

const config = `${root}build-system/paigram-sim.json`;
const bundleId = "ph.telegra.Telegraph";
const skipBuild = process.argv.includes("--no-build");
const extensions = process.argv.includes("--extensions") ? "False" : "True";

if (!(await Bun.file(config).exists())) throw new Error(`${config} is missing: copy build-system/paigram.example.json and fill in the api keys`);

/**
 * Bazel gets one fixed build number, so a changed define does not invalidate every action; the
 * simulator keeps an installed app whose version has not changed, so the unzipped copy gets a fresh one.
 */
const buildNumber = 100002;
const installedVersion = Math.floor(Date.now() / 60_000);

if (!skipBuild) {
  await writeSecrets();
  await $`python3 build-system/Make/Make.py --overrideXcodeVersion --cacheDir=${process.env.HOME}/telegram-bazel-cache --bazelArguments=--//Telegram:disableExtensions=${extensions} build --configurationPath=${config} --codesigningInformationPath=build-system/fake-codesigning --buildNumber=${buildNumber} --configuration=debug_sim_arm64`.cwd(root);
}

const devices = (await $`xcrun simctl list devices available -j`.json()) as { devices: Record<string, { udid: string; name: string; state: string }[]> };
/** Newest runtime first, so two simulators with the same name do not get mixed up. */
const iphones = Object.entries(devices.devices)
  .sort(([a], [b]) => b.localeCompare(a, undefined, { numeric: true }))
  .flatMap(([, list]) => list)
  .filter((d) => d.name.startsWith("iPhone"));
const device = iphones.find((d) => d.state === "Booted") ?? iphones[0];
if (!device) throw new Error("no iPhone simulator available");

const dir = mkdtempSync(`${tmpdir()}/paigram-`);
await $`unzip -q ${root}bazel-bin/Telegram/Telegram.ipa -d ${dir}`;
await $`plutil -replace CFBundleVersion -string ${String(installedVersion)} ${dir}/Payload/Telegram.app/Info.plist`;
if (device.state !== "Booted") await $`xcrun simctl boot ${device.udid}`;
await $`open -a Simulator`;
await $`xcrun simctl bootstatus ${device.udid} -b`.quiet();
await $`xcrun simctl terminate ${device.udid} ${bundleId}`.nothrow().quiet();
await $`xcrun simctl install ${device.udid} ${dir}/Payload/Telegram.app`;
await $`xcrun simctl launch ${device.udid} ${bundleId}`;
console.log(`Paigram running on ${device.name} (${device.udid})`);
