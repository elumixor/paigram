/**
 * Everything the App Store build needs from App Store Connect: the bundle ids of the app, its
 * extensions and the watch app registered with their capabilities, and a fresh App Store
 * provisioning profile for each, written to `build-system/paigram-codesigning/profiles/` under the
 * names Telegram's build expects. App groups cannot be attached through the API, so each extension's
 * profile is checked for the group and the portal link is printed when it is missing.
 * `bun run scripts/provision.ts` runs it alone; `bun run testflight` runs it first.
 */
import { mkdirSync } from "node:fs";
import { asc, ascDelete, ascGet, ascPost } from "./asc.ts";
import { codesigningPath as codesigning, configPath as config } from "./repo.ts";

const { bundle_id: bundleId, team_id: teamId, enable_siri: siri } = (await Bun.file(config).json()) as { bundle_id: string; team_id: string; enable_siri: boolean };
if (teamId !== asc.teamId) throw new Error(`team_id in paigram.json (${teamId}) differs from TEAM_ID in .env (${asc.teamId})`);

const appGroup = `group.${bundleId}`;

/** Bundle id suffix, the profile file name Telegram's build expects (BuildConfiguration.py), the capabilities. */
const targets: { suffix: string; file: string; name: string; capabilities: string[]; group: boolean }[] = [
  { suffix: "", file: "Telegram", name: "Paigram", capabilities: ["PUSH_NOTIFICATIONS", "APP_GROUPS", ...(siri ? ["SIRIKIT"] : [])], group: true },
  { suffix: ".Share", file: "Share", name: "Paigram Share", capabilities: ["APP_GROUPS"], group: true },
  { suffix: ".NotificationContent", file: "NotificationContent", name: "Paigram Notification Content", capabilities: ["APP_GROUPS"], group: true },
  { suffix: ".NotificationService", file: "NotificationService", name: "Paigram Notification Service", capabilities: ["APP_GROUPS"], group: true },
  { suffix: ".SiriIntents", file: "Intents", name: "Paigram Intents", capabilities: ["APP_GROUPS"], group: true },
  { suffix: ".Widget", file: "Widget", name: "Paigram Widget", capabilities: ["APP_GROUPS"], group: true },
  { suffix: ".BroadcastUpload", file: "BroadcastUpload", name: "Paigram Broadcast Upload", capabilities: ["APP_GROUPS"], group: true },
  { suffix: ".watchkitapp", file: "WatchApp", name: "Paigram Watch", capabilities: [], group: false },
];

async function ensureBundleId(identifier: string, name: string): Promise<any> {
  const existing = (await ascGet(`/bundleIds?filter[identifier]=${identifier}&limit=50`)).data.find((b: any) => b.attributes.identifier === identifier);
  if (existing) return existing;
  const created = await ascPost("/bundleIds", { data: { type: "bundleIds", attributes: { identifier, name, platform: "IOS" } } });
  console.log(`registered ${identifier}`);
  return created.data;
}

async function ensureCapabilities(bundle: any, wanted: string[]) {
  const have = new Set((await ascGet(`/bundleIds/${bundle.id}/bundleIdCapabilities`)).data.map((c: any) => c.attributes.capabilityType));
  for (const capabilityType of wanted) {
    if (have.has(capabilityType)) continue;
    await ascPost("/bundleIdCapabilities", {
      data: { type: "bundleIdCapabilities", attributes: { capabilityType }, relationships: { bundleId: { data: { type: "bundleIds", id: bundle.id } } } },
    });
    console.log(`${bundle.attributes.identifier}: enabled ${capabilityType}`);
  }
}

async function distributionCertificate(): Promise<any> {
  const certs = (await ascGet("/certificates?filter[certificateType]=DISTRIBUTION&limit=50")).data
    .filter((c: any) => new Date(c.attributes.expirationDate) > new Date())
    .sort((a: any, b: any) => b.attributes.expirationDate.localeCompare(a.attributes.expirationDate));
  if (!certs.length) throw new Error("no unexpired Distribution certificate on the account");
  return certs[0];
}

async function freshProfile(bundle: any, name: string, cert: any): Promise<Buffer> {
  const profileName = `${name} App Store`;
  for (const old of (await ascGet(`/profiles?filter[name]=${encodeURIComponent(profileName)}`)).data) await ascDelete(`/profiles/${old.id}`);
  const profile = await ascPost("/profiles", {
    data: {
      type: "profiles",
      attributes: { name: profileName, profileType: "IOS_APP_STORE" },
      relationships: {
        bundleId: { data: { type: "bundleIds", id: bundle.id } },
        certificates: { data: [{ type: "certificates", id: cert.id }] },
      },
    },
  });
  return Buffer.from(profile.data.attributes.profileContent, "base64");
}

/** The entitlements Apple baked into a profile. */
async function entitlements(path: string): Promise<Record<string, unknown>> {
  const plist = await Bun.$`security cms -D -i ${path}`.arrayBuffer();
  const json = await Bun.$`python3 -c ${"import sys,plistlib,json; print(json.dumps(plistlib.loads(sys.stdin.buffer.read())['Entitlements']))"} < ${new Blob([plist])}`.text();
  return JSON.parse(json);
}

export async function provision() {
  mkdirSync(`${codesigning}/profiles`, { recursive: true });
  mkdirSync(`${codesigning}/certs`, { recursive: true });
  const cert = await distributionCertificate();
  const missingGroup: string[] = [];
  for (const target of targets) {
    const identifier = bundleId + target.suffix;
    const bundle = await ensureBundleId(identifier, target.name);
    await ensureCapabilities(bundle, target.capabilities);
    const path = `${codesigning}/profiles/${target.file}.mobileprovision`;
    await Bun.write(path, await freshProfile(bundle, target.name, cert));
    const groups = (await entitlements(path))["com.apple.security.application-groups"] as string[] | undefined;
    if (target.group && !groups?.includes(appGroup)) missingGroup.push(identifier);
    console.log(`profile ${target.file} (${identifier}) written`);
  }
  if (missingGroup.length) {
    throw new Error(
      `app group ${appGroup} is not attached to: ${missingGroup.join(", ")}.\n` +
        `The API cannot do it: open https://developer.apple.com/account/resources/identifiers/list, ` +
        `edit each id, App Groups → Configure → tick ${appGroup}, then run again.`,
    );
  }
}

if (import.meta.main) await provision();
