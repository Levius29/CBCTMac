import tailwindcss from '@tailwindcss/postcss';
import vinext from 'vinext';
import { defineConfig } from 'vite';
// This application deliberately runs on the Mac. No cloud bindings or deployment.
export default defineConfig({
  css: { postcss: { plugins: [tailwindcss()] } },
  plugins: [vinext()],
  server: {
    host: '127.0.0.1',
    watch: { useFsEvents: false, usePolling: true },
  },
});
