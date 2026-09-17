import '../../../angular-test-env';
import { provideRouter } from '@angular/router';
import { RouterTestingModule } from '@angular/router/testing';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { beforeEach, describe, expect, it } from 'vitest';
import { WorkflowCardComponent } from './workflow-card.component';
import type { WorkflowListItem } from '../workflow.types';

describe('WorkflowCardComponent', () => {
  let fixture: ComponentFixture<WorkflowCardComponent>;
  const workflow: WorkflowListItem = {
    id: 'bug-fix',
    scope: 'project',
    effectiveScope: 'project',
    overview: 'Fix defects',
    editable: true,
    catalog: {
      purpose: 'Fix defects',
      expectedOutcome: 'Independently verified delivery',
      mode: 'dependency',
      stageCount: 6,
      executableStageCount: 4,
      supervisorStageCount: 2,
      requiresSuppliedPlan: false,
      writes: true,
      hasHumanGates: false,
    },
  };

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [WorkflowCardComponent, RouterTestingModule],
      providers: [provideRouter([])],
    }).compileComponents();
    fixture = TestBed.createComponent(WorkflowCardComponent);
    fixture.componentRef.setInput('workflow', workflow);
    fixture.detectChanges();
  });

  it('shows inherit hint for project override of bundled', () => {
    fixture.componentRef.setInput('workflow', {
      ...workflow,
      inheritsFrom: {
        scope: 'bundled',
        explanation: 'Project override of the bundled definition. The bundled original stays read-only.',
      },
      availableScopes: [
        { scope: 'project', overview: 'p' },
        { scope: 'bundled', overview: 'b' },
      ],
    });
    fixture.detectChanges();
    expect(fixture.nativeElement.querySelector('[data-testid="workflow-inherit-hint"]')?.textContent).toContain(
      'bundled original stays read-only',
    );
    expect(fixture.nativeElement.querySelector('[data-testid="workflow-layers-hint"]')).toBeNull();
  });

  it('renders purpose, outcome, source badge, and catalog badges', () => {
    const el: HTMLElement = fixture.nativeElement;
    expect(el.textContent).toContain('bug-fix');
    expect(el.querySelector('[data-testid="workflow-source-badge"]')?.textContent).toContain('project');
    expect(el.querySelector('[data-testid="workflow-purpose"]')?.textContent).toContain('Fix defects');
    expect(el.querySelector('[data-testid="workflow-outcome"]')?.textContent).toContain('Independently verified');
    expect(el.querySelector('[data-testid="workflow-catalog-badges"]')?.textContent).toContain('6 stages');
    expect(el.querySelector('[data-testid="workflow-catalog-badges"]')?.textContent).toContain('Writes');
  });

  it('exposes supplied-plan and human-gates data attributes for catalog queries', () => {
    fixture.componentRef.setInput('workflow', {
      ...workflow,
      id: 'plan-delivery',
      catalog: { ...workflow.catalog!, requiresSuppliedPlan: true },
    });
    fixture.detectChanges();
    expect(fixture.nativeElement.querySelector('[data-requires-plan="true"]')).not.toBeNull();

    fixture.componentRef.setInput('workflow', {
      ...workflow,
      id: 'human-verified-delivery',
      catalog: { ...workflow.catalog!, hasHumanGates: true, requiresSuppliedPlan: false },
    });
    fixture.detectChanges();
    expect(fixture.nativeElement.querySelector('[data-has-human-gates="true"]')).not.toBeNull();
  });

  it('shows a Start button for bundled (non-editable) workflows without implying editability', () => {
    fixture.componentRef.setInput('workflow', {
      ...workflow,
      scope: 'bundled',
      effectiveScope: 'bundled',
      editable: false,
    });
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('[data-testid="run-workflow-now"]')).not.toBeNull();
    expect(el.querySelector('[data-testid="workflow-readonly-badge"]')).not.toBeNull();
  });

  it('emits runNow with the workflow id and does not navigate', () => {
    let emitted: string | null = null;
    fixture.componentInstance.runNow.subscribe((id) => (emitted = id));
    const button = fixture.nativeElement.querySelector('[data-testid="run-workflow-now"]') as HTMLButtonElement;
    button.click();
    expect(emitted).toBe('bug-fix');
  });

  it('disables Start while triggering', () => {
    fixture.componentRef.setInput('triggering', true);
    fixture.detectChanges();
    const button = fixture.nativeElement.querySelector('[data-testid="run-workflow-now"]') as HTMLButtonElement;
    expect(button.disabled).toBe(true);
    expect(button.textContent).toContain('Starting');
  });
});
