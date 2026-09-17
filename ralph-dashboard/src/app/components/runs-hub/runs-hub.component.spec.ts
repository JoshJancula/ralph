import '../../../angular-test-env';
import { TestBed, ComponentFixture } from '@angular/core/testing';
import { HttpClientTestingModule } from '@angular/common/http/testing';
import { FormsModule } from '@angular/forms';
import { RouterTestingModule } from '@angular/router/testing';
import { signal } from '@angular/core';
import { RunsHubComponent } from './runs-hub.component';
import { WorkflowsApi } from '../../workflows/workflows-api.service';
import { RunListItem } from '../../workflows/workflow.types';
import { WorkspaceSelectorService } from '../../services/workspace-selector.service';
import { of, throwError, NEVER } from 'rxjs';
import { vi } from 'vitest';

describe('RunsHubComponent', () => {
  let fixture: ComponentFixture<RunsHubComponent>;
  let component: RunsHubComponent;
  let api: WorkflowsApi;

  const mockRuns: RunListItem[] = [
    {
      runId: 'run-20260910T015232Z-0-PzuPyc',
      workflowId: 'test-workflow',
      mode: 'sequential',
      entryKind: 'workflow',
      state: 'running',
      createdAt: '2026-09-10T01:52:32Z',
      task: 'stage-1',
      sourceKind: 'claude',
      graphRunLink: null,
    },
    {
      runId: 'run-20260910T001232Z-0-AbCdEf',
      workflowId: 'test-workflow',
      mode: 'sequential',
      entryKind: 'workflow',
      state: 'waiting',
      createdAt: '2026-09-10T00:12:32Z',
      task: 'approval-gate',
      sourceKind: 'claude',
      graphRunLink: null,
    },
    {
      runId: 'run-20260909T235232Z-0-XyZaBc',
      workflowId: 'test-workflow',
      mode: 'sequential',
      entryKind: 'workflow',
      state: 'failed',
      createdAt: '2026-09-09T23:52:32Z',
      sourceKind: 'claude',
      graphRunLink: null,
    },
    {
      runId: 'run-20260909T215232Z-0-DefGhi',
      workflowId: 'other-workflow',
      mode: 'sequential',
      entryKind: 'workflow',
      state: 'succeeded',
      createdAt: '2026-09-09T21:52:32Z',
      sourceKind: 'cursor',
      graphRunLink: null,
    },
  ];

  beforeEach(async () => {
    TestBed.configureTestingModule({
      imports: [RunsHubComponent, HttpClientTestingModule, FormsModule, RouterTestingModule],
      providers: [
        WorkflowsApi,
        {
          provide: WorkspaceSelectorService,
          useValue: {
            selectedWorkspacePath: signal<string | null>(null),
            workspaces: signal([]),
            hasLoadedOnce: signal(true),
          },
        },
      ],
    });

    fixture = TestBed.createComponent(RunsHubComponent);
    component = fixture.componentInstance;
    fixture.componentRef.setInput('paneActive', true);
    api = TestBed.inject(WorkflowsApi);
  });

  it('should create', () => {
    expect(component).toBeTruthy();
  });

  it('should render title', () => {
    vi.spyOn(api, 'listAllRuns').mockReturnValue(of([]));
    fixture.detectChanges();

    const el: HTMLElement = fixture.nativeElement;
    expect(el.textContent).toContain('Runs');
  });

  it('should display empty state when no runs', () => {
    vi.spyOn(api, 'listAllRuns').mockReturnValue(of([]));
    fixture.detectChanges();

    const el: HTMLElement = fixture.nativeElement;
    expect(el.textContent).toContain('No runs found');
    expect(el.textContent).toContain('Open workflows');
  });

  it('should display loading state initially', () => {
    vi.spyOn(api, 'listAllRuns').mockReturnValue(NEVER);
    fixture.detectChanges();

    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="route-loading-skeleton"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="runs-loading"]')?.textContent).toContain('Loading workflow runs');
  });

  it('should display runs after loading', () => {
    vi.spyOn(api, 'listAllRuns').mockReturnValue(of(mockRuns));
    fixture.detectChanges();

    const el: HTMLElement = fixture.nativeElement;
    expect(el.textContent).toContain('run-20260910T015232Z-0-PzuPyc');
    expect(el.textContent).toContain('test-workflow');
  });

  it('should handle API errors gracefully', () => {
    vi.spyOn(api, 'listAllRuns').mockReturnValue(throwError(() => new Error('Failed')));
    fixture.detectChanges();

    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="route-error"]')).toBeTruthy();
  });

  describe('Status filtering', () => {
    beforeEach(() => {
      vi.spyOn(api, 'listAllRuns').mockReturnValue(of(mockRuns));
    });

    it('should show all runs by default', () => {
      component.runs.set(mockRuns);
      expect(component.visibleRuns().length).toBe(4);
    });

    it('should filter by active status', () => {
      component.runs.set(mockRuns);
      component.queryState.set({ status: 'active', task: '', sort: 'createdAt', sortOrder: 'desc' });
      const visible = component.visibleRuns();
      expect(visible.length).toBe(1);
      expect(visible[0].state).toBe('running');
    });

    it('should filter by waiting status', () => {
      component.runs.set(mockRuns);
      component.queryState.set({ status: 'waiting', task: '', sort: 'createdAt', sortOrder: 'desc' });
      const visible = component.visibleRuns();
      expect(visible.length).toBe(1);
      expect(visible[0].state).toBe('waiting');
    });

    it('should filter by failed status', () => {
      component.runs.set(mockRuns);
      component.queryState.set({ status: 'failed', task: '', sort: 'createdAt', sortOrder: 'desc' });
      const visible = component.visibleRuns();
      expect(visible.length).toBe(1);
      expect(visible[0].state).toBe('failed');
    });

    it('should filter by completed status', () => {
      component.runs.set(mockRuns);
      component.queryState.set({ status: 'completed', task: '', sort: 'createdAt', sortOrder: 'desc' });
      const visible = component.visibleRuns();
      expect(visible.length).toBe(1);
      expect(visible[0].state).toBe('succeeded');
    });
  });

  describe('Task search', () => {
    beforeEach(() => {
      vi.spyOn(api, 'listAllRuns').mockReturnValue(of(mockRuns));
      component.runs.set(mockRuns);
    });

    it('matches runs on task substring', () => {
      component.queryState.set({ status: '', task: 'stage', sort: 'createdAt', sortOrder: 'desc' });
      const visible = component.visibleRuns();
      expect(visible.length).toBe(1);
      expect(visible[0].task).toBe('stage-1');
    });

    it('ignores case and surrounding whitespace', () => {
      component.queryState.set({ status: '', task: '  APPROVAL  ', sort: 'createdAt', sortOrder: 'desc' });
      const visible = component.visibleRuns();
      expect(visible.length).toBe(1);
      expect(visible[0].task).toBe('approval-gate');
    });

    it('falls back to matching the run id', () => {
      component.queryState.set({ status: '', task: 'XyZaBc', sort: 'createdAt', sortOrder: 'desc' });
      const visible = component.visibleRuns();
      expect(visible.length).toBe(1);
      expect(visible[0].runId).toBe('run-20260909T235232Z-0-XyZaBc');
    });

    it('does not throw for runs with no task recorded', () => {
      component.queryState.set({ status: '', task: 'stage', sort: 'createdAt', sortOrder: 'desc' });
      expect(() => component.visibleRuns()).not.toThrow();
    });

    it('combines with the status filter', () => {
      component.queryState.set({ status: 'waiting', task: 'stage', sort: 'createdAt', sortOrder: 'desc' });
      expect(component.visibleRuns().length).toBe(0);
    });

    it('reports active filters for the clear control', () => {
      component.queryState.set({ status: '', task: 'stage', sort: 'createdAt', sortOrder: 'desc' });
      expect(component.hasActiveFilters()).toBe(true);
      component.clearFilters();
      expect(component.queryState().task).toBe('');
      expect(component.hasActiveFilters()).toBe(false);
    });
  });

  describe('Sorting', () => {
    beforeEach(() => {
      vi.spyOn(api, 'listAllRuns').mockReturnValue(of(mockRuns));
      component.runs.set(mockRuns);
    });

    it('should sort by creation date descending by default', () => {
      const visible = component.visibleRuns();
      expect(visible[0].runId).toBe('run-20260910T015232Z-0-PzuPyc');
      expect(visible[visible.length - 1].runId).toBe('run-20260909T215232Z-0-DefGhi');
    });

    it('should sort by creation date ascending', () => {
      component.queryState.set({ status: '', task: '', sort: 'createdAt', sortOrder: 'asc' });
      const visible = component.visibleRuns();
      expect(visible[0].runId).toBe('run-20260909T215232Z-0-DefGhi');
      expect(visible[visible.length - 1].runId).toBe('run-20260910T015232Z-0-PzuPyc');
    });

    it('should sort by state', () => {
      component.queryState.set({ status: '', task: '', sort: 'state', sortOrder: 'asc' });
      const visible = component.visibleRuns();
      expect(visible[0].state).toBe('failed');
      expect(visible[1].state).toBe('running');
    });
  });

  describe('State mapping', () => {
    it('should identify active states correctly', () => {
      expect(component.isActive('running')).toBe(true);
      expect(component.isActive('queued')).toBe(true);
      expect(component.isActive('waiting')).toBe(false);
      expect(component.isActive('failed')).toBe(false);
    });

    it('should identify waiting states correctly', () => {
      expect(component.isWaiting('waiting')).toBe(true);
      expect(component.isWaiting('running')).toBe(false);
    });

    it('should identify failed states correctly', () => {
      expect(component.isFailed('failed')).toBe(true);
      expect(component.isFailed('stale')).toBe(true);
      expect(component.isFailed('cancelled')).toBe(true);
      expect(component.isFailed('running')).toBe(false);
    });
  });

  describe('Elapsed formatting', () => {
    it('formats elapsed seconds from createdAt', () => {
      expect(component.formatElapsed(30)).toBe('30s');
      expect(component.formatElapsed(120)).toBe('2m');
      expect(component.formatElapsed(3600)).toBe('1h');
      expect(component.formatElapsed(undefined)).toBe('-');
    });
  });

  describe('Navigation', () => {
    it('should generate correct run detail link', () => {
      const run = mockRuns[0];
      expect(component.getRunDetailLink(run)).toBe('/workflows/runs/run-20260910T015232Z-0-PzuPyc');
    });
  });
});
