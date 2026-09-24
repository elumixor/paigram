/**
 * App Store Connect API with the key from `.env` (ASC_KEY_ID, ASC_ISSUER_ID, TEAM_ID) and
 * `~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8`.
 */
import { SignJWT, importPKCS8 } from "jose";
import { homedir } from "node:os";

const API = "https://api.appstoreconnect.apple.com/v1";

export class AscError extends Error {
  constructor(
    readonly status: number,
    readonly path: string,
    readonly detail: string,
  ) {
    super(`ASC ${path}: HTTP ${status} ${detail}`);
  }
}

function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is not set (see .env)`);
  return value;
}

export const asc = {
  keyId: required("ASC_KEY_ID"),
  issuerId: required("ASC_ISSUER_ID"),
  teamId: required("TEAM_ID"),
  keyPath: `${homedir()}/.appstoreconnect/private_keys/AuthKey_${required("ASC_KEY_ID")}.p8`,
};

let token: { value: string; expires: number } | undefined;

async function bearer(): Promise<string> {
  if (token && token.expires > Date.now() + 60_000) return token.value;
  const key = await importPKCS8(await Bun.file(asc.keyPath).text(), "ES256");
  const expires = Date.now() + 19 * 60_000;
  const value = await new SignJWT({ aud: "appstoreconnect-v1" })
    .setProtectedHeader({ alg: "ES256", kid: asc.keyId, typ: "JWT" })
    .setIssuer(asc.issuerId)
    .setIssuedAt()
    .setExpirationTime(Math.floor(expires / 1000))
    .sign(key);
  token = { value, expires };
  return value;
}

export async function ascCall<T = any>(method: string, path: string, body?: unknown): Promise<T> {
  const response = await fetch(path.startsWith("http") ? path : `${API}${path}`, {
    method,
    headers: { Authorization: `Bearer ${await bearer()}`, ...(body ? { "Content-Type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (response.status === 204) return undefined as T;
  const json = (await response.json()) as { errors?: { detail?: string; title?: string }[] };
  if (!response.ok) throw new AscError(response.status, path, json.errors?.map((e) => e.detail ?? e.title).join("; ") ?? "");
  return json as T;
}

export const ascGet = <T = any>(path: string) => ascCall<T>("GET", path);
export const ascPost = <T = any>(path: string, body: unknown) => ascCall<T>("POST", path, body);
export const ascDelete = (path: string) => ascCall<void>("DELETE", path);
