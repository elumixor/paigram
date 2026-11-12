/**
 * `bun scripts/mac-release.ts [tag]`: what the TestFlight workflow runs on this Mac (a self-hosted runner,
 * `paigram-mac`), so a tag dispatched from pai's build card builds here, from the warm
 * Bazel cache, in a fraction of a GitHub runner's time. It builds `~/dev/@desk/native/paigram-ios` in place
 * rather than a second checkout (this disk has no room for one), so it first checks that those files are
 * exactly the tagged commit: the box and this Mac share the tree by sync, so they are whenever the tag was
 * cut from it. The check reads the tag's tree into a scratch index, because this Mac's own `.git` lags
 * behind the synced files and its index would call every newer file deleted. The build runs under
 * `caffeinate`, so the Mac does not doze off halfway. Signing and the App Store Connect key are this Mac's
 * own (the login keychain, `.env`).
 *
 * When this script fails for any reason, the workflow's `fallback` job starts the GitHub runner's build
 * (`testflight-hosted.yml`) of the same tag, so nothing here needs to recover; it only has to fail loudly.
 */
import { $ } from "bun";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { readVersions, root } from "./repo.ts";

const repo = "elumixor/paigram";
const tag = process.argv[2] ?? process.env.GITHUB_REF_NAME;
const git = (args: string[], env: Record<string, string> = {}) => $`git ${args}`.cwd(root).env({ ...process.env, ...env }).quiet();

/** The files under `root` against the tag's tree; submodules are left out (their links point into this Mac's `.git`). */
async function differences(ref: string): Promise<string[]> {
  const scratch = mkdtempSync(`${tmpdir()}/paigram-index-`);
  const env = { GIT_INDEX_FILE: `${scratch}/index` };
  try {
    await git(["read-tree", ref], env);
    const changed = (await git(["diff", "--name-only", "--ignore-submodules=all", ref, "--"], env).text()).trim();
    // Files the tag does not have but the build would pick up (Bazel globs them).
    const extra = (await git(["ls-files", "--others", "--exclude-standard", "--", "scripts", "submodules/PaiUI", "submodules/PaiGlance", "Telegram", "build-system/Make", "versions.json"], env).text()).trim();
    return [...changed.split("\n"), ...extra.split("\n").map((line) => `${line} (not in ${ref})`)].filter((line) => line && !line.startsWith(" (not in"));
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

if (tag?.startsWith("ios-v")) {
  // A tag that was moved (a retag after a fix) has to replace this Mac's copy; plain fetch refuses to.
  await git(["fetch", "-q", "--force", "origin", `+refs/tags/${tag}:refs/tags/${tag}`]);
  const changed = await differences(tag);
  if (changed.length) {
    throw new Error(`~/dev/@desk/native/paigram-ios is not ${tag} — these files differ:\n${changed.slice(0, 20).join("\n")}\nSync or commit first, then run the workflow again.`);
  }
  const { app } = await readVersions();
  if (`ios-v${app}` !== tag) throw new Error(`versions.json says ${app}, the tag is ${tag}`);
}

// The disk cache grows with every build and this disk is small: keep it bounded before adding to it.
await $`bun scripts/trim-cache.ts ${process.env.HOME}/telegram-bazel-cache 25`.cwd(root);
// -i: no idle sleep while the build runs; -s: no system sleep either, honoured on AC power only
// (on battery with the lid closed the Mac sleeps regardless, the job stalls, and GitHub fails it after
// ten minutes without a heartbeat — the fallback job takes over).
await $`caffeinate -ims bun run testflight --no-bump --once`.cwd(root);

// The same tag may have started a GitHub runner too (when this job was still queued as the Mac woke up).
if (tag) {
  const runs = (await $`gh run list --repo ${repo} --workflow testflight-hosted.yml --limit 20 --json databaseId,headBranch,status`.cwd(root).json()) as { databaseId: number; headBranch: string; status: string }[];
  for (const run of runs.filter((r) => r.headBranch === tag && r.status !== "completed")) {
    const { exitCode } = await $`gh run cancel ${run.databaseId} --repo ${repo}`.cwd(root).nothrow();
    console.log(exitCode === 0 ? `cancelled the GitHub runner's build of ${tag} (run ${run.databaseId})` : `could not cancel the GitHub runner's build of ${tag} (run ${run.databaseId})`);
  }
}
