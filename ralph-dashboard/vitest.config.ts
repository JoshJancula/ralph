import { defineConfig } from 'vitest/config';
import angular from '@analogjs/vite-plugin-angular';

export default defineConfig({
  plugins: [
    angular({
      inlineStylesFileExtension: 'css',
    }),
  ],
  test: {
    globals: true,
    environment: 'jsdom',
    setupFiles: ['src/vitest-test-env.ts'],
    include: ['src/**/*.spec.ts'],
    server: {
      deps: {
        inline: ['@ionic/core', '@ionic/angular', '@ionic/angular/standalone'],
      },
    },
    coverage: {
      provider: 'v8',
      reportsDirectory: 'coverage/vitest',
      include: ['src/app/**/*.ts'],
      exclude: [
        'src/app/**/*.spec.ts',
        'src/main.ts',
        'src/main.server.ts',
        'src/app/app.config.ts',
        'src/app/app.config.server.ts',
        'src/app/app.routes.ts',
        'src/app/app.routes.server.ts',
      ],
      thresholds: {
        statements: 80,
        branches: 75,
        functions: 80,
        lines: 80,
      },
    },
  },
});
