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
import { tmpdir } from "node:os";
import { ascGet, ascPost } from "./asc.ts";
import { precheck } from "./precheck.ts";
import { provision, readProfile } from "./provision.ts";
import { releaseBuild } from "./release-build.ts";
import { adHocCodesigningPath, configPath as config, root } from "./repo.ts";

class DeviceError extends Error {}

interface Device {
  readonly name: string;
  readonly udid: string;
}

/** TestFlight's first build of a version has number 1 too, so the two builds share Bazel's cache. */
const buildNumber = 1;
const day = 86_400_000;
const connectAttempts = 4;
const connectRetryMs = 3_000;

const skipBuild = process.argv.includes("--no-build");
const deviceArgument = process.argv.indexOf("--device");
const wanted = deviceArgument > 0 ? process.argv[deviceArgument + 1] : undefined;
const { bundle_id: bundleId } = (await Bun.file(config).json()) as { bundle_id: string };

/** Paired devices of a type (`iPhone`, `appleWatch`), the ones reachable right now (by cable or on the network) first. */
async function paired(type: string): Promise<Device[]> {
  const output = `${mkdtempSync(`${tmpdir()}/paigram-devices-`)}/devices.json`;
  await $`xcrun devicectl list devices --json-output ${output}`.quiet();
  const { result } = await Bun.file(output).json();
  return result.devices
    .filter((d: any) => d.hardwareProperties.deviceType === type && d.connectionProperties.pairingState === "paired")
    .sort((a: any, b: any) => Number(b.connectionProperties.transportType != null) - Number(a.connectionProperties.transportType != null))
    .map((d: any) => ({ name: d.deviceProperties.name, udid: d.hardwareProperties.udid }));
}

async function pickDevice(): Promise<Device> {
  const device = (await paired("iPhone")).find((d) => !wanted || d.name === wanted || d.udid === wanted);
  if (device) return device;
  throw new DeviceError(wanted ? `no paired iPhone named ${wanted}` : "no iPhone is paired with this Mac: connect it by cable once and tap Trust");
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

/** A Wi-Fi connection that sat idle is often reset on the first try: the tunnel is opened, retrying, before installing. */
async function connect(device: Device): Promise<boolean> {
  for (let attempt = 0; attempt < connectAttempts; attempt++) {
    if ((await $`xcrun devicectl device info details --device ${device.udid}`.nothrow().quiet()).exitCode === 0) return true;
    await Bun.sleep(connectRetryMs);
  }
  return false;
}

/** Wi-Fi can drop in the middle of the copy too: the tunnel is opened again and the copy retried. */
async function copyApp(device: Device, app: string): Promise<boolean> {
  for (let attempt = 0; attempt < connectAttempts; attempt++) {
    if ((await $`xcrun devicectl device install app --device ${device.udid} ${app}`.nothrow()).exitCode === 0) return true;
    if (!(await connect(device))) return false;
  }
  return false;
}

/** The watch app goes straight onto the watch; without Developer Mode there it is left to the iPhone's Watch app. */
async function installWatch(watch: Device, app: string) {
  const watchApp = `${app}/Watch/tgwatch Watch App.app`;
  if (!(await Bun.file(`${watchApp}/Info.plist`).exists())) return console.log("the build has no watch app");
  if (!(await covers(`${watchApp}/embedded.mobileprovision`, watch))) return console.log(`the watch app is not signed for ${watch.name}: run without --no-build`);
  if (await copyApp(watch, watchApp)) return console.log(`watch app installed on ${watch.name}`);
  console.log(
    `could not install on ${watch.name}: turn on Developer Mode there (Settings > Privacy & Security), ` +
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
  if (!(await connect(device))) throw new DeviceError(`${device.name} is not reachable: plug it in, or unlock it on this Mac's Wi-Fi, then run with --no-build`);
  if (!(await copyApp(device, app))) throw new DeviceError(`install on ${device.name} failed`);
  const launched = await $`xcrun devicectl device process launch --device ${device.udid} --terminate-existing ${bundleId}`.nothrow().quiet();
  console.log(launched.exitCode === 0 ? `Paigram running on ${device.name}` : `Paigram installed on ${device.name}; it is locked, so open it there`);
  if (watch) await installWatch(watch, app);
}

const device = await pickDevice();
const [watch] = await paired("appleWatch");
if (!skipBuild) {
  await precheck();
  const registered = (await Promise.all([device, ...(watch ? [watch] : [])].map(ensureRegistered))).some(Boolean);
  const profiles = `${adHocCodesigningPath}/profiles`;
  const stale = !(await covers(`${profiles}/Telegram.mobileprovision`, device)) || (watch !== undefined && !(await covers(`${profiles}/WatchApp.mobileprovision`, watch)));
  if (registered || stale) await provision("adHoc");
  await releaseBuild(adHocCodesigningPath, buildNumber, watch !== undefined);
}
await install(device, watch);
