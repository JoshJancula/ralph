import type { JestConfigWithTsJest } from 'ts-jest';

const jestConfig: JestConfigWithTsJest = {
  preset: 'ts-jest/presets/default-esm',
  testEnvironment: 'node',
  moduleFileExtensions: ['js', 'json', 'ts'],
  rootDir: '.',
  testMatch: ['<rootDir>/tests/**/*.test.ts'],
  testPathIgnorePatterns: ['/node_modules/', '/dist/'],
  collectCoverageFrom: ['src/app/utils/**/*.ts', '!src/app/utils/**/*.spec.ts'],
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
