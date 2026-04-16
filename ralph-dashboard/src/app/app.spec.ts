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
    document.body.classList.remove('theme-light');
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
    expect(compiled.querySelector('ion-title')?.textContent).toContain('Workspace Explorer');
  });

  it('should read theme preference from localStorage on init', () => {
    localStorageMock.getItem.mockReturnValue('light');
    const fixture = TestBed.createComponent(AppComponent);
    fixture.detectChanges();
    expect(fixture.componentInstance.isLightTheme()).toBe(true);
  });

  it('should store theme preference to localStorage when toggling', () => {
    const fixture = TestBed.createComponent(AppComponent);
    fixture.componentInstance.isLightTheme.set(false);
    fixture.componentInstance.toggleTheme();
    expect(localStorageMock.setItem).toHaveBeenCalledWith('ralph-dashboard-theme', 'light');
  });

  it('should apply theme class to document body when toggling', () => {
    const fixture = TestBed.createComponent(AppComponent);
    const initialClass = document.body.classList.contains('theme-light');
    fixture.componentInstance.toggleTheme();
    expect(document.body.classList.contains('theme-light')).toBe(!initialClass);
  });

  it('should call nav.refresh when refresh is called', () => {
    const fixture = TestBed.createComponent(AppComponent);
    const nav = TestBed.inject(NavService);
    const spy = vi.spyOn(nav, 'refresh');
    fixture.componentInstance.refresh();
    expect(spy).toHaveBeenCalled();
  });
});
