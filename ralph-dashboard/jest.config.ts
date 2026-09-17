import type { JestConfigWithTsJest } from 'ts-jest';

const jestConfig: JestConfigWithTsJest = {
  preset: 'ts-jest/presets/default-esm',
  testEnvironment: 'node',
  moduleFileExtensions: ['js', 'json', 'ts'],
  rootDir: '.',
  testMatch: ['<rootDir>/tests/**/*.test.ts', '<rootDir>/src/app/utils/**/*.test.ts'],
  testPathIgnorePatterns: ['/node_modules/', '/dist/', '\\.pw\\.test\\.ts$'],
  collectCoverageFrom: [
    'src/app/utils/**/*.ts',
    '!src/app/utils/**/*.spec.ts',
    '!src/app/utils/**/*.test.ts',
    '!src/app/utils/dashboard-file-hash.ts',
    '!src/app/utils/markdown-to-html.ts',
    '!src/app/utils/sanitize-html.ts',
  ],
  coverageDirectory: 'coverage/jest',
  coverageThreshold: {
    global: {
      statements: 80,
      branches: 80,
      functions: 80,
      lines: 80,
    },
  },
  transform: {
    '^.+\\.(t|j)sx?$': ['ts-jest', { useESMInterop: true, useESM: true }],
  },
  moduleNameMapper: {
    '^@ralph-dashboard/(.*)$': '<rootDir>/src/$1',
  },
  extensionsToTreatAsEsm: ['.ts'],
};

export default jestConfig;
