import { marked } from 'marked';

export function markdownToHtml(source: string): string {
  const tokens = marked.lexer(source);
  const html = marked.parser(tokens);
  
  let result = html;
  
  result = result.replace(/<pre><code class="language-mermaid">(.*?)<\/code><\/pre>/gs, (match, code) => {
    return `<div class="mermaid">${code.trim()}</div>`;
  });
  
  return result;
}

export function isMermaidBlock(token: unknown): boolean {
  if (!token || typeof token !== 'object') {
    return false;
  }
  
  const t = token as { type: string; lang?: string; text?: string };
  
  return t.type === 'code' && t.lang === 'mermaid';
}
