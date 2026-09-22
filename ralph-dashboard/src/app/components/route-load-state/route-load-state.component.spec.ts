import '../../../angular-test-env';
import { TestBed } from '@angular/core/testing';
import { RouteLoadStateComponent } from './route-load-state.component';

describe('RouteLoadStateComponent', () => {
  beforeEach(async () => {
    TestBed.resetTestingModule();
    await TestBed.configureTestingModule({
      imports: [RouteLoadStateComponent],
    }).compileComponents();
  });

  it('announces loading via aria-live polite region', () => {
    const fixture = TestBed.createComponent(RouteLoadStateComponent);
    fixture.componentRef.setInput('loading', true);
    fixture.detectChanges();

    const live = fixture.nativeElement.querySelector('[aria-live="polite"]');
    expect(live).toBeTruthy();
    expect(live.textContent).toContain('Loading');
    expect(fixture.nativeElement.querySelector('[data-testid="route-loading-skeleton"]')).toBeTruthy();
  });

  it('exposes errors as assertive alerts with retry', () => {
    const fixture = TestBed.createComponent(RouteLoadStateComponent);
    fixture.componentRef.setInput('loading', false);
    fixture.componentRef.setInput('error', 'Failed to load');
    fixture.detectChanges();

    const alert = fixture.nativeElement.querySelector('[role="alert"]');
    expect(alert).toBeTruthy();
    expect(alert.getAttribute('aria-live')).toBe('assertive');
    expect(alert.textContent).toContain('Failed to load');
    expect(fixture.nativeElement.querySelector('[data-testid="route-retry"]')).toBeTruthy();
  });
});
