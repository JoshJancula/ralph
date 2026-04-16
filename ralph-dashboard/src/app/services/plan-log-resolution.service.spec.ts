import '../../angular-test-env';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { PlanLogResolutionService } from './plan-log-resolution.service';

function requestPath(url: string): string {
  const q = url.indexOf('?');
  return q === -1 ? url : url.slice(0, q);
}

describe('PlanLogResolutionService', () => {
  let httpMock: HttpTestingController;

  beforeEach(async () => {
    TestBed.resetTestingModule();
    await TestBed.configureTestingModule({
      imports: [HttpClientTestingModule],
    }).compileComponents();
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
  });

  it('resolvePlanDirectory extracts the plan root from file and directory paths', () => {
    const service = TestBed.inject(PlanLogResolutionService);

    expect(service.resolvePlanDirectory('PLAN2/docs/readme.md')).toBe('PLAN2');
    expect(service.resolvePlanDirectory('PLAN2/')).toBe('PLAN2');
    expect(service.resolvePlanDirectory('')).toBeNull();
  });

  it('resolveLatestLogTarget returns the newest log file at the root', () => {
    const service = TestBed.inject(PlanLogResolutionService);
    let resolved: { directory: string | null; file: string | null } | undefined;

    service.resolveLatestLogTarget('PLAN2').subscribe((value) => {
      resolved = value;
    });

    const req = httpMock.expectOne(
      (r) => requestPath(r.url) === '/api/list' && r.params.get('root') === 'logs' && r.params.get('path') === 'PLAN2',
    );
    req.flush({
      root: 'logs',
      path: 'PLAN2',
      parent: null,
      entries: [
        { name: 'output.log', path: 'PLAN2/output.log', type: 'file', size: 10, mtime: 1000 },
        { name: 'older.log', path: 'PLAN2/older.log', type: 'file', size: 10, mtime: 500 },
      ],
    });

    expect(resolved).toEqual({ directory: null, file: 'PLAN2/output.log' });
  });

  it('resolveLatestLogTarget looks in the newest subdirectory when no root log exists', () => {
    const service = TestBed.inject(PlanLogResolutionService);
    let resolved: { directory: string | null; file: string | null } | undefined;

    service.resolveLatestLogTarget('PLAN2').subscribe((value) => {
      resolved = value;
    });

    const req = httpMock.expectOne(
      (r) => requestPath(r.url) === '/api/list' && r.params.get('root') === 'logs' && r.params.get('path') === 'PLAN2',
    );
    req.flush({
      root: 'logs',
      path: 'PLAN2',
      parent: null,
      entries: [
        { name: 'run-001', path: 'PLAN2/run-001/', type: 'dir', size: 0, mtime: 2000 },
        { name: 'run-000', path: 'PLAN2/run-000/', type: 'dir', size: 0, mtime: 1000 },
      ],
    });

    const subReq = httpMock.expectOne(
      (r) => requestPath(r.url) === '/api/list' && r.params.get('root') === 'logs' && r.params.get('path') === 'PLAN2/run-001',
    );
    subReq.flush({
      root: 'logs',
      path: 'PLAN2/run-001',
      parent: 'PLAN2',
      entries: [
        { name: 'output.log', path: 'PLAN2/run-001/output.log', type: 'file', size: 10, mtime: 1000 },
      ],
    });

    expect(resolved).toEqual({ directory: null, file: 'PLAN2/run-001/output.log' });
  });

  it('resolveLatestLogTarget returns null file when the newest subdirectory has no logs', () => {
    const service = TestBed.inject(PlanLogResolutionService);
    let resolved: { directory: string | null; file: string | null } | undefined;

    service.resolveLatestLogTarget('PLAN2').subscribe((value) => {
      resolved = value;
    });

    const req = httpMock.expectOne(
      (r) => requestPath(r.url) === '/api/list' && r.params.get('root') === 'logs' && r.params.get('path') === 'PLAN2',
    );
    req.flush({
      root: 'logs',
      path: 'PLAN2',
      parent: null,
      entries: [
        { name: 'run-001', path: 'PLAN2/run-001/', type: 'dir', size: 0, mtime: 2000 },
      ],
    });

    const subReq = httpMock.expectOne(
      (r) => requestPath(r.url) === '/api/list' && r.params.get('root') === 'logs' && r.params.get('path') === 'PLAN2/run-001',
    );
    subReq.flush({
      root: 'logs',
      path: 'PLAN2/run-001',
      parent: 'PLAN2',
      entries: [],
    });

    expect(resolved).toEqual({ directory: null, file: null });
  });

  it('resolveLatestLogTarget falls back to the directory when listing fails', () => {
    const service = TestBed.inject(PlanLogResolutionService);
    let resolved: { directory: string | null; file: string | null } | undefined;

    service.resolveLatestLogTarget('PLAN2').subscribe((value) => {
      resolved = value;
    });

    const req = httpMock.expectOne(
      (r) => requestPath(r.url) === '/api/list' && r.params.get('root') === 'logs' && r.params.get('path') === 'PLAN2',
    );
    req.flush('error', { status: 500, statusText: 'Error' });

    expect(resolved).toEqual({ directory: 'PLAN2', file: null });
  });
});
