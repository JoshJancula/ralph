import '../../../angular-test-env';
import { TestBed } from '@angular/core/testing';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { RuntimeStatusComponent } from './runtime-status.component';
import type { AmbientUsageResponse } from '../../services/api.service';

describe('RuntimeStatusComponent', () => {
  let httpMock: HttpTestingController;

  beforeEach(async () => {
    TestBed.resetTestingModule();
    await TestBed.configureTestingModule({
      imports: [RuntimeStatusComponent, HttpClientTestingModule],
    }).compileComponents();
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
  });

  const emptyRuntimeFields = {
    planHint: null as string | null,
    providers: [] as string[],
    links: [] as Array<{ label: string; url: string }>,
  };

  function flushPage(
    fixture: ReturnType<typeof TestBed.createComponent<RuntimeStatusComponent>>,
    ambient: AmbientUsageResponse,
  ): void {
    fixture.detectChanges();
    httpMock.expectOne('/api/runtime-status').flush([
      {
        runtimeId: 'codex',
        label: 'Codex (OpenAI)',
        state: 'connected',
        detail: null,
        accountHint: null,
        ...emptyRuntimeFields,
      },
    ]);
    httpMock.expectOne('/api/metrics/ambient-usage').flush(ambient);
    fixture.detectChanges();
  }

  it('renders runtimes in Claude → Codex → Antigravity → Cursor → OpenCode order', () => {
    const fixture = TestBed.createComponent(RuntimeStatusComponent);
    fixture.detectChanges();
    httpMock.expectOne('/api/runtime-status').flush([
      { runtimeId: 'claude', label: 'Claude (Anthropic)', state: 'connected', detail: null, accountHint: 'a@b.com', planHint: 'Pro', providers: [], links: [{ label: 'Check Claude usage', url: 'https://claude.ai/settings/usage' }] },
      { runtimeId: 'codex', label: 'Codex (OpenAI)', state: 'connected', detail: null, accountHint: null, planHint: 'ChatGPT · Plus', providers: [], links: [{ label: 'Check ChatGPT billing', url: 'https://chatgpt.com/#settings' }] },
      { runtimeId: 'antigravity', label: 'Antigravity (Google)', state: 'connected', detail: null, accountHint: null, ...emptyRuntimeFields },
      { runtimeId: 'cursor', label: 'Cursor Agent', state: 'connected', detail: null, accountHint: 'c@d.com', planHint: 'Pro+', providers: [], links: [{ label: 'View Cursor Usage', url: 'https://cursor.com/dashboard/billing' }] },
      { runtimeId: 'opencode', label: 'OpenCode', state: 'connected', detail: null, accountHint: null, planHint: null, providers: ['Ollama Cloud'], links: [{ label: 'View Ollama Usage', url: 'https://ollama.com/settings' }] },
    ]);
    httpMock.expectOne('/api/metrics/ambient-usage').flush({
      enabled: false,
      scope: 'machine_local',
      date_scope: { from: null, to: null, label: 'all' },
      providers: [],
    });
    fixture.detectChanges();

    const cards = Array.from(
      (fixture.nativeElement as HTMLElement).querySelectorAll<HTMLElement>('[data-runtime]'),
    ).map((el) => el.getAttribute('data-runtime'));
    expect(cards).toEqual(['claude', 'codex', 'antigravity', 'cursor', 'opencode']);
    expect(fixture.nativeElement.textContent).toContain('Plan');
    expect(fixture.nativeElement.textContent).toContain('Pro');
    expect(fixture.nativeElement.textContent).toContain('ChatGPT · Plus');
    expect(fixture.nativeElement.textContent).toContain('Pro+');
    expect(fixture.nativeElement.textContent).not.toContain('Pro+ · Auto');
    expect(fixture.nativeElement.textContent).toContain('Ollama Cloud');

    const cursorCard = (fixture.nativeElement as HTMLElement).querySelector('[data-runtime="cursor"]');
    const cursorLink = cursorCard?.querySelector('a') as HTMLAnchorElement | null;
    expect(cursorLink?.href).toBe('https://cursor.com/dashboard/billing');
    expect(cursorLink?.textContent).toContain('View Cursor Usage');

    const openCodeCard = (fixture.nativeElement as HTMLElement).querySelector('[data-runtime="opencode"]');
    const openCodeLink = openCodeCard?.querySelector('a') as HTMLAnchorElement | null;
    expect(openCodeLink?.href).toBe('https://ollama.com/settings');
    expect(openCodeLink?.textContent).toContain('View Ollama Usage');
  });

  it('fills the remaining-quota bar from used percent', () => {
    const fixture = TestBed.createComponent(RuntimeStatusComponent);
    flushPage(fixture, {
      enabled: true,
      scope: 'machine_local',
      date_scope: { from: null, to: null, label: 'all' },
      providers: [
        {
          id: 'codex',
          label: 'Codex',
          status: 'available',
          rate_limits: [
            {
              id: 'weekly',
              label: 'Weekly',
              used_percent: 1,
              resets_at: null,
              resets_in_seconds: null,
            },
          ],
          tokens: {
            input_tokens: 0,
            output_tokens: 0,
            cache_read_input_tokens: 0,
            cache_creation_input_tokens: 0,
            total_tokens: 0,
            session_count: 0,
          },
          model_breakdown: [],
          updated_at: new Date().toISOString(),
        },
      ],
    });

    const el: HTMLElement = fixture.nativeElement;
    const fill = el.querySelector('.runtime-quota-fill') as HTMLElement | null;
    expect(fill).toBeTruthy();
    expect(fill?.style.width).toBe('99%');
    expect(el.textContent).toContain('1% used');
    expect(el.textContent).toContain('99% remaining');
  });

  it('renders Antigravity ambient quota windows', () => {
    const fixture = TestBed.createComponent(RuntimeStatusComponent);
    fixture.detectChanges();
    httpMock.expectOne('/api/runtime-status').flush([
      {
        runtimeId: 'antigravity',
        label: 'Antigravity (Google)',
        state: 'connected',
        detail: null,
        accountHint: null,
        ...emptyRuntimeFields,
      },
    ]);
    httpMock.expectOne('/api/metrics/ambient-usage').flush({
      enabled: true,
      scope: 'machine_local',
      date_scope: { from: null, to: null, label: 'all' },
      providers: [
        {
          id: 'antigravity',
          label: 'Antigravity',
          status: 'available',
          rate_limits: [
            {
              id: 'gemini-weekly',
              label: 'Gemini Models · Weekly Limit',
              used_percent: 83,
              resets_at: '2026-09-25T14:24:54.000Z',
              resets_in_seconds: 86400,
            },
          ],
          tokens: {
            input_tokens: 0,
            output_tokens: 0,
            cache_read_input_tokens: 0,
            cache_creation_input_tokens: 0,
            total_tokens: 0,
            session_count: 0,
          },
          model_breakdown: [],
          updated_at: new Date().toISOString(),
        },
      ],
    });
    fixture.detectChanges();

    const el: HTMLElement = fixture.nativeElement;
    expect(el.textContent).toContain('Gemini Models · Weekly Limit');
    expect(el.textContent).toContain('83% used');
    expect(el.textContent).toContain('17% remaining');
    const fill = el.querySelector('.runtime-quota-fill') as HTMLElement | null;
    expect(fill?.style.width).toBe('17%');
  });

  it('computes remaining quota from used percent', () => {
    const fixture = TestBed.createComponent(RuntimeStatusComponent);
    flushPage(fixture, {
      enabled: false,
      scope: 'machine_local',
      date_scope: { from: null, to: null, label: 'all' },
      providers: [],
    });
    const component = fixture.componentInstance;
    expect(component.remainingQuotaPercent(1)).toBe(99);
    expect(component.remainingQuotaPercent(100)).toBe(0);
    expect(component.remainingQuotaPercent(Number.NaN)).toBe(0);
  });
});
