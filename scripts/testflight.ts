/**
 * `bun run testflight [--no-build] [--no-upload]`: a fresh App Store provisioning profile for the
 * bundle id, a release build for devices, the ipa uploaded to App Store Connect, then a wait until
 * TestFlight has processed it. Needs `.env` (ASC_KEY_ID, ASC_ISSUER_ID, TEAM_ID) and
 * `build-system/paigram.json`.
 */
import { $ } from "bun";
import { mkdirSync } from "node:fs";
import { asc, ascDelete, ascGet, ascPost } from "./asc.ts";

const root = new URL("..", import.meta.url).pathname;
const config = `${root}build-system/paigram.json`;
const codesigning = `${root}build-system/paigram-codesigning`;
const profileName = "Paigram App Store";
const skipBuild = process.argv.includes("--no-build");
const skipUpload = process.argv.includes("--no-upload");

const { bundle_id: bundleId, team_id: teamId } = (await Bun.file(config).json()) as { bundle_id: string; team_id: string };
if (teamId !== asc.teamId) throw new Error(`team_id in paigram.json (${teamId}) differs from TEAM_ID in .env (${asc.teamId})`);

async function freshProfile() {
  const bundle = (await ascGet(`/bundleIds?filter[identifier]=${bundleId}`)).data.find((b: any) => b.attributes.identifier === bundleId);
  if (!bundle) throw new Error(`bundle id ${bundleId} is not registered`);
  const certs = (await ascGet("/certificates?filter[certificateType]=DISTRIBUTION&limit=50")).data
    .filter((c: any) => new Date(c.attributes.expirationDate) > new Date())
    .sort((a: any, b: any) => b.attributes.expirationDate.localeCompare(a.attributes.expirationDate));
  if (!certs.length) throw new Error("no unexpired Distribution certificate on the account");
  for (const old of (await ascGet(`/profiles?filter[name]=${encodeURIComponent(profileName)}`)).data) await ascDelete(`/profiles/${old.id}`);
  const profile = await ascPost("/profiles", {
    data: {
      type: "profiles",
      attributes: { name: profileName, profileType: "IOS_APP_STORE" },
      relationships: {
        bundleId: { data: { type: "bundleIds", id: bundle.id } },
        certificates: { data: [{ type: "certificates", id: certs[0].id }] },
      },
    },
  });
  mkdirSync(`${codesigning}/profiles`, { recursive: true });
  mkdirSync(`${codesigning}/certs`, { recursive: true });
  await Bun.write(`${codesigning}/profiles/Telegram.mobileprovision`, Buffer.from(profile.data.attributes.profileContent, "base64"));
  console.log(`profile ${profileName} written`);
}

/** Build numbers must only go up; the minute of the upload is unique enough for one person. */
function buildNumber(): number {
  const d = new Date();
  const pad = (n: number) => String(n).padStart(2, "0");
  return Number(`${d.getUTCFullYear()}${pad(d.getUTCMonth() + 1)}${pad(d.getUTCDate())}${pad(d.getUTCHours())}${pad(d.getUTCMinutes())}`);
}

async function build(number: number) {
  await $`python3 build-system/Make/Make.py --overrideXcodeVersion --cacheDir=${process.env.HOME}/telegram-bazel-cache --bazelArguments=--//Telegram:disableExtensions=True build --configurationPath=${config} --codesigningInformationPath=${codesigning} --buildNumber=${number} --configuration=release_arm64`.cwd(root);
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

const number = buildNumber();
await freshProfile();
if (!skipBuild) await build(number);
if (!skipUpload) {
  await upload();
  const build = await waitProcessed(number);
  console.log(`build ${number} is on TestFlight (${build.id})`);
}
