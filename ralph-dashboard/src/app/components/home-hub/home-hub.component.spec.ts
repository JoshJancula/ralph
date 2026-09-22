import '../../../angular-test-env';
import { TestBed } from '@angular/core/testing';
import { HttpClientTestingModule } from '@angular/common/http/testing';
import { RouterTestingModule } from '@angular/router/testing';
import { of, NEVER, throwError } from 'rxjs';
import { vi } from 'vitest';
import { HomeHubComponent } from './home-hub.component';
import { WorkflowsApi } from '../../workflows/workflows-api.service';
import { RunListItem } from '../../workflows/workflow.types';
import { WorkspaceSelectorService } from '../../services/workspace-selector.service';
import { ComponentFixture, signal } from '@angular/core';

function mountHomeHub(fixture: ComponentFixture<HomeHubComponent>): void {
  fixture.componentRef.setInput('paneActive', true);
  fixture.detectChanges();
}

describe('HomeHubComponent', () => {
  let listRuns: ReturnType<typeof vi.fn>;

  beforeEach(async () => {
    listRuns = vi.fn().mockReturnValue(of([]));

    TestBed.configureTestingModule({
      imports: [HomeHubComponent, HttpClientTestingModule, RouterTestingModule],
      providers: [
        { provide: WorkflowsApi, useValue: { listRuns } },
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
  });

  it('should create', () => {
    const fixture = TestBed.createComponent(HomeHubComponent);
    expect(fixture.componentInstance).toBeTruthy();
  });

  it('should render empty state when no runs', async () => {
    listRuns.mockReturnValue(of([]));

    const fixture = TestBed.createComponent(HomeHubComponent);
    mountHomeHub(fixture);
    await fixture.whenStable();

    const el: HTMLElement = fixture.nativeElement;
    expect(el.textContent).toContain('Keep every plan, run, and workflow in view.');
    expect(el.textContent).toContain('Recommended');
    const docsCard = el.querySelector<HTMLAnchorElement>('[data-testid="home-docs-card"]');
    expect(docsCard?.getAttribute('href')).toBe('/docs');
    expect(docsCard?.textContent).toContain('Open documentation');
    expect(el.textContent).not.toContain('Browse plans');
    expect(el.textContent).not.toContain('Explore workflows');
    expect(el.querySelector('[data-testid="home-cli-panel"]')).not.toBeNull();
    expect(el.textContent).toContain('Prefer the terminal?');
    expect(el.textContent).toContain('ralph workflow list');
    expect(el.textContent).toContain('ralph plugin install --runtime claude');
    expect(el.textContent).toContain('ralph plugin');
  });

  it('should render continue cards for active runs', async () => {
    const mockRuns: RunListItem[] = [
      {
        runId: 'run-1',
        workflowId: 'workflow-1',
        mode: 'sequential',
        entryKind: 'workflow',
        state: 'active',
        createdAt: new Date(Date.now() - 600000).toISOString(),
        task: 'Stage 1',
        graphRunLink: null,
      },
    ];
    listRuns.mockReturnValue(of(mockRuns));

    const fixture = TestBed.createComponent(HomeHubComponent);
    mountHomeHub(fixture);
    await fixture.whenStable();

    const el: HTMLElement = fixture.nativeElement;
    expect(el.textContent).toContain('workflow-1');
    expect(el.textContent).toContain('Stage 1');
    expect(el.textContent).toContain('Resume run');
  });

  it('should prioritize waiting runs in approval section', async () => {
    const mockRuns: RunListItem[] = [
      {
        runId: 'run-waiting',
        workflowId: 'approval-workflow',
        mode: 'sequential',
        entryKind: 'workflow',
        state: 'waiting',
        createdAt: new Date(Date.now() - 300000).toISOString(),
        task: 'Approval stage',
        graphRunLink: null,
      },
      {
        runId: 'run-active',
        workflowId: 'active-workflow',
        mode: 'sequential',
        entryKind: 'workflow',
        state: 'active',
        createdAt: new Date(Date.now() - 600000).toISOString(),
        task: 'Stage 1',
        graphRunLink: null,
      },
    ];
    listRuns.mockReturnValue(of(mockRuns));

    const fixture = TestBed.createComponent(HomeHubComponent);
    mountHomeHub(fixture);
    await fixture.whenStable();

    const el: HTMLElement = fixture.nativeElement;
    expect(el.textContent).toContain('Needs you');
    expect(el.textContent).toContain('approval-workflow');
    expect(el.textContent).toContain('Respond to approval');
    expect(el.textContent).toContain('Continue');
  });

  it('should show loading state initially', () => {
    listRuns.mockReturnValue(NEVER);
    const fixture = TestBed.createComponent(HomeHubComponent);
    mountHomeHub(fixture);

    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="route-loading-skeleton"]')).not.toBeNull();
  });

  it('should render approval cards with correct action labels', async () => {
    const mockRuns: RunListItem[] = [
      {
        runId: 'run-approval',
        workflowId: 'test-workflow',
        mode: 'sequential',
        entryKind: 'workflow',
        state: 'waiting',
        createdAt: new Date(Date.now() - 900000).toISOString(),
        task: 'Approval stage',
        graphRunLink: null,
      },
    ];
    listRuns.mockReturnValue(of(mockRuns));

    const fixture = TestBed.createComponent(HomeHubComponent);
    mountHomeHub(fixture);
    await fixture.whenStable();

    const el: HTMLElement = fixture.nativeElement;
    expect(el.textContent).toContain('Respond to approval');
  });

  it('should format elapsed time correctly', () => {
    const fixture = TestBed.createComponent(HomeHubComponent);
    const component = fixture.componentInstance;

    expect(component.formatElapsed(30)).toBe('30s');
    expect(component.formatElapsed(120)).toBe('2m');
    expect(component.formatElapsed(3600)).toBe('1h');
    expect(component.formatElapsed(7200)).toBe('2h');
  });

  it('should limit to 10 most recent items', async () => {
    const mockRuns: RunListItem[] = Array.from({ length: 15 }, (_, i) => ({
      runId: `run-${i}`,
      workflowId: `workflow-${i}`,
      mode: 'sequential',
      entryKind: 'workflow',
      state: 'active',
      createdAt: new Date(Date.now() - i * 60000).toISOString(),
      task: `Stage ${i}`,
      graphRunLink: null,
    }));
    listRuns.mockReturnValue(of(mockRuns));

    const fixture = TestBed.createComponent(HomeHubComponent);
    mountHomeHub(fixture);
    await fixture.whenStable();

    expect(fixture.componentInstance.items().length).toBeLessThanOrEqual(10);
  });

  it('does not load data while the pane is inactive', async () => {
    listRuns.mockReturnValue(of([]));
    const fixture = TestBed.createComponent(HomeHubComponent);
    fixture.detectChanges();
    await fixture.whenStable();
    expect(listRuns).not.toHaveBeenCalled();
  });

  it('surfaces API errors when run listing fails', async () => {
    listRuns.mockReturnValue(throwError(() => ({ message: 'network down' })));
    const fixture = TestBed.createComponent(HomeHubComponent);
    mountHomeHub(fixture);
    await fixture.whenStable();
    fixture.detectChanges();
    expect(fixture.componentInstance.error()).toBeTruthy();
    expect(fixture.componentInstance.loading()).toBe(false);
  });

  it('should filter out non-active runs', async () => {
    const mockRuns: RunListItem[] = [
      {
        runId: 'run-completed',
        workflowId: 'completed-workflow',
        mode: 'sequential',
        entryKind: 'workflow',
        state: 'completed',
        createdAt: new Date(Date.now() - 600000).toISOString(),
        task: 'Stage 1',
        graphRunLink: null,
      },
      {
        runId: 'run-active',
        workflowId: 'active-workflow',
        mode: 'sequential',
        entryKind: 'workflow',
        state: 'active',
        createdAt: new Date(Date.now() - 300000).toISOString(),
        task: 'Stage 1',
        graphRunLink: null,
      },
    ];
    listRuns.mockReturnValue(of(mockRuns));

    const fixture = TestBed.createComponent(HomeHubComponent);
    mountHomeHub(fixture);
    await fixture.whenStable();

    const items = fixture.componentInstance.items();
    expect(items.length).toBe(1);
    expect(items[0].project).toBe('active-workflow');
  });
});
