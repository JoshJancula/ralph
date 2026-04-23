import { describe, it, expect } from 'vitest';
import { sanitizeHtmlDocument } from '../src/app/utils/sanitize-html';

describe('sanitizeHtmlDocument', () => {
  it('removes script tags and unsafe attributes', () => {
    const parser = new DOMParser();
    const doc = parser.parseFromString(
      '<div><script>alert()</script><a href="javascript:alert(1)">link</a><span onclick="evil">text</span><img srcdoc="<svg></svg>"></div>',
      'text/html',
    );

    sanitizeHtmlDocument(doc.body);

    expect(doc.querySelector('script')).toBeNull();
    expect(doc.querySelector('a')?.getAttribute('href')).toBeNull();
    expect(doc.querySelector('span')?.hasAttribute('onclick')).toBe(false);
    expect(doc.querySelector('img')?.hasAttribute('srcdoc')).toBe(false);
  });
});
