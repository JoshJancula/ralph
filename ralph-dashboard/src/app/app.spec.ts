import '../angular-test-env';
import { TestBed, fakeAsync, tick } from '@angular/core/testing';
import { HttpClientTestingModule } from '@angular/common/http/testing';
import { RouterTestingModule } from '@angular/router/testing';

import { AppComponent } from './app.component';
import { NavService } from './services/nav.service';

describe('AppComponent (root)', () => {
  let originalLocalStorage: Storage;
  let localStorageMock: { getItem: ReturnType<typeof vi.fn>; setItem: ReturnType<typeof vi.fn> };

  beforeEach(async () => {
    // Mock localStorage
    localStorageMock = {
      getItem: vi.fn(),
      setItem: vi.fn(),
    };
    Object.defineProperty(window, 'localStorage', {
      value: localStorageMock,
      writable: true,
    });

    await TestBed.configureTestingModule({
      imports: [AppComponent, HttpClientTestingModule, RouterTestingModule.withRoutes([])],
    }).compileComponents();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('should create the app', () => {
    const fixture = TestBed.createComponent(AppComponent);
    const app = fixture.componentInstance;
    expect(app).toBeTruthy();
  });

  it('should render dashboard title', async () => {
    const fixture = TestBed.createComponent(AppComponent);
    await fixture.whenStable();
    const compiled = fixture.nativeElement as HTMLElement;
    expect(compiled.querySelector('.title')?.textContent).toContain('Workspace Explorer');
  });

  it('should read theme preference from localStorage on init', () => {
    localStorageMock.getItem.mockReturnValue('light');
    const fixture = TestBed.createComponent(AppComponent);
    expect(fixture.componentInstance.isLightTheme()).toBe(true);
  });

  it('should store theme preference to localStorage when toggling', () => {
    const fixture = TestBed.createComponent(AppComponent);
    fixture.componentInstance.toggleTheme();
    expect(localStorageMock.setItem).toHaveBeenCalledWith('ralph-dashboard-theme', 'light');
  });

  it('should apply theme class to document body when toggling', () => {
    const fixture = TestBed.createComponent(AppComponent);
    const initialClass = document.body.classList.contains('theme-light');
    fixture.componentInstance.toggleTheme();
    expect(document.body.classList.contains('theme-light')).toBe(!initialClass);
  });

  it('should toggle sidebar open state', () => {
    const fixture = TestBed.createComponent(AppComponent);
    const initialState = fixture.componentInstance.sidebarOpen();
    fixture.componentInstance.toggleSidebar();
    expect(fixture.componentInstance.sidebarOpen()).toBe(!initialState);
  });

  it('should close sidebar when closeSidebar is called', () => {
    const fixture = TestBed.createComponent(AppComponent);
    fixture.componentInstance.sidebarOpen.set(true);
    fixture.componentInstance.closeSidebar();
    expect(fixture.componentInstance.sidebarOpen()).toBe(false);
  });

  it('should refresh nav when refresh is called', () => {
    const fixture = TestBed.createComponent(AppComponent);
    const nav = TestBed.inject(NavService);
    const spy = vi.spyOn(nav, 'refresh');
    fixture.componentInstance.refresh();
    expect(spy).toHaveBeenCalled();
  });

  it.skip('should close sidebar when active file changes', fakeAsync(() => {
    const fixture = TestBed.createComponent(AppComponent);
    fixture.componentInstance.sidebarOpen.set(true);
    
    // Force a re-run of the effect by triggering change detection
    fixture.detectChanges();
    tick();
    
    // Now simulate navigation to a file - this should trigger the effect
    const nav = TestBed.inject(NavService);
    nav.navigate('logs', '', 'some-file.md');
    tick();
    
    // Force change detection to run the effect
    fixture.detectChanges();
    tick();
    
    // The sidebar should be closed after navigating to a file
    expect(fixture.componentInstance.sidebarOpen()).toBe(false);
  }));
});
