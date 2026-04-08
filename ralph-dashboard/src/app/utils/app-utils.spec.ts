import { describe, expect, it } from 'vitest';
import { marked } from 'marked';
import { markdownToHtml, isMermaidBlock } from './markdown-to-html';
import { parseDashboardFileHash, buildDashboardFileHash } from './dashboard-file-hash';

describe('markdownToHtml (Vitest)', () => {
  it('wraps mermaid code blocks produced by marked', () => {
    const source = '```mermaid\ngraph TD\n  A --> B\n```';
    const result = markdownToHtml(source);
    expect(result).toContain('<pre><code class="language-mermaid">');
  });

  it('leaves non-mermaid fenced code as pre/code', () => {
    const source = '```txt\nhello\n```';
    const result = markdownToHtml(source);
    expect(result).not.toContain('language-mermaid');
  });
});

describe('isMermaidBlock (Vitest)', () => {
  it('returns false when token is not an object', () => {
    expect(isMermaidBlock(null)).toBe(false);
    expect(isMermaidBlock('x')).toBe(false);
  });

  it('returns true only for code tokens with lang mermaid', () => {
    expect(isMermaidBlock({ type: 'code', lang: 'mermaid' })).toBe(true);
    expect(isMermaidBlock({ type: 'code', lang: 'ts' })).toBe(false);
    expect(isMermaidBlock({ type: 'paragraph' })).toBe(false);
  });
});

describe('dashboard file hash (Vitest)', () => {
  it('parseDashboardFileHash returns null for invalid input', () => {
    expect(parseDashboardFileHash('')).toBeNull();
    expect(parseDashboardFileHash('nohash')).toBeNull();
  });

  it('buildDashboardFileHash and parse round-trip', () => {
    const h = buildDashboardFileHash('logs', 'p', 'f.log');
    expect(parseDashboardFileHash(h)).toEqual({ root: 'logs', path: 'p', file: 'f.log' });
  });

  it('escapes HTML entities in code blocks', () => {
    const source = '```typescript\nconst x = 1 < 2 && 3 > 4\n```';
    const result = markdownToHtml(source);
    expect(result).toContain('&lt;');
    expect(result).toContain('&gt;');
  });

  it('handles empty string input', () => {
    const result = markdownToHtml('');
    expect(result).toBe('');
  });

  it('highlights comments in code blocks', () => {
    const source = '```typescript\n// This is a comment\nconst x = 1;\n```';
    const result = markdownToHtml(source);
    expect(result).toContain('token_comment');
  });

  it('highlights keywords in code blocks', () => {
    const source = '```typescript\nconst x = 1;\n```';
    const result = markdownToHtml(source);
    expect(result).toContain('token_keyword');
  });

  it('highlights numbers in code blocks', () => {
    const source = '```typescript\nconst x = 42;\n```';
    const result = markdownToHtml(source);
    expect(result).toContain('token_number');
  });
});
