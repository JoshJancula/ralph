import { prettifyDocFileName } from './prettify-doc-filename';

describe('prettifyDocFileName', () => {
  it('title-cases hyphenated markdown basenames', () => {
    expect(prettifyDocFileName('AGENT-WORKFLOW.md')).toBe('Agent Workflow');
    expect(prettifyDocFileName('ENVIRONMENT.md')).toBe('Environment');
  });

  it('handles underscores and alternate extensions', () => {
    expect(prettifyDocFileName('HELP_AND_TROUBLESHOOTING.md')).toBe('Help And Troubleshooting');
    expect(prettifyDocFileName('GUIDE.mdx')).toBe('Guide');
    expect(prettifyDocFileName('note.txt')).toBe('Note');
  });

  it('preserves common acronym tokens', () => {
    expect(prettifyDocFileName('MCP.md')).toBe('MCP');
  });
});
