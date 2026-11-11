/**
 * Everything a signed build needs from App Store Connect: the bundle ids of the app, its extensions
 * and the watch app registered with their capabilities, and a fresh provisioning profile for each,
 * written under the names Telegram's build expects. App Store profiles go to
 * `build-input/paigram-codesigning/profiles/` for TestFlight; Ad Hoc ones, which install on the
 * registered iPhones directly, go to `build-input/paigram-codesigning-adhoc/profiles/` and leave the
 * watch app out. Both are signed with the Distribution certificate, so push stays on production APNs.
 * App groups cannot be attached through the API, so each extension's profile is checked for the group
 * and the portal link is printed when it is missing.
 * `bun run scripts/provision.ts` runs it alone; `bun run testflight` and `bun run device` run it first.
 */
import { mkdirSync } from "node:fs";
import { asc, ascDelete, ascGet, ascPost } from "./asc.ts";
import { adHocCodesigningPath, codesigningPath, configPath as config } from "./repo.ts";

const { bundle_id: bundleId, team_id: teamId, enable_siri: siri } = (await Bun.file(config).json()) as { bundle_id: string; team_id: string; enable_siri: boolean };
if (teamId !== asc.teamId) throw new Error(`team_id in paigram.json (${teamId}) differs from TEAM_ID in .env (${asc.teamId})`);

const appGroup = `group.${bundleId}`;
/** Lets the notification service show the sender's photo; the API cannot enable it, only the portal. */
const communication = "com.apple.developer.usernotifications.communication";

/** Bundle id suffix, the profile file name Telegram's build expects (BuildConfiguration.py), the capabilities. */
const targets: { suffix: string; file: string; name: string; capabilities: string[]; group: boolean; watch?: boolean }[] = [
  { suffix: "", file: "Telegram", name: "Paigram", capabilities: ["PUSH_NOTIFICATIONS", "APP_GROUPS", ...(siri ? ["SIRIKIT"] : [])], group: true },
  { suffix: ".Share", file: "Share", name: "Paigram Share", capabilities: ["APP_GROUPS"], group: true },
  { suffix: ".NotificationContent", file: "NotificationContent", name: "Paigram Notification Content", capabilities: ["APP_GROUPS"], group: true },
  { suffix: ".NotificationService", file: "NotificationService", name: "Paigram Notification Service", capabilities: ["APP_GROUPS"], group: true },
  { suffix: ".SiriIntents", file: "Intents", name: "Paigram Intents", capabilities: ["APP_GROUPS"], group: true },
  { suffix: ".Widget", file: "Widget", name: "Paigram Widget", capabilities: ["APP_GROUPS"], group: true },
  { suffix: ".BroadcastUpload", file: "BroadcastUpload", name: "Paigram Broadcast Upload", capabilities: ["APP_GROUPS"], group: true },
  { suffix: ".watchkitapp", file: "WatchApp", name: "Paigram Watch", capabilities: [], group: false, watch: true },
  { suffix: ".watchkitapp.widget", file: "WatchWidget", name: "Paigram Watch Complications", capabilities: [], group: false, watch: true },
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

export type ProfileKind = "appStore" | "adHoc";

const kinds = {
  appStore: { label: "App Store", type: "IOS_APP_STORE", dir: codesigningPath },
  adHoc: { label: "Ad Hoc", type: "IOS_APP_ADHOC", dir: adHocCodesigningPath },
} as const;

/** Ad Hoc profiles carry every enabled iPhone and iPad on the account: those are the devices they install on. */
async function iosDevices(): Promise<{ type: "devices"; id: string }[]> {
  return (await ascGet("/devices?filter[platform]=IOS&filter[status]=ENABLED&limit=200")).data
    .filter((d: any) => d.attributes.deviceClass === "IPHONE" || d.attributes.deviceClass === "IPAD")
    .map((d: any) => ({ type: "devices", id: d.id }));
}

async function freshProfile(bundle: any, name: string, cert: any, kind: ProfileKind, devices: { type: "devices"; id: string }[]): Promise<Buffer> {
  const profileName = `${name} ${kinds[kind].label}`;
  for (const old of (await ascGet(`/profiles?filter[name]=${encodeURIComponent(profileName)}`)).data) await ascDelete(`/profiles/${old.id}`);
  const profile = await ascPost("/profiles", {
    data: {
      type: "profiles",
      attributes: { name: profileName, profileType: kinds[kind].type },
      relationships: {
        bundleId: { data: { type: "bundleIds", id: bundle.id } },
        certificates: { data: [{ type: "certificates", id: cert.id }] },
        ...(kind === "adHoc" ? { devices: { data: devices } } : {}),
      },
    },
  });
  return Buffer.from(profile.data.attributes.profileContent, "base64");
}

/** A profile's plist as JSON: dates as ISO strings, data as hex. */
export async function readProfile(path: string): Promise<Record<string, any>> {
  const plist = await Bun.$`security cms -D -i ${path}`.arrayBuffer();
  const script = "import sys,plistlib,json; print(json.dumps(plistlib.loads(sys.stdin.buffer.read()), default=lambda o: o.isoformat() if hasattr(o, 'isoformat') else o.hex()))";
  const json = await Bun.$`python3 -c ${script} < ${new Blob([plist])}`.text();
  return JSON.parse(json);
}

/** The entitlements Apple baked into a profile. */
const entitlements = async (path: string): Promise<Record<string, unknown>> => (await readProfile(path)).Entitlements;

export async function provision(kind: ProfileKind = "appStore") {
  const { dir } = kinds[kind];
  mkdirSync(`${dir}/profiles`, { recursive: true });
  mkdirSync(`${dir}/certs`, { recursive: true });
  const cert = await distributionCertificate();
  const devices = kind === "adHoc" ? await iosDevices() : [];
  const missingGroup: string[] = [];
  let missingCommunication = false;
  for (const target of targets.filter((t) => kind === "appStore" || !t.watch)) {
    const identifier = bundleId + target.suffix;
    const bundle = await ensureBundleId(identifier, target.name);
    await ensureCapabilities(bundle, target.capabilities);
    const path = `${dir}/profiles/${target.file}.mobileprovision`;
    await Bun.write(path, await freshProfile(bundle, target.name, cert, kind, devices));
    const granted = await entitlements(path);
    const groups = granted["com.apple.security.application-groups"] as string[] | undefined;
    if (target.group && !groups?.includes(appGroup)) missingGroup.push(identifier);
    if (target.suffix === "" && !granted[communication]) missingCommunication = true;
    console.log(`profile ${target.file} (${identifier}) written`);
  }
  if (missingGroup.length) {
    throw new Error(
      `app group ${appGroup} is not attached to: ${missingGroup.join(", ")}.\n` +
        `The API cannot do it: open https://developer.apple.com/account/resources/identifiers/list, ` +
        `edit each id, App Groups → Configure → tick ${appGroup}, then run again.`,
    );
  }
  if (missingCommunication) {
    throw new Error(
      `${bundleId} lacks Communication Notifications, which notifications need to show the sender's photo.\n` +
        `The API cannot enable it: open https://developer.apple.com/account/resources/identifiers/list, ` +
        `edit ${bundleId}, tick Communication Notifications, save, then run again.`,
    );
  }
}

if (import.meta.main) await provision(process.argv.includes("--ad-hoc") ? "adHoc" : "appStore");
