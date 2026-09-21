import { defineConfig } from 'vite';

export default defineConfig({
  base: './',
  build: {
    target: 'es2022',
    chunkSizeWarningLimit: 700,
    rollupOptions: { input: { main: 'index.html', expedition: 'expedition.html' }, output: { manualChunks(id) {
      if (id.includes('/node_modules/three/src/') || id.includes('/node_modules/three/build/')) return 'three-core';
      if (id.includes('/node_modules/three/examples/')) return 'three-tools';
    } } },
  },
  server: { host: '127.0.0.1' },
});
