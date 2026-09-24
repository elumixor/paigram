/**
 * `bun run sim [--no-build]`: build Paigram for the simulator, install it on a booted (or the first
 * available) iPhone, launch it. Uses the repo's fake codesigning, so the bundle id is Telegram's.
 */
import { $ } from "bun";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";

const root = new URL("..", import.meta.url).pathname;
const config = `${root}build-system/paigram-sim.json`;
const bundleId = "ph.telegra.Telegraph";
const skipBuild = process.argv.includes("--no-build");

if (!(await Bun.file(config).exists())) throw new Error(`${config} is missing: copy build-system/paigram.example.json and fill in the api keys`);

if (!skipBuild) {
  await $`python3 build-system/Make/Make.py --overrideXcodeVersion --cacheDir=${process.env.HOME}/telegram-bazel-cache --bazelArguments=--//Telegram:disableExtensions=True build --configurationPath=${config} --codesigningInformationPath=build-system/fake-codesigning --buildNumber=100002 --configuration=debug_sim_arm64`.cwd(root);
}

const devices = (await $`xcrun simctl list devices available -j`.json()) as { devices: Record<string, { udid: string; name: string; state: string }[]> };
const iphones = Object.values(devices.devices)
  .flat()
  .filter((d) => d.name.startsWith("iPhone"));
const device = iphones.find((d) => d.state === "Booted") ?? iphones[0];
if (!device) throw new Error("no iPhone simulator available");

const dir = mkdtempSync(`${tmpdir()}/paigram-`);
await $`unzip -q ${root}bazel-bin/Telegram/Telegram.ipa -d ${dir}`;
if (device.state !== "Booted") await $`xcrun simctl boot ${device.udid}`;
await $`open -a Simulator`;
await $`xcrun simctl bootstatus ${device.udid} -b`.quiet();
await $`xcrun simctl install ${device.udid} ${dir}/Payload/Telegram.app`;
await $`xcrun simctl launch ${device.udid} ${bundleId}`;
console.log(`Paigram running on ${device.name}`);
