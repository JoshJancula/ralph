import { marked } from 'marked';
import { markdownToHtml, isMermaidBlock } from '../src/app/utils/markdown-to-html';
import { parseDashboardFileHash, buildDashboardFileHash } from '../src/app/utils/dashboard-file-hash';
import { isUnsafeUrl, sanitizeHtmlDocument } from '../src/app/utils/sanitize-html';

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

  it('converts a ` ```mermaid ` fenced block to <pre><code class="language-mermaid">', () => {
    const source = `Some text

\`\`\`mermaid
graph TD
    A --> B
    B --> C
\`\`\`

More text
`;

    const result = markdownToHtml(source);

    expect(result).toContain('<pre><code class="language-mermaid">');
    expect(result).toContain('graph TD');
    expect(result).toContain('A --&gt; B');
    expect(result).toContain('B --&gt; C');
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

  it('preserves apostrophes in highlighted code instead of escaping them as entities', () => {
    const source = `\`\`\`ts
const label = 'app-sidebar-tree';
\`\`\``;

    const result = markdownToHtml(source);

    expect(result).toContain("'app-sidebar-tree'");
    expect(result).not.toContain('&#39;');
    expect(result).not.toContain('&amp;#39;');
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

describe('sanitizeHtmlDocument', () => {
  it('removes blocked tags and unsafe attributes while keeping safe content', () => {
    const script = createFakeElement('script', {});
    const iframe = createFakeElement('iframe', { src: 'https://example.com' });
    const link = createFakeElement('a', {
      href: 'javascript:alert(1)',
      onclick: 'evil()',
      'data-safe': 'keep',
    });
    const image = createFakeElement('img', {
      src: 'https://example.com/image.png',
      onerror: 'evil()',
      srcdoc: '<p>ignored</p>',
    });
    const form = createFakeElement('form', {
      action: ' data:application/javascript,alert(1) ',
      formaction: '/submit',
    });
    const root = createFakeRoot([script, iframe, link, image, form]);

    sanitizeHtmlDocument(root);

    expect(script.removed).toBe(true);
    expect(iframe.removed).toBe(true);
    expect(link.getAttribute('href')).toBeNull();
    expect(link.getAttribute('data-safe')).toBe('keep');
    expect(link.hasAttribute('onclick')).toBe(false);
    expect(image.getAttribute('src')).toBe('https://example.com/image.png');
    expect(image.hasAttribute('onerror')).toBe(false);
    expect(image.hasAttribute('srcdoc')).toBe(false);
    expect(form.getAttribute('action')).toBeNull();
    expect(form.getAttribute('formaction')).toBe('/submit');
  });
});

describe('isUnsafeUrl', () => {
  it.each([
    ['javascript:alert(1)', true],
    ['  JaVaScRiPt:alert(1)', true],
    ['vbscript:alert(1)', true],
    ['data:text/html,<svg></svg>', true],
    ['data:application/javascript,alert(1)', true],
    ['data:application/ecmascript,alert(1)', true],
    ['data:application/x-javascript,alert(1)', true],
    ['https://example.com', false],
    ['/relative/path', false],
    ['mailto:team@example.com', false],
  ])('returns %s -> %s', (value, expected) => {
    expect(isUnsafeUrl(value)).toBe(expected);
  });
});

function createFakeRoot(elements: FakeElement[]): ParentNode {
  return {
    querySelectorAll: () => elements,
  } as unknown as ParentNode;
}

function createFakeElement(
  tagName: string,
  initialAttributes: Record<string, string>,
): FakeElement {
  const attributes = new Map(Object.entries(initialAttributes));

  return {
    tagName: tagName.toUpperCase(),
    removed: false,
    get attributes() {
      return Array.from(attributes.entries()).map(([name, value]) => ({ name, value }));
    },
    remove() {
      this.removed = true;
    },
    removeAttribute(name: string) {
      for (const key of Array.from(attributes.keys())) {
        if (key.toLowerCase() === name.toLowerCase()) {
          attributes.delete(key);
        }
      }
    },
    getAttribute(name: string) {
      for (const [key, value] of attributes.entries()) {
        if (key.toLowerCase() === name.toLowerCase()) {
          return value;
        }
      }
      return null;
    },
    hasAttribute(name: string) {
      return this.getAttribute(name) !== null;
    },
  } as FakeElement;
}

type FakeElement = {
  tagName: string;
  removed: boolean;
  readonly attributes: Array<{ name: string; value: string }>;
  remove: () => void;
  removeAttribute: (name: string) => void;
  getAttribute: (name: string) => string | null;
  hasAttribute: (name: string) => boolean;
};
