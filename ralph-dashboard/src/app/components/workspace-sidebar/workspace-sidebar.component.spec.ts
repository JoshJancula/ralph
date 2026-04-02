import '../../../angular-test-env';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { WorkspaceSidebarComponent } from './workspace-sidebar.component';
import { NavService } from '../../services/nav.service';
import type { Root } from '../../services/api.service';

function requestPath(url: string): string {
  const q = url.indexOf('?');
  return q === -1 ? url : url.slice(0, q);
}

describe('WorkspaceSidebarComponent', () => {
  let httpMock: HttpTestingController;

  beforeEach(async () => {
    window.location.hash = '';
    TestBed.resetTestingModule();
    await TestBed.configureTestingModule({
      imports: [WorkspaceSidebarComponent, HttpClientTestingModule],
    }).compileComponents();
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
    window.location.hash = '';
  });

  it('ngOnInit loads roots and isActive reflects NavService', () => {
    const fixture = TestBed.createComponent(WorkspaceSidebarComponent);
    const nav = TestBed.inject(NavService);
    nav.navigate('logs', 'P');

    fixture.detectChanges();

    const req = httpMock.expectOne((r) => requestPath(r.url) === '/api/roots');
    req.flush([
      { key: 'logs', label: 'Logs', exists: true },
      { key: 'plans', label: 'Plans', exists: true },
    ]);

    const logs: Root = { key: 'logs', label: 'Logs', exists: true };
    const plans: Root = { key: 'plans', label: 'Plans', exists: true };
    expect(fixture.componentInstance.roots()).toEqual([logs, plans]);
    expect(fixture.componentInstance.isActive(logs)).toBe(true);
    expect(fixture.componentInstance.isActive(plans)).toBe(false);
  });

  it('selectRoot calls navigate with root key', () => {
    const fixture = TestBed.createComponent(WorkspaceSidebarComponent);
    const nav = TestBed.inject(NavService);
    const spy = vi.spyOn(nav, 'navigate');

    fixture.detectChanges();

    const req = httpMock.expectOne((r) => requestPath(r.url) === '/api/roots');
    req.flush([{ key: 'artifacts', label: 'Artifacts', exists: true }]);

    const root: Root = { key: 'artifacts', label: 'Artifacts', exists: true };
    fixture.componentInstance.selectRoot(root);
    expect(spy).toHaveBeenCalledWith('artifacts');
  });
});
