import '../../angular-test-env';
import { provideRouter } from '@angular/router';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { signal } from '@angular/core';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { AssistantDockComponent } from './assistant-dock.component';
import { AssistantStore } from './assistant.store';
import { CapabilitiesService } from '../workflows/capabilities.service';
import type { AssistantChatMessage, AssistantProposalView } from './assistant.types';

function fakeStore() {
  return {
    open: signal(false),
    prefilledDraft: signal(''),
    messages: signal<readonly AssistantChatMessage[]>([]),
    sending: signal(false),
    error: signal<string | null>(null),
    tools: signal([]),
    runtimes: signal([]),
    models: signal([]),
    lastAnsweredBy: signal<string | null>(null),
    lastDegraded: signal(false),
    proposals: signal<readonly AssistantProposalView[]>([]),
    committing: signal<string | null>(null),
    selectedRuntime: signal<string | null>(null),
    selectedModel: signal(''),
    toggle: vi.fn(),
    close: vi.fn(),
    clear: vi.fn(),
    setRuntime: vi.fn(),
    setModel: vi.fn(),
    consumePrefilledDraft: vi.fn(() => ''),
    send: vi.fn(async () => true),
    sendApprovedAction: vi.fn(async () => true),
    commitProposal: vi.fn(async () => true),
    dismissProposal: vi.fn(),
  };
}

function fakeCapabilities(assistant = true) {
  return { load: vi.fn(), capabilities: signal({ workflowWrites: assistant, workflowRuns: assistant, assistant }) };
}

describe('AssistantDockComponent', () => {
  let fixture: ComponentFixture<AssistantDockComponent>;
  let store: ReturnType<typeof fakeStore>;

  async function build(capabilities = fakeCapabilities()): Promise<void> {
    store = fakeStore();
    await TestBed.configureTestingModule({
      imports: [AssistantDockComponent],
      providers: [provideRouter([]), { provide: AssistantStore, useValue: store }, { provide: CapabilitiesService, useValue: capabilities }],
    }).compileComponents();
    fixture = TestBed.createComponent(AssistantDockComponent);
    fixture.detectChanges();
  }

  it('renders nothing when capabilities.assistant is false', async () => {
    await build(fakeCapabilities(false));
    expect(fixture.nativeElement.querySelector('[data-testid="assistant-launcher"]')).toBeNull();
  });

  it('shows the launcher and toggles the panel via the store', async () => {
    await build();
    const launcher = fixture.nativeElement.querySelector('[data-testid="assistant-launcher"]') as HTMLButtonElement;
    expect(launcher).not.toBeNull();
    launcher.click();
    expect(store.toggle).toHaveBeenCalled();
  });

  it('hides the launcher while a hub modal backdrop is open', async () => {
    await build();
    expect(fixture.nativeElement.querySelector('[data-testid="assistant-launcher"]')).not.toBeNull();

    const backdrop = document.createElement('div');
    backdrop.className = 'hub-modal-backdrop';
    document.body.appendChild(backdrop);
    await new Promise((resolve) => setTimeout(resolve, 0));
    fixture.detectChanges();

    expect(fixture.nativeElement.querySelector('[data-testid="assistant-launcher"]')).toBeNull();

    backdrop.remove();
    await new Promise((resolve) => setTimeout(resolve, 0));
    fixture.detectChanges();
    expect(fixture.nativeElement.querySelector('[data-testid="assistant-launcher"]')).not.toBeNull();
  });

  it('closes the panel on Escape and restores focus to the launcher', async () => {
    await build();
    store.open.set(true);
    fixture.detectChanges();
    const panel = fixture.nativeElement.querySelector('[data-testid="assistant-panel"]') as HTMLElement;
    expect(panel).not.toBeNull();
    panel.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
    fixture.componentInstance.closePanel();
    expect(store.close).toHaveBeenCalled();
    await new Promise((r) => setTimeout(r, 0));
    const launcher = fixture.nativeElement.querySelector('[data-testid="assistant-launcher"]') as HTMLButtonElement;
    expect(document.activeElement).toBe(launcher);
  });

  it('renders markdown message content sanitized, stripping a script tag', async () => {
    await build();
    store.open.set(true);
    store.messages.set([{ role: 'assistant', content: '**bold** <script>alert(1)</script> text' }]);
    fixture.detectChanges();
    const bubble = fixture.nativeElement.querySelector('.bubble-assistant');
    expect(bubble?.innerHTML).toContain('<strong>bold</strong>');
    expect(bubble?.innerHTML).not.toContain('<script');
    expect(bubble?.innerHTML).not.toContain('alert(1)');
  });

  it('quick action confirm gating: start_workflow only calls sendApprovedAction after Confirm, with both fields filled', async () => {
    await build();
    store.open.set(true);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;

    (el.querySelector('[data-testid="quick-action-start"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    const confirmBtn = el.querySelector('[data-testid="confirm-send-start"]') as HTMLButtonElement;
    expect(confirmBtn.disabled).toBe(true);
    expect(store.sendApprovedAction).not.toHaveBeenCalled();

    fixture.componentInstance.actionWorkflowId.set('bug-fix');
    fixture.componentInstance.actionTask.set('investigate the crash');
    fixture.detectChanges();
    await fixture.componentInstance.confirmStartWorkflow();
    expect(store.sendApprovedAction).toHaveBeenCalledWith('Start workflow bug-fix: investigate the crash', {
      tool: 'start_workflow',
      arguments: { workflowId: 'bug-fix', task: 'investigate the crash' },
    });
  });

  it('quick action confirm gating: cancel_run requires a run id and Cancel dismisses without sending', async () => {
    await build();
    store.open.set(true);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;

    (el.querySelector('[data-testid="quick-action-cancel"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    (el.querySelector('[data-testid="confirm-cancel-action"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    expect(el.querySelector('[data-testid="confirm-card-cancel"]')).toBeNull();
    expect(store.sendApprovedAction).not.toHaveBeenCalled();

    (el.querySelector('[data-testid="quick-action-cancel"]') as HTMLButtonElement).click();
    fixture.componentInstance.actionRunId.set('run-1');
    await fixture.componentInstance.confirmCancelRun();
    expect(store.sendApprovedAction).toHaveBeenCalledWith('Cancel run run-1', { tool: 'cancel_run', arguments: { runId: 'run-1' } });
  });

  it('send() clears the draft immediately and restores it when the store rejects the send', async () => {
    await build();
    fixture.componentInstance.draft = 'hello';
    await fixture.componentInstance.send();
    expect(store.send).toHaveBeenCalledWith('hello');
    expect(fixture.componentInstance.draft).toBe('');

    store.send.mockResolvedValueOnce(false);
    fixture.componentInstance.draft = 'still here';
    await fixture.componentInstance.send();
    expect(fixture.componentInstance.draft).toBe('still here');
  });

  it('uses the runtime model picker and exposes a custom-model entry field', async () => {
    await build();
    store.open.set(true);
    fixture.componentInstance.configOpen.set(true);
    store.selectedRuntime.set('claude');
    store.models.set([{ id: 'sonnet', label: 'sonnet' }]);
    fixture.detectChanges();

    fixture.componentInstance.selectModel('sonnet');
    expect(store.setModel).toHaveBeenCalledWith('sonnet');
    fixture.componentInstance.selectModel('__custom__');
    fixture.detectChanges();
    expect(fixture.nativeElement.querySelector('input[placeholder="Enter a model id"]')).not.toBeNull();
  });

  it('onRuntimeChange ignores empty values so a restored selection is not wiped', async () => {
    await build();
    store.selectedRuntime.set('claude');
    fixture.componentInstance.onRuntimeChange('');
    expect(store.setRuntime).not.toHaveBeenCalled();
    fixture.componentInstance.onRuntimeChange('codex');
    expect(store.setRuntime).toHaveBeenCalledWith('codex');
  });

  it('toggleConfig restores a custom model id into the entry field', async () => {
    await build();
    store.open.set(true);
    store.selectedRuntime.set('claude');
    store.selectedModel.set('my-custom-model');
    store.models.set([]);
    fixture.componentInstance.toggleConfig();
    fixture.detectChanges();
    expect(fixture.componentInstance.configOpen()).toBe(true);
    expect(fixture.componentInstance.customModel).toBe('my-custom-model');
    expect(fixture.nativeElement.querySelector('input[placeholder="Enter a model id"]')).not.toBeNull();
  });

  it('onEnter sends on plain Enter and inserts a newline on Shift+Enter', async () => {
    await build();
    fixture.componentInstance.draft = 'hello';
    const plainEnter = { shiftKey: false, preventDefault: vi.fn() } as unknown as Event;
    fixture.componentInstance.onEnter(plainEnter);
    await Promise.resolve();
    expect(store.send).toHaveBeenCalledWith('hello');

    store.send.mockClear();
    const shiftEnter = { shiftKey: true, preventDefault: vi.fn() } as unknown as Event;
    fixture.componentInstance.onEnter(shiftEnter);
    expect(store.send).not.toHaveBeenCalled();
  });

  it('renderedContent falls back to escaped plain text under SSR (no DOMParser)', async () => {
    await TestBed.configureTestingModule({
      imports: [AssistantDockComponent],
      providers: [
        provideRouter([]),
        { provide: AssistantStore, useValue: fakeStore() },
        { provide: CapabilitiesService, useValue: fakeCapabilities() },
        { provide: (await import('@angular/core')).PLATFORM_ID, useValue: 'server' },
      ],
    }).compileComponents();
    const serverFixture = TestBed.createComponent(AssistantDockComponent);
    const html = serverFixture.componentInstance.renderedContent({ role: 'assistant', content: '<script>x</script>' });
    expect(String(html)).toContain('&lt;script&gt;');
  });

  function scheduleProposal(overrides: Partial<AssistantProposalView> = {}): AssistantProposalView {
    return {
      id: 'create_schedule-0',
      tool: 'create_schedule',
      title: 'Create schedule: Weekday drain',
      description: 'Propose a new schedule.',
      arguments: { name: 'Weekday drain', cron: '0 9 * * 1-5', timezone: 'UTC' },
      preview: { valid: true, upcoming: ['2026-09-16T09:00:00.000Z'] },
      ...overrides,
    } as AssistantProposalView;
  }

  it('renders a proposal as a confirm card showing the server-verified fire times', async () => {
    await build();
    store.open.set(true);
    store.proposals.set([scheduleProposal()]);
    fixture.detectChanges();
    const card = fixture.nativeElement.querySelector('[data-testid="proposal-create_schedule"]');
    expect(card).not.toBeNull();
    expect(card.textContent).toContain('Weekday drain');
    expect(card.textContent).toContain('2026-09-16T09:00:00.000Z');
  });

  it('commits a proposal only when Confirm is clicked', async () => {
    await build();
    store.open.set(true);
    const proposal = scheduleProposal();
    store.proposals.set([proposal]);
    fixture.detectChanges();
    expect(store.commitProposal).not.toHaveBeenCalled();

    (fixture.nativeElement.querySelector('[data-testid="proposal-confirm"]') as HTMLButtonElement).click();
    expect(store.commitProposal).toHaveBeenCalledWith(proposal);
  });

  it('refuses to commit a proposal whose server-side preview failed', async () => {
    await build();
    store.open.set(true);
    store.proposals.set([scheduleProposal({ preview: { valid: false, error: 'cron must be five fields' } })]);
    fixture.detectChanges();
    const confirm = fixture.nativeElement.querySelector('[data-testid="proposal-confirm"]') as HTMLButtonElement;
    expect(confirm.disabled).toBe(true);
    expect(fixture.nativeElement.querySelector('[data-testid="proposal-invalid"]').textContent).toContain('cron must be five fields');
  });

  it('refuses to commit a workflow proposal that failed validation', async () => {
    await build();
    store.open.set(true);
    store.proposals.set([
      scheduleProposal({
        id: 'create_workflow-0',
        tool: 'create_workflow',
        title: 'Create workflow demo (project)',
        arguments: { id: 'demo', scope: 'project', model: {} },
        preview: { valid: false, diagnostics: 'workflow requires at least one todo' },
      }),
    ]);
    fixture.detectChanges();
    expect((fixture.nativeElement.querySelector('[data-testid="proposal-confirm"]') as HTMLButtonElement).disabled).toBe(true);
    expect(fixture.nativeElement.querySelector('[data-testid="proposal-invalid"]').textContent).toContain('at least one todo');
  });

  it('dismisses a proposal without committing it', async () => {
    await build();
    store.open.set(true);
    store.proposals.set([scheduleProposal()]);
    fixture.detectChanges();
    (fixture.nativeElement.querySelector('[data-testid="proposal-dismiss"]') as HTMLButtonElement).click();
    expect(store.dismissProposal).toHaveBeenCalledWith('create_schedule-0');
    expect(store.commitProposal).not.toHaveBeenCalled();
  });

  it('marks provenance as degraded with a status dot instead of a badge', async () => {
    await build();
    store.open.set(true);
    store.lastAnsweredBy.set('dashboard (no agent runtime installed)');
    store.lastDegraded.set(true);
    fixture.detectChanges();
    const provenance = fixture.nativeElement.querySelector('[data-testid="assistant-provenance"]') as HTMLElement;
    expect(provenance.querySelector('.provenance-dot.is-degraded')).not.toBeNull();
    expect(fixture.nativeElement.querySelector('[data-testid="assistant-degraded-badge"]')).toBeNull();
  });

  it('keeps provenance quiet when the last reply was not degraded', async () => {
    await build();
    store.open.set(true);
    store.lastAnsweredBy.set('Claude (local agent CLI)');
    store.lastDegraded.set(false);
    fixture.detectChanges();
    const provenance = fixture.nativeElement.querySelector('[data-testid="assistant-provenance"]') as HTMLElement;
    expect(provenance.querySelector('.provenance-dot.is-degraded')).toBeNull();
  });

  it('hides Start workflow / Cancel run chips once a conversation has user messages', async () => {
    await build();
    store.open.set(true);
    fixture.detectChanges();
    expect(fixture.nativeElement.querySelector('[data-testid="assistant-quick-actions"]')).not.toBeNull();

    store.messages.set([{ role: 'user', content: 'hello' }]);
    fixture.detectChanges();
    expect(fixture.nativeElement.querySelector('[data-testid="assistant-quick-actions"]')).toBeNull();
  });

  it('closes the config panel from the Done control', async () => {
    await build();
    store.open.set(true);
    fixture.componentInstance.configOpen.set(true);
    fixture.detectChanges();
    (fixture.nativeElement.querySelector('[data-testid="assistant-config-done"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    expect(fixture.componentInstance.configOpen()).toBe(false);
    expect(fixture.nativeElement.querySelector('[data-testid="assistant-config"]')).toBeNull();
  });
});
