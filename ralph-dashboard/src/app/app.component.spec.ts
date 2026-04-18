import '../angular-test-env';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { Component, inject } from '@angular/core';
import { TestBed } from '@angular/core/testing';
import { Router } from '@angular/router';
import { RouterTestingModule } from '@angular/router/testing';
import { AppComponent } from './app.component';
import { NavService } from './services/nav.service';

@Component({
  selector: 'ralph-plan-hub',
  standalone: true,
  template: '',
})
class PlanHubStubComponent {}

@Component({
  selector: 'app-file-viewer',
  standalone: true,
  template: '',
})
class FileViewerStubComponent {}

@Component({
  selector: 'ralph-log-viewer',
  standalone: true,
  template: '',
})
class LogViewerStubComponent {}

@Component({
  selector: 'app-workspace-view',
  standalone: true,
  imports: [PlanHubStubComponent, FileViewerStubComponent, LogViewerStubComponent],
  template: `
    @switch (viewKind()) {
      @case ('plan') {
        <ralph-plan-hub></ralph-plan-hub>
      }
      @case ('file') {
        <app-file-viewer></app-file-viewer>
      }
      @case ('log') {
        <ralph-log-viewer></ralph-log-viewer>
      }
      @default {
        @if (activeRoot()) {
          <div class="empty-state">Select a file to inspect its contents.</div>
        } @else {
          <div class="empty-state">Select a section from the sidebar to get started.</div>
        }
      }
    }
  `,
})
class WorkspaceViewStubComponent {
  private readonly nav = inject(NavService);
  readonly activeRoot = this.nav.activeRoot;
  readonly activeFile = this.nav.activeFile;
  readonly viewKind = () => {
    const root = this.activeRoot();
    const file = this.activeFile();

    if (!root) {
      return 'empty';
    }
    if (file) {
      return file.endsWith('.log') ? 'log' : 'file';
    }
    return root === 'plans' ? 'plan' : 'empty';
  };
}

const testRoutes = [
  { path: '', redirectTo: 'plans', pathMatch: 'full' },
  { path: 'plans', component: WorkspaceViewStubComponent },
  { path: ':root/path/:path/file/:file', component: WorkspaceViewStubComponent },
  { path: ':root/file/:file', component: WorkspaceViewStubComponent },
  { path: ':root/path/:path', component: WorkspaceViewStubComponent },
  { path: ':root', component: WorkspaceViewStubComponent },
  { path: '**', redirectTo: 'plans' },
];

function requestPath(url: string): string {
  const q = url.indexOf('?');
  return q === -1 ? url : url.slice(0, q);
}

function flushOutstandingHttp(httpMock: HttpTestingController): void {
  for (let round = 0; round < 15; round++) {
    let flushed = false;
    for (const req of httpMock.match((r) => requestPath(r.url) === '/api/roots')) {
      req.flush([]);
      flushed = true;
    }
    for (const req of httpMock.match((r) => requestPath(r.url) === '/api/list')) {
      const root = req.request.params.get('root') ?? '';
      const path = req.request.params.get('path') ?? '';
      req.flush({
        root,
        path,
        parent: null,
        entries: [],
      });
      flushed = true;
    }
    for (const req of httpMock.match((r) => requestPath(r.url) === '/api/file')) {
      req.flush({
        content: '',
        size: 0,
        offset: 0,
        nextOffset: 0,
      });
      flushed = true;
    }
    for (const req of httpMock.match((r) => requestPath(r.url) === '/api/workspace')) {
      req.flush({ root: '/test' });
      flushed = true;
    }
    if (!flushed) {
      break;
    }
  }
}

async function renderDashboard(
  fixture: {
    detectChanges(): void;
    whenStable(): Promise<unknown>;
  },
  httpMock: HttpTestingController,
): Promise<void> {
  await fixture.whenStable();
  fixture.detectChanges();
  flushOutstandingHttp(httpMock);
  await fixture.whenStable();
  fixture.detectChanges();
  flushOutstandingHttp(httpMock);
  await fixture.whenStable();
  fixture.detectChanges();
}

describe('AppComponent', () => {
  let httpMock: HttpTestingController;

  beforeEach(async () => {
    TestBed.resetTestingModule();
    await TestBed.configureTestingModule({
      imports: [AppComponent, HttpClientTestingModule, RouterTestingModule.withRoutes(testRoutes)],
    }).compileComponents();
    const router = TestBed.inject(Router);
    await router.initialNavigation();
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
  });

  it('renders ion-split-pane for responsive layout', async () => {
    const fixture = TestBed.createComponent(AppComponent);
    await renderDashboard(fixture, httpMock);

    const compiled = fixture.nativeElement as HTMLElement;
    const splitPane = compiled.querySelector('ion-split-pane');
    const menu = compiled.querySelector('ion-menu');
    const contentTarget = compiled.querySelector('#main-content');
    const routerOutlet = compiled.querySelector('router-outlet');
    expect(splitPane).toBeTruthy();
    expect(menu).toBeTruthy();
    expect(contentTarget).toBeTruthy();
    expect(routerOutlet).toBeTruthy();
    expect(menu?.getAttribute('contentid')).toBe('main-content');
    expect(menu?.getAttribute('menuid')).toBe('workspace-menu');
  });

  it('theme preference loads from localStorage light', async () => {
    localStorage.setItem('ralph-dashboard-theme', 'light');

    const fixture = TestBed.createComponent(AppComponent);
    await renderDashboard(fixture, httpMock);

    expect(fixture.componentInstance.isLightTheme()).toBe(true);

    localStorage.removeItem('ralph-dashboard-theme');
  });

  it('theme preference loads from localStorage dark', async () => {
    localStorage.setItem('ralph-dashboard-theme', 'dark');

    const fixture = TestBed.createComponent(AppComponent);
    await renderDashboard(fixture, httpMock);

    expect(fixture.componentInstance.isLightTheme()).toBe(false);

    localStorage.removeItem('ralph-dashboard-theme');
  });

  it('refresh button calls NavService.refresh()', async () => {
    const fixture = TestBed.createComponent(AppComponent);
    const nav = TestBed.inject(NavService);
    const spy = vi.spyOn(nav, 'refresh');
    await renderDashboard(fixture, httpMock);

    const endToolbarButtons = fixture.nativeElement.querySelectorAll(
      'ion-toolbar ion-buttons[slot="end"] ion-button',
    );
    expect(endToolbarButtons.length).toBeGreaterThanOrEqual(3);
    const refreshBtn = endToolbarButtons[1];
    expect(refreshBtn).toBeTruthy();
    (refreshBtn as HTMLElement).click();
    expect(spy).toHaveBeenCalledTimes(1);
  });

  it('with no active file: plan hub is shown and file viewers are not rendered', async () => {
    const fixture = TestBed.createComponent(AppComponent);
    await renderDashboard(fixture, httpMock);

    const el = fixture.nativeElement as HTMLElement;
    expect(el.querySelector('ralph-plan-hub')).toBeTruthy();
    expect(el.querySelector('ralph-log-viewer')).toBeNull();
    expect(el.querySelector('app-file-viewer')).toBeNull();
  });

  it('with activeRoot plans and no activeFile: plan-hub is shown', async () => {
    const fixture = TestBed.createComponent(AppComponent);
    const nav = TestBed.inject(NavService);
    nav.navigate('plans', 'PLAN2');
    await renderDashboard(fixture, httpMock);

    const el = fixture.nativeElement as HTMLElement;
    expect(el.querySelector('ralph-plan-hub')).toBeTruthy();
  });

  it('with activeRoot logs and activeFile .log: log-viewer is shown', async () => {
    const fixture = TestBed.createComponent(AppComponent);
    const nav = TestBed.inject(NavService);
    nav.navigate('logs', 'PLAN2', 'runner.log');
    await renderDashboard(fixture, httpMock);

    const el = fixture.nativeElement as HTMLElement;
    expect(el.querySelector('ralph-log-viewer')).toBeTruthy();
  });

   it('theme toggle switches body class and icon', async () => {
     localStorage.setItem('ralph-dashboard-theme', 'dark');

     const fixture = TestBed.createComponent(AppComponent);
     await renderDashboard(fixture, httpMock);

     expect(fixture.componentInstance.isLightTheme()).toBe(false);

     const endToolbarButtons = fixture.nativeElement.querySelectorAll(
       'ion-toolbar ion-buttons[slot="end"] ion-button',
     );
     expect(endToolbarButtons.length).toBeGreaterThanOrEqual(3);
     const themeBtn = endToolbarButtons[2];
     expect(themeBtn).toBeTruthy();
     (themeBtn as HTMLElement).click();
     fixture.detectChanges();
     expect(document.body.classList.contains('theme-light')).toBe(true);
     expect(fixture.componentInstance.isLightTheme()).toBe(true);

     (themeBtn as HTMLElement).click();
     fixture.detectChanges();
     expect(document.body.classList.contains('theme-light')).toBe(false);
     expect(fixture.componentInstance.isLightTheme()).toBe(false);

     localStorage.removeItem('ralph-dashboard-theme');
   });

  it('theme toggle reflects localStorage value', async () => {
    localStorage.setItem('ralph-dashboard-theme', 'light');

    const fixture = TestBed.createComponent(AppComponent);
    await renderDashboard(fixture, httpMock);

    expect(fixture.componentInstance.isLightTheme()).toBe(true);

    localStorage.removeItem('ralph-dashboard-theme');
  });

  it('theme toggle reflects dark localStorage value', async () => {
    localStorage.setItem('ralph-dashboard-theme', 'dark');

    const fixture = TestBed.createComponent(AppComponent);
    await renderDashboard(fixture, httpMock);

    expect(fixture.componentInstance.isLightTheme()).toBe(false);

    localStorage.removeItem('ralph-dashboard-theme');
  });

  it('with activeFile .md filename: file-viewer is shown', async () => {
    const fixture = TestBed.createComponent(AppComponent);
    const nav = TestBed.inject(NavService);
    nav.navigate('plans', 'PLAN2', 'notes.md');
    await renderDashboard(fixture, httpMock);

    const el = fixture.nativeElement as HTMLElement;
    expect(el.querySelector('app-file-viewer')).toBeTruthy();
  });

  it('renders ion-menu-button for mobile navigation', async () => {
    const fixture = TestBed.createComponent(AppComponent);
    await renderDashboard(fixture, httpMock);

    const compiled = fixture.nativeElement as HTMLElement;
    expect(compiled.querySelector('ion-menu-button')).toBeTruthy();
  });
});
