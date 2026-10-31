/**
 * The signed release build for iPhones, shared by TestFlight and direct installs so either one
 * reuses the other's Bazel cache: only the signing differs between them.
 */
import { $ } from "bun";
import { writeSecrets } from "./secrets.ts";
import { configPath as config, root } from "./repo.ts";

/** Signs with the profiles in `codesigning`; `watch` embeds the watch app, which adds an xcodebuild step. */
export async function releaseBuild(codesigning: string, buildNumber: number, watch: boolean) {
  const { api_id: apiId, api_hash: apiHash } = (await Bun.file(config).json()) as { api_id: string; api_hash: string };
  const watchArguments = watch ? ["--embedWatchApp", `--watchApiId=${apiId}`, `--watchApiHash=${apiHash}`] : [];
  await writeSecrets();
  await $`python3 build-system/Make/Make.py --overrideXcodeVersion --cacheDir=${process.env.HOME}/telegram-bazel-cache build --configurationPath=${config} --codesigningInformationPath=${codesigning} --buildNumber=${buildNumber} --configuration=release_arm64 ${watchArguments}`.cwd(root);
}
