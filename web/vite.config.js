import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';
import colorMixFallback from './tools/color-mix-fallback.mjs';

// Builds straight into ../html, which is the actual FiveM NUI page directory
// declared in fxmanifest.lua (ui_page 'html/index.html'). Relative asset paths
// are required because FiveM's NUI browser does not reliably serve from root.
export default defineConfig({
  plugins: [svelte(), colorMixFallback()],
  base: './',
  build: {
    outDir: '../html',
    emptyOutDir: true,
    assetsDir: 'assets',
  },
});
