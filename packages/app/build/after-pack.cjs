const { readdirSync, rmSync } = require("node:fs");
const { join } = require("node:path");

/** Trim Electron Framework locales before electron-builder signs the app. */
exports.default = async function afterPack(context) {
  if (context.electronPlatformName !== "darwin") return;

  const resources = join(
    context.appOutDir,
    "Agent Island.app",
    "Contents",
    "Frameworks",
    "Electron Framework.framework",
    "Versions",
    "A",
    "Resources",
  );

  for (const entry of readdirSync(resources)) {
    if (entry.endsWith(".lproj") && !entry.startsWith("en")) {
      rmSync(join(resources, entry), { recursive: true, force: true });
    }
  }
};
