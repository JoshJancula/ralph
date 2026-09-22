import '../../../angular-test-env';
import { TestBed } from '@angular/core/testing';
import { PlanListRowComponent } from './plan-list-row.component';
import { PlanInventoryItem } from '../../services/api.service';

describe('PlanListRowComponent', () => {
  const mockItem: PlanInventoryItem = {
    id: 'plan-1',
    name: 'PLAN1',
    path: 'plans/PLAN1.md',
    projectRoot: '/mock/proj',
    type: 'leaf',
    planName: 'My Plan',
    overview: 'Test plan',
    isProject: false,
    checkboxProgress: { completed: 5, total: 10 },
    currentTodo: { id: 'todo-1', content: 'Do something' },
    lastActivityMs: Date.now() - 60000,
    hasLatestRun: true,
  };

  beforeEach(async () => {
    TestBed.resetTestingModule();
    await TestBed.configureTestingModule({
      imports: [PlanListRowComponent],
    }).compileComponents();
  });

  it('renders plan name and display name', () => {
    const fixture = TestBed.createComponent(PlanListRowComponent);
    fixture.componentInstance.item = mockItem;
    fixture.detectChanges();

    const text = fixture.nativeElement.textContent;
    expect(text).toContain('PLAN1');
    expect(text).toContain('My Plan');
  });

  it('formats status correctly', () => {
    const fixture = TestBed.createComponent(PlanListRowComponent);
    fixture.componentInstance.item = mockItem;
    fixture.detectChanges();

    const comp = fixture.componentInstance;
    expect(comp.getStatusLabel(mockItem)).toBe('active');
  });

  it('formats status as completed when all checkboxes done', () => {
    const fixture = TestBed.createComponent(PlanListRowComponent);
    const completedItem = { ...mockItem, checkboxProgress: { completed: 10, total: 10 } };
    fixture.componentInstance.item = completedItem;
    fixture.detectChanges();

    const comp = fixture.componentInstance;
    expect(comp.getStatusLabel(completedItem)).toBe('completed');
  });

  it('formats status as pending when no latest run', () => {
    const fixture = TestBed.createComponent(PlanListRowComponent);
    const pendingItem = { ...mockItem, hasLatestRun: false };
    fixture.componentInstance.item = pendingItem;
    fixture.detectChanges();

    const comp = fixture.componentInstance;
    expect(comp.getStatusLabel(pendingItem)).toBe('pending');
  });

  it('shows durable run identity and its live process count', () => {
    const fixture = TestBed.createComponent(PlanListRowComponent);
    fixture.componentInstance.item = {
      ...mockItem,
      activeRunId: 'registry-run-1',
      activeRun: { id: 'registry-run-1', ownerPid: 42, ownerAlive: true, liveProcesses: 2, startedAt: '2026-09-16T12:00:00Z' },
    };
    fixture.detectChanges();
    fixture.nativeElement.querySelector('.data-table-expand').click();
    fixture.detectChanges();

    expect(fixture.nativeElement.textContent).toContain('registry-run-1');
    expect(fixture.nativeElement.textContent).toContain('2 live processes');
    expect(fixture.nativeElement.textContent).toContain('Stop');
  });

  it('formats type names correctly', () => {
    const fixture = TestBed.createComponent(PlanListRowComponent);
    const comp = fixture.componentInstance;

    expect(comp.formatType('leaf')).toBe('Leaf');
    expect(comp.formatType('generated-control')).toBe('Generated');
    expect(comp.formatType('supplied')).toBe('Supplied');
    expect(comp.formatType('workflow-derived')).toBe('Workflow');
  });

  it('extracts project name from root path', () => {
    const fixture = TestBed.createComponent(PlanListRowComponent);
    const comp = fixture.componentInstance;

    expect(comp.extractProjectName('/home/user/my-project')).toBe('my-project');
    expect(comp.extractProjectName('/mock/proj')).toBe('proj');
  });

  it('formats last activity time correctly', () => {
    const fixture = TestBed.createComponent(PlanListRowComponent);
    const comp = fixture.componentInstance;

    const now = Date.now();
    expect(comp.formatLastActivity(now - 5000)).toBe('5s ago');
    expect(comp.formatLastActivity(now - 60000)).toBe('1m ago');
    expect(comp.formatLastActivity(now - 3600000)).toBe('1h ago');
    expect(comp.formatLastActivity(now - 86400000)).toBe('1d ago');
  });

  it('emits openPlan event when clicked', () => {
    const fixture = TestBed.createComponent(PlanListRowComponent);
    fixture.componentInstance.item = mockItem;
    fixture.detectChanges();

    const spy = vi.spyOn(fixture.componentInstance.openPlan, 'emit');
    fixture.componentInstance.onOpen();

    expect(spy).toHaveBeenCalledWith(mockItem);
  });

  it('displays checkbox progress', () => {
    const fixture = TestBed.createComponent(PlanListRowComponent);
    fixture.componentInstance.item = mockItem;
    fixture.detectChanges();

    const text = fixture.nativeElement.textContent;
    expect(text).toContain('5/10');
    expect(text).toContain('Do something');
    expect(fixture.nativeElement.querySelector('.progress-fill')).toBeTruthy();
  });

  it('exposes semantic status text alongside the color indicator', () => {
    const fixture = TestBed.createComponent(PlanListRowComponent);
    fixture.componentInstance.item = mockItem;
    fixture.detectChanges();

    const statusLabel = fixture.nativeElement.querySelector('.status-label');
    expect(statusLabel?.textContent?.trim()).toBe('active');
    expect(fixture.nativeElement.querySelector('.status-icon.status-active')).toBeTruthy();
  });

  it('toggles expandable secondary detail for narrow-screen pattern', () => {
    const fixture = TestBed.createComponent(PlanListRowComponent);
    fixture.componentInstance.item = mockItem;
    fixture.detectChanges();

    const expand = fixture.nativeElement.querySelector('.data-table-expand') as HTMLButtonElement;
    expect(expand).toBeTruthy();
    expect(expand.getAttribute('aria-expanded')).toBe('false');

    expand.click();
    fixture.detectChanges();

    expect(fixture.componentInstance.expanded()).toBe(true);
    expect(expand.getAttribute('aria-expanded')).toBe('true');
    const detail = fixture.nativeElement.querySelector('.data-table-detail');
    expect(detail?.textContent).toContain('Type');
    expect(detail?.textContent).toContain('Leaf');
    expect(detail?.textContent).toContain('Project');
  });

  it('hides display name when same as name', () => {
    const fixture = TestBed.createComponent(PlanListRowComponent);
    const item = { ...mockItem, planName: 'PLAN1' };
    fixture.componentInstance.item = item;
    fixture.detectChanges();

    const text = fixture.nativeElement.textContent;
    expect(text).toContain('PLAN1');
    expect(text.match(/PLAN1/g)?.length).toBe(1);
  });
});
