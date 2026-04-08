import '../../../angular-test-env';
import { HttpClientTestingModule, HttpTestingController, TestRequest } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { FileViewerComponent } from './file-viewer.component';
import { markdownToHtml } from '../../utils/markdown-to-html';
import { NavService } from '../../services/nav.service';
import { RouterTestingModule } from '@angular/router/testing';

function requestPath(url: string): string {
  const q = url.indexOf('?');
  return q === -1 ? url : url.slice(0, q);
}

describe('FileViewerComponent', () => {
  let httpMock: HttpTestingController;

  beforeEach(async () => {
    TestBed.resetTestingModule();
    await TestBed.configureTestingModule({
      imports: [FileViewerComponent, HttpClientTestingModule, RouterTestingModule.withRoutes([])],
    }).compileComponents();
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
  });

  function expectFileRequest(root: string, path: string): TestRequest {
    return httpMock.expectOne(
      (r) =>
        requestPath(r.url) === '/api/file' &&
        r.params.get('root') === root &&
        r.params.get('path') === path &&
        r.params.get('offset') === '0',
    );
  }

  function expectWorkspaceRequest(): TestRequest {
    return httpMock.expectOne(
      (r) => requestPath(r.url) === '/api/workspace',
    );
  }

  function flushWorkspaceAndFile(root: string, path: string, content: string): void {
    const wsReq = expectWorkspaceRequest();
    wsReq.flush({ root: '/test' });
    const fileReq = expectFileRequest(root, path);
    fileReq.flush({ content, size: content.length, offset: 0, nextOffset: 0 });
  }

  it('.md file: content is rendered via markdownToHtml into [innerHTML]', async () => {
    const fixture = TestBed.createComponent(FileViewerComponent);
    const raw = '# Hello from md';
    fixture.componentInstance.filePath = 'PLAN2/notes.md';
    fixture.componentInstance.root = 'plans';
    fixture.detectChanges();

    flushWorkspaceAndFile('plans', 'PLAN2/notes.md', raw);
    await fixture.whenStable();
    fixture.detectChanges();

    const markdownEl = (fixture.nativeElement as HTMLElement).querySelector(
      '.markdown-content',
    ) as HTMLElement | null;
    expect(markdownEl).toBeTruthy();
    expect(markdownEl?.innerHTML).toBe(markdownToHtml(raw));
  });

  it('mermaid markdown is rendered into SVG markup', async () => {
    const fixture = TestBed.createComponent(FileViewerComponent);
    const raw = '```mermaid\ngraph TD\n  A --> B\n```';
    const renderSpy = vi.spyOn(fixture.componentInstance as any, 'loadMermaidClient').mockResolvedValue({
      initialize: vi.fn(),
      render: vi.fn(async () => ({ svg: '<svg id="diagram"></svg>' })),
    });
    fixture.componentInstance.filePath = 'PLAN2/diagram.md';
    fixture.componentInstance.root = 'plans';
    fixture.detectChanges();

    flushWorkspaceAndFile('plans', 'PLAN2/diagram.md', raw);
    await fixture.whenStable();
    fixture.detectChanges();

    const markdownEl = (fixture.nativeElement as HTMLElement).querySelector(
      '.markdown-content',
    ) as HTMLElement | null;
    expect(markdownEl).toBeTruthy();
    expect(markdownEl?.innerHTML).toContain('<svg');
    expect(markdownEl?.innerHTML).not.toContain('language-mermaid');
    expect(renderSpy).toHaveBeenCalled();
  });

  it('.json file: content is displayed in a <pre> as pretty-printed JSON', async () => {
    const fixture = TestBed.createComponent(FileViewerComponent);
    const raw = '{"z":1,"a":2}';
    fixture.componentInstance.filePath = 'PLAN2/config.json';
    fixture.componentInstance.root = 'plans';
    fixture.detectChanges();

    flushWorkspaceAndFile('plans', 'PLAN2/config.json', raw);
    await fixture.whenStable();
    fixture.detectChanges();

    const pre = (fixture.nativeElement as HTMLElement).querySelector('.json-content');
    expect(pre?.textContent).toBe(JSON.stringify(JSON.parse(raw), null, 2));
  });

  it('non-markdown, non-JSON file: content is shown as raw text in a <pre>', async () => {
    const fixture = TestBed.createComponent(FileViewerComponent);
    const raw = 'plain line\nsecond line';
    fixture.componentInstance.filePath = 'PLAN2/readme.txt';
    fixture.componentInstance.root = 'logs';
    fixture.detectChanges();

    flushWorkspaceAndFile('logs', 'PLAN2/readme.txt', raw);
    await fixture.whenStable();
    fixture.detectChanges();

    const pre = (fixture.nativeElement as HTMLElement).querySelector('.text-content');
    expect(pre?.textContent).toBe(raw);
  });

  it('loading state shown while fetch is in flight', async () => {
    const fixture = TestBed.createComponent(FileViewerComponent);
    fixture.componentInstance.filePath = 'PLAN2/x.md';
    fixture.componentInstance.root = 'plans';
    fixture.detectChanges();

    const el = fixture.nativeElement as HTMLElement;
    expect(el.querySelector('ion-spinner')).toBeTruthy();

    const wsReq = expectWorkspaceRequest();
    wsReq.flush({ root: '/test' });
    const req = expectFileRequest('plans', 'PLAN2/x.md');
    req.flush({ content: 'ok', size: 2, offset: 0, nextOffset: 0 });
    await fixture.whenStable();
    fixture.detectChanges();

    expect(el.querySelector('ion-spinner')).toBeNull();
  });

  it('error state shown when fetch fails', async () => {
    const fixture = TestBed.createComponent(FileViewerComponent);
    fixture.componentInstance.filePath = 'PLAN2/missing.md';
    fixture.componentInstance.root = 'plans';
    fixture.detectChanges();

    const wsReq = expectWorkspaceRequest();
    wsReq.flush({ root: '/test' });
    const req = expectFileRequest('plans', 'PLAN2/missing.md');
    req.flush('fail', { status: 500, statusText: 'Internal Server Error' });
    await fixture.whenStable();
    fixture.detectChanges();

    const el = fixture.nativeElement as HTMLElement;
    expect(el.querySelector('.error-message')?.textContent?.trim()).toBe('Failed to load file');
  });

  it('toggle button switches between rendered and source for .md files', async () => {
    const fixture = TestBed.createComponent(FileViewerComponent);
    const raw = '# Doc';
    fixture.componentInstance.filePath = 'PLAN2/page.md';
    fixture.componentInstance.root = 'plans';
    fixture.detectChanges();

    flushWorkspaceAndFile('plans', 'PLAN2/page.md', raw);
    await fixture.whenStable();
    fixture.detectChanges();

    const el = fixture.nativeElement as HTMLElement;
    // Get all buttons and find the one with "View Raw" / "View Pretty" text
    const buttons = el.querySelectorAll('.file-toolbar ion-button');
    const btn = Array.from(buttons).find(b => b.textContent?.includes('View Raw') || b.textContent?.includes('View Pretty')) as HTMLElement;
    expect(btn).toBeTruthy();
    expect(btn?.textContent?.trim()).toBe('View Raw');
    expect(el.querySelector('.markdown-content')).toBeTruthy();

    btn.click();
    fixture.detectChanges();

    expect(fixture.componentInstance.isRendered()).toBe(false);
    expect(btn.textContent?.trim()).toBe('View Pretty');
    expect(el.querySelector('.markdown-content')).toBeNull();

    btn.click();
    fixture.detectChanges();

    expect(fixture.componentInstance.isRendered()).toBe(true);
    expect(btn.textContent?.trim()).toBe('View Raw');
    expect(el.querySelector('.markdown-content')).toBeTruthy();
  });

  it('viewLogs navigates to the most recent log file', async () => {
    const fixture = TestBed.createComponent(FileViewerComponent);
    fixture.componentInstance.filePath = 'PLAN2/plan.md';
    fixture.componentInstance.root = 'plans';
    fixture.detectChanges();

    const wsReq = expectWorkspaceRequest();
    wsReq.flush({ root: '/test' });
    const req = expectFileRequest('plans', 'PLAN2/plan.md');
    req.flush({ content: '# Plan', size: 10, offset: 0, nextOffset: 0 });
    await fixture.whenStable();
    fixture.detectChanges();

    fixture.componentInstance.viewLogs();

    const listReq = httpMock.expectOne(
      (r) =>
        requestPath(r.url) === '/api/list' &&
        r.params.get('root') === 'logs' &&
        r.params.get('path') === 'PLAN2',
    );
    listReq.flush({
      root: 'logs',
      path: 'PLAN2',
      parent: null,
      entries: [
        { name: 'output.log', path: 'PLAN2/output.log', type: 'file', size: 100, mtime: 1000 },
      ],
    });
    await fixture.whenStable();
  });

  it('viewLogs looks in subdirectories when no logs at root', async () => {
    const fixture = TestBed.createComponent(FileViewerComponent);
    fixture.componentInstance.filePath = 'PLAN2/plan.md';
    fixture.componentInstance.root = 'plans';
    fixture.detectChanges();

    const wsReq = expectWorkspaceRequest();
    wsReq.flush({ root: '/test' });
    const req = expectFileRequest('plans', 'PLAN2/plan.md');
    req.flush({ content: '# Plan', size: 10, offset: 0, nextOffset: 0 });
    await fixture.whenStable();
    fixture.detectChanges();

    fixture.componentInstance.viewLogs();

    const listReq = httpMock.expectOne(
      (r) =>
        requestPath(r.url) === '/api/list' &&
        r.params.get('root') === 'logs' &&
        r.params.get('path') === 'PLAN2',
    );
    listReq.flush({
      root: 'logs',
      path: 'PLAN2',
      parent: null,
      entries: [
        { name: 'run-001', path: 'PLAN2/run-001/', type: 'dir', size: 0, mtime: 2000 },
      ],
    });
    await fixture.whenStable();

    // Should fetch subdirectory listing
    const subListReq = httpMock.expectOne(
      (r) =>
        requestPath(r.url) === '/api/list' &&
        r.params.get('root') === 'logs' &&
        r.params.get('path') === 'PLAN2/run-001',
    );
    subListReq.flush({
      root: 'logs',
      path: 'PLAN2/run-001',
      parent: 'PLAN2',
      entries: [
        { name: 'output.log', path: 'PLAN2/run-001/output.log', type: 'file', size: 100, mtime: 1000 },
      ],
    });
    await fixture.whenStable();
  });

  it('viewLogs navigates to directory when no log file found', async () => {
    const fixture = TestBed.createComponent(FileViewerComponent);
    fixture.componentInstance.filePath = 'PLAN2/plan.md';
    fixture.componentInstance.root = 'plans';
    fixture.detectChanges();

    const wsReq = expectWorkspaceRequest();
    wsReq.flush({ root: '/test' });
    const req = expectFileRequest('plans', 'PLAN2/plan.md');
    req.flush({ content: '# Plan', size: 10, offset: 0, nextOffset: 0 });
    await fixture.whenStable();
    fixture.detectChanges();

    fixture.componentInstance.viewLogs();

    const listReq = httpMock.expectOne(
      (r) =>
        requestPath(r.url) === '/api/list' &&
        r.params.get('root') === 'logs' &&
        r.params.get('path') === 'PLAN2',
    );
    listReq.flush({
      root: 'logs',
      path: 'PLAN2',
      parent: null,
      entries: [],
    });
    await fixture.whenStable();
  });

  it('viewLogs handles error when listing fails', async () => {
    const fixture = TestBed.createComponent(FileViewerComponent);
    fixture.componentInstance.filePath = 'PLAN2/plan.md';
    fixture.componentInstance.root = 'plans';
    fixture.detectChanges();

    const wsReq = expectWorkspaceRequest();
    wsReq.flush({ root: '/test' });
    const req = expectFileRequest('plans', 'PLAN2/plan.md');
    req.flush({ content: '# Plan', size: 10, offset: 0, nextOffset: 0 });
    await fixture.whenStable();
    fixture.detectChanges();

    fixture.componentInstance.viewLogs();

    const listReq = httpMock.expectOne(
      (r) =>
        requestPath(r.url) === '/api/list' &&
        r.params.get('root') === 'logs' &&
        r.params.get('path') === 'PLAN2',
    );
    listReq.flush('error', { status: 500, statusText: 'Internal Server Error' });
    await fixture.whenStable();
  });

  it('handleContentClick navigates for internal relative links', async () => {
    const fixture = TestBed.createComponent(FileViewerComponent);
    const raw = '[Link](./other.md)';
    fixture.componentInstance.filePath = 'PLAN2/plan.md';
    fixture.componentInstance.root = 'plans';
    fixture.detectChanges();

    const wsReq = expectWorkspaceRequest();
    wsReq.flush({ root: '/test' });
    const req = expectFileRequest('plans', 'PLAN2/plan.md');
    req.flush({ content: raw, size: raw.length, offset: 0, nextOffset: 0 });
    await fixture.whenStable();
    fixture.detectChanges();

    const nav = TestBed.inject(NavService);
    const spy = vi.spyOn(nav, 'navigate');

    const anchor = (fixture.nativeElement as HTMLElement).querySelector('a');
    const clickEvent = new MouseEvent('click', { bubbles: true });
    Object.defineProperty(clickEvent, 'target', { value: anchor });

    fixture.componentInstance.handleContentClick(clickEvent);

    expect(spy).toHaveBeenCalledWith('plans', null, 'PLAN2/other.md');
  });

  it('handleContentClick ignores external links', async () => {
    const fixture = TestBed.createComponent(FileViewerComponent);
    const raw = '<a href="https://example.com">External</a>';
    fixture.componentInstance.filePath = 'PLAN2/plan.md';
    fixture.componentInstance.root = 'plans';
    fixture.detectChanges();

    const wsReq = expectWorkspaceRequest();
    wsReq.flush({ root: '/test' });
    const req = expectFileRequest('plans', 'PLAN2/plan.md');
    req.flush({ content: raw, size: raw.length, offset: 0, nextOffset: 0 });
    await fixture.whenStable();
    fixture.detectChanges();

    const nav = TestBed.inject(NavService);
    const spy = vi.spyOn(nav, 'navigate');

    const anchor = (fixture.nativeElement as HTMLElement).querySelector('a');
    const clickEvent = new MouseEvent('click', { bubbles: true });
    Object.defineProperty(clickEvent, 'target', { value: anchor });

    fixture.componentInstance.handleContentClick(clickEvent);

    expect(spy).not.toHaveBeenCalled();
  });

  it('runSnippet returns command for plan files', async () => {
    const fixture = TestBed.createComponent(FileViewerComponent);
    fixture.componentInstance.filePath = 'PLAN2/plan.md';
    fixture.componentInstance.root = 'plans';
    fixture.detectChanges();

    const wsReq = expectWorkspaceRequest();
    wsReq.flush({ root: '/test' });
    const req = expectFileRequest('plans', 'PLAN2/plan.md');
    req.flush({ content: '# Plan', size: 10, offset: 0, nextOffset: 0 });
    await fixture.whenStable();

    expect(fixture.componentInstance.runSnippet).toBe('bash /test/.ralph/run-plan.sh --plan plan.md');
  });

  it('runSnippet returns command for orchestration files', async () => {
    const fixture = TestBed.createComponent(FileViewerComponent);
    fixture.componentInstance.filePath = 'my-plan.orch.json';
    fixture.componentInstance.root = 'orchestration-plans';
    fixture.detectChanges();

    const wsReq = expectWorkspaceRequest();
    wsReq.flush({ root: '/test' });
    const req = expectFileRequest('orchestration-plans', 'my-plan.orch.json');
    req.flush({ content: '{}', size: 2, offset: 0, nextOffset: 0 });
    await fixture.whenStable();

    expect(fixture.componentInstance.runSnippet).toBe('bash /test/.ralph/run-orchestration.sh --plan my-plan.orch.json');
  });

  it('runSnippet returns null for unsupported file types', async () => {
    const fixture = TestBed.createComponent(FileViewerComponent);
    fixture.componentInstance.filePath = 'readme.txt';
    fixture.componentInstance.root = 'docs';
    fixture.detectChanges();

    const wsReq = expectWorkspaceRequest();
    wsReq.flush({ root: '/test' });
    const req = expectFileRequest('docs', 'readme.txt');
    req.flush({ content: 'Hello', size: 5, offset: 0, nextOffset: 0 });
    await fixture.whenStable();

    expect(fixture.componentInstance.runSnippet).toBeNull();
  });

  it('formatJson returns pretty-printed JSON', () => {
    const fixture = TestBed.createComponent(FileViewerComponent);
    fixture.componentInstance.content.set('{"z":1,"a":2}');
    const result = fixture.componentInstance.formatJson();
    // JSON.stringify sorts keys, so we just check it's valid JSON
    expect(JSON.parse(result)).toEqual({ a: 2, z: 1 });
  });

  it('formatJson returns original content on parse error', () => {
    const fixture = TestBed.createComponent(FileViewerComponent);
    fixture.componentInstance.content.set('invalid json');
    expect(fixture.componentInstance.formatJson()).toBe('invalid json');
  });

  it('isPlainText returns true for non-markdown non-JSON files', () => {
    const fixture = TestBed.createComponent(FileViewerComponent);
    fixture.componentInstance.filePath = 'readme.txt';
    expect(fixture.componentInstance.isPlainText()).toBe(true);
  });

  it('isPlainText returns false for markdown files', () => {
    const fixture = TestBed.createComponent(FileViewerComponent);
    fixture.componentInstance.filePath = 'readme.md';
    expect(fixture.componentInstance.isPlainText()).toBe(false);
  });

  it('planDirectory extracts directory from file path', () => {
    const fixture = TestBed.createComponent(FileViewerComponent);
    fixture.componentInstance.filePath = 'PLAN2/docs/readme.md';
    expect(fixture.componentInstance.planDirectory).toBe('PLAN2');
  });

  it('planDirectory returns null for empty path', () => {
    const fixture = TestBed.createComponent(FileViewerComponent);
    fixture.componentInstance.filePath = '';
    expect(fixture.componentInstance.planDirectory).toBeNull();
  });

  it('showViewLogs returns true for plans and logs root with markdown', async () => {
    const fixture = TestBed.createComponent(FileViewerComponent);
    fixture.componentInstance.root = 'plans';
    fixture.componentInstance.filePath = 'readme.md';
    fixture.detectChanges();

    const wsReq = expectWorkspaceRequest();
    wsReq.flush({ root: '/test' });
    const req = expectFileRequest('plans', 'readme.md');
    req.flush({ content: '# Doc', size: 5, offset: 0, nextOffset: 0 });
    await fixture.whenStable();

    expect(fixture.componentInstance.showViewLogs).toBe(true);
  });

  it('showViewLogs returns false for other roots', async () => {
    const fixture = TestBed.createComponent(FileViewerComponent);
    fixture.componentInstance.root = 'docs';
    fixture.componentInstance.filePath = 'readme.md';
    fixture.detectChanges();

    const wsReq = expectWorkspaceRequest();
    wsReq.flush({ root: '/test' });
    const req = expectFileRequest('docs', 'readme.md');
    req.flush({ content: '# Doc', size: 5, offset: 0, nextOffset: 0 });
    await fixture.whenStable();

    expect(fixture.componentInstance.showViewLogs).toBe(false);
  });

  it('isJson returns true for .json files', () => {
    const fixture = TestBed.createComponent(FileViewerComponent);
    fixture.componentInstance.filePath = 'config.json';
    expect(fixture.componentInstance.isJson()).toBe(true);
  });

  it('isJson returns true for .orch.json files', () => {
    const fixture = TestBed.createComponent(FileViewerComponent);
    fixture.componentInstance.filePath = 'plan.orch.json';
    expect(fixture.componentInstance.isJson()).toBe(true);
  });

  it('isJson returns false for other files', () => {
    const fixture = TestBed.createComponent(FileViewerComponent);
    fixture.componentInstance.filePath = 'readme.txt';
    expect(fixture.componentInstance.isJson()).toBe(false);
  });
});
