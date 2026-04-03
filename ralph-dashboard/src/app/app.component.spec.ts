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

  it('shell renders topbar with title Workspace Explorer', async () => {
    const fixture = TestBed.createComponent(AppComponent);
    fixture.detectChanges();
    flushOutstandingHttp(httpMock);
    await fixture.whenStable();
    fixture.detectChanges();

    const compiled = fixture.nativeElement as HTMLElement;
    expect(compiled.querySelector('.topbar .title')?.textContent?.trim()).toBe('Workspace Explorer');
  });

  it('refresh button calls NavService.refresh()', async () => {
    const fixture = TestBed.createComponent(AppComponent);
    const nav = TestBed.inject(NavService);
    const spy = vi.spyOn(nav, 'refresh');
    fixture.detectChanges();
    flushOutstandingHttp(httpMock);
    await fixture.whenStable();
    fixture.detectChanges();

    const btn = fixture.nativeElement.querySelector('.refresh-btn') as HTMLButtonElement;
    btn.click();
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

  it('theme toggle switches body class and button label', async () => {
    const fixture = TestBed.createComponent(AppComponent);
    fixture.detectChanges();
    flushOutstandingHttp(httpMock);
    await fixture.whenStable();
    fixture.detectChanges();

    document.body.classList.remove('theme-light');
    const btn = fixture.nativeElement.querySelector('.theme-toggle') as HTMLButtonElement;
    expect(btn.textContent?.trim()).toContain('Light');
    btn.click();
    fixture.detectChanges();
    expect(document.body.classList.contains('theme-light')).toBe(true);
    expect(btn.textContent?.trim()).toContain('Dark');
    btn.click();
    fixture.detectChanges();
    expect(document.body.classList.contains('theme-light')).toBe(false);
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

  it('marks the layout with the page scroll model attribute', async () => {
    const fixture = TestBed.createComponent(AppComponent);
    fixture.detectChanges();
    flushOutstandingHttp(httpMock);
    await fixture.whenStable();
    fixture.detectChanges();

    const compiled = fixture.nativeElement as HTMLElement;
    expect(compiled.querySelector('.layout')?.getAttribute('data-scroll-model')).toBe('page');
  });
});
