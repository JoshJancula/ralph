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

    it('should reject invalid template names at compile time', () => {
      const invalidName = 'my-template' as const;
      // @ts-expect-error - only plan and orchestration are valid template names
      service.fetchTemplate(invalidName);
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
