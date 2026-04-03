import { marked, Renderer } from 'marked';

function escapeHtml(input: string): string {
  return input
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function basicHighlight(code: string): string {
  // First, escape HTML entities in the code
  let result = escapeHtml(code);

  // Apply syntax highlighting - order matters to avoid conflicts
  // Use single quotes for class attributes to avoid matching the quotes we add

  // Comments first (before strings, since comments can contain quotes)
  result = result.replace(
    /(\/\/[^\n]*|\/\*[\s\S]*?\*\/)/g,
    '<span class=\'token_comment\'>$1</span>',
  );

  // Strings (single, double, and template literals)
  result = result.replace(
    /("[^"\\]*(?:\\.[^"\\]*)*"|'[^'\\]*(?:\\.[^'\\]*)*'|`[^`\\]*(?:\\.[^`\\]*)*`)/g,
    '<span class=\'token_string\'>$1</span>',
  );

  // Keywords
  result = result.replace(
    /\b(const|let|var|function|return|if|else|for|while|do|switch|case|break|continue|try|catch|finally|throw|class|extends|new|this|super|import|export|from|as|interface|type|implements|public|private|protected|readonly|async|await)\b/g,
    '<span class=\'token_keyword\'>$1</span>',
  );

  // Numbers
  result = result.replace(
    /(\b\d+(?:\.\d+)?\b)/g,
    '<span class=\'token_number\'>$1</span>',
  );

  return result;
}

export function markdownToHtml(source: string): string {
  const renderer = new Renderer();

  renderer.code = ({ text, lang }) => {
    const code = text || '';
    const language = (lang || '').trim();

    if (language === 'mermaid') {
      return `<div class="mermaid">${code.trim()}</div>`;
    }

    const highlighted = basicHighlight(code);
    const className = language ? `language-${language}` : '';
    return `<pre><code class="hljs ${className}">${highlighted}</code></pre>`;
  };

  marked.setOptions({
    renderer,
    gfm: true,
    breaks: false,
    async: false,
  });

  return marked.parse(source, { async: false }) as string;
}

export function isMermaidBlock(token: unknown): boolean {
  if (!token || typeof token !== 'object') {
    return false;
  }

  const t = token as { type: string; lang?: string; text?: string };

  return t.type === 'code' && t.lang === 'mermaid';
}
