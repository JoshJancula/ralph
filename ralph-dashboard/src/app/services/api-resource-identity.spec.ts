import '../../angular-test-env';
import { TestBed } from '@angular/core/testing';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { ApiService } from './api.service';
import { ResourceIdentityBuilder, ResourceIdentityCodec } from '../../shared';

describe('ApiService Resource Identity Methods', () => {
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

  it('should fetch resource file using resource identity', () => {
    const identity = ResourceIdentityBuilder.forPlan(
      '/home/user/project',
      'plans/PLAN1.md',
      'PLAN1',
      'source'
    );

    service.fetchResourceFile(identity, 0).subscribe();

    const encodedIdentity = ResourceIdentityCodec.encode(identity);
    const req = httpMock.expectOne((request) =>
      request.url === '/api/resource/file' &&
      request.params.get('resourceId') === encodedIdentity &&
      request.params.get('offset') === '0'
    );

    expect(req.request.method).toBe('GET');
    req.flush({ content: 'test', size: 4, offset: 0, nextOffset: 4 });
  });

  it('should fetch resource file with custom offset', () => {
    const identity = ResourceIdentityBuilder.forLog(
      '/home/user/project',
      'logs/PLAN1/output.log',
      'Output Log'
    );

    service.fetchResourceFile(identity, 1024).subscribe();

    const encodedIdentity = ResourceIdentityCodec.encode(identity);
    const req = httpMock.expectOne((request) =>
      request.url === '/api/resource/file' &&
      request.params.get('offset') === '1024'
    );

    expect(req.request.method).toBe('GET');
    req.flush({ content: '', size: 2048, offset: 1024, nextOffset: 2048 });
  });

  it('should fetch resource listing using resource identity', () => {
    const identity = ResourceIdentityBuilder.forArtifact(
      '/home/user/project',
      'artifacts/benchmark',
      'Benchmark Reports'
    );

    service.fetchResourceListing(identity).subscribe();

    const encodedIdentity = ResourceIdentityCodec.encode(identity);
    const req = httpMock.expectOne((request) =>
      request.url === '/api/resource/list' &&
      request.params.get('resourceId') === encodedIdentity
    );

    expect(req.request.method).toBe('GET');
    req.flush({
      root: 'artifacts',
      path: 'benchmark',
      parent: 'artifacts',
      entries: [
        {
          name: 'report-1.json',
          path: 'benchmark/report-1.json',
          type: 'file',
          size: 1024,
          mtime: Date.now(),
        },
      ],
    });
  });

  it('should distinguish resources in different projects', () => {
    const project1 = ResourceIdentityBuilder.forPlan(
      '/home/alice/workspace',
      'PLAN17.md',
      'PLAN17'
    );
    const project2 = ResourceIdentityBuilder.forPlan(
      '/home/bob/workspace',
      'PLAN17.md',
      'PLAN17'
    );

    const enc1 = ResourceIdentityCodec.encode(project1);
    const enc2 = ResourceIdentityCodec.encode(project2);

    expect(enc1).not.toBe(enc2);

    service.fetchResourceFile(project1).subscribe();
    service.fetchResourceFile(project2).subscribe();

    const req1 = httpMock.expectOne((request) =>
      request.url === '/api/resource/file' && request.params.get('resourceId') === enc1
    );
    const req2 = httpMock.expectOne((request) =>
      request.url === '/api/resource/file' && request.params.get('resourceId') === enc2
    );

    req1.flush({ content: 'alice content', size: 12, offset: 0, nextOffset: 12 });
    req2.flush({ content: 'bob content', size: 11, offset: 0, nextOffset: 11 });
  });

  it('should handle all resource kinds in listing requests', () => {
    const projectRoot = '/home/user/project';
    const kinds = [
      { builder: ResourceIdentityBuilder.forPlan, root: 'plans', path: 'test.md' },
      { builder: ResourceIdentityBuilder.forLog, root: 'logs', path: 'test/output.log' },
      { builder: ResourceIdentityBuilder.forArtifact, root: 'artifacts', path: 'test.json' },
      { builder: ResourceIdentityBuilder.forWorkflow, root: 'workflows', path: 'test.yaml' },
      { builder: ResourceIdentityBuilder.forRun, root: 'runs', path: 'run-123' },
    ];

    for (const k of kinds) {
      const identity = k.builder(projectRoot, k.path, `Test ${k.root}`);
      service.fetchResourceListing(identity).subscribe();

      const encoded = ResourceIdentityCodec.encode(identity);
      const req = httpMock.expectOne((request) =>
        request.url === '/api/resource/list' &&
        request.params.get('resourceId') === encoded
      );

      expect(req.request.method).toBe('GET');
      req.flush({
        root: k.root,
        path: k.path,
        parent: null,
        entries: [],
      });
    }
  });
});
