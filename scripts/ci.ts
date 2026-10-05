/**
 * `bun scripts/ci.ts`: turns a bare GitHub Actions macOS runner into a machine that can produce a
 * signed App Store build, so the workflow stays a thin wrapper over `bun run testflight`.
 *
 * A developer's Mac needs none of this: the App Store Connect key, the distribution certificate and
 * the api keys already live there. CI gets them as repo secrets instead, so this script checks every
 * one of them up front — a missing secret fails in seconds instead of an hour into Bazel — then
 * writes the key and `build-system/paigram.json`, and imports the distribution certificate into a
 * throwaway keychain that `codesign` can read. The build itself writes `PaiSecrets.swift` from the
 * `PAI_*` secrets, which is why they are checked here too.
 */
import { $ } from "bun";
import { mkdirSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { configPath, exampleConfigPath, readVersions, root } from "./repo.ts";

/** Every repo secret the signed build needs, with what the user has to put in it. */
const required = {
  ASC_KEY_ID: "the App Store Connect API key id",
  ASC_ISSUER_ID: "the App Store Connect issuer id",
  ASC_KEY_P8: "base64 of the AuthKey_<id>.p8 private key",
  TEAM_ID: "the Apple Developer team id",
  DIST_CERT_P12: "base64 of the Apple Distribution certificate exported with its private key (.p12)",
  DIST_CERT_P12_PASSWORD: "the password the .p12 was exported with",
  TELEGRAM_API_ID: "api_id from my.telegram.org",
  TELEGRAM_API_HASH: "api_hash from my.telegram.org",
  PAI_BOX_URL: "the box the app talks to",
  PAI_BOX_TOKEN: "the box's bearer token",
  PAI_BOT_USERNAME: "the box's Telegram bot username, without the @",
} as const;

const keychain = "paigram-ci.keychain";

function env(): Record<keyof typeof required, string> {
  const missing = Object.keys(required).filter((name) => !process.env[name]);
  if (missing.length) {
    throw new Error(
      `missing GitHub repo secret${missing.length > 1 ? "s" : ""}:\n` +
        missing.map((name) => `  ${name} — ${required[name as keyof typeof required]}`).join("\n") +
        `\nAdd them under Settings → Secrets and variables → Actions.`,
    );
  }
  return process.env as Record<keyof typeof required, string>;
}

/** `security` and `altool` both look the key up by id under this exact path. */
async function writeApiKey(keyId: string, p8: string) {
  const directory = `${homedir()}/.appstoreconnect/private_keys`;
  mkdirSync(directory, { recursive: true });
  const pem = p8.includes("BEGIN PRIVATE KEY") ? p8 : Buffer.from(p8, "base64").toString("utf8");
  if (!pem.includes("BEGIN PRIVATE KEY")) throw new Error("ASC_KEY_P8 is neither a PEM private key nor base64 of one");
  await Bun.write(`${directory}/AuthKey_${keyId}.p8`, pem);
}

/** paigram.example.json is the committed source of truth for everything but the api keys and the team. */
async function writeConfig(apiId: string, apiHash: string, teamId: string) {
  const config = await Bun.file(exampleConfigPath).json();
  await Bun.write(configPath, `${JSON.stringify({ ...config, api_id: apiId, api_hash: apiHash, team_id: teamId }, null, "\t")}\n`);
}

/**
 * The runner's login keychain is locked to the runner user, so the certificate goes into its own
 * keychain which is added to the search list `codesign` walks. `set-key-partition-list` is what
 * stops codesign from blocking on a UI prompt that nobody can answer.
 */
async function importCertificate(p12: string, password: string) {
  const p12Path = `${tmpdir()}/paigram-distribution.p12`;
  await Bun.write(p12Path, Buffer.from(p12, "base64"));
  const keychainPassword = crypto.randomUUID();
  await $`security delete-keychain ${keychain}`.nothrow().quiet();
  await $`security create-keychain -p ${keychainPassword} ${keychain}`;
  await $`security set-keychain-settings ${keychain}`;
  await $`security unlock-keychain -p ${keychainPassword} ${keychain}`;
  const existing = (await $`security list-keychains -d user`.text()).split("\n").map((line) => line.trim().replace(/"/g, "")).filter(Boolean);
  await $`security list-keychains -d user -s ${keychain} ${existing}`;
  await $`security import ${p12Path} -k ${keychain} -P ${password} -f pkcs12 -A -T /usr/bin/codesign -T /usr/bin/security`;
  await $`security import ${root}build-system/AppleWWDRCAG3.cer -k ${keychain} -T /usr/bin/codesign`.nothrow();
  await $`security set-key-partition-list -S apple-tool:,apple:,codesign: -k ${keychainPassword} ${keychain}`.quiet();
  rmSync(p12Path);

  const identities = await $`security find-identity -v -p codesigning ${keychain}`.text();
  if (!identities.includes("Apple Distribution") && !identities.includes("iPhone Distribution")) {
    throw new Error(`DIST_CERT_P12 holds no usable distribution identity (is the private key included, and DIST_CERT_P12_PASSWORD right?):\n${identities}`);
  }
  console.log(identities.trim());
}

/** A tag is a promise about which version is being built; versions.json is what the build actually reads. */
async function checkTag() {
  const ref = process.env.GITHUB_REF_NAME;
  if (!ref?.startsWith("ios-v")) return;
  const tagged = ref.slice("ios-v".length);
  const { app } = await readVersions();
  if (tagged !== app) throw new Error(`tag ${ref} does not match versions.json (${app}): tag the commit that bumped the version, or use \`bun run tag\``);
}

const secrets = env();
await checkTag();
await writeApiKey(secrets.ASC_KEY_ID, secrets.ASC_KEY_P8);
await writeConfig(secrets.TELEGRAM_API_ID, secrets.TELEGRAM_API_HASH, secrets.TEAM_ID);
await importCertificate(secrets.DIST_CERT_P12, secrets.DIST_CERT_P12_PASSWORD);
console.log(`runner ready for ${(await readVersions()).app}`);
