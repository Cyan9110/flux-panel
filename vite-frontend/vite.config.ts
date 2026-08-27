import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import path from "path";
import legacy from '@vitejs/plugin-legacy'

export default defineConfig({
  plugins: [
    react(),
    legacy({
      targets: ['Chrome >= 67', 'Edge >= 79', 'Firefox >= 68', 'Safari >= 14'],
      modernTargets: ['Chrome >= 67', 'Edge >= 79', 'Firefox >= 68', 'Safari >= 14']
    })
  ],
  base: './',    
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
  },
  server: {
    port: 3000,
    host: '0.0.0.0'
  },
  build: {
    outDir: 'dist',
    sourcemap: false,
    minify: false,  
    rollupOptions: {
      treeshake: false,
    }
  }
});
