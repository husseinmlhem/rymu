import { spawn } from "node:child_process";
import { access, lstat, mkdir, readFile, realpath, symlink } from "node:fs/promises";
import { delimiter, isAbsolute, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const [mode, sdkOption, ...flags] = process.argv.slice(2);
if (process.platform !== "win32" || !["prepare", "build"].includes(mode)) {
  throw new Error("Use windows-flutter.mjs prepare|build [workspace-local-sdk] [--online|--local] on Windows.");
}
if (flags.some((flag) => flag !== (mode === "prepare" ? "--online" : "--local"))) {
  throw new Error("Use --online with prepare or --local with build.");
}
const accountApi = mode === "build" && process.env.RYMU_ACCOUNT_API_BASE
  ? new URL(process.env.RYMU_ACCOUNT_API_BASE)
  : null;
if (accountApi && (flags.includes("--local") || accountApi.protocol !== "https:" ||
    accountApi.href !== `${accountApi.origin}/api/v1`)) {
  throw new Error("RYMU_ACCOUNT_API_BASE must be an HTTPS /api/v1 URL used without --local.");
}

function onC(path) {
  return /^c:[\\/]/i.test(path);
}

function isChild(parent, target) {
  const child = relative(parent, target);
  return child && !isAbsolute(child) && child !== ".." && !child.startsWith(`..${sep}`);
}

const local = await realpath(join(root, ".local"));
const sdkPath = resolve(sdkOption ?? join(local, "flutter-sdk/flutter"));
const cachePath = resolve(process.env.PUB_CACHE ?? join(process.env.LOCALAPPDATA, "Pub/Cache"));
if (!onC(local) || !onC(sdkPath) || !isChild(local, sdkPath) || !onC(cachePath)) {
  throw new Error("Use a dedicated SDK under the workspace .local directory and a C: Pub cache.");
}
const sdk = await realpath(sdkPath);
const project = await realpath(join(root, "apps/native/flutter"));
if (!onC(sdk) || !isChild(local, sdk) || !onC(project)) {
  throw new Error("The Flutter SDK and project must resolve to the workspace on C:.");
}
const version = JSON.parse(await readFile(join(sdk, "bin/cache/flutter.version.json"), "utf8"));
if (version.frameworkVersion !== "3.24.5" || version.dartSdkVersion !== "3.5.4") {
  throw new Error("Use the pinned Flutter 3.24.5 SDK with Dart 3.5.4.");
}
const temp = join(local, "windows-runner-temp");
await mkdir(temp, { recursive: true });
const dart = join(sdk, "bin/cache/dart-sdk/bin/dart.exe");
const tool = join(sdk, "packages/flutter_tools");
const jittedTool = ["--disable-dart-dev", `--packages=${join(tool, ".dart_tool/package_config.json")}`];
const env = Object.fromEntries(Object.entries(process.env).filter(([name, value]) =>
  name.toLowerCase() !== "path" && !/^d:/iu.test(value.trim().replace(/^"/u, ""))));
Object.assign(env, {
  PATH: (process.env.PATH ?? "").split(delimiter).filter((part) =>
    onC(part.trim().replace(/^"/u, ""))).join(delimiter),
  FLUTTER_ROOT: sdk,
  FLUTTER_ALREADY_LOCKED: "true",
  FLUTTER_SUPPRESS_ANALYTICS: "true",
  DART_SUPPRESS_ANALYTICS: "true",
  CI: "true",
  TMP: temp,
  TEMP: temp,
  PUB_CACHE: cachePath,
});

async function run(args, cwd) {
  const child = spawn(dart, args, { cwd, env, windowsHide: true, stdio: "inherit" });
  const code = await new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("exit", (code) => resolve(code));
  });
  if (code !== 0) throw new Error(`Dart command exited ${code ?? "without an exit code"}: ${args.join(" ")}`);
}

if (mode === "prepare") {
  const pub = ["pub", "get", "--enforce-lockfile"];
  if (!flags.includes("--online")) pub.push("--offline");
  await run(pub, tool);
  await run(pub, project);
  await run([...jittedTool, join(root, "scripts/windows-plugin-registrants.dart"), project, sdk], project);

  const pubRoot = await realpath(cachePath);
  const directory = join(project, "windows/flutter/ephemeral/.plugin_symlinks");
  const { plugins } = JSON.parse(await readFile(join(project, ".flutter-plugins-dependencies"), "utf8"));
  await mkdir(directory, { recursive: true });
  if (!onC(pubRoot) || (await realpath(directory)).toLowerCase() !== resolve(directory).toLowerCase()) {
    throw new Error("The Pub cache and generated plugin directory must be on C:.");
  }
  for (const plugin of plugins.windows) {
    if (!/^[a-z0-9_]+$/u.test(plugin.name) || !onC(plugin.path)) throw new Error("Invalid Windows plugin metadata.");
    const source = await realpath(plugin.path);
    if (!isChild(pubRoot, source)) throw new Error(`Plugin is outside the pinned Pub cache: ${plugin.name}`);
    if (plugin.native_build) await access(join(source, "windows/CMakeLists.txt"));
    const link = join(directory, plugin.name);
    const existing = await lstat(link).catch((error) => {
      if (error.code === "ENOENT") return null;
      throw error;
    });
    if (existing) {
      if ((await realpath(link)).toLowerCase() !== source.toLowerCase()) {
        throw new Error(`Preserved a different existing plugin entry: ${plugin.name}`);
      }
    } else {
      await symlink(source, link, "junction");
    }
  }
  console.log(`Prepared ${plugins.windows.length} Windows plugin entries.`);
} else {
  await access(join(project, "windows/flutter/generated_plugins.cmake"));
  await access(join(project, "../target/release/librustdesk.dll"));
  const args = [...jittedTool, join(tool, "bin/flutter_tools.dart"), "--no-version-check",
    "--verbose", "build", "windows", "--release", "--no-pub"];
  if (flags.includes("--local")) {
    args.push("--dart-define=RYMU_LOCAL_BUILD=true",
      "--dart-define=RYMU_LOCAL_API_BASE=http://127.0.0.1:18787/api/v1",
      "--dart-define=RYMU_LOCAL_WEB_ORIGIN=http://localhost:15173");
  } else if (accountApi) {
    args.push(`--dart-define=RYMU_ACCOUNT_API_BASE=${accountApi.href}`);
  }
  await run(args, project);
}
