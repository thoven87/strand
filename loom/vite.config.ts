import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import path from 'path'

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: { '@': path.resolve(__dirname, './src') },
  },
  server: {
    proxy: {
      '/api': 'http://localhost:8080',
      '/health': 'http://localhost:8080',
      '/version': 'http://localhost:8080',
    },
  },
  build: {
    outDir: '../Sources/StrandServer/Resources/ui',
    emptyOutDir: true,
  },
})
