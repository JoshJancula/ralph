import '../../../angular-test-env';
import { provideRouter } from '@angular/router';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { beforeEach, describe, expect, it } from 'vitest';
import { WorkflowRunsComponent } from './workflow-runs.component';
import type { RunListItem } from '../workflow.types';

function run(overrides: Partial<RunListItem>): RunListItem {
  return {
    runId: 'run-1',
    workflowId: 'bug-fix',
    mode: 'dependency',
    entryKind: 'task',
    state: 'running',
    createdAt: '2026-09-14T00:00:00Z',
    graphRunLink: null,
    ...overrides,
  };
}

describe('WorkflowRunsComponent', () => {
  let fixture: ComponentFixture<WorkflowRunsComponent>;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [WorkflowRunsComponent],
      providers: [provideRouter([])],
    }).compileComponents();
    fixture = TestBed.createComponent(WorkflowRunsComponent);
  });

  it('shows an empty-state message when there are no runs', () => {
    fixture.componentRef.setInput('runs', []);
    fixture.detectChanges();
    expect(fixture.nativeElement.querySelector('[data-testid="workflow-runs-empty"]')).not.toBeNull();
  });

  it('shows a loading message while loading with no runs yet', () => {
    fixture.componentRef.setInput('runs', []);
    fixture.componentRef.setInput('loading', true);
    fixture.detectChanges();
    expect(fixture.nativeElement.querySelector('[data-testid="workflow-runs-loading"]')).not.toBeNull();
  });

  it('lists runs and shows a live count badge', () => {
    fixture.componentRef.setInput('runs', [run({ runId: 'run-1', state: 'running' }), run({ runId: 'run-2', state: 'succeeded' })]);
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="workflow-run-run-1"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="workflow-run-run-2"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="workflow-runs-live"]')?.textContent).toContain('1 in progress');
  });

  it('does not show the live badge when every run is terminal', () => {
    fixture.componentRef.setInput('runs', [run({ state: 'succeeded' }), run({ runId: 'run-2', state: 'failed' })]);
    fixture.detectChanges();
    expect(fixture.nativeElement.querySelector('[data-testid="workflow-runs-live"]')).toBeNull();
  });

  it('pillClass maps live/failed/succeeded states to distinct classes', () => {
    const component = fixture.componentInstance;
    expect(component.pillClass('running')).toBe('pill-live');
    expect(component.pillClass('failed')).toBe('pill-failed');
    expect(component.pillClass('succeeded')).toBe('pill-succeeded');
    expect(component.pillClass('unknown-state')).toBe('');
  });
});
