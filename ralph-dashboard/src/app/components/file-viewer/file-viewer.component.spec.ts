import '../../../angular-test-env';
import { HttpClientTestingModule, HttpTestingController, TestRequest } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { FileViewerComponent } from './file-viewer.component';
import { markdownToHtml } from '../../utils/markdown-to-html';

function requestPath(url: string): string {
  const q = url.indexOf('?');
  return q === -1 ? url : url.slice(0, q);
}

describe('FileViewerComponent', () => {
  let httpMock: HttpTestingController;

  beforeEach(async () => {
    TestBed.resetTestingModule();
    await TestBed.configureTestingModule({
      imports: [FileViewerComponent, HttpClientTestingModule],
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

  it('.md file: content is rendered via markdownToHtml into [innerHTML]', async () => {
    const fixture = TestBed.createComponent(FileViewerComponent);
    const raw = '# Hello from md';
    fixture.componentInstance.filePath = 'PLAN2/notes.md';
    fixture.componentInstance.root = 'plans';
    fixture.detectChanges();

    const req = expectFileRequest('plans', 'PLAN2/notes.md');
    req.flush({ content: raw, size: raw.length, offset: 0, nextOffset: 0 });
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

    const req = expectFileRequest('plans', 'PLAN2/diagram.md');
    req.flush({ content: raw, size: raw.length, offset: 0, nextOffset: 0 });
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

    const req = expectFileRequest('plans', 'PLAN2/config.json');
    req.flush({ content: raw, size: raw.length, offset: 0, nextOffset: 0 });
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

    const req = expectFileRequest('logs', 'PLAN2/readme.txt');
    req.flush({ content: raw, size: raw.length, offset: 0, nextOffset: 0 });
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
    expect(el.querySelector('.loading-indicator')?.textContent?.trim()).toBe('Loading...');

    const req = expectFileRequest('plans', 'PLAN2/x.md');
    req.flush({ content: 'ok', size: 2, offset: 0, nextOffset: 0 });
    await fixture.whenStable();
    fixture.detectChanges();

    expect(el.querySelector('.loading-indicator')).toBeNull();
  });

  it('error state shown when fetch fails', async () => {
    const fixture = TestBed.createComponent(FileViewerComponent);
    fixture.componentInstance.filePath = 'PLAN2/missing.md';
    fixture.componentInstance.root = 'plans';
    fixture.detectChanges();

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

    const req = expectFileRequest('plans', 'PLAN2/page.md');
    req.flush({ content: raw, size: raw.length, offset: 0, nextOffset: 0 });
    await fixture.whenStable();
    fixture.detectChanges();

    const el = fixture.nativeElement as HTMLElement;
    const btn = el.querySelector('.file-toolbar button') as HTMLButtonElement;
    expect(btn?.textContent?.trim()).toBe('View source');
    expect(el.querySelector('.markdown-content')).toBeTruthy();

    btn.click();
    fixture.detectChanges();

    expect(fixture.componentInstance.isRendered()).toBe(false);
    expect(btn.textContent?.trim()).toBe('View rendered');
    expect(el.querySelector('.markdown-content')).toBeNull();

    btn.click();
    fixture.detectChanges();

    expect(fixture.componentInstance.isRendered()).toBe(true);
    expect(btn.textContent?.trim()).toBe('View source');
    expect(el.querySelector('.markdown-content')).toBeTruthy();
  });
});
