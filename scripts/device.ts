/**
 * `bun run device [--no-build] [--device <name|udid>]`: the release build TestFlight ships, signed Ad Hoc
 * instead, installed straight on an iPhone over USB or Wi-Fi and launched, and its watch app on the Apple
 * Watch paired with this Mac, when there is one (Developer Mode on the watch). No upload, no processing,
 * no version bump. The iPhone has to be paired with this Mac once by cable (`xcrun devicectl manage pair`,
 * Developer Mode on; `pymobiledevice3 lockdown set True com.apple.mobile.wireless_lockdown EnableWifiDebugging`
 * for Wi-Fi). The first time a device is used it is registered on the account and the Ad Hoc profiles are made
 * again to include it.
 */
import { $ } from "bun";
import { mkdtempSync } from "node:fs";
import { hostname, tmpdir } from "node:os";
import { ascGet, ascPost } from "./asc.ts";
import { missingEntitlements } from "./entitlements.ts";
import { type Device, matches, pairedDevices } from "./devices.ts";
import { precheck } from "./precheck.ts";
import { provision, readProfile } from "./provision.ts";
import { releaseBuild } from "./release-build.ts";
import { adHocCodesigningPath, configPath as config, root } from "./repo.ts";

class DeviceError extends Error {}

/** TestFlight's first build of a version has number 1 too, so the two builds share Bazel's cache. */
const buildNumber = 1;
const day = 86_400_000;
const connectAttempts = 4;
const connectRetryMs = 3_000;
const waitRetryMs = 5_000;
const waitLimitMs = 10 * 60_000;

const skipBuild = process.argv.includes("--no-build");
const deviceArgument = process.argv.indexOf("--device");
const wanted = deviceArgument > 0 ? process.argv[deviceArgument + 1] : undefined;
const { bundle_id: bundleId } = (await Bun.file(config).json()) as { bundle_id: string };

async function paired(type: string): Promise<Device[]> {
  const output = `${mkdtempSync(`${tmpdir()}/paigram-devices-`)}/devices.json`;
  await $`xcrun devicectl list devices --json-output ${output}`.quiet();
  return pairedDevices(await Bun.file(output).json(), type);
}

async function pickDevice(): Promise<Device> {
  const device = (await paired("iPhone")).find((d) => matches(d, wanted));
  if (device) return device;
  throw new DeviceError(wanted ? `no paired iPhone named ${wanted}` : "no iPhone is paired with this Mac: connect it by cable once and tap Trust");
}

/**
 * Stops before the long build when the iPhone is connected to another Mac: paired with several Macs, it shows up
 * here too, but only the one it is next to can install. A locked iPhone that answers is still here.
 */
async function ensureHere(device: Device) {
  if (device.reachable) return;
  const attempt = await connect(device);
  if (attempt.ok || blocker(attempt.output) === "locked") return;
  throw new DeviceError(`${device.name} is not connected to this Mac (${hostname()}): run on the Mac it is next to, or plug it in here`);
}

/** Registers a device on the account when it is new there; Ad Hoc profiles only install on registered devices. */
async function ensureRegistered(device: Device): Promise<boolean> {
  if ((await ascGet(`/devices?filter[udid]=${device.udid}`)).data.length) return false;
  await ascPost("/devices", { data: { type: "devices", attributes: { name: device.name, udid: device.udid, platform: "IOS" } } });
  console.log(`registered ${device.name} (${device.udid})`);
  return true;
}

/** Whether a profile installs on the iPhone for at least another day. */
async function covers(profilePath: string, device: Device): Promise<boolean> {
  if (!(await Bun.file(profilePath).exists())) return false;
  const profile = await readProfile(profilePath);
  return Boolean(profile.ProvisionedDevices?.includes(device.udid)) && new Date(profile.ExpirationDate).getTime() > Date.now() + day;
}

interface Attempt {
  readonly ok: boolean;
  readonly output: string;
}

/** A Wi-Fi connection that sat idle is often reset on the first try: the tunnel is opened, retrying, before installing. */
async function connect(device: Device): Promise<Attempt> {
  let output = "";
  for (let attempt = 0; attempt < connectAttempts; attempt++) {
    const result = await $`xcrun devicectl device info details --device ${device.udid}`.nothrow().quiet();
    if (result.exitCode === 0) return { ok: true, output: "" };
    output = `${result.stdout}${result.stderr}`;
    await Bun.sleep(connectRetryMs);
  }
  return { ok: false, output };
}

/** Wi-Fi can drop in the middle of the copy too: the tunnel is opened again and the copy retried. */
async function copyApp(device: Device, app: string): Promise<Attempt> {
  let output = "";
  for (let attempt = 0; attempt < connectAttempts; attempt++) {
    const result = await $`xcrun devicectl device install app --device ${device.udid} ${app}`.nothrow().quiet();
    if (result.exitCode === 0) return { ok: true, output: "" };
    output = `${result.stdout}${result.stderr}`;
    process.stderr.write(output);
    const connected = await connect(device);
    if (!connected.ok) return connected;
  }
  return { ok: false, output };
}

type Blocker = "locked" | "unreachable";

function blocker(output: string): Blocker | undefined {
  if (/DeviceLocked|0xe80000e2|device is locked/i.test(output)) return "locked";
  if (/not reachable|CoreDevice[^\n]*1011|error 1011|Code=1011/i.test(output)) return "unreachable";
  return undefined;
}

/** Repeats a step while the device is locked or out of reach, up to ten minutes, saying once what it waits for. */
async function waitFor(device: Device, step: () => Promise<Attempt>): Promise<Attempt> {
  const deadline = Date.now() + waitLimitMs;
  let announced: Blocker | undefined;
  for (;;) {
    const attempt = await step();
    const reason = attempt.ok ? undefined : blocker(attempt.output);
    if (!reason) return attempt;
    if (Date.now() > deadline) {
      throw new DeviceError(reason === "locked" ? `${device.name} stayed locked: unlock it and Retry` : `${device.name} stayed unreachable: plug it in or join this Mac's Wi-Fi, then Retry`);
    }
    if (announced !== reason) console.log(reason === "locked" ? `${device.name} is locked: unlock it, waiting…` : `${device.name} is not reachable: plug it in or unlock it on this Mac's Wi-Fi, waiting…`);
    announced = reason;
    await Bun.sleep(waitRetryMs);
  }
}

/** The watch app goes straight onto the watch; without Developer Mode there it is left to the iPhone's Watch app. */
async function installWatch(watch: Device, app: string) {
  const watchApp = `${app}/Watch/tgwatch Watch App.app`;
  if (!(await Bun.file(`${watchApp}/Info.plist`).exists())) return console.log("the build has no watch app");
  if (!(await covers(`${watchApp}/embedded.mobileprovision`, watch))) return console.log(`the watch app is not signed for ${watch.name}: run without --no-build`);
  if ((await copyApp(watch, watchApp)).ok) return console.log(`watch app installed on ${watch.name}`);
  console.log(
    `could not install on ${watch.name}: unlock it, with Developer Mode on (Settings > Privacy & Security), ` +
      `or install it from the iPhone's Watch app > Available Apps`,
  );
}

async function install(device: Device, watch: Device | undefined) {
  const dir = mkdtempSync(`${tmpdir()}/paigram-device-`);
  await $`unzip -q ${root}bazel-bin/Telegram/Telegram.ipa -d ${dir}`;
  const app = `${dir}/Payload/Telegram.app`;
  if (!(await covers(`${app}/embedded.mobileprovision`, device))) {
    throw new DeviceError(`the last build is not signed for ${device.name} (a TestFlight build, or before it was registered): run without --no-build`);
  }
  if (!(await waitFor(device, () => connect(device))).ok) throw new DeviceError(`${device.name} is not reachable: plug it in, or unlock it on this Mac's Wi-Fi, then run with --no-build`);
  if (!(await waitFor(device, () => copyApp(device, app))).ok) throw new DeviceError(`install on ${device.name} failed`);
  const launched = await $`xcrun devicectl device process launch --device ${device.udid} --terminate-existing ${bundleId}`.nothrow().quiet();
  console.log(launched.exitCode === 0 ? `Paigram running on ${device.name}` : `Paigram installed on ${device.name}; it is locked, so open it there`);
  if (watch) await installWatch(watch, app);
}

const device = await pickDevice();
await ensureHere(device);
const [watch] = await paired("appleWatch");
if (!skipBuild) {
  await precheck();
  const registered = (await Promise.all([device, ...(watch ? [watch] : [])].map(ensureRegistered))).some(Boolean);
  const profiles = `${adHocCodesigningPath}/profiles`;
  const stale = !(await covers(`${profiles}/Telegram.mobileprovision`, device)) || (watch !== undefined && !(await covers(`${profiles}/WatchApp.mobileprovision`, watch)));
  const granted = (await readProfile(`${profiles}/Telegram.mobileprovision`).catch(() => undefined))?.Entitlements;
  if (registered || stale || missingEntitlements(granted).length) await provision("adHoc");
  await releaseBuild(adHocCodesigningPath, buildNumber, watch !== undefined);
}
await install(device, watch);
