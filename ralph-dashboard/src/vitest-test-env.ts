declare const globalThis: { __ralphVitestTestEnv?: boolean };

if (!globalThis.__ralphVitestTestEnv) {
  if (typeof window !== 'undefined' && typeof window.matchMedia === 'undefined') {
    Object.defineProperty(window, 'matchMedia', {
      writable: true,
      value: (query: string) => ({
        matches: query === '(prefers-color-scheme: light)',
        media: query,
        onchange: null,
        addListener: vi.fn(),
        removeListener: vi.fn(),
        addEventListener: vi.fn(),
        removeEventListener: vi.fn(),
        dispatchEvent: vi.fn(),
      }),
    });
  }

  globalThis.__ralphVitestTestEnv = true;
}
