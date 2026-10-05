/**
 * `bun run testflight [--no-build] [--no-upload] [--no-bump] [--minor]`: a patch (or minor) version bump committed to versions.json, fresh App Store provisioning profiles for the
 * app, its extensions and the watch app (scripts/provision.ts), a release build for devices with
 * every extension and the watch app embedded, the ipa uploaded to App Store Connect, then a wait until
 * TestFlight has processed it. Needs `.env` (ASC_KEY_ID, ASC_ISSUER_ID, TEAM_ID) and
 * `build-system/paigram.json`. CI builds a version that is already tagged, so they pass `--no-bump`.
 */
import { $ } from "bun";
import { asc, ascGet } from "./asc.ts";
import { provision } from "./provision.ts";
import { writeSecrets } from "./secrets.ts";
import { bumpVersion, codesigningPath as codesigning, configPath as config, readVersions, root } from "./repo.ts";

const skipBuild = process.argv.includes("--no-build");
const skipUpload = process.argv.includes("--no-upload");
const skipBump = skipBuild || process.argv.includes("--no-bump");

const { bundle_id: bundleId, api_id: apiId, api_hash: apiHash } = (await Bun.file(config).json()) as { bundle_id: string; api_id: string; api_hash: string };

/** Build numbers only have to go up within a version: one past the highest App Store Connect has for it, so a new version starts at 1. */
async function buildNumber(version: string): Promise<number> {
  const app = (await ascGet(`/apps?filter[bundleId]=${bundleId}`)).data[0];
  if (!app) throw new Error(`no App Store Connect app for ${bundleId}; create it once at appstoreconnect.apple.com`);
  const builds = (await ascGet(`/builds?filter[app]=${app.id}&filter[preReleaseVersion.version]=${version}&limit=50`)).data;
  return Math.max(0, ...builds.map((b: any) => Number(b.attributes.version) || 0)) + 1;
}

async function build(number: number) {
  await writeSecrets();
  await $`python3 build-system/Make/Make.py --overrideXcodeVersion --cacheDir=${process.env.HOME}/telegram-bazel-cache build --configurationPath=${config} --codesigningInformationPath=${codesigning} --buildNumber=${number} --configuration=release_arm64 --embedWatchApp --watchApiId=${apiId} --watchApiHash=${apiHash}`.cwd(root);
}

async function upload() {
  await $`xcrun altool --upload-app -f ${root}bazel-bin/Telegram/Telegram.ipa -t ios --apiKey ${asc.keyId} --apiIssuer ${asc.issuerId}`;
}

/** Build numbers restart at 1 for every version, so the build is looked up by both. */
async function waitProcessed(version: string, number: number) {
  const app = (await ascGet(`/apps?filter[bundleId]=${bundleId}`)).data[0];
  if (!app) throw new Error(`no App Store Connect app for ${bundleId}; create it once at appstoreconnect.apple.com`);
  for (let i = 0; i < 60; i++) {
    const builds = (await ascGet(`/builds?filter[app]=${app.id}&filter[version]=${number}&filter[preReleaseVersion.version]=${version}&limit=1`)).data;
    const state = builds[0]?.attributes.processingState;
    if (state === "VALID") return builds[0];
    if (state === "FAILED" || state === "INVALID") throw new Error(`build ${number} ${state}`);
    console.log(`waiting for TestFlight processing (${state ?? "not yet listed"})…`);
    await Bun.sleep(30_000);
  }
  throw new Error("TestFlight did not finish processing in 30 minutes");
}

/** `--no-build` uploads the ipa as it is: its build number is read back, and the profiles it embeds stay untouched. */
const version = skipBump ? (await readVersions()).app : await bumpVersion(process.argv.includes("--minor"));
const number = skipBuild ? Number(await $`unzip -p ${root}bazel-bin/Telegram/Telegram.ipa Payload/Telegram.app/Info.plist | plutil -extract CFBundleVersion raw -o - -`.text()) : await buildNumber(version);
if (!skipBuild) {
  await provision();
  await build(number);
}
if (!skipUpload) {
  await upload();
  const build = await waitProcessed(version, number);
  console.log(`v${version} build ${number} is on TestFlight (${build.id})`);
}
