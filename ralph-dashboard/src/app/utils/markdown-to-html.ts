import { marked, Renderer } from 'marked';

function escapeHtml(input: string): string {
  return input
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function replaceOutsideTags(
  html: string,
  pattern: RegExp,
  replacement: (match: string, ...groups: string[]) => string,
): string {
  return html
    .split(/(<[^>]+>)/g)
    .map((part) => (part.startsWith('<') ? part : part.replace(pattern, replacement)))
    .join('');
}

function basicHighlight(code: string): string {
  // First, escape HTML entities in the code
  let result = escapeHtml(code);

  // Apply syntax highlighting while leaving previously inserted span tags alone.
  result = replaceOutsideTags(
    result,
    /(\/\/[^\n]*|\/\*[\s\S]*?\*\/)/g,
    (match) => `<span class='token_comment'>${match}</span>`,
  );

  result = replaceOutsideTags(
    result,
    /("[^"\\]*(?:\\.[^"\\]*)*"|'[^'\\]*(?:\\.[^'\\]*)*'|`[^`\\]*(?:\\.[^`\\]*)*`)/g,
    (match) => `<span class='token_string'>${match}</span>`,
  );

  result = replaceOutsideTags(
    result,
    /\b(const|let|var|function|return|if|else|for|while|do|switch|case|break|continue|try|catch|finally|throw|class|extends|new|this|super|import|export|from|as|interface|type|implements|public|private|protected|readonly|async|await)\b/g,
    (match) => `<span class='token_keyword'>${match}</span>`,
  );

  result = replaceOutsideTags(result, /(\b\d+(?:\.\d+)?\b)/g, (match) => {
    return `<span class='token_number'>${match}</span>`;
  });

  return result;
}

export function markdownToHtml(source: string): string {
  const renderer = new Renderer();

  renderer.code = ({ text, lang }) => {
    const code = text || '';
    const language = (lang || '').trim();

    if (language === 'mermaid') {
      return `<pre><code class="language-mermaid">${escapeHtml(code.trim())}</code></pre>`;
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
