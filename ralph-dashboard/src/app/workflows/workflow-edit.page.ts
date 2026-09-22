import { Component, OnDestroy, OnInit, computed, effect, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { ActivatedRoute, Router } from '@angular/router';
import { combineLatest, map } from 'rxjs';
import { WorkflowsFacade } from './workflows.facade';
import { CapabilitiesService } from './capabilities.service';
import { ConfirmationDialogService } from '../services/confirmation-dialog.service';
import { WorkflowStageEditorComponent } from './components/workflow-stage-editor.component';
import { ModelSelectComponent } from './components/model-select.component';
import { SCOPE_LABEL } from './workflow-scope.helpers';
import type { OrdinaryStageModel, VerificationProfileModel, WorkflowMode, WorkflowScope, WorkflowStageModel, WritableWorkflowScope } from './workflow.types';

const DEFAULT_RUNTIME_OPTIONS = ['cursor', 'claude', 'codex', 'opencode', 'antigravity'] as const;

/**
 * Ported from trade-beacon's workflow-edit-form.component.ts. A bundled
 * workflow offers only Customize (creates the project copy and opens it,
 * same seeding as `ralph workflow edit`); a file with unsupportedKeys opens
 * a raw-frontmatter textarea, still saved through the validated PUT route;
 * otherwise the structured stage editor edits the parsed model directly.
 * See port-design.md "Component decisions" and "Structured-edit subset".
 */
@Component({
  selector: 'ralph-workflow-edit-page',
  standalone: true,
  imports: [FormsModule, WorkflowStageEditorComponent, ModelSelectComponent],
  template: `
    <div class="page" data-testid="workflow-edit-page">
      @if (customizing()) {
        <section class="customize-loading" data-testid="edit-customizing-loader" aria-live="polite">
          <span class="loader-mark" aria-hidden="true"></span>
          <div><p class="eyebrow">Workflow studio</p><h1>Creating your {{ customizeScope() }} copy…</h1><p>Opening the editor now. Ralph is materializing the editable definition in the background.</p></div>
        </section>
      } @else if (!facade.selected()) {
        <h1 class="page-title">Edit workflow</h1>
        @if (facade.error(); as message) {
          <p class="error" data-testid="edit-error">{{ message }}</p>
        } @else {
          <p class="muted">Loading workflow…</p>
        }
      } @else if (facade.selected(); as workflow) {
        @if (facade.error(); as message) {
          <p class="error" data-testid="edit-error">{{ message }}</p>
        }
        <header class="editor-head hub-panel-card">
          <div>
            <p class="eyebrow">Workflow studio</p>
            <h1 data-testid="edit-title">Edit {{ workflow.id }}</h1>
            <p class="subhead">Set the defaults that shape every stage, then refine individual stages below.</p>
          </div>
          <div class="origin-card" data-testid="edit-workflow-origin">
            <span class="origin-label">Definition origin</span>
            <strong>{{ originLabel(workflow) }}</strong>
            @if (workflow.origin?.projectRoot; as projectRoot) {
              <code title="{{ projectRoot }}">{{ projectRoot }}</code>
            } @else if (workflow.origin?.sourcePath; as sourcePath) {
              <code title="{{ sourcePath }}">{{ sourcePath }}</code>
            }
          </div>
        </header>

        @if (workflow.availableScopes && workflow.availableScopes.length > 1) {
          <section class="scope-layers hub-panel-card" data-testid="edit-scope-layers" aria-label="Which definition copy to edit">
            <div class="scope-layers-copy">
              <h3 class="scope-layers-title">Edit definition copy</h3>
              <p class="scope-layers-hint">
                Switch which file you are editing. Runs still use the winning override until you delete a higher-priority copy.
              </p>
            </div>
            <div class="scope-layer-toggle" role="radiogroup" aria-label="Definition copy">
              @for (layer of workflow.availableScopes; track layer.scope) {
                <button
                  type="button"
                  role="radio"
                  class="layer-btn"
                  [class.active]="layer.scope === workflow.scope"
                  [attr.aria-checked]="layer.scope === workflow.scope"
                  [attr.data-testid]="'edit-scope-' + layer.scope"
                  (click)="openScope(workflow.id, layer.scope)"
                >
                  {{ scopeLabel(layer.scope) }}
                </button>
              }
            </div>
          </section>
        }
        @if (workflow.shadowedBy; as shadow) {
          <p class="notice notice-warn" data-testid="edit-shadowed-note">
            Editing the {{ workflow.scope }} layer. Runs use the {{ shadow.scope }} winner until this override is removed.
          </p>
        }

        @if (workflow.scope === 'bundled') {
          <p class="notice" data-testid="edit-bundled-note">
            Bundled workflows are immutable. Project overrides beat global copies, which beat bundled defaults.
          </p>
          <div class="actions">
            <button type="button" class="btn btn-primary" data-testid="edit-customize-global" [disabled]="facade.saving()" (click)="customize(workflow.id, 'global')">
              {{ facade.saving() ? 'Working…' : 'Customize globally' }}
            </button>
            <button
              type="button"
              class="btn btn-secondary"
              data-testid="edit-customize-project"
              [disabled]="facade.saving() || facade.needsProjectSelection()"
              (click)="customize(workflow.id, 'project')"
            >
              {{ facade.saving() ? 'Working…' : 'Customize for this project' }}
            </button>
          </div>
        } @else if (!capabilities.capabilities().workflowWrites) {
          <p class="notice" data-testid="edit-writes-disabled">
            The server is not bound to a loopback host, so workflow writes are disabled.
          </p>
        } @else {
          @if (conflict()) {
            <div class="notice notice-warn" data-testid="edit-conflict">
              <p>The file changed since it was loaded.</p>
              <div class="actions">
                <button type="button" class="btn btn-secondary" data-testid="edit-conflict-reload" (click)="reload(workflow.id)">Reload</button>
                <button type="button" class="btn btn-danger" data-testid="edit-conflict-overwrite" (click)="save(workflow.id, true)">Overwrite anyway</button>
              </div>
            </div>
          }
          <p class="editor-guide">
            Define shared defaults first, then use the stage cards for the individual runtime, model, dependency, and artifact settings.
          </p>
        }

        @if (workflow.scope !== 'bundled' && capabilities.capabilities().workflowWrites && workflow.model && !conflict()) {
          <section class="hub-panel-card" data-testid="edit-workflow-defaults">
            <div class="section-head">
              <h3 class="section-legend">Workflow defaults</h3>
              <p class="section-hint">Shared identity, runtime defaults, and publication settings.</p>
            </div>
          <label class="field">
            <span>Name</span>
            <input class="control" type="text" data-testid="edit-name" [(ngModel)]="name" name="name" (ngModelChange)="markDirty()" />
          </label>
          <label class="field">
            <span>Overview</span>
            <textarea class="control" rows="2" data-testid="edit-overview" [(ngModel)]="overview" name="overview" (ngModelChange)="markDirty()"></textarea>
          </label>
          <label class="field">
            <span>Mode</span>
            <select class="control" data-testid="edit-mode" [(ngModel)]="mode" name="mode" (ngModelChange)="markDirty()">
              <option value="dependency">Dependency</option>
              <option value="sequential">Sequential</option>
            </select>
          </label>
          <div class="row">
            <label class="field">
              <span>Default runtime</span>
              <select class="control" data-testid="edit-defaults-runtime" [(ngModel)]="defaultsRuntime" name="defaultsRuntime" (ngModelChange)="markDirty()">
                <option value="">inherit</option>
                @for (runtime of runtimeOptions(); track runtime) {
                  <option [value]="runtime">{{ runtime }}</option>
                }
              </select>
            </label>
            @if (defaultsRuntime()) {
              <ralph-model-select [runtime]="defaultsRuntime()" [model]="defaultsModel()" (modelChange)="onDefaultsModelChange($event)" />
            } @else {
              <label class="field">
                <span>Default model</span>
                <select class="control" data-testid="edit-defaults-model-inherit" disabled>
                  <option value="">inherit</option>
                </select>
              </label>
            }
          </div>

          <div class="row">
            <label class="field">
              <span>Max parallel</span>
              <input class="control" type="number" min="1" data-testid="edit-max-parallel" [(ngModel)]="maxParallel" name="maxParallel" (ngModelChange)="markDirty()" />
            </label>
            <label class="field">
              <span>Max rework iterations</span>
              <input class="control" type="number" min="1" max="5" data-testid="edit-max-rework" [(ngModel)]="maxReworkIterations" name="maxReworkIterations" (ngModelChange)="markDirty()" />
            </label>
          </div>

          <label class="field">
            <span>Publish mode</span>
            <select class="control" data-testid="edit-publish-mode" [(ngModel)]="publishMode" name="publishMode" (ngModelChange)="markDirty()">
              <option value="">unset</option>
              <option value="manual">manual</option>
              <option value="on-verified">on-verified</option>
            </select>
            <span class="help">Dependency workflows use manual or on-verified publication.</span>
          </label>

          <fieldset class="field" data-testid="edit-plan-input">
            <legend>planInput (supplied plan)</legend>
            <span class="help">When set, 'ralph workflow start' accepts a '--plan &lt;path&gt;' argument to supply tasks to the designated consumer stage.</span>
            <label class="field">
              <span>Consumer stage</span>
              <select
                class="control"
                data-testid="edit-plan-input-stage"
                [(ngModel)]="planInputStage"
                name="planInputStage"
                (ngModelChange)="markDirty()"
              >
                <option value="">None (workflow generates or manages its own plan)</option>
                @for (stage of ordinaryStages(); track stage.id) {
                  <option [value]="stage.id">{{ stage.id }}</option>
                }
                @if (planInputStage() && !hasOrdinaryStage(planInputStage())) {
                  <option [value]="planInputStage()">{{ planInputStage() }} (custom)</option>
                }
              </select>
              <span class="help">The stage that consumes the external leaf plan provided via --plan.</span>
            </label>
            <label class="checkbox-row">
              <input type="checkbox" [(ngModel)]="planInputRequired" name="planInputRequired" (ngModelChange)="markDirty()" />
              <span>Required (reject task-only start without --plan)</span>
            </label>
          </fieldset>

          </section>

          <fieldset class="field hub-panel-card" data-testid="edit-verification-profiles">
            <legend>verificationProfiles (gate checks)</legend>
            <span class="help">Model-free automated test commands executed by gate stages. Gate stages reference a profile by name.</span>

            @if (verificationProfiles().length === 0) {
              <div class="empty-profiles-box">
                <p>No verification profiles configured. Gate stages require a verification profile to run checks.</p>
              </div>
            }

            @for (profile of verificationProfiles(); track $index; let pi = $index) {
              <details class="verification-profile" data-testid="edit-verification-profile-card" [open]="pi === 0">
                <summary class="verification-profile-summary">
                  <span class="profile-badge">Profile {{ pi + 1 }}</span>
                  <strong class="profile-title">{{ profile.name || 'Untitled Profile' }}</strong>
                  <span class="steps-count steps-count-inline">Steps ({{ profile.steps.length }})</span>
                </summary>
                <div class="verification-profile-body">
                  <div class="profile-toolbar">
                    <button type="button" class="btn btn-danger-ghost btn-sm" (click)="removeVerificationProfile(pi)">
                      Remove profile
                    </button>
                  </div>

                  <label class="field">
                    <span>Profile name</span>
                    <input
                      class="control"
                      type="text"
                      placeholder="e.g. release-verdict"
                      [ngModel]="profile.name"
                      [ngModelOptions]="{ standalone: true }"
                      (ngModelChange)="onProfileName(pi, $event)"
                    />
                    <span class="help">Identifier referenced by gate stages (e.g. profile: {{ profile.name || 'release-verdict' }}). Must be unique.</span>
                  </label>

                  <div class="steps-container">
                    <div class="steps-header">
                      <span class="steps-count">Steps ({{ profile.steps.length }})</span>
                      <button type="button" class="btn btn-secondary btn-sm" (click)="addVerificationStep(pi)">
                        + Add step
                      </button>
                    </div>

                    @for (step of profile.steps; track $index; let si = $index) {
                      <details class="verification-step" [open]="profile.steps.length === 1">
                        <summary class="verification-step-summary">
                          <span class="step-number">Step {{ si + 1 }}</span>
                          <span class="step-summary-name">{{ step.name || 'Untitled step' }}</span>
                        </summary>
                        <div class="verification-step-body">
                          @if (profile.steps.length > 1) {
                            <div class="step-toolbar">
                              <button
                                type="button"
                                class="btn btn-danger-ghost btn-xs"
                                title="Remove step"
                                (click)="removeVerificationStep(pi, si)"
                              >
                                Remove step
                              </button>
                            </div>
                          }

                          <div class="step-grid">
                            <label class="field">
                              <span>Step name</span>
                              <input
                                class="control"
                                type="text"
                                placeholder="e.g. release-approved"
                                [ngModel]="step.name"
                                [ngModelOptions]="{ standalone: true }"
                                (ngModelChange)="onStepField(pi, si, 'name', $event)"
                              />
                            </label>
                            <label class="field">
                              <span>Timeout (seconds)</span>
                              <div class="input-unit-wrapper">
                                <input
                                  class="control"
                                  type="number"
                                  min="1"
                                  max="3600"
                                  placeholder="120"
                                  [ngModel]="step.timeout ?? 120"
                                  [ngModelOptions]="{ standalone: true }"
                                  (ngModelChange)="onStepTimeout(pi, si, $event)"
                                />
                                <span class="unit-tag">sec</span>
                              </div>
                              <span class="help">Wall-clock execution limit in seconds. Default: 120s.</span>
                            </label>
                          </div>

                          <label class="field">
                            <span>Command</span>
                            <input
                              class="control code-font"
                              type="text"
                              placeholder="e.g. python3 .ralph/python/evaluator_contract.py require-approved --artifact .ralph-workspace/artifacts/{{'{{'}}ARTIFACT_NS{{'}}'}}/release-verdict.json"
                              [ngModel]="step.command"
                              [ngModelOptions]="{ standalone: true }"
                              (ngModelChange)="onStepField(pi, si, 'command', $event)"
                            />
                            <span class="help">Workspace shell command. Non-zero exit fails the gate. Tokens {{'{{'}}ARTIFACT_NS{{'}}'}} and {{'{{'}}STAGE_ID{{'}}'}} are resolved at runtime.</span>
                          </label>
                        </div>
                      </details>
                    }
                  </div>
                </div>
              </details>
            }
            <div class="profile-actions">
              <button type="button" class="btn btn-secondary" data-testid="edit-add-verification-profile" (click)="addVerificationProfile()">
                + Add verification profile
              </button>
            </div>
          </fieldset>

          <section class="hub-panel-card" data-testid="edit-stage-editor-panel">
            <div class="section-head">
              <h3 class="section-legend">Stages</h3>
              <p class="section-hint">Runtime, dependencies, artifacts, and supervisor nodes for this workflow.</p>
            </div>
            <ralph-workflow-stage-editor [stagesValue]="stages()" [verificationProfiles]="verificationProfiles()" (stagesChange)="onStagesChange($event)" />
          </section>

          @if (invalidDiagnostics(); as diagnostics) {
            <p class="error" data-testid="edit-invalid-diagnostics">{{ diagnostics }}</p>
          }

          <div class="actions">
            <button type="button" class="btn btn-primary" data-testid="edit-save" [disabled]="facade.saving()" (click)="save(workflow.id, false)">
              {{ facade.saving() ? 'Saving…' : 'Save changes' }}
            </button>
          </div>
        } @else if (workflow.scope !== 'bundled' && capabilities.capabilities().workflowWrites && !conflict()) {
          <p class="notice" data-testid="edit-raw-mode-note">
            This file uses frontmatter keys outside the structured-edit subset — edit the raw text below.
          </p>
          <textarea class="control raw-editor" rows="24" data-testid="edit-raw-textarea" [(ngModel)]="rawText" name="rawText" (ngModelChange)="markDirty()"></textarea>

          @if (invalidDiagnostics(); as diagnostics) {
            <p class="error" data-testid="edit-invalid-diagnostics">{{ diagnostics }}</p>
          }

          <div class="actions">
            <button type="button" class="btn btn-primary" data-testid="edit-save-raw" [disabled]="facade.saving()" (click)="saveRaw(workflow.id, false)">
              {{ facade.saving() ? 'Saving…' : 'Save changes' }}
            </button>
          </div>
        }
      }
    </div>
  `,
  styles: `
    :host {
      display: flex;
      flex: 1;
      min-height: 0;
    }
    .page {
      display: flex;
      flex-direction: column;
      gap: 1.1rem;
      max-width: 76rem;
      flex: 1;
      min-height: 0;
      padding: 1.5rem 1.75rem calc(3rem + var(--fab-clearance));
    }
    .editor-head {
      display: flex;
      align-items: flex-start;
      justify-content: space-between;
      gap: 1.5rem;
      background: linear-gradient(
        135deg,
        color-mix(in srgb, var(--ion-color-step-50, #0d1117) 88%, var(--accent) 12%),
        var(--ion-color-step-50, #0d1117)
      );
    }
    .customize-loading {
      display: flex;
      align-items: center;
      gap: var(--space-4);
      min-height: 15rem;
      padding: var(--space-6);
      border: 1px solid color-mix(in srgb, var(--accent) 35%, var(--border));
      border-radius: var(--radius-xl);
      background: linear-gradient(135deg, color-mix(in srgb, var(--accent) 10%, var(--surface)), var(--surface) 60%);
    }
    .customize-loading h1 { margin: 0; color: var(--text-primary); font-size: clamp(1.35rem, 2vw, 1.8rem); }
    .customize-loading p:last-child { max-width: 34rem; margin: 0.45rem 0 0; color: var(--text-muted); line-height: 1.5; }
    .loader-mark {
      width: 2.5rem;
      height: 2.5rem;
      flex: 0 0 auto;
      border: 3px solid color-mix(in srgb, var(--accent) 24%, transparent);
      border-top-color: var(--accent);
      border-radius: 50%;
      animation: workflow-loader-spin 0.8s linear infinite;
    }
    @keyframes workflow-loader-spin { to { transform: rotate(360deg); } }
    .eyebrow {
      margin: 0 0 0.3rem;
      color: var(--accent-active);
      font-size: 0.72rem;
      font-weight: 700;
      letter-spacing: 0.08em;
      text-transform: uppercase;
    }
    h1 {
      margin: 0;
      color: var(--text-primary);
      font-size: clamp(1.4rem, 2vw, 1.9rem);
      letter-spacing: -0.025em;
    }
    .subhead {
      max-width: 42rem;
      margin: 0.35rem 0 0;
      color: var(--text-muted);
      font-size: 0.9rem;
      line-height: 1.45;
    }
    .editor-guide {
      margin: 0;
      padding: 0.8rem 0.9rem;
      border-left: 3px solid var(--accent);
      border-radius: 0 var(--radius-md) var(--radius-md) 0;
      background: color-mix(in srgb, var(--accent) 7%, var(--surface));
      color: var(--text-muted);
      font-size: 0.85rem;
      line-height: 1.45;
    }
    .origin-card {
      display: grid;
      gap: 0.2rem;
      min-width: min(100%, 20rem);
      padding: 0.7rem 0.8rem;
      border: 1px solid color-mix(in srgb, var(--accent) 38%, var(--border));
      border-radius: 9px;
      background: color-mix(in srgb, var(--surface) 90%, var(--accent) 10%);
    }
    .origin-label {
      color: var(--text-muted);
      font-size: 0.7rem;
      font-weight: 700;
      letter-spacing: 0.06em;
      text-transform: uppercase;
    }
    .origin-card strong { color: var(--text-primary); font-size: 0.86rem; }
    .origin-card code {
      overflow: hidden;
      color: var(--text-muted);
      font-family: var(--monospace-font);
      font-size: 0.72rem;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .field {
      display: flex;
      flex-direction: column;
      gap: 0.4rem;
      font-size: 0.78rem;
      font-weight: 650;
      letter-spacing: 0.01em;
      color: var(--text-muted);
    }
    .help {
      font-size: 0.72rem;
      color: var(--text-muted);
    }
    .checkbox-row {
      display: flex;
      align-items: center;
      gap: 0.35rem;
      font-size: 0.8rem;
    }
    .verification-profile {
      display: flex;
      flex-direction: column;
      border-top: 1px solid var(--border);
      padding-top: 0.65rem;
    }
    .verification-profile:first-of-type {
      border-top: 0;
      padding-top: 0;
    }
    .verification-profile-summary {
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      gap: 0.5rem 0.75rem;
      cursor: pointer;
      list-style: none;
      padding: 0.35rem 0;
      font-size: 0.95rem;
    }
    .verification-profile-summary::-webkit-details-marker {
      display: none;
    }
    .verification-profile-summary::before {
      content: '';
      width: 0.45rem;
      height: 0.45rem;
      border-right: 2px solid var(--text-muted);
      border-bottom: 2px solid var(--text-muted);
      transform: rotate(-45deg);
      transition: transform 0.15s ease;
      flex-shrink: 0;
    }
    .verification-profile[open] > .verification-profile-summary::before {
      transform: rotate(45deg);
    }
    .steps-count-inline {
      margin-left: auto;
      font-size: 0.72rem;
    }
    .verification-profile-body {
      display: flex;
      flex-direction: column;
      gap: 0.85rem;
      padding: 0.65rem 0 0.85rem;
    }
    .profile-toolbar,
    .step-toolbar {
      display: flex;
      justify-content: flex-end;
    }
    .profile-badge-row {
      display: flex;
      align-items: center;
      gap: 0.6rem;
    }
    .profile-badge {
      font-size: 0.7rem;
      font-weight: 700;
      text-transform: uppercase;
      letter-spacing: 0.05em;
      color: var(--accent);
      background: color-mix(in srgb, var(--accent) 12%, transparent);
      border: 1px solid color-mix(in srgb, var(--accent) 30%, transparent);
      padding: 0.15rem 0.5rem;
      border-radius: 999px;
    }
    .profile-title {
      font-size: 0.95rem;
      color: var(--text-primary);
    }
    .steps-container {
      display: flex;
      flex-direction: column;
      gap: 0.5rem;
      margin-top: 0.25rem;
      padding-top: 0.75rem;
      border-top: 1px solid color-mix(in srgb, var(--border) 60%, transparent);
    }
    .steps-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
    }
    .steps-count {
      font-size: 0.75rem;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.04em;
      color: var(--text-muted);
    }
    .verification-step {
      border-bottom: 1px solid var(--border);
    }
    .verification-step:last-child {
      border-bottom: 0;
    }
    .verification-step-summary {
      display: flex;
      align-items: center;
      gap: 0.5rem;
      cursor: pointer;
      list-style: none;
      padding: 0.5rem 0;
    }
    .verification-step-summary::-webkit-details-marker {
      display: none;
    }
    .verification-step-summary::before {
      content: '';
      width: 0.4rem;
      height: 0.4rem;
      border-right: 2px solid var(--text-muted);
      border-bottom: 2px solid var(--text-muted);
      transform: rotate(-45deg);
      transition: transform 0.15s ease;
      flex-shrink: 0;
    }
    .verification-step[open] > .verification-step-summary::before {
      transform: rotate(45deg);
    }
    .step-summary-name {
      font-size: 0.82rem;
      color: var(--text-primary);
      font-weight: 600;
    }
    .verification-step-body {
      display: flex;
      flex-direction: column;
      gap: 0.65rem;
      padding: 0 0 0.75rem;
    }
    .step-number {
      font-size: 0.75rem;
      font-weight: 600;
      color: var(--text-muted);
    }
    .step-grid {
      display: grid;
      grid-template-columns: minmax(0, 1.4fr) minmax(0, 1fr);
      gap: 0.85rem;
    }
    @media (max-width: 680px) {
      .step-grid {
        grid-template-columns: 1fr;
      }
    }
    .input-unit-wrapper {
      position: relative;
      display: flex;
      align-items: center;
    }
    .input-unit-wrapper .control {
      padding-right: 3rem;
    }
    .unit-tag {
      position: absolute;
      right: 0.75rem;
      font-size: 0.75rem;
      font-weight: 600;
      color: var(--text-muted);
      pointer-events: none;
      user-select: none;
    }
    .code-font {
      font-family: var(--monospace-font);
      font-size: 0.82rem;
    }
    .btn-danger-ghost {
      color: var(--danger);
      background: transparent;
      border: 1px solid transparent;
      border-radius: var(--radius-md);
      cursor: pointer;
      font: inherit;
      transition: all 0.15s ease;
    }
    .btn-danger-ghost:hover {
      background: color-mix(in srgb, var(--danger) 12%, transparent);
      border-color: color-mix(in srgb, var(--danger) 40%, transparent);
    }
    .btn-sm {
      min-height: 32px;
      padding: 0.25rem 0.65rem;
      font-size: 0.78rem;
    }
    .btn-xs {
      min-height: 24px;
      padding: 0.15rem 0.45rem;
      font-size: 0.72rem;
    }
    .profile-actions {
      display: flex;
      margin-top: 0.5rem;
    }
    .empty-profiles-box {
      padding: 1.5rem;
      text-align: center;
      border: 1px dashed var(--border);
      border-radius: var(--radius-md);
      color: var(--text-muted);
      font-size: 0.85rem;
    }
    .row {
      display: flex;
      gap: 1rem;
    }
    .row .field {
      flex: 1;
    }
    textarea.control {
      min-height: auto;
      line-height: 1.45;
    }
    .raw-editor {
      font-family: var(--monospace-font);
      font-size: 0.8rem;
    }
    .muted {
      color: var(--text-muted);
    }
    .error {
      color: var(--danger);
      font-size: 0.8rem;
    }
    .notice {
      color: var(--text-muted);
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 10px;
      padding: 0.8rem 0.9rem;
    }
    .notice-warn {
      color: var(--danger);
      border-color: var(--danger);
    }
    .scope-layers {
      display: grid;
      gap: 0.5rem;
    }
    .scope-layers-copy {
      display: grid;
      gap: 0.25rem;
    }
    .scope-layers-title {
      margin: 0;
      font-size: 0.85rem;
      font-weight: 600;
      color: var(--text-primary);
    }
    .scope-layers-hint {
      margin: 0;
      max-width: 42rem;
      color: var(--text-muted);
      font-size: 0.75rem;
      line-height: 1.45;
    }
    .scope-layer-toggle {
      display: inline-flex;
      flex-wrap: wrap;
      gap: 0.2rem;
      width: fit-content;
      max-width: 100%;
      padding: 0.2rem;
      border: 1px solid var(--border);
      border-radius: 8px;
      background: color-mix(in srgb, var(--background) 70%, var(--surface));
    }
    .layer-btn {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      min-height: var(--touch-target-min, 44px);
      padding: 0.35rem 0.85rem;
      border: 0;
      border-radius: 6px;
      background: transparent;
      color: var(--text-muted);
      cursor: pointer;
      font-size: 0.8rem;
      font-weight: 600;
    }
    .layer-btn:hover:not(.active) {
      color: var(--text-primary);
      background: var(--surface-hover);
    }
    .layer-btn.active {
      background: var(--accent);
      color: var(--button-text);
    }
    .actions {
      display: flex;
      gap: 0.5rem;
      justify-content: flex-end;
    }
    @media (max-width: 991px) {
      .page { padding: 1rem; }
      .editor-head, .row { flex-direction: column; }
      .origin-card { width: 100%; min-width: 0; }
      .actions { justify-content: stretch; flex-wrap: wrap; }
      .actions .btn { flex: 1 1 auto; min-height: var(--touch-target-min, 44px); }
      .customize-loading { align-items: flex-start; padding: var(--space-4); }
    }
  `,
})
export class WorkflowEditPageComponent implements OnInit, OnDestroy {
  readonly facade = inject(WorkflowsFacade);
  readonly capabilities = inject(CapabilitiesService);
  private readonly confirmationDialog = inject(ConfirmationDialogService);
  private readonly route = inject(ActivatedRoute);
  private readonly router = inject(Router);

  readonly name = signal('');
  readonly customizing = signal(false);
  readonly customizeScope = signal<WritableWorkflowScope>('global');
  readonly overview = signal('');
  readonly mode = signal<WorkflowMode>('dependency');
  readonly maxParallel = signal(1);
  readonly maxReworkIterations = signal(1);
  readonly publishMode = signal('');
  readonly planInputStage = signal('');
  readonly planInputRequired = signal(false);
  readonly verificationProfiles = signal<VerificationProfileModel[]>([]);
  readonly stages = signal<WorkflowStageModel[]>([]);
  readonly ordinaryStages = computed(() =>
    this.stages().filter((s): s is OrdinaryStageModel => s.kind === 'ordinary'),
  );
  readonly defaultsRuntime = signal('');
  readonly defaultsModel = signal('');
  readonly rawText = signal('');
  readonly conflict = signal(false);
  readonly invalidDiagnostics = signal<string | null>(null);

  private workflowId = '';

  constructor() {
    effect(() => {
      if (!this.customizing()) return;
      const selected = this.facade.selected();
      const target = this.customizeScope();
      if (selected?.scope === target && !this.facade.saving()) {
        this.customizing.set(false);
      } else if (!this.facade.saving() && this.facade.error()) {
        this.customizing.set(false);
      }
    });
    effect(() => {
      const workflow = this.facade.selected();
      if (!workflow) {
        return;
      }
      this.conflict.set(false);
      this.rawText.set(workflow.raw);
      if (workflow.model) {
        this.name.set(workflow.model.name ?? '');
        this.overview.set(workflow.model.overview ?? '');
        this.mode.set((workflow.model.mode as WorkflowMode) ?? 'dependency');
        this.maxParallel.set(workflow.model.maxParallel ?? 1);
        this.maxReworkIterations.set(workflow.model.maxReworkIterations ?? 1);
        this.publishMode.set(workflow.model.publishMode ?? '');
        this.planInputStage.set(workflow.model.planInput?.stage ?? '');
        this.planInputRequired.set(workflow.model.planInput?.required ?? false);
        this.verificationProfiles.set([...(workflow.model.verificationProfiles ?? [])]);
        this.defaultsRuntime.set(workflow.model.defaultsRuntime ?? '');
        this.defaultsModel.set(workflow.model.defaultsModel ?? '');
        this.stages.set([...workflow.model.stages]);
      }
    });
  }

  runtimeOptions(): readonly string[] {
    const installed = this.facade.runtimes().filter((entry) => entry.installed).map((entry) => entry.id);
    return [...new Set<string>([...DEFAULT_RUNTIME_OPTIONS, ...installed])];
  }

  scopeLabel(scope: WorkflowScope): string {
    return SCOPE_LABEL[scope];
  }

  originLabel(workflow: { scope: WorkflowScope; origin?: { projectRoot: string | null } }): string {
    if (workflow.origin?.projectRoot) {
      return 'Project override';
    }
    return workflow.scope === 'global' ? 'Global Ralph definition' : 'Bundled framework definition';
  }

  ngOnInit(): void {
    this.capabilities.load();
    combineLatest([this.route.paramMap, this.route.queryParamMap])
      .pipe(map(([params, query]) => ({ id: params.get('id'), scope: query.get('scope') as WorkflowScope | null, customizing: query.get('customizing') === '1' })))
      .subscribe(({ id, scope, customizing }) => {
        if (id) {
          this.workflowId = id;
          this.customizing.set(customizing);
          if (scope === 'project' || scope === 'global') this.customizeScope.set(scope);
          void this.facade.openDetail(id, scope ?? undefined);
        }
      });
  }

  ngOnDestroy(): void {
    this.facade.markEditDirty(false);
    this.facade.stopRunsPolling();
  }

  markDirty(): void {
    this.facade.markEditDirty(true);
    this.conflict.set(false);
  }

  onStagesChange(stages: WorkflowStageModel[]): void {
    this.stages.set(stages);
    this.markDirty();
  }

  onDefaultsModelChange(model: string): void {
    this.defaultsModel.set(model);
    this.markDirty();
  }

  addVerificationProfile(): void {
    this.verificationProfiles.set([
      ...this.verificationProfiles(),
      { name: 'new-profile', steps: [{ name: 'step', command: '', timeout: 120 }] },
    ]);
    this.markDirty();
  }

  removeVerificationProfile(index: number): void {
    this.verificationProfiles.set(this.verificationProfiles().filter((_, i) => i !== index));
    this.markDirty();
  }

  hasOrdinaryStage(id: string): boolean {
    return this.ordinaryStages().some((s) => s.id === id);
  }

  addVerificationStep(profileIndex: number): void {
    this.verificationProfiles.set(
      this.verificationProfiles().map((profile, i) =>
        i === profileIndex
          ? { ...profile, steps: [...profile.steps, { name: 'step', command: '', timeout: 120 }] }
          : profile,
      ),
    );
    this.markDirty();
  }

  removeVerificationStep(profileIndex: number, stepIndex: number): void {
    this.verificationProfiles.set(
      this.verificationProfiles().map((profile, i) =>
        i === profileIndex
          ? {
              ...profile,
              steps: profile.steps.filter((_, si) => si !== stepIndex),
            }
          : profile,
      ),
    );
    this.markDirty();
  }

  onProfileName(index: number, name: string): void {
    this.verificationProfiles.set(
      this.verificationProfiles().map((profile, i) => (i === index ? { ...profile, name } : profile)),
    );
    this.markDirty();
  }

  onStepField(profileIndex: number, stepIndex: number, field: 'name' | 'command', value: string): void {
    this.verificationProfiles.set(
      this.verificationProfiles().map((profile, i) =>
        i === profileIndex
          ? {
              ...profile,
              steps: profile.steps.map((step, si) => (si === stepIndex ? { ...step, [field]: value } : step)),
            }
          : profile,
      ),
    );
    this.markDirty();
  }

  onStepTimeout(profileIndex: number, stepIndex: number, value: number): void {
    this.verificationProfiles.set(
      this.verificationProfiles().map((profile, i) =>
        i === profileIndex
          ? {
              ...profile,
              steps: profile.steps.map((step, si) =>
                si === stepIndex ? { ...step, timeout: Number(value) || undefined } : step,
              ),
            }
          : profile,
      ),
    );
    this.markDirty();
  }

  async openScope(id: string, scope: WorkflowScope): Promise<void> {
    if (this.facade.editDirty() && !(await this.confirmationDialog.confirm({
      header: 'Discard unsaved changes?',
      message: 'Your edits will be lost if you switch workflow layers.',
      confirmText: 'Discard',
    }))) {
      return;
    }
    // The route subscription is the single detail-load authority. Calling the
    // facade here as well used to launch the same expensive workflow request twice.
    await this.router.navigate(['/workflows', id, 'edit'], { queryParams: { scope } });
  }

  async customize(id: string, targetScope: WritableWorkflowScope): Promise<void> {
    // Do not navigate into a route-level fake loading state while a mutation is
    // still in flight. The current editor remains stable until the copy exists.
    const copy = await this.facade.customize(id, { targetScope, sourceScope: 'bundled' });
    if (copy) {
      await this.router.navigate(['/workflows', id, 'edit'], { queryParams: { scope: copy.scope, customizing: '1' } });
    }
  }

  async reload(id: string): Promise<void> {
    this.conflict.set(false);
    await this.facade.openDetail(id);
  }

  async save(id: string, overwrite: boolean): Promise<void> {
    const workflow = this.facade.selected();
    if (!workflow) {
      return;
    }
    this.invalidDiagnostics.set(null);
    const sha256 = overwrite ? '' : workflow.sha256;
    const scope = this.facade.writableScope(workflow);
    const result = await this.facade.update(
      id,
      {
        sha256: overwrite ? await this.currentSha256(id) : sha256,
        model: {
          ...workflow.model!,
          name: this.name() || undefined,
          overview: this.overview() || undefined,
          mode: this.mode(),
          defaultsRuntime: this.defaultsRuntime() || undefined,
          defaultsModel: this.defaultsModel() || undefined,
          maxParallel: this.maxParallel(),
          maxReworkIterations: this.maxReworkIterations(),
          publishMode: this.publishMode() || undefined,
          planInput: this.planInputStage()
            ? { stage: this.planInputStage(), required: this.planInputRequired() }
            : undefined,
          verificationProfiles: this.verificationProfiles().length > 0 ? this.verificationProfiles() : undefined,
          stages: this.stages(),
        },
      },
      scope,
    );
    this.handleSaveResult(result);
  }

  async saveRaw(id: string, overwrite: boolean): Promise<void> {
    const workflow = this.facade.selected();
    if (!workflow) {
      return;
    }
    this.invalidDiagnostics.set(null);
    const sha256 = overwrite ? await this.currentSha256(id) : workflow.sha256;
    const result = await this.facade.update(id, { sha256, raw: this.rawText() }, this.facade.writableScope(workflow));
    this.handleSaveResult(result);
  }

  private async currentSha256(id: string): Promise<string> {
    const scope = this.facade.selectedScope() ?? undefined;
    await this.facade.openDetail(id, scope);
    return this.facade.selected()?.sha256 ?? '';
  }

  private handleSaveResult(result: 'ok' | 'conflict' | 'invalid'): void {
    if (result === 'ok') {
      this.facade.markEditDirty(false);
      void this.router.navigate(['/workflows', this.workflowId]);
      return;
    }
    if (result === 'conflict') {
      this.conflict.set(true);
      return;
    }
    this.invalidDiagnostics.set(this.facade.error());
  }

}
