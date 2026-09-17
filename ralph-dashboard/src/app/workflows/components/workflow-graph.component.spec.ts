import { ComponentFixture, TestBed } from '@angular/core/testing';
import { beforeEach, describe, expect, it } from 'vitest';
import '../../../angular-test-env';
import { SelectedStageStore } from '../selected-stage.store';
import { WorkflowGraphComponent } from './workflow-graph.component';
import type { WorkflowDisplayGraph } from '../workflow.types';

const GRAPH: WorkflowDisplayGraph = {
  workflowId: 'feature-delivery',
  mode: 'dependency',
  sourceKind: 'bundled',
  sourcePath: '/tmp/feature-delivery.workflow.md',
  maxReworkIterations: 2,
  nodes: [
    {
      id: 'investigate',
      label: 'investigate',
      kind: 'agent',
      stageType: 'agent',
      authored: true,
      derivedFrom: 'stage',
      planRole: null,
      waveIndex: 0,
      loopBackTo: null,
      changesTarget: null,
    },
    {
      id: 'qa-gate',
      label: 'qa-gate',
      kind: 'gate',
      stageType: 'gate',
      authored: true,
      derivedFrom: 'stage',
      planRole: null,
      waveIndex: 1,
      loopBackTo: null,
      changesTarget: null,
    },
  ],
  edges: [{ from: 'investigate', to: 'qa-gate', kind: 'dependency', label: null, scheduleEdge: true }],
  waves: [['investigate'], ['qa-gate']],
};

describe('WorkflowGraphComponent', () => {
  let fixture: ComponentFixture<WorkflowGraphComponent>;
  let store: SelectedStageStore;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [WorkflowGraphComponent],
      providers: [SelectedStageStore],
    }).compileComponents();
    store = TestBed.inject(SelectedStageStore);
    fixture = TestBed.createComponent(WorkflowGraphComponent);
  });

  it('renders nodes and selects a stage into the shared store', () => {
    fixture.componentRef.setInput('graph', GRAPH);
    fixture.componentRef.setInput('error', null);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="workflow-display-graph"]')).not.toBeNull();
    (el.querySelector('[data-node-id="qa-gate"]') as HTMLButtonElement).click();
    fixture.detectChanges();
    expect(store.stageId()).toBe('qa-gate');
    expect(store.workflowId()).toBe('feature-delivery');
    expect(el.querySelector('[data-node-id="qa-gate"]')?.classList.contains('selected')).toBe(true);
  });

  it('renders diagnostics and a source link on error', () => {
    fixture.componentRef.setInput('graph', null);
    fixture.componentRef.setInput('error', {
      code: 'inspect-failed',
      message: 'Could not build a display graph.',
      diagnostics: 'Error at line 9: missing dependsOn',
      sourcePath: '/tmp/bad.workflow.md',
      sourceKind: 'project',
      line: 9,
      column: null,
    });
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="workflow-graph-error"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="workflow-graph-source-link"]')?.getAttribute('href')).toContain(
      '/tmp/bad.workflow.md',
    );
    expect(el.querySelector('[data-testid="workflow-graph-diagnostics"]')?.textContent).toContain('line 9');
  });
});
