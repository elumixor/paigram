/**
 * `bun run testflight [--no-build] [--no-upload] [--no-bump] [--once] [--minor]`: a patch (or minor) version bump committed to versions.json, the swiftc precheck (scripts/precheck.ts), fresh App Store provisioning profiles for the
 * app, its extensions and the watch app (scripts/provision.ts), a release build for devices with
 * every extension and the watch app embedded, the ipa uploaded to App Store Connect, then a wait until
 * TestFlight has processed it. Needs `.env` (ASC_KEY_ID, ASC_ISSUER_ID, TEAM_ID) and
 * `build-system/paigram.json`. CI builds a version that is already tagged, so they pass `--no-bump`.
 */
import { tmpdir } from "node:os";
import { $ } from "bun";
import { asc, ascGet } from "./asc.ts";
import { precheck } from "./precheck.ts";
import { provision, readProfile } from "./provision.ts";
import { releaseBuild } from "./release-build.ts";
import { bumpVersion, codesigningPath as codesigning, configPath as config, readVersions, root } from "./repo.ts";

const skipBuild = process.argv.includes("--no-build");
const skipUpload = process.argv.includes("--no-upload");
const skipBump = skipBuild || process.argv.includes("--no-bump");

const { bundle_id: bundleId } = (await Bun.file(config).json()) as { bundle_id: string };
const ipa = `${root}bazel-bin/Telegram/Telegram.ipa`;

/** Build numbers only have to go up within a version: one past the highest App Store Connect has for it, so a new version starts at 1. */
async function buildNumber(version: string): Promise<number> {
  const app = (await ascGet(`/apps?filter[bundleId]=${bundleId}`)).data[0];
  if (!app) throw new Error(`no App Store Connect app for ${bundleId}; create it once at appstoreconnect.apple.com`);
  const builds = (await ascGet(`/builds?filter[app]=${app.id}&filter[preReleaseVersion.version]=${version}&limit=50`)).data;
  return Math.max(0, ...builds.map((b: any) => Number(b.attributes.version) || 0)) + 1;
}

async function upload() {
  await $`xcrun altool --upload-app -f ${ipa} -t ios --apiKey ${asc.keyId} --apiIssuer ${asc.issuerId}`;
}

/**
 * The watch app has to carry its own profile. A file sync that mirrors this tree puts older profiles back
 * while the build runs, and App Store Connect then rejects the upload with an unrelated-looking error 90046.
 */
async function checkWatchProfile() {
  const path = `${tmpdir()}/paigram-watch.mobileprovision`;
  await $`unzip -p ${ipa} ${"Payload/Telegram.app/Watch/tgwatch Watch App.app/embedded.mobileprovision"} > ${path}`;
  const signed = (await readProfile(path)).Entitlements["application-identifier"];
  const expected = `${asc.teamId}.${bundleId}.watchkitapp`;
  if (signed !== expected) throw new Error(`the watch app is signed for ${signed}, not ${expected}: something replaced the profiles under build-input/ during the build`);
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
// A tag builds on two machines at once (this Mac and a GitHub runner); whichever comes second finds it done.
if (process.argv.includes("--once") && (await buildNumber(version)) > 1) {
  console.log(`v${version} is already on TestFlight; nothing to do`);
  process.exit(0);
}
const number = skipBuild ? Number(await $`unzip -p ${ipa} Payload/Telegram.app/Info.plist | plutil -extract CFBundleVersion raw -o - -`.text()) : await buildNumber(version);
if (!skipBuild) {
  await precheck();
  await provision();
  await releaseBuild(codesigning, number, true);
  await checkWatchProfile();
}
if (!skipUpload) {
  await upload();
  const build = await waitProcessed(version, number);
  console.log(`v${version} build ${number} is on TestFlight (${build.id})`);
}
