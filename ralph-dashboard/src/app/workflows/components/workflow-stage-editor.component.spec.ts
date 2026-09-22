import '../../../angular-test-env';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { WorkflowStageEditorComponent } from './workflow-stage-editor.component';
import { WorkflowsFacade } from '../workflows.facade';
import type { OrdinaryStageModel, SupervisorStageModel, WorkflowStageModel } from '../workflow.types';

function ordinary(id: string, dependsOn: readonly string[] = []): OrdinaryStageModel {
  return { id, kind: 'ordinary', dependsOn, produces: [], requires: [], unsupportedKeys: [] };
}

function supervisor(id: string, dependsOn: readonly string[] = []): SupervisorStageModel {
  return { id, kind: 'supervisor', type: 'gate', dependsOn, unsupportedKeys: [] };
}

describe('WorkflowStageEditorComponent', () => {
  let fixture: ComponentFixture<WorkflowStageEditorComponent>;
  let lastEmitted: WorkflowStageModel[] | null;

  beforeEach(async () => {
    lastEmitted = null;
    await TestBed.configureTestingModule({
      imports: [WorkflowStageEditorComponent],
      providers: [{ provide: WorkflowsFacade, useValue: { loadModels: vi.fn(async () => []) } }],
    }).compileComponents();
    fixture = TestBed.createComponent(WorkflowStageEditorComponent);
    fixture.componentInstance.stagesChange.subscribe((stages) => (lastEmitted = stages));
  });

  function setStages(stages: readonly WorkflowStageModel[]): void {
    fixture.componentRef.setInput('stagesValue', stages);
    fixture.detectChanges();
  }

  it('add stage appends a new ordinary stage with a unique id', () => {
    setStages([ordinary('a')]);
    (fixture.nativeElement.querySelector('[data-testid="pipeline-add-stage"]') as HTMLButtonElement).click();
    expect(lastEmitted).toHaveLength(2);
    expect(lastEmitted?.[1]?.id).toBe('stage-1');
  });

  it('remove stage drops it and cleans up dependsOn references', () => {
    setStages([ordinary('a'), ordinary('b', ['a'])]);
    fixture.componentInstance.onRemove('a');
    expect(lastEmitted).toHaveLength(1);
    expect((lastEmitted?.[0] as OrdinaryStageModel).dependsOn).toEqual([]);
  });

  it('reorder moves a stage up or down', () => {
    setStages([ordinary('a'), ordinary('b'), ordinary('c')]);
    fixture.componentInstance.onMove(0, 1);
    expect(lastEmitted?.map((s) => s.id)).toEqual(['b', 'a', 'c']);
  });

  it('shows a cycle error banner when dependsOn forms a cycle', () => {
    setStages([ordinary('a', ['b']), ordinary('b', ['a'])]);
    fixture.detectChanges();
    const banner = fixture.nativeElement.querySelector('[data-testid="pipeline-cycle-error"]');
    expect(banner).not.toBeNull();
    expect(banner?.textContent).toContain('Cyclic dependencies');
  });

  it('shows no cycle error for an acyclic graph', () => {
    setStages([ordinary('a'), ordinary('b', ['a'])]);
    expect(fixture.nativeElement.querySelector('[data-testid="pipeline-cycle-error"]')).toBeNull();
  });

  it('toggling a dependency checkbox updates dependsOn and emits', () => {
    setStages([ordinary('a'), ordinary('b')]);
    fixture.componentInstance.toggleExpanded('b', new Event('click'));
    fixture.detectChanges();
    fixture.componentInstance.onToggleDependency('b', 'a', { target: { checked: true } } as unknown as Event);
    expect((lastEmitted?.find((s) => s.id === 'b') as OrdinaryStageModel).dependsOn).toEqual(['a']);
  });

  it('renders supervisor stages read-only: no instructions/runtime controls, dependsOn checkboxes disabled', () => {
    setStages([ordinary('a'), supervisor('gate-1', ['a'])]);
    fixture.componentInstance.toggleExpanded('gate-1', new Event('click'));
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="supervisor-readonly-note"]')).not.toBeNull();
    const stageCards = el.querySelectorAll('[data-testid="pipeline-stage"]');
    const supervisorCard = stageCards[1] as HTMLElement;
    expect(supervisorCard.querySelector('textarea')).toBeNull();
  });

  it('adding and removing produces/requires path rows on an ordinary stage', () => {
    setStages([ordinary('a')]);
    fixture.componentInstance.addPath('a', 'produces');
    expect((lastEmitted?.[0] as OrdinaryStageModel).produces).toHaveLength(1);
    fixture.componentInstance.removePath('a', 'produces', 0);
    expect((lastEmitted?.[0] as OrdinaryStageModel).produces).toHaveLength(0);
  });

  it('toggleExpanded opens then closes a stage card', () => {
    setStages([ordinary('a')]);
    expect(fixture.componentInstance.expanded().has('a')).toBe(false);
    fixture.componentInstance.toggleExpanded('a', new Event('click'));
    expect(fixture.componentInstance.expanded().has('a')).toBe(true);
    fixture.componentInstance.toggleExpanded('a', new Event('click'));
    expect(fixture.componentInstance.expanded().has('a')).toBe(false);
  });

  it('unchecking a dependency checkbox removes it from dependsOn', () => {
    setStages([ordinary('a'), { ...ordinary('b'), dependsOn: ['a'] }]);
    fixture.componentInstance.onToggleDependency('b', 'a', { target: { checked: false } } as unknown as Event);
    expect((lastEmitted?.find((s) => s.id === 'b') as OrdinaryStageModel).dependsOn).toEqual([]);
  });

  it('isValidId delegates to isValidStageId', () => {
    expect(fixture.componentInstance.isValidId('good-id')).toBe(true);
    expect(fixture.componentInstance.isValidId('Bad Id')).toBe(false);
  });

  it('onIdChange renames a stage and rewrites dependsOn references to it', () => {
    setStages([ordinary('a'), ordinary('b', ['a'])]);
    fixture.componentInstance.onIdChange('a', { target: { value: 'renamed' } } as unknown as Event);
    expect(lastEmitted?.[0]?.id).toBe('renamed');
    expect((lastEmitted?.[1] as OrdinaryStageModel).dependsOn).toEqual(['renamed']);
  });

  it('onInstructionsChange, routing, and session strategy update an ordinary stage', () => {
    setStages([ordinary('a')]);
    fixture.componentInstance.onInstructionsChange('a', { target: { value: 'do the thing' } } as unknown as Event);
    expect((lastEmitted?.[0] as OrdinaryStageModel).instructions).toBe('do the thing');

    fixture.componentInstance.onRuntimeChange('a', 'claude');
    expect((lastEmitted?.[0] as OrdinaryStageModel).runtime).toBe('claude');

    fixture.componentInstance.onModelChange('a', 'sonnet');
    expect((lastEmitted?.[0] as OrdinaryStageModel).model).toBe('sonnet');

    fixture.componentInstance.onSessionStrategyChange('a', 'compact');
    expect((lastEmitted?.[0] as OrdinaryStageModel).sessionStrategy).toBe('compact');

    fixture.componentInstance.onRuntimeChange('a', '');
    expect((lastEmitted?.[0] as OrdinaryStageModel).runtime).toBeUndefined();
    expect((lastEmitted?.[0] as OrdinaryStageModel).model).toBeUndefined();

    fixture.componentInstance.onSessionStrategyChange('a', '');
    expect((lastEmitted?.[0] as OrdinaryStageModel).sessionStrategy).toBeUndefined();
  });

  it('onPathChange and onPathRequiredChange edit an existing produces/requires row', () => {
    setStages([{ ...ordinary('a'), produces: [{ path: 'out.md', required: false }] }]);
    fixture.componentInstance.onPathChange('a', 'produces', 0, { target: { value: 'new.md' } } as unknown as Event);
    expect((lastEmitted?.[0] as OrdinaryStageModel).produces[0]?.path).toBe('new.md');

    fixture.componentInstance.onPathRequiredChange('a', 'produces', 0, { target: { checked: true } } as unknown as Event);
    expect((lastEmitted?.[0] as OrdinaryStageModel).produces[0]?.required).toBe(true);
  });

  it('renders produces/requires rows through the template and edits them via DOM events', () => {
    setStages([{ ...ordinary('a'), produces: [{ path: 'out.md', required: true }] }]);
    fixture.componentInstance.toggleExpanded('a', new Event('click'));
    fixture.detectChanges();
    const pathInput = fixture.nativeElement.querySelector('.path-row .control') as HTMLInputElement;
    expect(pathInput.value).toBe('out.md');
    pathInput.value = 'edited.md';
    pathInput.dispatchEvent(new Event('input'));
    expect((lastEmitted?.[0] as OrdinaryStageModel).produces[0]?.path).toBe('edited.md');
  });

  it('model list fallback: an empty model list from the facade does not block rendering', async () => {
    setStages([{ ...ordinary('a'), runtime: 'claude' }]);
    fixture.componentInstance.toggleExpanded('a', new Event('click'));
    fixture.detectChanges();
    await fixture.whenStable();
    fixture.detectChanges();
    // ralph-model-select renders even though the facade returned [] models.
    expect(fixture.nativeElement.querySelector('ralph-model-select')).not.toBeNull();
  });

  it('renders the ordinary-stage session strategy selector', () => {
    setStages([{ ...ordinary('a'), sessionStrategy: 'compact' }]);
    fixture.componentInstance.toggleExpanded('a', new Event('click'));
    fixture.detectChanges();
    const select = fixture.nativeElement.querySelector('[data-testid="stage-session-strategy-select"]') as HTMLSelectElement;
    expect(select).not.toBeNull();
    expect(select.value).toBe('compact');
    expect(Array.from(select.options).map((option) => option.value)).toEqual(['', 'fresh', 'resume', 'reset', 'compact']);
  });

  it('previousStages returns only preceding stages for loopBackTo and changesTarget', () => {
    setStages([ordinary('a'), ordinary('b'), ordinary('c')]);
    expect(fixture.componentInstance.previousStages(0)).toEqual([]);
    expect(fixture.componentInstance.previousStages(1).map((s) => s.id)).toEqual(['a']);
    expect(fixture.componentInstance.previousStages(2).map((s) => s.id)).toEqual(['a', 'b']);
  });

  it('selecting loopBackTo sets target and defaults onExhausted to fail; clearing it clears both', () => {
    setStages([ordinary('a'), ordinary('b')]);
    fixture.componentInstance.onLoopBackToChange('b', 'a');
    expect((lastEmitted?.find((s) => s.id === 'b') as OrdinaryStageModel).loopBackTo).toBe('a');
    expect((lastEmitted?.find((s) => s.id === 'b') as OrdinaryStageModel).onExhausted).toBe('fail');

    // Setting onExhausted to proceed
    fixture.componentInstance.onOnExhaustedChange('b', 'proceed');
    expect((lastEmitted?.find((s) => s.id === 'b') as OrdinaryStageModel).onExhausted).toBe('proceed');

    // Clearing loopBackTo
    fixture.componentInstance.onLoopBackToChange('b', '');
    expect((lastEmitted?.find((s) => s.id === 'b') as OrdinaryStageModel).loopBackTo).toBeUndefined();
    expect((lastEmitted?.find((s) => s.id === 'b') as OrdinaryStageModel).onExhausted).toBeUndefined();
  });

  it('renders loopback dropdown with preceding stages and explicit onExhausted options in DOM', () => {
    setStages([ordinary('a'), { ...ordinary('b'), loopBackTo: 'a', onExhausted: 'fail' }]);
    fixture.componentInstance.toggleExpanded('b', new Event('click'));
    fixture.detectChanges();

    const stageCards = fixture.nativeElement.querySelectorAll('[data-testid="pipeline-stage"]');
    const loopSelect = stageCards[1]?.querySelector('[data-testid="stage-loopback-to-select"]') as HTMLSelectElement;
    expect(loopSelect).not.toBeNull();
    const options = Array.from(loopSelect.options).map((o) => o.value);
    expect(options).toContain('');
    expect(options).toContain('a');
    expect(options).not.toContain('b'); // stage cannot loop to itself

    const onExhaustedSelect = stageCards[1]?.querySelector('[data-testid="stage-on-exhausted-select"]') as HTMLSelectElement;
    expect(onExhaustedSelect).not.toBeNull();
    const exhaustedOptions = Array.from(onExhaustedSelect.options).map((o) => o.value);
    expect(exhaustedOptions).toEqual(['fail', 'proceed']);
  });

  it('availablePlannerStages lists ordinary stages with planner configured', () => {
    const plannerStage: OrdinaryStageModel = {
      ...ordinary('plan-stage'),
      planner: { outputMode: 'plan-file', maxTodos: 50 },
    };
    setStages([plannerStage, ordinary('worker-stage')]);
    expect(fixture.componentInstance.availablePlannerStages('worker-stage').map((s) => s.id)).toEqual(['plan-stage']);
    expect(fixture.componentInstance.availablePlannerStages('plan-stage')).toEqual([]); // cannot planFrom self
  });

  it('gate stage profile select populated from verificationProfiles input', () => {
    fixture.componentRef.setInput('verificationProfiles', [{ name: 'gate-profile-1', steps: [] }]);
    setStages([ordinary('a'), { ...supervisor('gate-1'), type: 'gate', profile: 'gate-profile-1' }]);
    fixture.componentInstance.toggleExpanded('gate-1', new Event('click'));
    fixture.detectChanges();

    const select = fixture.nativeElement.querySelector('[data-testid="supervisor-gate-profile-select"]') as HTMLSelectElement;
    expect(select).not.toBeNull();
    const options = Array.from(select.options).map((o) => o.value);
    expect(options).toContain('gate-profile-1');
  });

  it('approval supervisor stage changesTarget dropdown populates with preceding stages', () => {
    setStages([ordinary('build'), { ...supervisor('approve-gate'), type: 'approval' }]);
    fixture.componentInstance.toggleExpanded('approve-gate', new Event('click'));
    fixture.detectChanges();

    const select = fixture.nativeElement.querySelector('[data-testid="supervisor-changes-target-select"]') as HTMLSelectElement;
    expect(select).not.toBeNull();
    const options = Array.from(select.options).map((o) => o.value);
    expect(options).toContain('');
    expect(options).toContain('build');
  });

  it('shows invalid-id and dangling-dependency error banners', () => {
    setStages([ordinary('Bad Id')]);
    fixture.detectChanges();
    expect(fixture.nativeElement.querySelector('[data-testid="pipeline-invalid-id-error"]')?.textContent).toContain(
      'Invalid or duplicate stage id',
    );

    setStages([ordinary('a', ['missing'])]);
    fixture.detectChanges();
    expect(fixture.nativeElement.querySelector('[data-testid="pipeline-dangling-error"]')?.textContent).toContain(
      'depends on unknown stage',
    );
  });

  it('covers path schema, writeScopes, planner, planFrom, workspace, and git access branches', () => {
    const withScopes: OrdinaryStageModel = {
      ...ordinary('a'),
      produces: [
        { path: 'one.md', required: true },
        { path: 'two.md', required: false },
      ],
      writeScopes: ['src/**'],
    };
    setStages([withScopes]);

    expect(fixture.componentInstance.writeScopesText(withScopes)).toBe('["src/**"]');
    expect(fixture.componentInstance.writeScopesText(ordinary('plain'))).toBe('');

    fixture.componentInstance.onPathSchemaChange('a', 'produces', 0, { target: { value: 'schema.json' } } as unknown as Event);
    expect((lastEmitted?.[0] as OrdinaryStageModel).produces[0]?.schema).toBe('schema.json');
    fixture.componentInstance.onPathSchemaChange('a', 'produces', 1, { target: { value: '' } } as unknown as Event);
    expect((lastEmitted?.[0] as OrdinaryStageModel).produces[1]?.schema).toBeUndefined();

    fixture.componentInstance.onModelChange('a', '');
    expect((lastEmitted?.[0] as OrdinaryStageModel).model).toBeUndefined();

    fixture.componentInstance.onWriteScopesChange('a', { target: { value: '  ' } } as unknown as Event);
    expect((lastEmitted?.[0] as OrdinaryStageModel).writeScopes).toBeUndefined();
    fixture.componentInstance.onWriteScopesChange('a', { target: { value: '["a/**","b/**"]' } } as unknown as Event);
    expect((lastEmitted?.[0] as OrdinaryStageModel).writeScopes).toEqual(['a/**', 'b/**']);
    fixture.componentInstance.onWriteScopesChange('a', { target: { value: '[1,2]' } } as unknown as Event);
    expect((lastEmitted?.[0] as OrdinaryStageModel).writeScopes).toEqual(['[1', '2]']);
    fixture.componentInstance.onWriteScopesChange('a', { target: { value: 'src/**, docs/**' } } as unknown as Event);
    expect((lastEmitted?.[0] as OrdinaryStageModel).writeScopes).toEqual(['src/**', 'docs/**']);

    fixture.componentInstance.onTogglePlanner('a', { target: { checked: true } } as unknown as Event);
    expect((lastEmitted?.[0] as OrdinaryStageModel).planner).toEqual({ outputMode: 'plan-file', maxTodos: 100 });
    fixture.componentInstance.onPlannerMaxTodos('a', { target: { value: '12' } } as unknown as Event);
    expect((lastEmitted?.[0] as OrdinaryStageModel).planner?.maxTodos).toBe(12);
    fixture.componentInstance.onPlannerMaxTodos('a', { target: { value: 'nope' } } as unknown as Event);
    expect((lastEmitted?.[0] as OrdinaryStageModel).planner?.maxTodos).toBeUndefined();
    fixture.componentInstance.onTogglePlanner('a', { target: { checked: false } } as unknown as Event);
    expect((lastEmitted?.[0] as OrdinaryStageModel).planner).toBeUndefined();
    fixture.componentInstance.onPlannerMaxTodos('a', { target: { value: '5' } } as unknown as Event);
    expect((lastEmitted?.[0] as OrdinaryStageModel).planner).toBeUndefined();

    fixture.componentInstance.onPlanFromChange('a', 'planner-stage');
    expect((lastEmitted?.[0] as OrdinaryStageModel).planFrom).toBe('planner-stage');
    fixture.componentInstance.onPlanFromChange('a', { target: { value: '  ' } } as unknown as Event);
    expect((lastEmitted?.[0] as OrdinaryStageModel).planFrom).toBeUndefined();

    fixture.componentInstance.onWorkspaceModeChange('a', 'isolated');
    expect((lastEmitted?.[0] as OrdinaryStageModel).workspaceMode).toBe('isolated');
    fixture.componentInstance.onWorkspaceModeChange('a', '');
    expect((lastEmitted?.[0] as OrdinaryStageModel).workspaceMode).toBeUndefined();

    fixture.componentInstance.onGitAccessChange('a', 'read-write');
    expect((lastEmitted?.[0] as OrdinaryStageModel).agentGitAccess).toBe('read-write');
    fixture.componentInstance.onGitAccessChange('a', '');
    expect((lastEmitted?.[0] as OrdinaryStageModel).agentGitAccess).toBeUndefined();
  });

  it('covers loop-check and event-based loopBackTo / onExhausted branches', () => {
    setStages([ordinary('a'), ordinary('b')]);
    fixture.componentInstance.onLoopBackToChange('b', { target: { value: 'a' } } as unknown as Event);
    expect((lastEmitted?.find((s) => s.id === 'b') as OrdinaryStageModel).loopBackTo).toBe('a');

    fixture.componentInstance.onLoopCheckPathChange('b', { target: { value: 'check.json' } } as unknown as Event);
    expect((lastEmitted?.find((s) => s.id === 'b') as OrdinaryStageModel).loopCheck).toEqual({
      path: 'check.json',
      schema: undefined,
    });
    fixture.componentInstance.onLoopCheckSchemaChange('b', { target: { value: 'schema.json' } } as unknown as Event);
    expect((lastEmitted?.find((s) => s.id === 'b') as OrdinaryStageModel).loopCheck).toEqual({
      path: 'check.json',
      schema: 'schema.json',
    });
    fixture.componentInstance.onLoopCheckSchemaChange('b', { target: { value: '' } } as unknown as Event);
    expect((lastEmitted?.find((s) => s.id === 'b') as OrdinaryStageModel).loopCheck).toEqual({
      path: 'check.json',
      schema: undefined,
    });
    fixture.componentInstance.onLoopCheckPathChange('b', { target: { value: '' } } as unknown as Event);
    expect((lastEmitted?.find((s) => s.id === 'b') as OrdinaryStageModel).loopCheck).toBeUndefined();

    fixture.componentInstance.onLoopCheckSchemaChange('b', { target: { value: 'only-schema.json' } } as unknown as Event);
    expect((lastEmitted?.find((s) => s.id === 'b') as OrdinaryStageModel).loopCheck).toEqual({
      path: '',
      schema: 'only-schema.json',
    });
    fixture.componentInstance.onLoopCheckSchemaChange('b', { target: { value: '' } } as unknown as Event);
    expect((lastEmitted?.find((s) => s.id === 'b') as OrdinaryStageModel).loopCheck).toBeUndefined();

    fixture.componentInstance.onOnExhaustedChange('b', { target: { value: 'proceed' } } as unknown as Event);
    expect((lastEmitted?.find((s) => s.id === 'b') as OrdinaryStageModel).onExhausted).toBe('proceed');
    fixture.componentInstance.onOnExhaustedChange('b', { target: { value: '  ' } } as unknown as Event);
    expect((lastEmitted?.find((s) => s.id === 'b') as OrdinaryStageModel).onExhausted).toBeUndefined();
  });

  it('covers supervisor profile, workspace, question, and changesTarget update branches', () => {
    setStages([ordinary('build'), { ...supervisor('gate-1'), type: 'gate' }, { ...supervisor('approve'), type: 'approval' }]);

    fixture.componentInstance.onSupervisorProfileChange('gate-1', 'strict');
    expect((lastEmitted?.find((s) => s.id === 'gate-1') as SupervisorStageModel).profile).toBe('strict');
    fixture.componentInstance.onSupervisorProfileChange('gate-1', { target: { value: '  ' } } as unknown as Event);
    expect((lastEmitted?.find((s) => s.id === 'gate-1') as SupervisorStageModel).profile).toBeUndefined();

    fixture.componentInstance.onSupervisorWorkspaceModeChange('gate-1', 'isolated');
    expect((lastEmitted?.find((s) => s.id === 'gate-1') as SupervisorStageModel).workspaceMode).toBe('isolated');
    fixture.componentInstance.onSupervisorWorkspaceModeChange('gate-1', '');
    expect((lastEmitted?.find((s) => s.id === 'gate-1') as SupervisorStageModel).workspaceMode).toBeUndefined();

    fixture.componentInstance.onSupervisorQuestionChange('approve', { target: { value: 'Ship it?' } } as unknown as Event);
    expect((lastEmitted?.find((s) => s.id === 'approve') as SupervisorStageModel).question).toBe('Ship it?');
    fixture.componentInstance.onSupervisorQuestionChange('approve', { target: { value: '' } } as unknown as Event);
    expect((lastEmitted?.find((s) => s.id === 'approve') as SupervisorStageModel).question).toBeUndefined();

    fixture.componentInstance.onSupervisorChangesTargetChange('approve', 'build');
    expect((lastEmitted?.find((s) => s.id === 'approve') as SupervisorStageModel).changesTarget).toBe('build');
    fixture.componentInstance.onSupervisorChangesTargetChange('approve', { target: { value: '' } } as unknown as Event);
    expect((lastEmitted?.find((s) => s.id === 'approve') as SupervisorStageModel).changesTarget).toBeUndefined();

    // Ordinary updater no-op path when targeting a supervisor id.
    fixture.componentInstance.onInstructionsChange('gate-1', { target: { value: 'ignored' } } as unknown as Event);
    expect((lastEmitted?.find((s) => s.id === 'gate-1') as SupervisorStageModel).kind).toBe('supervisor');
  });

  it('isAvailablePlanner and availableVerificationProfiles reflect configured inputs', () => {
    const plannerStage: OrdinaryStageModel = {
      ...ordinary('plan-stage'),
      planner: { outputMode: 'plan-file', maxTodos: 10 },
    };
    setStages([plannerStage, ordinary('worker')]);
    expect(fixture.componentInstance.isAvailablePlanner('plan-stage', 'worker')).toBe(true);
    expect(fixture.componentInstance.isAvailablePlanner('missing', 'worker')).toBe(false);

    fixture.componentRef.setInput('verificationProfiles', [{ name: 'p1', steps: [] }, { name: '', steps: [] }]);
    expect(fixture.componentInstance.availableVerificationProfiles()).toEqual(['p1']);
  });
});
