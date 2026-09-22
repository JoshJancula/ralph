import '../../../angular-test-env';
import { TestBed, fakeAsync, tick } from '@angular/core/testing';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { vi } from 'vitest';

import { type WorkspaceRegistry } from '../../services/api.service';
import { WorkspaceSwitcherComponent } from './workspace-switcher.component';
import { WorkspaceSelectorService } from '../../services/workspace-selector.service';

function stubWorkspace(
  path: string,
  projectRoot: string,
  exists = true,
  lastSeen?: string
): WorkspaceRegistry {
  const segments = path.split('/');
  const label = segments[segments.length - 1] || path;
  return {
    path,
    workspaceRoot: `${path}/.ralph-workspace`,
    projectRoot,
    label,
    exists,
    lastSeen,
  };
}

describe('WorkspaceSwitcherComponent', () => {
  let httpMock: HttpTestingController;
  let selectorService: WorkspaceSelectorService;

  beforeEach(async () => {
    localStorage.clear();
    TestBed.resetTestingModule();
    await TestBed.configureTestingModule({
      imports: [WorkspaceSwitcherComponent, HttpClientTestingModule],
    }).compileComponents();
    httpMock = TestBed.inject(HttpTestingController);
    selectorService = TestBed.inject(WorkspaceSelectorService);
  });

  afterEach(() => {
    httpMock.verify();
    localStorage.clear();
  });

  it('hides the switcher when fewer than two workspaces are registered', fakeAsync(() => {
    const fixture = TestBed.createComponent(WorkspaceSwitcherComponent);
    fixture.detectChanges();

    const req = httpMock.expectOne('/api/workspaces');
    req.flush([stubWorkspace('/a', '/a')]);
    tick();
    fixture.detectChanges();

    expect(fixture.nativeElement.querySelector('.workspace-switcher-container')).toBeNull();
  }));

  it('renders the switcher with multiple workspaces', fakeAsync(() => {
    const fixture = TestBed.createComponent(WorkspaceSwitcherComponent);
    fixture.detectChanges();

    const req = httpMock.expectOne('/api/workspaces');
    req.flush([
      stubWorkspace('/first', '/first'),
      stubWorkspace('/second/spot', '/second/spot'),
    ]);
    tick();
    fixture.detectChanges();

    expect(fixture.nativeElement.querySelector('.workspace-switcher-container')).toBeTruthy();
    expect(fixture.nativeElement.querySelector('.switcher-button')).toBeTruthy();
  }));

  it('displays duplicate names with parent path disambiguation', fakeAsync(() => {
    const fixture = TestBed.createComponent(WorkspaceSwitcherComponent);
    fixture.detectChanges();

    const req = httpMock.expectOne('/api/workspaces');
    req.flush([
      stubWorkspace('/projects/myapp', '/projects/myapp'),
      stubWorkspace('/archive/myapp', '/archive/myapp'),
    ]);
    tick();
    fixture.detectChanges();

    const button = fixture.nativeElement.querySelector('.switcher-button');
    button.click();
    fixture.detectChanges();

    const projectItems = fixture.nativeElement.querySelectorAll('.project-item:not(.all-projects)');
    expect(projectItems.length).toBe(2);

    const parentPaths = fixture.nativeElement.querySelectorAll('.project-item-path');
    expect(parentPaths.length).toBeGreaterThan(0);
    expect(parentPaths[0].textContent).toContain('/projects');
  }));

  it('filters projects based on search query', fakeAsync(() => {
    const fixture = TestBed.createComponent(WorkspaceSwitcherComponent);
    fixture.detectChanges();

    const req = httpMock.expectOne('/api/workspaces');
    req.flush([
      stubWorkspace('/projects/alpha', '/projects/alpha'),
      stubWorkspace('/projects/beta', '/projects/beta'),
      stubWorkspace('/other/gamma', '/other/gamma'),
    ]);
    tick();
    fixture.detectChanges();

    const button = fixture.nativeElement.querySelector('.switcher-button');
    button.click();
    fixture.detectChanges();

    const searchInput = fixture.nativeElement.querySelector('.search-input');
    searchInput.value = 'alpha';
    searchInput.dispatchEvent(new Event('input'));
    fixture.detectChanges();

    const projectItems = fixture.nativeElement.querySelectorAll('.project-item:not(.all-projects)');
    expect(projectItems.length).toBe(1);
    expect(projectItems[0].textContent).toContain('alpha');
  }));

  it('supports keyboard navigation with arrow keys', fakeAsync(() => {
    const fixture = TestBed.createComponent(WorkspaceSwitcherComponent);
    const component = fixture.componentInstance;
    fixture.detectChanges();

    const req = httpMock.expectOne('/api/workspaces');
    req.flush([
      stubWorkspace('/first', '/first'),
      stubWorkspace('/second', '/second'),
      stubWorkspace('/third', '/third'),
    ]);
    tick();
    fixture.detectChanges();

    // Mock scrollIntoView
    Element.prototype.scrollIntoView = vi.fn();

    const button = fixture.nativeElement.querySelector('.switcher-button');
    button.click();
    tick();
    fixture.detectChanges();

    expect(component.selectedIndex()).toBe(0);

    const downEvent = new KeyboardEvent('keydown', { key: 'ArrowDown' });
    component.onKeyDown(downEvent);
    tick();
    fixture.detectChanges();
    expect(component.selectedIndex()).toBe(1);

    component.onKeyDown(downEvent);
    tick();
    fixture.detectChanges();
    expect(component.selectedIndex()).toBe(2);

    component.onKeyDown(downEvent);
    tick();
    fixture.detectChanges();
    expect(component.selectedIndex()).toBe(3);

    const upEvent = new KeyboardEvent('keydown', { key: 'ArrowUp' });
    component.onKeyDown(upEvent);
    tick();
    fixture.detectChanges();
    expect(component.selectedIndex()).toBe(2);
  }));

  it('closes dropdown on Escape key', fakeAsync(() => {
    const fixture = TestBed.createComponent(WorkspaceSwitcherComponent);
    const component = fixture.componentInstance;
    fixture.detectChanges();

    const req = httpMock.expectOne('/api/workspaces');
    req.flush([
      stubWorkspace('/first', '/first'),
      stubWorkspace('/second', '/second'),
    ]);
    tick();
    fixture.detectChanges();

    const button = fixture.nativeElement.querySelector('.switcher-button') as HTMLButtonElement;
    button.focus();
    button.click();
    fixture.detectChanges();

    expect(component.isOpen()).toBe(true);

    const event = new KeyboardEvent('keydown', { key: 'Escape' });
    component.onKeyDown(event);
    tick();
    fixture.detectChanges();

    expect(component.isOpen()).toBe(false);
    expect(document.activeElement).toBe(button);
  }));

  it('selects project on Enter key', fakeAsync(() => {
    const fixture = TestBed.createComponent(WorkspaceSwitcherComponent);
    const component = fixture.componentInstance;
    const selectSpy = vi.spyOn(selectorService, 'selectWorkspace');
    fixture.detectChanges();

    const req = httpMock.expectOne('/api/workspaces');
    req.flush([
      stubWorkspace('/first', '/first'),
      stubWorkspace('/second', '/second'),
    ]);
    tick();
    fixture.detectChanges();

    const button = fixture.nativeElement.querySelector('.switcher-button');
    button.click();
    fixture.detectChanges();

    component.onKeyDown(new KeyboardEvent('keydown', { key: 'ArrowDown' }));
    fixture.detectChanges();

    const event = new KeyboardEvent('keydown', { key: 'Enter' });
    component.onKeyDown(event);
    fixture.detectChanges();

    expect(selectSpy).toHaveBeenCalledWith('/first');
  }));

  it('persists selected workspace to localStorage', fakeAsync(() => {
    const fixture = TestBed.createComponent(WorkspaceSwitcherComponent);
    fixture.detectChanges();

    const req = httpMock.expectOne('/api/workspaces');
    req.flush([
      stubWorkspace('/first', '/first'),
      stubWorkspace('/second', '/second'),
    ]);
    tick();
    fixture.detectChanges();

    const button = fixture.nativeElement.querySelector('.switcher-button');
    button.click();
    fixture.detectChanges();

    const projectItems = fixture.nativeElement.querySelectorAll('.project-item:not(.all-projects)');
    const secondItem = projectItems[1];
    secondItem.click();
    fixture.detectChanges();

    const stored = localStorage.getItem('ralph-workspace-selected');
    expect(stored).toBe('/second');
  }));

  it('tracks recent projects', fakeAsync(() => {
    const fixture = TestBed.createComponent(WorkspaceSwitcherComponent);
    fixture.detectChanges();

    const req = httpMock.expectOne('/api/workspaces');
    req.flush([
      stubWorkspace('/first', '/first'),
      stubWorkspace('/second', '/second'),
      stubWorkspace('/third', '/third'),
    ]);
    tick();
    fixture.detectChanges();

    const button = fixture.nativeElement.querySelector('.switcher-button');
    button.click();
    fixture.detectChanges();

    const projectItems = fixture.nativeElement.querySelectorAll('.project-item:not(.all-projects)');
    projectItems[0].click();
    fixture.detectChanges();

    button.click();
    fixture.detectChanges();

    const groups = fixture.nativeElement.querySelectorAll('.project-group');
    expect(groups.length).toBeGreaterThan(0);
    const recentGroup = Array.from(groups).find((g: any) =>
      g.textContent.includes('Recent')
    );
    expect(recentGroup).toBeTruthy();
  }));

  it('allows pinning and unpinning projects', fakeAsync(() => {
    const fixture = TestBed.createComponent(WorkspaceSwitcherComponent);
    fixture.detectChanges();

    const req = httpMock.expectOne('/api/workspaces');
    req.flush([
      stubWorkspace('/first', '/first'),
      stubWorkspace('/second', '/second'),
    ]);
    tick();
    fixture.detectChanges();

    const button = fixture.nativeElement.querySelector('.switcher-button');
    button.click();
    fixture.detectChanges();

    const pinButtons = fixture.nativeElement.querySelectorAll('.pin-button');
    expect(pinButtons.length).toBeGreaterThan(0);

    pinButtons[0].click();
    fixture.detectChanges();

    const stored = localStorage.getItem('ralph-pinned-projects');
    expect(stored).toBeTruthy();
    const pinned = JSON.parse(stored!);
    expect(pinned).toContain('/first');
  }));

  it('shows "All projects" option to clear selection', fakeAsync(() => {
    const fixture = TestBed.createComponent(WorkspaceSwitcherComponent);
    fixture.detectChanges();

    const req = httpMock.expectOne('/api/workspaces');
    req.flush([
      stubWorkspace('/first', '/first'),
      stubWorkspace('/second', '/second'),
    ]);
    tick();
    fixture.detectChanges();

    const button = fixture.nativeElement.querySelector('.switcher-button');
    button.click();
    fixture.detectChanges();

    const allProjectsButton = fixture.nativeElement.querySelector('.all-projects');
    expect(allProjectsButton).toBeTruthy();
    const list = fixture.nativeElement.querySelector('.switcher-list');
    expect(list?.firstElementChild?.querySelector('.all-projects')).toBe(allProjectsButton);

    allProjectsButton.click();
    fixture.detectChanges();

    expect(selectorService.selectedWorkspacePath()).toBeNull();
  }));

  it('falls back to safe default when remembered project vanishes', fakeAsync(() => {
    localStorage.setItem('ralph-workspace-selected', '/missing');

    const fixture = TestBed.createComponent(WorkspaceSwitcherComponent);
    fixture.detectChanges();

    const req = httpMock.expectOne('/api/workspaces');
    req.flush([
      stubWorkspace('/first', '/first'),
      stubWorkspace('/second', '/second'),
    ]);
    tick();
    fixture.detectChanges();

    expect(selectorService.selectedWorkspacePath()).toBeNull();
  }));

  it('displays current selection indicator', fakeAsync(() => {
    const fixture = TestBed.createComponent(WorkspaceSwitcherComponent);
    fixture.detectChanges();

    const req = httpMock.expectOne('/api/workspaces');
    req.flush([
      stubWorkspace('/first', '/first'),
      stubWorkspace('/second', '/second'),
    ]);
    tick();
    fixture.detectChanges();

    selectorService.selectWorkspace('/first');
    fixture.detectChanges();

    const button = fixture.nativeElement.querySelector('.switcher-button');
    expect(button.textContent).toContain('first');

    button.click();
    fixture.detectChanges();

    const currentIcons = fixture.nativeElement.querySelectorAll('.current-icon');
    expect(currentIcons.length).toBeGreaterThan(0);
  }));
});
