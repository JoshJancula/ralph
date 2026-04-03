import { marked } from 'marked';
import { markdownToHtml, isMermaidBlock } from '../src/app/utils/markdown-to-html';
import { parseDashboardFileHash, buildDashboardFileHash } from '../src/app/utils/dashboard-file-hash';

describe('markdownToHtml', () => {
  it('converts plain markdown (headings, bold, lists) to HTML without mermaid wrappers', () => {
    const source = `# Heading

Some text with **bold** and *italic*.

- Item 1
- Item 2
`;

    const result = markdownToHtml(source);

    expect(result).toContain('<h1>Heading</h1>');
    expect(result).toContain('<strong>bold</strong>');
    expect(result).toContain('<em>italic</em>');
    expect(result).toContain('<ul>');
    expect(result).toContain('<li>Item 1</li>');
    expect(result).not.toContain('<div class="mermaid">');
  });

  it('converts a ` ```mermaid ` fenced block to <div class="mermaid">', () => {
    const source = `Some text

\`\`\`mermaid
graph TD
    A --> B
    B --> C
\`\`\`

More text
`;

    const result = markdownToHtml(source);

    expect(result).toContain('<div class="mermaid">');
    expect(result).toContain('graph TD');
    // Mermaid content is NOT escaped (no HTML escaping within mermaid blocks)
    expect(result).toContain('A --> B');
    expect(result).toContain('B --> C');
  });

  it('does not produce mermaid wrapper for ` ```js ` fenced block', () => {
    const source = `Some text

\`\`\`js
function hello() {
  console.log("hello");
}
\`\`\`

More text
`;

    const result = markdownToHtml(source);

    expect(result).not.toContain('<div class="mermaid">');
    expect(result).toContain('class="hljs language-js"');
  });
});

describe('isMermaidBlock', () => {
  it('returns true for a mermaid code token', () => {
    const token = { type: 'code', lang: 'mermaid', text: 'graph TD' };
    expect(isMermaidBlock(token)).toBe(true);
  });

  it('returns false for non-mermaid code token', () => {
    const token = { type: 'code', lang: 'js', text: 'console.log' };
    expect(isMermaidBlock(token)).toBe(false);
  });

  it('returns false for non-code token', () => {
    const token = { type: 'paragraph', text: 'some text' };
    expect(isMermaidBlock(token)).toBe(false);
  });

  it('returns false for invalid input', () => {
    expect(isMermaidBlock(null)).toBe(false);
    expect(isMermaidBlock(undefined)).toBe(false);
    expect(isMermaidBlock('string')).toBe(false);
    expect(isMermaidBlock(123)).toBe(false);
  });
});

describe('parseDashboardFileHash', () => {
  it('returns correct fields for a well-formed hash', () => {
    const hash = '#root=logs&path=PLAN2&file=plan-runner.log';
    const result = parseDashboardFileHash(hash);

    expect(result).toEqual({
      root: 'logs',
      path: 'PLAN2',
      file: 'plan-runner.log',
    });
  });

  it('returns null for empty string', () => {
    expect(parseDashboardFileHash('')).toBeNull();
  });

  it('returns null for hash without leading #', () => {
    expect(parseDashboardFileHash('root=logs&path=PLAN2&file=plan-runner.log')).toBeNull();
  });

  it('returns null for missing root key', () => {
    expect(parseDashboardFileHash('#path=PLAN2&file=plan-runner.log')).toBeNull();
  });

  it('returns null for missing path key', () => {
    expect(parseDashboardFileHash('#root=logs&file=plan-runner.log')).toBeNull();
  });

  it('returns null for missing file key', () => {
    expect(parseDashboardFileHash('#root=logs&path=PLAN2')).toBeNull();
  });

  it('returns null for malformed input', () => {
    expect(parseDashboardFileHash('#invalid')).toBeNull();
    expect(parseDashboardFileHash('not-a-hash-at-all')).toBeNull();
  });
});

describe('buildDashboardFileHash', () => {
  it('round-trips through parseDashboardFileHash', () => {
    const root = 'logs';
    const path = 'PLAN2';
    const file = 'plan-runner.log';

    const built = buildDashboardFileHash(root, path, file);
    const parsed = parseDashboardFileHash(built);

    expect(parsed).toEqual({ root, path, file });
  });

  it('encodes special characters in URL parameters', () => {
    const root = 'log files';
    const path = 'PLAN 2';
    const file = 'plan-runner (final).log';

    const built = buildDashboardFileHash(root, path, file);
    const parsed = parseDashboardFileHash(built);

    expect(parsed).toEqual({ root, path, file });
  });
});
