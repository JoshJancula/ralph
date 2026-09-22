import '../../../angular-test-env';
import { HttpClientTestingModule, HttpTestingController, TestRequest } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { ApiService, FileChunk } from '../../services/api.service';
import { PlanDetailComponent } from './plan-detail.component';
import { NavService } from '../../services/nav.service';
import { Router } from '@angular/router';
import { RouterTestingModule } from '@angular/router/testing';

describe('PlanDetailComponent', () => {
  let httpMock: HttpTestingController;

  beforeEach(async () => {
    TestBed.resetTestingModule();
    await TestBed.configureTestingModule({
      imports: [PlanDetailComponent, HttpClientTestingModule, RouterTestingModule.withRoutes([])],
    }).compileComponents();

    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
  });

  function expectFileRequest(root: string, path: string): TestRequest {
    return httpMock.expectOne(
      (r) =>
        r.url.includes('/api/file') &&
        r.params.get('root') === root &&
        r.params.get('path') === path &&
        r.params.get('offset') === '0',
    );
  }

  function flushWorkspaceAndFile(root: string, path: string, content: string): void {
    const fileReq = expectFileRequest(root, path);
    fileReq.flush({ content, size: content.length, offset: 0, nextOffset: 0 });
  }

  describe('classic markdown plans', () => {
    it('should load and parse classic plan', async () => {
      const fixture = TestBed.createComponent(PlanDetailComponent);
      const content = '# Test Plan\n- [ ] First task\n- [ ] Second task';

      fixture.componentInstance.root.set('plans');
      fixture.componentInstance.filePath.set('TEST.md');
      fixture.detectChanges();

      flushWorkspaceAndFile('plans', 'TEST.md', content);
      await fixture.whenStable();
      fixture.detectChanges();

      const parsed = fixture.componentInstance.parsedPlan();
      expect(parsed).toBeTruthy();
      expect(parsed?.format).toBe('classic');
      expect(parsed?.todos).toHaveLength(2);
      expect(parsed?.todos[0].content).toContain('First');
    });

    it('should display classic plan header with progress', async () => {
      const fixture = TestBed.createComponent(PlanDetailComponent);
      const content = '- [x] Done\n- [ ] Open';

      fixture.componentInstance.root.set('plans');
      fixture.componentInstance.filePath.set('TEST.md');
      fixture.detectChanges();

      flushWorkspaceAndFile('plans', 'TEST.md', content);
      await fixture.whenStable();
      fixture.detectChanges();

      const progressEl = (fixture.nativeElement as HTMLElement).querySelector('.plan-progress');
      expect(progressEl?.textContent).toContain('1/2');
    });

    it('should render markdown content in rendered mode', async () => {
      const fixture = TestBed.createComponent(PlanDetailComponent);
      const content = '# Heading\n- [ ] Task\n\nSome paragraph text';

      fixture.componentInstance.root.set('plans');
      fixture.componentInstance.filePath.set('TEST.md');
      fixture.detectChanges();

      flushWorkspaceAndFile('plans', 'TEST.md', content);
      await fixture.whenStable();
      fixture.detectChanges();

      expect(fixture.componentInstance.viewMode()).toBe('rendered');
      const markdownEl = (fixture.nativeElement as HTMLElement).querySelector('.markdown-content');
      expect(markdownEl).toBeTruthy();
    });

    it('should toggle to source mode and show raw content', async () => {
      const fixture = TestBed.createComponent(PlanDetailComponent);
      const content = '# Test\n- [ ] Task';

      fixture.componentInstance.root.set('plans');
      fixture.componentInstance.filePath.set('TEST.md');
      fixture.detectChanges();

      flushWorkspaceAndFile('plans', 'TEST.md', content);
      await fixture.whenStable();
      fixture.detectChanges();

      fixture.componentInstance.toggleViewMode('source');
      fixture.detectChanges();

      expect(fixture.componentInstance.viewMode()).toBe('source');
      const sourceEl = (fixture.nativeElement as HTMLElement).querySelector('.source-view');
      expect(sourceEl).toBeTruthy();
      expect(sourceEl?.textContent).toContain('# Test');
    });
  });

  describe('YAML frontmatter plans', () => {
    it('should load and parse YAML plan', async () => {
      const fixture = TestBed.createComponent(PlanDetailComponent);
      const content = [
        '---',
        'name: YAML Plan',
        'todos:',
        '  - id: task1',
        '    content: First task',
        '    status: pending',
        '  - id: task2',
        '    content: Second task',
        '    status: completed',
        '---',
      ].join('\n');

      fixture.componentInstance.root.set('plans');
      fixture.componentInstance.filePath.set('TEST.yaml.md');
      fixture.detectChanges();

      flushWorkspaceAndFile('plans', 'TEST.yaml.md', content);
      await fixture.whenStable();
      fixture.detectChanges();

      const parsed = fixture.componentInstance.parsedPlan();
      expect(parsed).toBeTruthy();
      expect(parsed?.format).toBe('yaml');
      expect(parsed?.todos).toHaveLength(2);
      expect(parsed?.metadata.name).toBe('YAML Plan');
    });

    it('should recognize completed status in YAML plan', async () => {
      const fixture = TestBed.createComponent(PlanDetailComponent);
      const content = [
        '---',
        'todos:',
        '  - id: task1',
        '    status: done',
        '  - id: task2',
        '    status: pending',
        '---',
      ].join('\n');

      fixture.componentInstance.root.set('plans');
      fixture.componentInstance.filePath.set('TEST.yaml.md');
      fixture.detectChanges();

      flushWorkspaceAndFile('plans', 'TEST.yaml.md', content);
      await fixture.whenStable();
      fixture.detectChanges();

      const parsed = fixture.componentInstance.parsedPlan();
      expect(parsed?.todos[0].completed).toBe(true);
      expect(parsed?.todos[1].completed).toBe(false);
    });

    it('should display YAML todos in outline', async () => {
      const fixture = TestBed.createComponent(PlanDetailComponent);
      const content = [
        '---',
        'todos:',
        '  - id: task-a',
        '    content: Do something',
        '  - id: task-b',
        '    content: Do another',
        '---',
      ].join('\n');

      fixture.componentInstance.root.set('plans');
      fixture.componentInstance.filePath.set('TEST.md');
      fixture.detectChanges();

      flushWorkspaceAndFile('plans', 'TEST.md', content);
      await fixture.whenStable();
      fixture.detectChanges();

      const todoItems = (fixture.nativeElement as HTMLElement).querySelectorAll('.todo-item');
      expect(todoItems.length).toBe(2);
    });
  });

  describe('TODO selection and details', () => {
    it('should select TODO and show details', async () => {
      const fixture = TestBed.createComponent(PlanDetailComponent);
      const content = '- [ ] First task\n  Extra details\n- [ ] Second task';

      fixture.componentInstance.root.set('plans');
      fixture.componentInstance.filePath.set('TEST.md');
      fixture.detectChanges();

      flushWorkspaceAndFile('plans', 'TEST.md', content);
      await fixture.whenStable();
      fixture.detectChanges();

      fixture.componentInstance.selectTodo(0);
      fixture.detectChanges();

      const todoDetails = (fixture.nativeElement as HTMLElement).querySelector('.todo-details');
      expect(todoDetails).toBeTruthy();
      expect(fixture.componentInstance.selectedTodoIndex()).toBe(0);
    });

    it('should update details when different TODO is selected', async () => {
      const fixture = TestBed.createComponent(PlanDetailComponent);
      const content = '- [ ] First\n- [x] Second';

      fixture.componentInstance.root.set('plans');
      fixture.componentInstance.filePath.set('TEST.md');
      fixture.detectChanges();

      flushWorkspaceAndFile('plans', 'TEST.md', content);
      await fixture.whenStable();
      fixture.detectChanges();

      fixture.componentInstance.selectTodo(1);
      fixture.detectChanges();

      const selectedTodo = fixture.componentInstance.selectedTodo();
      expect(selectedTodo?.completed).toBe(true);
    });
  });

  describe('control copy and diff view', () => {
    it('should detect when control copy is available', async () => {
      const fixture = TestBed.createComponent(PlanDetailComponent);
      const content = '- [ ] Original task';

      fixture.componentInstance.root.set('plans');
      fixture.componentInstance.filePath.set('PLAN.md');
      fixture.componentInstance.controlCopyPath.set('PLAN.md.control');
      fixture.detectChanges();

      flushWorkspaceAndFile('plans', 'PLAN.md', content);
      const controlReq = httpMock.expectOne(
        (r) =>
          r.url.includes('/api/file') &&
          r.params.get('path') === 'PLAN.md.control',
      );
      controlReq.flush({ content: '- [ ] Modified task', size: 20, offset: 0, nextOffset: 0 });

      await fixture.whenStable();
      fixture.detectChanges();

      expect(fixture.componentInstance.showDiffMode()).toBe(true);
    });

    it('should disable diff mode when no control copy exists', async () => {
      const fixture = TestBed.createComponent(PlanDetailComponent);
      const content = '- [ ] Task';

      fixture.componentInstance.root.set('plans');
      fixture.componentInstance.filePath.set('PLAN.md');
      fixture.detectChanges();

      flushWorkspaceAndFile('plans', 'PLAN.md', content);
      await fixture.whenStable();
      fixture.detectChanges();

      expect(fixture.componentInstance.showDiffMode()).toBe(false);
    });
  });

  describe('error handling', () => {
    it('should display error when file loading fails', async () => {
      const fixture = TestBed.createComponent(PlanDetailComponent);

      fixture.componentInstance.root.set('plans');
      fixture.componentInstance.filePath.set('MISSING.md');
      fixture.detectChanges();

      const fileReq = expectFileRequest('plans', 'MISSING.md');
      fileReq.error(
        new ErrorEvent('Not found'),
        { status: 404 },
      );

      await fixture.whenStable();
      fixture.detectChanges();

      const errorPanel = (fixture.nativeElement as HTMLElement).querySelector('.error-panel');
      expect(errorPanel).toBeTruthy();
    });

    it('should retry loading on error action', async () => {
      const fixture = TestBed.createComponent(PlanDetailComponent);

      fixture.componentInstance.root.set('plans');
      fixture.componentInstance.filePath.set('TEST.md');
      fixture.detectChanges();

      let fileReq = expectFileRequest('plans', 'TEST.md');
      fileReq.error(new ErrorEvent('Error'));

      await fixture.whenStable();
      fixture.detectChanges();

      fixture.componentInstance.performErrorAction('RETRY');
      fixture.detectChanges();

      fileReq = expectFileRequest('plans', 'TEST.md');
      fileReq.flush({ content: '# Plan', size: 6, offset: 0, nextOffset: 0 });

      await fixture.whenStable();
      fixture.detectChanges();

      expect(fixture.componentInstance.parsedPlan()).toBeTruthy();
    });
  });

  describe('artifact links', () => {
    it('should intercept markdown links and navigate', async () => {
      const fixture = TestBed.createComponent(PlanDetailComponent);
      const content = '# Plan\n[Link](./artifact.txt)';
      const navSpy = vi.spyOn(fixture.componentInstance['nav'], 'navigate');

      fixture.componentInstance.root.set('plans');
      fixture.componentInstance.filePath.set('TEST.md');
      fixture.detectChanges();

      flushWorkspaceAndFile('plans', 'TEST.md', content);
      await fixture.whenStable();
      fixture.detectChanges();

      const link = (fixture.nativeElement as HTMLElement).querySelector('a');
      if (link) {
        const clickEvent = new MouseEvent('click', { bubbles: true });
        link.dispatchEvent(clickEvent);
        fixture.detectChanges();

        expect(navSpy).toHaveBeenCalled();
      }
    });

    it('should not intercept external links', async () => {
      const fixture = TestBed.createComponent(PlanDetailComponent);
      const content = '# Plan\n[External](https://example.com)';
      const navSpy = vi.spyOn(fixture.componentInstance['nav'], 'navigate');

      fixture.componentInstance.root.set('plans');
      fixture.componentInstance.filePath.set('TEST.md');
      fixture.detectChanges();

      flushWorkspaceAndFile('plans', 'TEST.md', content);
      await fixture.whenStable();
      fixture.detectChanges();

      const link = (fixture.nativeElement as HTMLElement).querySelector('a[href^="https"]');
      expect(link).toBeTruthy();
      expect(navSpy).not.toHaveBeenCalled();
    });
  });

  describe('accessibility', () => {
    it('should have proper labels for todo checkboxes', async () => {
      const fixture = TestBed.createComponent(PlanDetailComponent);
      const content = '- [ ] First task';

      fixture.componentInstance.root.set('plans');
      fixture.componentInstance.filePath.set('TEST.md');
      fixture.detectChanges();

      flushWorkspaceAndFile('plans', 'TEST.md', content);
      await fixture.whenStable();
      fixture.detectChanges();

      const checkbox = (fixture.nativeElement as HTMLElement).querySelector('input[type="checkbox"]');
      expect(checkbox?.getAttribute('aria-label')).toContain('First task');
    });

    it('should show completion status as text label', async () => {
      const fixture = TestBed.createComponent(PlanDetailComponent);
      const content = '- [x] Completed task';

      fixture.componentInstance.root.set('plans');
      fixture.componentInstance.filePath.set('TEST.md');
      fixture.detectChanges();

      flushWorkspaceAndFile('plans', 'TEST.md', content);
      await fixture.whenStable();
      fixture.detectChanges();

      fixture.componentInstance.selectTodo(0);
      fixture.detectChanges();

      const statusLabel = (fixture.nativeElement as HTMLElement).querySelector('.todo-status');
      expect(statusLabel?.textContent).toContain('Complete');
    });
  });

  describe('responsive layout', () => {
    it('should display without horizontal overflow on desktop', async () => {
      const fixture = TestBed.createComponent(PlanDetailComponent);
      const content = '# Test\n- [ ] Task';

      fixture.componentInstance.root.set('plans');
      fixture.componentInstance.filePath.set('TEST.md');
      fixture.detectChanges();

      flushWorkspaceAndFile('plans', 'TEST.md', content);
      await fixture.whenStable();
      fixture.detectChanges();

      const container = fixture.nativeElement as HTMLElement;
      const scrollWidth = container.scrollWidth;
      const clientWidth = container.clientWidth;
      expect(scrollWidth).toBeLessThanOrEqual(clientWidth + 1);
    });
  });

  describe('conditional UI, errors, and navigation edges', () => {
    it('resets when root or file path is cleared', async () => {
      const fixture = TestBed.createComponent(PlanDetailComponent);
      fixture.componentInstance.root.set('plans');
      fixture.componentInstance.filePath.set('TEST.md');
      fixture.detectChanges();
      flushWorkspaceAndFile('plans', 'TEST.md', '- [ ] Task');
      await fixture.whenStable();

      fixture.componentInstance.filePath.set('');
      fixture.detectChanges();
      await fixture.whenStable();

      expect(fixture.componentInstance.loading()).toBe(false);
      expect(fixture.componentInstance.primaryContent()).toBe('');
      expect(fixture.componentInstance.parsedPlan()).toBeNull();
    });

    it('blocks diff mode without a control copy and renders when available', async () => {
      const fixture = TestBed.createComponent(PlanDetailComponent);
      fixture.componentInstance.root.set('plans');
      fixture.componentInstance.filePath.set('PLAN.md');
      fixture.detectChanges();
      flushWorkspaceAndFile('plans', 'PLAN.md', 'line-a\nshared\n');
      await fixture.whenStable();

      fixture.componentInstance.toggleViewMode('diff');
      expect(fixture.componentInstance.viewMode()).toBe('rendered');

      fixture.componentInstance.controlCopyPath.set('PLAN.md.control');
      fixture.componentInstance.controlCopyContent.set('line-b\nshared\nextra');
      fixture.componentInstance.toggleViewMode('diff');
      expect(fixture.componentInstance.viewMode()).toBe('diff');
      (
        fixture.componentInstance as unknown as { generateDiff: () => void }
      ).generateDiff();
      expect(fixture.componentInstance.diffHtml()).toBeTruthy();
    });

    it('viewLogs navigates with project scope', async () => {
      const fixture = TestBed.createComponent(PlanDetailComponent);
      const router = TestBed.inject(Router);
      const navigateSpy = vi.spyOn(router, 'navigate').mockResolvedValue(true);
      fixture.componentInstance.root.set('plans');
      fixture.componentInstance.filePath.set('dir/PLAN.md');
      fixture.componentInstance.projectRoot.set('/tmp/project');
      fixture.detectChanges();
      flushWorkspaceAndFile('plans', 'dir/PLAN.md', '- [ ] Task');
      await fixture.whenStable();

      fixture.componentInstance.viewLogs();
      expect(navigateSpy).toHaveBeenCalledWith(['/plan-detail', 'dir/PLAN.md', 'logs'], {
        queryParams: { projectRoot: '/tmp/project' },
      });
    });

    it('maps structured ResourceError and returns to plans', async () => {
      const fixture = TestBed.createComponent(PlanDetailComponent);
      const navSpy = vi.spyOn(fixture.componentInstance['nav'], 'navigate');
      fixture.componentInstance.root.set('plans');
      fixture.componentInstance.filePath.set('GONE.md');
      fixture.detectChanges();

      const fileReq = expectFileRequest('plans', 'GONE.md');
      fileReq.flush(
        {
          code: 'NOT_FOUND',
          message: 'missing',
          title: 'Not Found',
          explanation: 'gone',
          recoverable: true,
          suggestedActions: ['RETRY', 'RETURN_TO_PLANS'],
        },
        { status: 404, statusText: 'Not Found' },
      );
      await fixture.whenStable();
      fixture.detectChanges();

      expect(fixture.componentInstance.error()?.code).toBe('NOT_FOUND');
      fixture.componentInstance.performErrorAction('RETURN_TO_PLANS');
      expect(navSpy).toHaveBeenCalledWith('plans');
    });

    it('ignores stale load responses after a newer request starts', async () => {
      const fixture = TestBed.createComponent(PlanDetailComponent);
      fixture.detectChanges();

      (
        fixture.componentInstance as unknown as {
          loadPlanFiles: (root: string, path: string) => void;
        }
      ).loadPlanFiles('plans', 'A.md');
      (
        fixture.componentInstance as unknown as {
          loadPlanFiles: (root: string, path: string) => void;
        }
      ).loadPlanFiles('plans', 'B.md');

      const first = expectFileRequest('plans', 'A.md');
      const second = expectFileRequest('plans', 'B.md');
      first.flush({ content: '# stale', size: 7, offset: 0, nextOffset: 0 });
      second.flush({ content: '- [ ] Keep', size: 10, offset: 0, nextOffset: 0 });
      await fixture.whenStable();
      fixture.detectChanges();

      expect(fixture.componentInstance.primaryContent()).toContain('Keep');
      expect(fixture.componentInstance.primaryContent()).not.toContain('stale');
    });

    it('clears control copy content on load failure', async () => {
      const fixture = TestBed.createComponent(PlanDetailComponent);
      fixture.componentInstance.root.set('plans');
      fixture.componentInstance.filePath.set('PLAN.md');
      fixture.componentInstance.controlCopyPath.set('PLAN.md.control');
      fixture.detectChanges();

      flushWorkspaceAndFile('plans', 'PLAN.md', '- [ ] Task');
      const controlReq = httpMock.expectOne(
        (r) => r.url.includes('/api/file') && r.params.get('path') === 'PLAN.md.control',
      );
      controlReq.error(new ErrorEvent('fail'));
      await fixture.whenStable();
      expect(fixture.componentInstance.controlCopyContent()).toBeNull();
    });

    it('handleContentClick resolves relative, absolute, and parent paths', async () => {
      const fixture = TestBed.createComponent(PlanDetailComponent);
      const navSpy = vi.spyOn(fixture.componentInstance['nav'], 'navigate');
      fixture.componentInstance.root.set('artifacts');
      fixture.componentInstance.filePath.set('ns/sub/PLAN.md');
      fixture.detectChanges();
      flushWorkspaceAndFile('artifacts', 'ns/sub/PLAN.md', '# Plan');
      await fixture.whenStable();

      const makeEvent = (href: string) => {
        const anchor = document.createElement('a');
        anchor.setAttribute('href', href);
        const span = document.createElement('span');
        anchor.appendChild(span);
        return { event: new MouseEvent('click', { bubbles: true }), target: span, anchor };
      };

      const relative = makeEvent('../out.md');
      Object.defineProperty(relative.event, 'target', { value: relative.target });
      fixture.componentInstance.handleContentClick(relative.event);
      expect(navSpy).toHaveBeenCalledWith('artifacts', null, 'ns/out.md', null, null);

      navSpy.mockClear();
      const absolute = makeEvent('/top/file.md#section');
      Object.defineProperty(absolute.event, 'target', { value: absolute.target });
      fixture.componentInstance.handleContentClick(absolute.event);
      expect(navSpy).toHaveBeenCalledWith('artifacts', null, 'top/file.md', null, null);

      navSpy.mockClear();
      const hashOnly = makeEvent('#only');
      Object.defineProperty(hashOnly.event, 'target', { value: hashOnly.target });
      fixture.componentInstance.handleContentClick(hashOnly.event);
      expect(navSpy).not.toHaveBeenCalled();

      navSpy.mockClear();
      const mail = makeEvent('mailto:ops@example.com');
      Object.defineProperty(mail.event, 'target', { value: mail.target });
      fixture.componentInstance.handleContentClick(mail.event);
      expect(navSpy).not.toHaveBeenCalled();

      navSpy.mockClear();
      const nonAnchor = new MouseEvent('click', { bubbles: true });
      Object.defineProperty(nonAnchor, 'target', { value: document.createElement('div') });
      fixture.componentInstance.handleContentClick(nonAnchor);
      expect(navSpy).not.toHaveBeenCalled();
    });

    it('re-renders markdown when switching back to rendered mode', async () => {
      const fixture = TestBed.createComponent(PlanDetailComponent);
      fixture.componentInstance.root.set('plans');
      fixture.componentInstance.filePath.set('TEST.md');
      fixture.detectChanges();
      flushWorkspaceAndFile('plans', 'TEST.md', '# Title\n- [ ] Task');
      await fixture.whenStable();

      fixture.componentInstance.toggleViewMode('source');
      fixture.componentInstance.primarySafeHtml.set(null);
      fixture.componentInstance.toggleViewMode('rendered');
      await fixture.whenStable();
      expect(fixture.componentInstance.primarySafeHtml()).toBeTruthy();
    });

    it('applies controlCopy and projectRoot query params on init', async () => {
      const { WorkspaceSelectorService } = await import('../../services/workspace-selector.service');
      const { ActivatedRoute } = await import('@angular/router');
      const { BehaviorSubject } = await import('rxjs');

      const queryParams$ = new BehaviorSubject<Record<string, string>>({
        controlCopy: 'CONTROL.md',
        projectRoot: '/tmp/proj',
      });
      const params$ = new BehaviorSubject<Record<string, string>>({ file: 'PLAN.md' });

      TestBed.resetTestingModule();
      await TestBed.configureTestingModule({
        imports: [PlanDetailComponent, HttpClientTestingModule, RouterTestingModule.withRoutes([])],
        providers: [
          {
            provide: ActivatedRoute,
            useValue: { queryParams: queryParams$.asObservable(), params: params$.asObservable() },
          },
        ],
      }).compileComponents();
      httpMock = TestBed.inject(HttpTestingController);

      const fixture = TestBed.createComponent(PlanDetailComponent);
      const selector = TestBed.inject(WorkspaceSelectorService);
      const selectSpy = vi.spyOn(selector, 'selectWorkspace').mockImplementation(() => {});
      fixture.componentInstance.root.set('plans');
      fixture.detectChanges();

      expect(fixture.componentInstance.controlCopyPath()).toBe('CONTROL.md');
      expect(fixture.componentInstance.projectRoot()).toBe('/tmp/proj');
      expect(selectSpy).toHaveBeenCalledWith('/tmp/proj');

      const fileReqs = httpMock.match((r) => r.url.includes('/api/file'));
      const primary = fileReqs.find((r) => r.request.params.get('path') === 'PLAN.md');
      const control = fileReqs.find((r) => r.request.params.get('path') === 'CONTROL.md');
      expect(primary).toBeTruthy();
      expect(control).toBeTruthy();
      primary!.flush({ content: 'a\nb\n', size: 4, offset: 0, nextOffset: 0 });
      control!.flush({ content: 'a\nc\nextra', size: 9, offset: 0, nextOffset: 0 });
      await fixture.whenStable();
      expect(fixture.componentInstance.isMutableControlCopy()).toBe(true);
      expect(fixture.componentInstance.sourceLineNumbers().length).toBeGreaterThan(0);
    });

    it('maps unknown load errors and ignores stale error callbacks', async () => {
      const fixture = TestBed.createComponent(PlanDetailComponent);
      fixture.detectChanges();

      (
        fixture.componentInstance as unknown as {
          loadPlanFiles: (root: string, path: string) => void;
        }
      ).loadPlanFiles('plans', 'A.md');
      (
        fixture.componentInstance as unknown as {
          loadPlanFiles: (root: string, path: string) => void;
        }
      ).loadPlanFiles('plans', 'B.md');

      const reqs = httpMock.match((r) => r.url.includes('/api/file'));
      expect(reqs.length).toBe(2);
      const first = reqs.find((r) => r.request.params.get('path') === 'A.md')!;
      const second = reqs.find((r) => r.request.params.get('path') === 'B.md')!;
      first.flush({ message: 'stale' }, { status: 500, statusText: 'Error' });
      second.error(new ProgressEvent('error'));
      await fixture.whenStable();
      expect(fixture.componentInstance.error()?.code).toBe('UNKNOWN');
      expect(fixture.componentInstance.primaryContent()).toBe('');
    });

    it('handles empty markdown, missing diff inputs, and empty link targets', async () => {
      const fixture = TestBed.createComponent(PlanDetailComponent);
      fixture.componentInstance.root.set('plans');
      fixture.componentInstance.filePath.set('EMPTY.md');
      fixture.detectChanges();
      flushWorkspaceAndFile('plans', 'EMPTY.md', '');
      await fixture.whenStable();

      await (
        fixture.componentInstance as unknown as { renderMarkdown: () => Promise<void> }
      ).renderMarkdown();
      expect(fixture.componentInstance.primarySafeHtml()).toBeNull();

      (
        fixture.componentInstance as unknown as { generateDiff: () => void }
      ).generateDiff();
      expect(fixture.componentInstance.diffHtml()).toBeNull();

      fixture.componentInstance.primaryContent.set('only-left\n');
      fixture.componentInstance.controlCopyContent.set('only-right\nshared');
      (
        fixture.componentInstance as unknown as { generateDiff: () => void }
      ).generateDiff();
      expect(fixture.componentInstance.diffHtml()).toBeTruthy();

      const navSpy = vi.spyOn(fixture.componentInstance['nav'], 'navigate');
      const anchor = document.createElement('a');
      anchor.setAttribute('href', '../../../../');
      const span = document.createElement('span');
      anchor.appendChild(span);
      const event = new MouseEvent('click', { bubbles: true });
      Object.defineProperty(event, 'target', { value: span });
      fixture.componentInstance.filePath.set('a.md');
      fixture.componentInstance.handleContentClick(event);
      expect(navSpy).not.toHaveBeenCalled();

      const unequal = (
        fixture.componentInstance as unknown as {
          createSimpleDiff: (a: string, b: string) => string;
        }
      ).createSimpleDiff('keep\nremoved-only', 'keep\n');
      expect(unequal).toContain('-removed-only');
      const addedOnly = (
        fixture.componentInstance as unknown as {
          createSimpleDiff: (a: string, b: string) => string;
        }
      ).createSimpleDiff('keep', 'keep\nadded-only');
      expect(addedOnly).toContain('+added-only');

      httpMock.match((r) => r.url.includes('/api/file')).forEach((req) => {
        req.flush({ content: '', size: 0, offset: 0, nextOffset: 0 });
      });
      fixture.componentInstance.controlCopyPath.set(null);
      (
        fixture.componentInstance as unknown as { loadControlCopyContent: () => void }
      ).loadControlCopyContent();
      expect(httpMock.match((r) => r.url.includes('/api/file')).length).toBe(0);
    });

    it('viewLogs falls back to nav project root and control copy generates diff', async () => {
      const fixture = TestBed.createComponent(PlanDetailComponent);
      const router = TestBed.inject(Router);
      const navigateSpy = vi.spyOn(router, 'navigate').mockResolvedValue(true);
      const nav = TestBed.inject(NavService);
      nav['activeProjectRootSignal'].set('/from-nav');
      fixture.componentInstance.root.set('plans');
      fixture.componentInstance.filePath.set('PLAN.md');
      fixture.componentInstance.projectRoot.set(null);
      fixture.detectChanges();
      flushWorkspaceAndFile('plans', 'PLAN.md', 'line-a\n');
      await fixture.whenStable();

      fixture.componentInstance.viewLogs();
      expect(navigateSpy).toHaveBeenCalledWith(['/plan-detail', 'PLAN.md', 'logs'], {
        queryParams: { projectRoot: '/from-nav' },
      });

      fixture.componentInstance.viewMode.set('diff');
      fixture.componentInstance.controlCopyPath.set('PLAN.md.control');
      (
        fixture.componentInstance as unknown as { loadControlCopyContent: () => void }
      ).loadControlCopyContent();
      const controlReq = httpMock.expectOne(
        (r) => r.url.includes('/api/file') && r.params.get('path') === 'PLAN.md.control',
      );
      controlReq.flush({ content: 'line-b\n', size: 7, offset: 0, nextOffset: 0 });
      await fixture.whenStable();
      expect(fixture.componentInstance.diffHtml()).toBeTruthy();
    });
  });
});
