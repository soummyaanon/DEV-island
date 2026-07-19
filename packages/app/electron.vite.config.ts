import { defineConfig, externalizeDepsPlugin } from "electron-vite";
import react from "@vitejs/plugin-react";
import { resolve } from "node:path";

// @agent-island/shared ships as TypeScript source, so it must be BUNDLED into
// main/preload (not externalized) — otherwise Node would try to require its .ts
// entry at runtime. npm deps (electron, ws) stay external.
const bundleShared = { exclude: ["@agent-island/shared"] };

export default defineConfig({
  main: {
    plugins: [externalizeDepsPlugin(bundleShared)],
  },
  preload: {
    plugins: [externalizeDepsPlugin(bundleShared)],
  },
  renderer: {
    resolve: {
      alias: {
        "@renderer": resolve("src/renderer"),
      },
    },
    build: {
      rollupOptions: {
        input: {
          // The notch overlay plus the first-run onboarding window.
          index: resolve("src/renderer/index.html"),
          onboarding: resolve("src/renderer/onboarding.html"),
        },
      },
    },
    plugins: [react()],
  },
});
