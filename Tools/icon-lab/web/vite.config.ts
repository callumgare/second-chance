import path from "node:path";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { mockFiles } from "./mock-plugin";

// The dev server (Tools/icon-lab/server) the dev page's /api is proxied to: `sc icon-lab serve` sets it.
const ENGINE = process.env.ICON_LAB_ENGINE ?? "http://127.0.0.1:8767";

export default defineConfig({
  plugins: [react(), mockFiles()],
  // Relative asset paths, so the page works wherever a host serves it.
  base: "./",
  server: {
    port: Number(process.env.ICON_LAB_WEB_PORT ?? 5173),
    strictPort: false,
    proxy: {
      "/api/events": { target: ENGINE.replace("http", "ws"), ws: true, changeOrigin: true },
      "/api": { target: ENGINE, changeOrigin: true },
    },
  },
  // Built into IconLabAPI's resources, which the app and the dev server serve (`sc icon-lab build`).
  build: {
    outDir: path.resolve(__dirname, "../../../Packages/IconLab/Sources/IconLabAPI/Resources/web"),
    emptyOutDir: true,
    chunkSizeWarningLimit: 1200,
  },
});
