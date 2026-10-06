/**
 * `bun scripts/mac-release.ts [tag]`: what the TestFlight workflow runs on this Mac (a self-hosted runner,
 * `paigram-mac`), so a tag pushed from anywhere — this Mac, the box, pai's chat — builds here for free, from
 * the warm Bazel cache. It builds `~/dev/paigram` in place rather than a second checkout (this disk has no
 * room for one), so it first checks that those files are exactly the tagged commit: the box and this Mac
 * share the tree, so they are whenever the tag was cut from it. Signing and the App Store Connect key are
 * this Mac's own (the login keychain, `.env`).
 */
import { $ } from "bun";
import { readVersions, root } from "./repo.ts";

const tag = process.argv[2] ?? process.env.GITHUB_REF_NAME;
const git = (args: string[]) => $`git ${args}`.cwd(root).quiet();

if (tag?.startsWith("ios-v")) {
  await git(["fetch", "-q", "origin", "tag", tag]);
  const changed = (await $`git diff --name-only --ignore-submodules=all ${tag} --`.cwd(root).nothrow().quiet().text()).trim();
  if (changed) {
    throw new Error(`~/dev/paigram is not ${tag} — these files differ:\n${changed.split("\n").slice(0, 20).join("\n")}\nSync or commit first, then run the workflow again.`);
  }
  const { app } = await readVersions();
  if (`ios-v${app}` !== tag) throw new Error(`versions.json says ${app}, the tag is ${tag}`);
}

// The disk cache grows with every build and this disk is small: keep it bounded before adding to it.
await $`bun scripts/trim-cache.ts ${process.env.HOME}/telegram-bazel-cache 25`.cwd(root);
await $`bun run testflight --no-bump`.cwd(root);
