import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

declare const process: { cwd: () => string }

export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: {
    alias: { '@': `${process.cwd()}/src` },
  },
  server: {
    port: 5173,
    proxy: {
      '/api': 'http://127.0.0.1:9001',
      '/health': 'http://127.0.0.1:9001',
    },
  },
})
