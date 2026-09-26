/**
 * `bun run testflight [--no-build] [--no-upload] [--minor]`: a patch (or minor) version bump committed to versions.json, fresh App Store provisioning profiles for the
 * app, its extensions and the watch app (scripts/provision.ts), a release build for devices with
 * every extension and the watch app embedded, the ipa uploaded to App Store Connect, then a wait until
 * TestFlight has processed it. Needs `.env` (ASC_KEY_ID, ASC_ISSUER_ID, TEAM_ID) and
 * `build-system/paigram.json`.
 */
import { $ } from "bun";
import { asc, ascGet } from "./asc.ts";
import { provision } from "./provision.ts";
import { writeSecrets } from "./secrets.ts";

const root = new URL("..", import.meta.url).pathname;
const config = `${root}build-system/paigram.json`;
const codesigning = `${root}build-system/paigram-codesigning`;
const skipBuild = process.argv.includes("--no-build");
const skipUpload = process.argv.includes("--no-upload");

const { bundle_id: bundleId, api_id: apiId, api_hash: apiHash } = (await Bun.file(config).json()) as { bundle_id: string; api_id: string; api_hash: string };

/** Build numbers must only go up; the minute of the upload is unique enough for one person. */
function buildNumber(): number {
  const d = new Date();
  const pad = (n: number) => String(n).padStart(2, "0");
  return Number(`${d.getUTCFullYear()}${pad(d.getUTCMonth() + 1)}${pad(d.getUTCDate())}${pad(d.getUTCHours())}${pad(d.getUTCMinutes())}`);
}

async function build(number: number) {
  await writeSecrets();
  await $`python3 build-system/Make/Make.py --overrideXcodeVersion --cacheDir=${process.env.HOME}/telegram-bazel-cache build --configurationPath=${config} --codesigningInformationPath=${codesigning} --buildNumber=${number} --configuration=release_arm64 --embedWatchApp --watchApiId=${apiId} --watchApiHash=${apiHash}`.cwd(root);
}

async function upload() {
  await $`xcrun altool --upload-app -f ${root}bazel-bin/Telegram/Telegram.ipa -t ios --apiKey ${asc.keyId} --apiIssuer ${asc.issuerId}`;
}

async function waitProcessed(number: number) {
  const app = (await ascGet(`/apps?filter[bundleId]=${bundleId}`)).data[0];
  if (!app) throw new Error(`no App Store Connect app for ${bundleId}; create it once at appstoreconnect.apple.com`);
  for (let i = 0; i < 60; i++) {
    const builds = (await ascGet(`/builds?filter[app]=${app.id}&filter[version]=${number}&limit=1`)).data;
    const state = builds[0]?.attributes.processingState;
    if (state === "VALID") return builds[0];
    if (state === "FAILED" || state === "INVALID") throw new Error(`build ${number} ${state}`);
    console.log(`waiting for TestFlight processing (${state ?? "not yet listed"})…`);
    await Bun.sleep(30_000);
  }
  throw new Error("TestFlight did not finish processing in 30 minutes");
}

/** Every upload is a new patch version (`--minor` bumps the minor), recorded in versions.json and committed, so TestFlight tells builds apart. */
async function bumpVersion() {
  const file = Bun.file(`${root}versions.json`);
  const versions = await file.json();
  const [major, minor, patch] = String(versions.app).split(".").map(Number);
  versions.app = process.argv.includes("--minor") ? `${major}.${minor + 1}.0` : `${major}.${minor}.${patch + 1}`;
  await Bun.write(file, `${JSON.stringify(versions, null, 4)}\n`);
  await $`git commit -qm ${`Paigram v${versions.app}`} -- versions.json`.cwd(root);
  console.log(`version ${versions.app}`);
  return versions.app as string;
}

const number = buildNumber();
await provision();
const version = skipBuild ? (await Bun.file(`${root}versions.json`).json()).app : await bumpVersion();
if (!skipBuild) await build(number);
if (!skipUpload) {
  await upload();
  const build = await waitProcessed(number);
  console.log(`v${version} build ${number} is on TestFlight (${build.id})`);
}
