/** Uppercase labels for common doc basename tokens (matched case-insensitively). */
const DOC_TITLE_ACRONYMS = new Set([
  'api',
  'ci',
  'cli',
  'http',
  'https',
  'json',
  'mcp',
  'qa',
  'ssr',
  'ui',
  'url',
  'ux',
  'yaml',
]);

/** Turn `AGENT-WORKFLOW.md` into `Agent Workflow` for doc hub display. */
export function prettifyDocFileName(fileName: string): string {
  const base = fileName.replace(/\.(md|mdx|txt)$/i, '');
  return base
    .split(/[-_]+/)
    .filter((segment) => segment.length > 0)
    .map((segment) => {
      const lower = segment.toLowerCase();
      if (DOC_TITLE_ACRONYMS.has(lower)) {
        return lower.toUpperCase();
      }
      return lower.charAt(0).toUpperCase() + lower.slice(1);
    })
    .join(' ');
}
