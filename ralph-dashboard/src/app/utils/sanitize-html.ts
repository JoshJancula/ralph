const BLOCKED_TAGS = new Set(['script', 'iframe', 'object', 'embed', 'template', 'link', 'meta']);
const URL_ATTRIBUTES = new Set(['href', 'src', 'xlink:href', 'action', 'formaction', 'poster', 'data']);

export function sanitizeHtmlDocument(root: ParentNode): void {
  const elements = Array.from(root.querySelectorAll('*'));

  for (const element of elements) {
    const tagName = element.tagName.toLowerCase();
    if (BLOCKED_TAGS.has(tagName)) {
      element.remove();
      continue;
    }

    for (const attr of Array.from(element.attributes)) {
      const attrName = attr.name.toLowerCase();
      if (attrName.startsWith('on') || attrName === 'srcdoc') {
        element.removeAttribute(attr.name);
        continue;
      }

      if (URL_ATTRIBUTES.has(attrName) && isUnsafeUrl(attr.value)) {
        element.removeAttribute(attr.name);
      }
    }
  }
}

export function isUnsafeUrl(value: string): boolean {
  const normalized = value.trim().toLowerCase().replace(/\s+/g, '');
  return (
    normalized.startsWith('javascript:') ||
    normalized.startsWith('vbscript:') ||
    normalized.startsWith('data:text/html') ||
    normalized.startsWith('data:application/javascript') ||
    normalized.startsWith('data:application/ecmascript') ||
    normalized.startsWith('data:application/x-javascript')
  );
}
