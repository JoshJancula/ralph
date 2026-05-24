import '../../../angular-test-env';
import { TestBed, fakeAsync, tick } from '@angular/core/testing';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';

import { type WorkspaceRegistry } from '../../services/api.service';
import { WorkspaceSwitcherComponent } from './workspace-switcher.component';
import { WorkspaceSelectorService } from '../../services/workspace-selector.service';

function stubWorkspace(path: string, exists = true): WorkspaceRegistry {
  const segments = path.split('/');
  const label = segments[segments.length - 1] || path;
  return {
    path,
    workspaceRoot: `${path}/.ralph-workspace`,
    projectRoot: path,
    label,
    exists,
  };
}

describe('WorkspaceSwitcherComponent', () => {
  let httpMock: HttpTestingController;

  beforeEach(async () => {
    localStorage.clear();
    TestBed.resetTestingModule();
    await TestBed.configureTestingModule({
      imports: [WorkspaceSwitcherComponent, HttpClientTestingModule],
    }).compileComponents();
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
    localStorage.clear();
  });

  it('hides the switcher when fewer than two workspaces are registered', fakeAsync(() => {
    const fixture = TestBed.createComponent(WorkspaceSwitcherComponent);
    fixture.detectChanges();

    const req = httpMock.expectOne('/api/workspaces');
    req.flush([stubWorkspace('/a')]);
    tick();
    fixture.detectChanges();

    expect(fixture.nativeElement.querySelector('.workspace-switcher')).toBeNull();
  }));

  it('renders only existing workspaces and routes change to WorkspaceSelectorService', fakeAsync(() => {
    const fixture = TestBed.createComponent(WorkspaceSwitcherComponent);
    const service = TestBed.inject(WorkspaceSelectorService);
    const selectSpy = vi.spyOn(service, 'selectWorkspace');

    fixture.detectChanges();
    const req = httpMock.expectOne('/api/workspaces');
    req.flush([stubWorkspace('/first'), stubWorkspace('/second/spot'), stubWorkspace('/deleted', false)]);
    tick();
    fixture.detectChanges();

    const el = fixture.nativeElement.querySelector('.workspace-switcher') as HTMLElement;
    expect(el).toBeTruthy();
    expect(el.querySelector('option[value="/deleted"]')).toBeNull();

    const select = el.querySelector('select') as HTMLSelectElement;
    select.value = 'all';
    select.dispatchEvent(new Event('change'));
    expect(selectSpy).toHaveBeenCalledWith(null);

    select.value = '/first';
    select.dispatchEvent(new Event('change'));
    expect(selectSpy).toHaveBeenCalledWith('/first');
  }));
});
