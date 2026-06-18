import '../../angular-test-env';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { firstValueFrom } from 'rxjs';
import { ApiService } from './api.service';

describe('ApiService', () => {
  let service: ApiService;
  let httpMock: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      imports: [HttpClientTestingModule],
      providers: [ApiService],
    });

    service = TestBed.inject(ApiService);
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
  });

  it('should be created', () => {
    expect(service).toBeTruthy();
  });

  describe('fetchRoots()', () => {
    it('should make GET to /api/roots and return typed array', async () => {
      const mockRoots = [
        { key: '/root1', label: 'Root 1', exists: true },
        { key: '/root2', label: 'Root 2', exists: false },
      ];

      const responsePromise = firstValueFrom(service.fetchRoots());
      const req = httpMock.expectOne('/api/roots');
      expect(req.request.method).toBe('GET');
      req.flush(mockRoots);

      const roots = await responsePromise;
      expect(roots).toEqual(mockRoots);
    });
  });

  describe('fetchListing()', () => {
    it('should make GET with correct query params', async () => {
      const root = '/test-root';
      const path = '/folder/subfolder';
      const mockListing = {
        root,
        path,
        parent: '/folder',
        entries: [],
      };

      const responsePromise = firstValueFrom(service.fetchListing(root, path));
      const req = httpMock.expectOne(
        (r) => r.urlWithParams.startsWith('/api/list') && r.params.get('root') === root && r.params.get('path') === path,
      );
      expect(req.request.method).toBe('GET');
      req.flush(mockListing);

      const listing = await responsePromise;
      expect(listing).toEqual(mockListing);
    });

    it('includes projectRoot in query when provided', async () => {
      const root = 'plans';
      const path = '';
      const mockListing = { root, path, parent: null, entries: [] };
      const pr = '/data/my-repo';

      const responsePromise = firstValueFrom(service.fetchListing(root, path, undefined, pr));
      const req = httpMock.expectOne(
        (r) =>
          r.urlWithParams.startsWith('/api/list') &&
          r.params.get('root') === root &&
          r.params.get('path') === path &&
          r.params.get('projectRoot') === pr,
      );
      req.flush(mockListing);
      await responsePromise;
    });

    it('includes workspaceRoot and projectRoot together when both provided', async () => {
      const root = 'plans';
      const path = '';
      const ws = '/w/.ralph-workspace';
      const pr = '/w';
      const mockListing = { root, path, parent: null, entries: [] };

      const responsePromise = firstValueFrom(service.fetchListing(root, path, ws, pr));
      const req = httpMock.expectOne(
        (r) =>
          r.urlWithParams.startsWith('/api/list') &&
          r.params.get('workspaceRoot') === ws &&
          r.params.get('projectRoot') === pr,
      );
      req.flush(mockListing);
      await responsePromise;
    });
  });

  describe('fetchFile()', () => {
    it('should make GET with correct offset param', async () => {
      const root = '/test-root';
      const filePath = '/folder/file.txt';
      const offset = 100;
      const mockChunk = {
        content: 'file content',
        size: 1000,
        offset: 100,
        nextOffset: 200,
      };

      const responsePromise = firstValueFrom(service.fetchFile(root, filePath, offset));
      const req = httpMock.expectOne(
        (r) =>
          r.urlWithParams.startsWith('/api/file') &&
          r.params.get('root') === root &&
          r.params.get('path') === filePath &&
          r.params.get('offset') === '100',
      );
      expect(req.request.method).toBe('GET');
      req.flush(mockChunk);

      const chunk = await responsePromise;
      expect(chunk).toEqual(mockChunk);
    });

    it('should default offset to 0', async () => {
      const root = '/test-root';
      const filePath = '/folder/file.txt';
      const mockChunk = {
        content: 'file content',
        size: 1000,
        offset: 0,
        nextOffset: 100,
      };

      const responsePromise = firstValueFrom(service.fetchFile(root, filePath));
      const req = httpMock.expectOne(
        (r) =>
          r.urlWithParams.startsWith('/api/file') &&
          r.params.get('root') === root &&
          r.params.get('path') === filePath &&
          r.params.get('offset') === '0',
      );
      req.flush(mockChunk);

      const chunk = await responsePromise;
      expect(chunk).toEqual(mockChunk);
    });

    it('includes projectRoot in query when provided', async () => {
      const root = 'plans';
      const filePath = 'x.md';
      const pr = '/p/root';
      const mockChunk = { content: '', size: 0, offset: 0, nextOffset: 0 };

      const responsePromise = firstValueFrom(service.fetchFile(root, filePath, 0, undefined, pr));
      const req = httpMock.expectOne(
        (r) =>
          r.urlWithParams.startsWith('/api/file') &&
          r.params.get('projectRoot') === pr &&
          r.params.get('root') === root,
      );
      req.flush(mockChunk);
      await responsePromise;
    });

    it('includes workspaceRoot and projectRoot together when offset fetch', async () => {
      const root = 'plans';
      const filePath = 'a.md';
      const ws = '/w/.ralph-workspace';
      const pr = '/w';
      const mockChunk = { content: '', size: 0, offset: 0, nextOffset: 0 };

      const responsePromise = firstValueFrom(service.fetchFile(root, filePath, 0, ws, pr));
      const req = httpMock.expectOne(
        (r) =>
          r.urlWithParams.startsWith('/api/file') &&
          r.params.get('workspaceRoot') === ws &&
          r.params.get('projectRoot') === pr,
      );
      req.flush(mockChunk);
      await responsePromise;
    });
  });

  describe('fetchTemplate()', () => {
    it.each(['plan', 'orchestration'] as const)(
      'should make GET to /api/template?name=%s',
      async (name) => {
        const mockTemplate = {
          name,
          content: 'template content here',
        };

        const responsePromise = firstValueFrom(service.fetchTemplate(name));
        const req = httpMock.expectOne(
          (r) => r.urlWithParams.startsWith('/api/template') && r.params.get('name') === name,
        );
        expect(req.request.method).toBe('GET');
        req.flush(mockTemplate);

        const template = await responsePromise;
        expect(template).toEqual(mockTemplate);
      },
    );

    it('includes projectRoot in template request when provided', async () => {
      const name = 'plan' as const;
      const pr = '/proj/a';
      const mockTemplate = { name, content: 'x' };
      const responsePromise = firstValueFrom(service.fetchTemplate(name, pr));
      const req = httpMock.expectOne(
        (r) =>
          r.urlWithParams.startsWith('/api/template') &&
          r.params.get('name') === name &&
          r.params.get('projectRoot') === pr,
      );
      req.flush(mockTemplate);
      await responsePromise;
    });

    it('should reject invalid template names at compile time', () => {
      const invalidName = 'my-template' as const;
      // @ts-expect-error - only plan and orchestration are valid template names
      service.fetchTemplate(invalidName);
    });
  });

  describe('fetchMetricsSummary()', () => {
    it('should make GET to /api/metrics/summary and return typed metrics payload', async () => {
      const mockSummary = {
        overall: {
          input_tokens: 123,
          output_tokens: 456,
          cache_creation_input_tokens: 78,
          cache_read_input_tokens: 90,
          max_turn_total_tokens: 0,
          cache_hit_ratio: 0,
          elapsed_seconds: 12.5,
          count: 2,
        },
        plans: [
          {
            path: '/mock/w/.ralph-workspace/logs/plan-1/plan-usage-summary.json',
            plan_key: 'plan-1',
            artifact_ns: 'plan-1',
            workspace_root: '/mock/w/.ralph-workspace',
            project_root: '/mock/w',
            elapsed_seconds: 5,
            input_tokens: 10,
            output_tokens: 20,
            cache_creation_input_tokens: 0,
            cache_read_input_tokens: 1,
            max_turn_total_tokens: 0,
            cache_hit_ratio: 0,
          },
        ],
        orchestrations: [],
        projects: [] as const,
      };

      const responsePromise = firstValueFrom(service.fetchMetricsSummary());
      const req = httpMock.expectOne('/api/metrics/summary');
      expect(req.request.method).toBe('GET');
      req.flush(mockSummary);

      const summary = await responsePromise;
      expect(summary).toEqual(mockSummary);
    });
  });

  describe('error handling', () => {
    it('should surface non-200 responses as observable errors', async () => {
      const responsePromise = firstValueFrom(service.fetchRoots());
      const req = httpMock.expectOne('/api/roots');
      req.flush('Not found', { status: 404, statusText: 'Not Found' });

      await expect(responsePromise).rejects.toMatchObject({ status: 404 });
    });
  });
});
