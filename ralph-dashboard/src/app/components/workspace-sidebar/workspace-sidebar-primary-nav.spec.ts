import '../../../angular-test-env';
import { Component } from '@angular/core';
import { TestBed, fakeAsync, tick, flush } from '@angular/core/testing';
import { RouterTestingModule } from '@angular/router/testing';
import { WorkspaceSidebarComponent } from './workspace-sidebar.component';
import { NavService } from '../../services/nav.service';
import { HttpClientTestingModule } from '@angular/common/http/testing';

@Component({ selector: 'ralph-route-stub', template: '', standalone: true })
class RouteStubComponent {}

const testRoutes = [
  { path: '', redirectTo: 'plans', pathMatch: 'full' },
  { path: 'home', component: RouteStubComponent },
  { path: '**', redirectTo: 'plans' },
];

describe('WorkspaceSidebarComponent - Primary Navigation', () => {
  beforeEach(async () => {
    TestBed.resetTestingModule();
    await TestBed.configureTestingModule({
      imports: [WorkspaceSidebarComponent, HttpClientTestingModule, RouterTestingModule.withRoutes(testRoutes)],
    }).compileComponents();
  });

  it('renders the task-oriented primary navigation without the parked explorer', fakeAsync(() => {
    const fixture = TestBed.createComponent(WorkspaceSidebarComponent);
    fixture.detectChanges();
    tick();
    flush();

    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="sidebar-home-link"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="sidebar-runs-link"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="sidebar-plans-link"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="sidebar-workflows-link"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="sidebar-docs-link"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="sidebar-insights-link"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="sidebar-safety-link"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="sidebar-browse-link"]')).toBeNull();
  }));

  it('applies active class to current section', async () => {
    const fixture = TestBed.createComponent(WorkspaceSidebarComponent);
    const nav = TestBed.inject(NavService);

    fixture.detectChanges();
    await fixture.whenStable();

    // routerLinkActive tracks the Router's URL, so drive it through NavService.navigate()
    // rather than poking the section signal directly.
    nav.navigate('home');
    await fixture.whenStable();
    fixture.detectChanges();
    await fixture.whenStable();

    const homeLink = fixture.nativeElement.querySelector('[data-testid="sidebar-home-link"]');
    expect(homeLink?.classList.contains('active')).toBe(true);
  });

  it('expands task subroutes while Tasks is active', fakeAsync(() => {
    const fixture = TestBed.createComponent(WorkspaceSidebarComponent);
    const nav = TestBed.inject(NavService);

    fixture.detectChanges();
    tick();
    nav['activeSectionSignal'].set('tasks');
    fixture.detectChanges();

    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelectorAll('.nav-subroute').length).toBe(3);
    expect(el.textContent).toContain('Active board');
    expect(el.textContent).toContain('Backlog');
    expect(el.textContent).toContain('History');
  }));

  it('keeps the parked browse control out of the sidebar', fakeAsync(() => {
    const fixture = TestBed.createComponent(WorkspaceSidebarComponent);
    const nav = TestBed.inject(NavService);

    fixture.detectChanges();
    tick();

    nav['activeSectionSignal'].set('browse');
    fixture.detectChanges();
    tick();

    expect(fixture.nativeElement.querySelector('[data-testid="sidebar-browse-link"]')).toBeNull();
  }));

  it('does not render the parked explorer on a legacy browse route', fakeAsync(() => {
    const fixture = TestBed.createComponent(WorkspaceSidebarComponent);
    const nav = TestBed.inject(NavService);
    const sidebarComponent = fixture.componentInstance;

    fixture.detectChanges();
    tick();

    nav['activeSectionSignal'].set('browse');
    fixture.detectChanges();
    tick();

    expect(sidebarComponent.showBrowseSection()).toBe(false);

    nav['activeSectionSignal'].set('plans');
    fixture.detectChanges();
    tick();

    expect(sidebarComponent.showBrowseSection()).toBe(false);
  }));

  it('toggleBrowseSection navigates to browse when not in browse', fakeAsync(() => {
    const fixture = TestBed.createComponent(WorkspaceSidebarComponent);
    const nav = TestBed.inject(NavService);
    const sidebarComponent = fixture.componentInstance;
    const navSpy = vi.spyOn(nav, 'navigate');

    fixture.detectChanges();
    tick();

    nav['activeSectionSignal'].set('plans');
    sidebarComponent.toggleBrowseSection();

    expect(navSpy).toHaveBeenCalledWith('docs');
  }));

  it('toggleBrowseSection navigates to plans when in browse', fakeAsync(() => {
    const fixture = TestBed.createComponent(WorkspaceSidebarComponent);
    const nav = TestBed.inject(NavService);
    const sidebarComponent = fixture.componentInstance;
    const navSpy = vi.spyOn(nav, 'navigate');

    fixture.detectChanges();
    tick();

    nav['activeSectionSignal'].set('browse');
    sidebarComponent.toggleBrowseSection();

    expect(navSpy).toHaveBeenCalledWith('plans');
  }));
});
