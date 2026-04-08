import '../angular-test-env';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { Component } from '@angular/core';
import { TestBed } from '@angular/core/testing';
import { RouterTestingModule } from '@angular/router/testing';
import { AppComponent } from './app.component';
import { PlanHubComponent } from './components/plan-hub/plan-hub.component';
import { NavService } from './services/nav.service';

@Component({
  selector: 'ralph-plan-hub',
  standalone: true,
  template: '',
})
class PlanHubStubComponent {}

const testRoutes = [
  { path: '', redirectTo: 'plans', pathMatch: 'full' },
  { path: 'plans', component: PlanHubStubComponent },
  { path: ':root', component: PlanHubStubComponent },
  { path: '**', component: PlanHubStubComponent },
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

describe('AppComponent', () => {
  let httpMock: HttpTestingController;

  beforeEach(async () => {
    TestBed.resetTestingModule();
    await TestBed.configureTestingModule({
      imports: [AppComponent, HttpClientTestingModule, RouterTestingModule.withRoutes(testRoutes)],
    })
      .overrideComponent(AppComponent, {
        remove: { imports: [PlanHubComponent] },
        add: { imports: [PlanHubStubComponent] },
      })
      .compileComponents();
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
  });

  it('renders ion-split-pane for responsive layout', async () => {
    const fixture = TestBed.createComponent(AppComponent);
    fixture.detectChanges();
    flushOutstandingHttp(httpMock);
    await fixture.whenStable();
    fixture.detectChanges();

    const compiled = fixture.nativeElement as HTMLElement;
    const splitPane = compiled.querySelector('ion-split-pane');
    const menu = compiled.querySelector('ion-menu');
    const contentTarget = compiled.querySelector('#main-content');
    expect(splitPane).toBeTruthy();
    expect(menu).toBeTruthy();
    expect(contentTarget).toBeTruthy();
    expect(menu?.getAttribute('contentid')).toBe('main-content');
    expect(menu?.getAttribute('menuid')).toBe('workspace-menu');
  });

  it('theme preference loads from localStorage light', async () => {
    localStorage.setItem('ralph-dashboard-theme', 'light');

    const fixture = TestBed.createComponent(AppComponent);
    fixture.detectChanges();
    flushOutstandingHttp(httpMock);
    await fixture.whenStable();
    fixture.detectChanges();

    expect(fixture.componentInstance.isLightTheme()).toBe(true);

    localStorage.removeItem('ralph-dashboard-theme');
  });

  it('theme preference loads from localStorage dark', async () => {
    localStorage.setItem('ralph-dashboard-theme', 'dark');

    const fixture = TestBed.createComponent(AppComponent);
    fixture.detectChanges();
    flushOutstandingHttp(httpMock);
    await fixture.whenStable();
    fixture.detectChanges();

    expect(fixture.componentInstance.isLightTheme()).toBe(false);

    localStorage.removeItem('ralph-dashboard-theme');
  });

  it('refresh button calls NavService.refresh()', async () => {
    const fixture = TestBed.createComponent(AppComponent);
    const nav = TestBed.inject(NavService);
    const spy = vi.spyOn(nav, 'refresh');
    fixture.detectChanges();
    flushOutstandingHttp(httpMock);
    await fixture.whenStable();
    fixture.detectChanges();

    const btns = fixture.nativeElement.querySelectorAll('ion-button');
    // Find the refresh button by its icon
    const refreshBtn = Array.from(btns).find((btn: any) => 
      btn.querySelector('ion-icon[name="refresh-outline"]'));
    expect(refreshBtn).toBeTruthy();
    (refreshBtn as HTMLElement).click();
    expect(spy).toHaveBeenCalledTimes(1);
  });

  it('with no active file: plan hub is shown and file viewers are not rendered', async () => {
    const fixture = TestBed.createComponent(AppComponent);
    fixture.detectChanges();
    flushOutstandingHttp(httpMock);
    await fixture.whenStable();
    fixture.detectChanges();

    const el = fixture.nativeElement as HTMLElement;
    expect(el.querySelector('ralph-plan-hub')).toBeTruthy();
    expect(el.querySelector('ralph-log-viewer')).toBeNull();
    expect(el.querySelector('app-file-viewer')).toBeNull();
  });

  it('with activeRoot plans and no activeFile: plan-hub is shown', async () => {
    const fixture = TestBed.createComponent(AppComponent);
    const nav = TestBed.inject(NavService);
    nav.navigate('plans', 'PLAN2');
    fixture.detectChanges();
    flushOutstandingHttp(httpMock);
    await fixture.whenStable();
    fixture.detectChanges();
    flushOutstandingHttp(httpMock);
    await fixture.whenStable();
    fixture.detectChanges();

    const el = fixture.nativeElement as HTMLElement;
    expect(el.querySelector('ralph-plan-hub')).toBeTruthy();
  });

  it('with activeRoot logs and activeFile .log: log-viewer is shown', async () => {
    const fixture = TestBed.createComponent(AppComponent);
    const nav = TestBed.inject(NavService);
    nav.navigate('logs', 'PLAN2', 'runner.log');
    fixture.detectChanges();
    flushOutstandingHttp(httpMock);
    await fixture.whenStable();
    fixture.detectChanges();
    flushOutstandingHttp(httpMock);
    await fixture.whenStable();
    fixture.detectChanges();

    const el = fixture.nativeElement as HTMLElement;
    expect(el.querySelector('ralph-log-viewer')).toBeTruthy();
  });

   it('theme toggle switches body class and icon', async () => {
     localStorage.setItem('ralph-dashboard-theme', 'dark');

     const fixture = TestBed.createComponent(AppComponent);
     fixture.detectChanges();
     flushOutstandingHttp(httpMock);
     await fixture.whenStable();
     fixture.detectChanges();

     expect(fixture.componentInstance.isLightTheme()).toBe(false);

     const btns = fixture.nativeElement.querySelectorAll('ion-button');
     // Find the theme button by its icon
     const themeBtn = Array.from(btns).find((btn: any) =>
       btn.querySelector('ion-icon[name="sunny-outline"], ion-icon[name="moon-outline"]'));
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
    fixture.detectChanges();
    flushOutstandingHttp(httpMock);
    await fixture.whenStable();
    fixture.detectChanges();

    expect(fixture.componentInstance.isLightTheme()).toBe(true);

    localStorage.removeItem('ralph-dashboard-theme');
  });

  it('theme toggle reflects dark localStorage value', async () => {
    localStorage.setItem('ralph-dashboard-theme', 'dark');

    const fixture = TestBed.createComponent(AppComponent);
    fixture.detectChanges();
    flushOutstandingHttp(httpMock);
    await fixture.whenStable();
    fixture.detectChanges();

    expect(fixture.componentInstance.isLightTheme()).toBe(false);

    localStorage.removeItem('ralph-dashboard-theme');
  });

  it('with activeFile .md filename: file-viewer is shown', async () => {
    const fixture = TestBed.createComponent(AppComponent);
    const nav = TestBed.inject(NavService);
    nav.navigate('plans', 'PLAN2', 'notes.md');
    fixture.detectChanges();
    flushOutstandingHttp(httpMock);
    await fixture.whenStable();
    fixture.detectChanges();
    flushOutstandingHttp(httpMock);
    await fixture.whenStable();
    fixture.detectChanges();

    const el = fixture.nativeElement as HTMLElement;
    expect(el.querySelector('app-file-viewer')).toBeTruthy();
  });

  it('renders ion-menu-button for mobile navigation', async () => {
    const fixture = TestBed.createComponent(AppComponent);
    fixture.detectChanges();
    flushOutstandingHttp(httpMock);
    await fixture.whenStable();
    fixture.detectChanges();

    const compiled = fixture.nativeElement as HTMLElement;
    expect(compiled.querySelector('ion-menu-button')).toBeTruthy();
  });
});
