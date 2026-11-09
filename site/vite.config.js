import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Relative asset paths: the same build works at n19htfall.github.io/OctoDot/
// (GitHub Pages, .github/workflows/pages.yml) and at a domain's root.
export default defineConfig({
  base: "./",
  plugins: [react()],
  server: { port: 5173, strictPort: true },
});
