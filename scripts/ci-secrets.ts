/**
 * `bun run ci-secrets`: fills every GitHub repo secret the TestFlight workflow needs, once, from the
 * Mac that holds the Apple material. Eight of the eleven values already live on the box and are read
 * over `pai ssh`; the App Store Connect key and the distribution certificate exist nowhere but this
 * Mac. Each value reaches `gh secret set` on stdin, so none of them lands in argv or shell history,
 * and this file holds no secret of its own.
 *
 * `--p12 <path>` skips the keychain export and uses a .p12 exported by hand from Keychain Access
 * (it asks for its password), for when `security export` will not give up the private key.
 */
import { $ } from "bun";
import { mkdtempSync, rmSync } from "node:fs";
import { randomBytes } from "node:crypto";
import { homedir, tmpdir } from "node:os";
import { root } from "./repo.ts";
import { fetchBotUsername } from "./secrets.ts";

/** What the box can answer for, read in one round trip. `PAI_BOX_URL` is derived from the domain. */
const boxReader = `
import json, os
home = os.path.expanduser('~')
env = {}
for line in open(home + '/dev/paigram/.env'):
    line = line.strip()
    if line and not line.startswith('#') and '=' in line:
        key, value = line.split('=', 1)
        env[key.strip()] = value.strip().strip('"').strip("'")
app = json.load(open(home + '/dev/paigram/build-system/paigram.json'))
pai = json.load(open(home + '/pai/data/config.json'))
print(json.dumps({
    'ASC_KEY_ID': env['ASC_KEY_ID'],
    'ASC_ISSUER_ID': env['ASC_ISSUER_ID'],
    'TEAM_ID': env['TEAM_ID'],
    'TELEGRAM_API_ID': app['api_id'],
    'TELEGRAM_API_HASH': app['api_hash'],
    'PAI_BOX_URL': 'https://' + pai['PAI_DOMAIN'],
    'PAI_BOX_TOKEN': pai['PAI_TOKEN'],
}))
`;

const argument = (name: string) => {
  const index = process.argv.indexOf(name);
  return index === -1 ? undefined : process.argv[index + 1];
};

const randomPassword = () => randomBytes(24).toString("base64url");

/** `pai ssh` runs its command through the box's shell, so the reader travels as base64 rather than as quoting. */
async function fromBox(): Promise<Record<string, string>> {
  const encoded = Buffer.from(boxReader).toString("base64");
  const output = await $`pai ssh ${`echo ${encoded} | base64 -d | python3 -`}`.text();
  const json = output.replace(/\r/g, "").match(/\{[\s\S]*\}/)?.[0];
  if (!json) throw new Error(`the box did not answer with the values; it said:\n${output.trim()}`);
  const values = JSON.parse(json) as Record<string, string>;
  const missing = Object.entries(values).filter(([, value]) => !value).map(([name]) => name);
  if (missing.length) throw new Error(`the box has no value for ${missing.join(", ")}`);
  return values;
}

async function appStoreConnectKey(keyId: string): Promise<string> {
  const path = `${homedir()}/.appstoreconnect/private_keys/AuthKey_${keyId}.p8`;
  const file = Bun.file(path);
  if (!(await file.exists())) throw new Error(`${path} is missing: download the App Store Connect key for ${keyId} and put it there`);
  return Buffer.from(await file.arrayBuffer()).toString("base64");
}

interface Identity {
  readonly hash: string;
  readonly name: string;
}

/** Distribution identities in the login keychain — the only keychain `security export` can be pointed at here. */
async function distributionIdentities(keychain: string): Promise<Identity[]> {
  const listing = await $`security find-identity -v -p codesigning ${keychain}`.text();
  const found = [...listing.matchAll(/^\s*\d+\)\s+([0-9A-F]{40})\s+"(.+)"\s*$/gm)].map(([, hash, name]) => ({ hash, name }));
  const distribution = found.filter(({ name }) => name.startsWith("Apple Distribution") || name.startsWith("iPhone Distribution"));
  if (!distribution.length) throw new Error(`no distribution identity in ${keychain}; the certificate whose profiles the build uses has to be in this keychain with its private key:\n${listing}`);
  return [...new Map(distribution.map((identity) => [identity.hash, identity])).values()];
}

function pick(identities: readonly Identity[]): Identity {
  if (identities.length === 1) return identities[0];
  console.log("more than one distribution identity:");
  identities.forEach(({ name }, index) => console.log(`  ${index + 1}) ${name}`));
  const chosen = Number(prompt("which one does App Store Connect issue the profiles for?"));
  const identity = identities[chosen - 1];
  if (!identity) throw new Error("not one of the listed identities");
  return identity;
}

/** openssl reads PEM from a file rather than a pipe here, and these run in parallel, so each block gets its own. */
async function pemFile(pem: string, workdir: string, name: string): Promise<string> {
  const path = `${workdir}/${name}.pem`;
  await Bun.write(path, pem);
  return path;
}

async function fingerprint(pem: string, workdir: string, name: string): Promise<string> {
  const output = await $`openssl x509 -in ${await pemFile(pem, workdir, name)} -noout -fingerprint -sha1`.text();
  return output.split("=")[1].replace(/[:\s]/g, "").toUpperCase();
}

/** Pairs a certificate with its key: the two are separate bags in the export and their order is not promised. */
async function modulus(pem: string, kind: "certificate" | "key", workdir: string, name: string): Promise<string> {
  const path = await pemFile(pem, workdir, name);
  const output = kind === "certificate" ? await $`openssl x509 -in ${path} -noout -modulus`.text() : await $`openssl rsa -in ${path} -noout -modulus`.nothrow().text();
  return output.split("=")[1]?.trim() ?? "";
}

/**
 * `security` writes and reads .p12 files with RC2/3DES, which OpenSSL 3 only speaks with `-legacy`;
 * LibreSSL (/usr/bin/openssl) speaks it by default and knows no such flag.
 */
const legacy = (await $`openssl version`.text()).startsWith("OpenSSL 3") ? ["-legacy"] : [];

/**
 * The whole keychain's identities in PEM, so the chosen one can be picked out of them: `security
 * export` cannot be pointed at a single identity. macOS asks for the login password before it hands
 * over a private key — that prompt is expected.
 */
async function exportedPem(keychain: string, workdir: string): Promise<string> {
  const bundle = `${workdir}/identities.p12`;
  const intermediate = randomPassword();
  await $`security export -k ${keychain} -t identities -f pkcs12 -P ${intermediate} -o ${bundle}`;
  return await $`openssl pkcs12 ${legacy} -in ${bundle} -passin env:INTERMEDIATE -nodes`.env({ ...process.env, INTERMEDIATE: intermediate }).text();
}

/** The chosen identity alone, as a .p12 encrypted with `password`. */
async function distributionP12(identity: Identity, keychain: string, workdir: string, password: string): Promise<string> {
  const blocks = (await exportedPem(keychain, workdir)).match(/-----BEGIN [^-]+-----[\s\S]*?-----END [^-]+-----/g) ?? [];
  const certificates = blocks.filter((block) => block.includes("BEGIN CERTIFICATE"));
  const keys = blocks.filter((block) => block.includes("PRIVATE KEY"));

  const fingerprints = await Promise.all(certificates.map((pem, index) => fingerprint(pem, workdir, `certificate-${index}`)));
  const certificate = certificates[fingerprints.indexOf(identity.hash)];
  if (!certificate) throw new Error(`${identity.name} was not in the keychain export: export it from Keychain Access and pass --p12 <path>`);

  const wanted = await modulus(certificate, "certificate", workdir, "chosen");
  const moduli = await Promise.all(keys.map((pem, index) => modulus(pem, "key", workdir, `key-${index}`)));
  const key = keys[moduli.indexOf(wanted)];
  if (!key) throw new Error(`the private key of ${identity.name} is not in this keychain: export it from Keychain Access and pass --p12 <path>`);

  const certificatePath = `${workdir}/distribution.crt`;
  const keyPath = `${workdir}/distribution.key`;
  const p12Path = `${workdir}/distribution.p12`;
  await Bun.write(certificatePath, certificate);
  await Bun.write(keyPath, key);
  await $`openssl pkcs12 -export ${legacy} -inkey ${keyPath} -in ${certificatePath} -name ${identity.name} -passout env:EXPORT -out ${p12Path}`.env({ ...process.env, EXPORT: password });
  return Buffer.from(await Bun.file(p12Path).arrayBuffer()).toString("base64");
}

/** Reads the whole stdin-fed value in one go: `gh` takes a secret's value on stdin when `--body` is absent. */
async function setSecret(repo: string, name: string, value: string) {
  await $`gh secret set ${name} --repo ${repo} < ${new Blob([value])}`.quiet();
}

async function requireTooling(repo: string) {
  if ((await $`which gh`.nothrow().quiet()).exitCode !== 0) throw new Error("gh is not installed: `brew install gh`");
  if ((await $`gh auth status`.nothrow().quiet()).exitCode !== 0) throw new Error("gh is not logged in: `gh auth login`");
  if ((await $`gh repo view ${repo}`.nothrow().quiet()).exitCode !== 0) throw new Error(`gh cannot see ${repo}: the token needs access to it`);
  if ((await $`pai ssh true`.nothrow().quiet()).exitCode !== 0) throw new Error("`pai ssh` does not reach the box: run `pai ssh` by hand and fix that first");
}

const origin = (await $`git config --get remote.origin.url`.cwd(root).text()).trim();
const repo = origin.match(/[:/]([^/:]+\/[^/]+?)(?:\.git)?$/)?.[1];
if (!repo) throw new Error(`cannot read the GitHub repo out of origin (${origin})`);

await requireTooling(repo);

const boxValues = await fromBox();
const botUsername = await fetchBotUsername(boxValues.PAI_BOX_URL, boxValues.PAI_BOX_TOKEN);

const keychain = (await $`security default-keychain -d user`.text()).trim().replace(/"/g, "");
const workdir = mkdtempSync(`${tmpdir()}/paigram-ci-secrets-`);
const password = randomPassword();
try {
  const given = argument("--p12");
  const p12 = given
    ? Buffer.from(await Bun.file(given).arrayBuffer()).toString("base64")
    : await distributionP12(pick(await distributionIdentities(keychain)), keychain, workdir, password);
  const p12Password = given ? (prompt(`password of ${given}:`) ?? "") : password;

  const secrets = {
    ...boxValues,
    PAI_BOT_USERNAME: botUsername,
    ASC_KEY_P8: await appStoreConnectKey(boxValues.ASC_KEY_ID),
    DIST_CERT_P12: p12,
    DIST_CERT_P12_PASSWORD: p12Password,
  };

  for (const [name, value] of Object.entries(secrets)) {
    await setSecret(repo, name, value);
    console.log(`set ${name}`);
  }
  console.log(`\n${Object.keys(secrets).length} secrets set on ${repo}. Cut a release with \`bun run tag\`.`);
} finally {
  rmSync(workdir, { recursive: true, force: true });
}
