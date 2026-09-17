import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { HttpErrorResponse } from '@angular/common/http';
import { FormsModule } from '@angular/forms';
import { firstValueFrom } from 'rxjs';
import { CapabilitiesService } from '../workflows/capabilities.service';
import { WorkspaceSelectorService } from '../services/workspace-selector.service';
import { RouteLoadStateComponent } from '../components/route-load-state/route-load-state.component';
import { SafetyApi } from './safety-api.service';
import type {
  SafetyCheckResult,
  SafetyConfig,
  SafetyCustomRule,
  SafetyDeniedArgumentPattern,
  SafetyStatus,
  UpdateSafetyConfigCommand,
} from './safety.types';

/** One-click samples from the shipped bundle custom_rules (and a benign allow). */
const SAMPLE_COMMANDS: readonly { readonly label: string; readonly command: string }[] = [
  { label: 'sudo ls', command: 'sudo ls' },
  { label: 'rm -rf /', command: 'rm -rf /' },
  { label: 'git push --force', command: 'git push --force' },
  { label: 'echo ok', command: 'echo ok' },
];

const STRING_LIST_FIELDS = [
  { key: 'banned_paths', label: 'Protected paths', description: 'Glob patterns for files and folders Ralph must not access.', testId: 'banned-paths' },
  { key: 'banned_tools', label: 'Blocked tools', description: 'Tool names or glob patterns to stop before they run.', testId: 'banned-tools' },
  { key: 'tool_denylist', label: 'Blocked MCP and native tools', description: 'Exact tool names denied across Ralph MCP and runtime hooks.', testId: 'tool-denylist' },
  { key: 'allowed_tools', label: 'Allowed tools', description: 'Narrow exceptions to a blocked tool rule.', testId: 'allowed-tools' },
  { key: 'allowed_paths', label: 'Allowed paths', description: 'Narrow exceptions to a protected path rule.', testId: 'allowed-paths' },
  { key: 'allowed_commands', label: 'Allowed commands', description: 'Command substring exceptions. Prefer a precise custom rule where possible.', testId: 'allowed-commands' },
  { key: 'allowed_patterns', label: 'Allowed command patterns', description: 'Regular-expression command exceptions. Test these carefully.', testId: 'allowed-patterns' },
] as const;

type StringListKey = (typeof STRING_LIST_FIELDS)[number]['key'];

const DENIED_MODES = ['regex', 'literal', 'substring', 'contains'] as const;

interface EditableCustomRule {
  name: string;
  kind: 'match' | 'pattern';
  value: string;
  target: string;
}

interface EditableDeniedPattern {
  tool: string;
  argument: string;
  pattern: string;
  mode: string;
}

const EDIT_HINT = 'ralph safety edit --project';

interface SafetyProfile {
  readonly id: string;
  readonly title: string;
  readonly description: string;
  readonly paths?: readonly string[];
  readonly rules?: readonly EditableCustomRule[];
}

/** Additive profiles: they never remove a project-specific rule. */
const SAFETY_PROFILES: readonly SafetyProfile[] = [
  {
    id: 'recommended',
    title: 'Recommended baseline',
    description: 'Protects common secret locations and blocks elevated privileges, root deletion, and force pushes.',
    paths: ['.env*', '**/.env*', '**/secrets/**', '~/.ssh/**', '~/.aws/**'],
    rules: [
      { name: 'no_sudo', kind: 'pattern', value: '^sudo\\s', target: 'command' },
      { name: 'no_rm_rf_root', kind: 'match', value: 'rm -rf /', target: 'command' },
      { name: 'no_force_push', kind: 'match', value: 'git push --force', target: 'command' },
    ],
  },
  {
    id: 'credentials',
    title: 'Credential files',
    description: 'Adds private keys and credential directories to the protected-path list.',
    paths: ['**/*.pem', '**/*.key', '**/credentials/**'],
  },
  {
    id: 'git-guardrails',
    title: 'Git guardrails',
    description: 'Adds protection against destructive resets and repository-wide clean operations.',
    rules: [
      { name: 'no_hard_reset', kind: 'match', value: 'git reset --hard', target: 'command' },
      { name: 'no_git_clean_force', kind: 'match', value: 'git clean -fd', target: 'command' },
    ],
  },
];

/** Project killswitch rules editor. enabled / dry_run stay terminal-only. */
@Component({
  selector: 'ralph-safety-page',
  standalone: true,
  imports: [FormsModule, RouteLoadStateComponent],
  template: `
    <div class="page hub-page" data-testid="safety-page">
      <div class="head page-header">
        <div class="head-text">
          <h1 class="page-title">Safety</h1>
          <p class="lede page-lede">
            Protect this project from unsafe agent actions. Choose a starting profile, tune the rules, then test before saving.
          </p>
        </div>
        @if (capabilities.capabilities().safetyWrites) {
          <button
            type="button"
            class="btn btn-primary"
            data-testid="safety-save"
            [disabled]="saving() || loading() || !loaded()"
            (click)="save()"
          >
            {{ saving() ? 'Saving…' : 'Save rules' }}
          </button>
        }
      </div>

      <ralph-route-load-state
        [loading]="loading() && !loaded()"
        [error]="loadError()"
        [columns]="1"
        [rowCount]="4"
        (retry)="reload()"
      />

      @if (conflict()) {
        <div class="notice notice-warn" data-testid="safety-conflict">
          <p>The file changed since it was loaded. Reload before saving.</p>
          <button type="button" class="btn btn-secondary" data-testid="safety-conflict-reload" (click)="reload()">
            Reload
          </button>
        </div>
      }

      @if (invalidDiagnostics(); as diagnostics) {
        <pre class="diagnostics" data-testid="safety-invalid-diagnostics">{{ diagnostics }}</pre>
      }

      @if ((!loading() || loaded()) && !loadError() && status(); as st) {
        <section class="status-banner" data-testid="safety-status-banner" [attr.data-mode]="enforcementMode()">
          <div class="status-mode" data-testid="safety-status-mode">{{ enforcementLabel() }}</div>
          <p class="status-meta" data-testid="safety-status-source">
            Source: <strong>{{ st.source }}</strong>
            @if (st.path) {
              <span class="status-path" data-testid="safety-status-path">{{ st.path }}</span>
            }
          </p>
        </section>

        @if (!configExists()) {
          <div class="notice notice-info" data-testid="safety-create-project-cta">
            <p>
              No project killswitch file yet. Shipped bundle defaults are in force.
              Saving creates <code>state-root/killswitch.json</code>
              @if (configPath()) {
                <span data-testid="safety-create-project-path"> ({{ configPath() }})</span>
              }
              .
            </p>
          </div>
        }

        <section class="profile-panel hub-panel-card" data-testid="safety-profiles">
          <div>
            <h2 class="section-title">Start with a protection profile</h2>
            <p class="hint">Profiles add rules to your draft; they do not remove your existing rules or save automatically.</p>
          </div>
          <div class="profile-grid">
            @for (profile of safetyProfiles; track profile.id) {
              <article class="profile-card hub-choice-card" [class.profile-applied]="lastAppliedProfile() === profile.id" [class.selected]="lastAppliedProfile() === profile.id">
                <h3>{{ profile.title }}</h3>
                <p>{{ profile.description }}</p>
                <button
                  type="button"
                  class="btn btn-secondary"
                  [attr.data-testid]="'safety-profile-' + profile.id"
                  [disabled]="!canEdit()"
                  (click)="applyProfile(profile)"
                >
                  {{ lastAppliedProfile() === profile.id ? 'Applied to draft' : 'Add to draft' }}
                </button>
              </article>
            }
          </div>
          @if (hasUnsavedChanges()) {
            <p class="draft-notice" data-testid="safety-unsaved-changes">You have unsaved rule changes. Save rules to apply them to future runs.</p>
          }
        </section>

        @if (overrideSourceActive()) {
          <div class="notice notice-warn" data-testid="safety-override-banner">
            <p>
              An override source is active. Edits to the project config will not take effect
              while the override is active.
            </p>
          </div>
        }

        @if (activeEnvironmentOverrides().length > 0) {
          <section class="notice notice-info env-overrides" data-testid="safety-env-overrides">
            <h2 class="section-title">Environment overrides (read-only)</h2>
            <p class="hint">
              These variables add rules on top of the file. The project config cannot remove them.
            </p>
            <ul class="env-list" data-testid="safety-env-overrides-list">
              @for (entry of activeEnvironmentOverrides(); track entry.name) {
                <li class="env-item" [attr.data-testid]="'safety-env-' + entry.name">
                  <code class="env-name">{{ entry.name }}</code>
                  <span class="env-value">{{ entry.value }}</span>
                </li>
              }
            </ul>
          </section>
        }

        <section class="lock-panel hub-panel-card" data-testid="safety-lock-panel">
          <h2 class="section-title">Enforcement (read-only)</h2>
          <div class="row">
            <label class="field">
              <span>enabled</span>
              <input
                class="control"
                type="text"
                data-testid="safety-enabled"
                [value]="configEnabled() ? 'true' : 'false'"
                readonly
              />
            </label>
            <label class="field">
              <span>dry_run</span>
              <input
                class="control"
                type="text"
                data-testid="safety-dry-run"
                [value]="configDryRun() ? 'true' : 'false'"
                readonly
              />
            </label>
          </div>
          <p class="hint" data-testid="safety-edit-hint">
            To change these, run
            <code data-testid="safety-edit-hint-command">{{ editHint }}</code>
            in a terminal.
          </p>
        </section>

        <section class="check-panel hub-panel-card" data-testid="safety-check-panel">
          <h2 class="section-title">Test a command</h2>
          <p class="hint" data-testid="safety-check-copy">
            Paste command text to classify it against the effective killswitch config. The text is never executed.
          </p>
          <div class="sample-row" data-testid="safety-check-samples">
            @for (sample of sampleCommands; track sample.command) {
              <button
                type="button"
                class="btn btn-secondary sample-btn"
                [attr.data-testid]="'safety-check-sample-' + sample.label"
                (click)="useSampleCommand(sample.command)"
              >
                {{ sample.label }}
              </button>
            }
          </div>
          <label class="field grow">
            <span class="visually-hidden">Command text</span>
            <textarea
              class="control check-input"
              rows="3"
              data-testid="safety-check-input"
              [ngModel]="checkCommandText()"
              (ngModelChange)="checkCommandText.set($event)"
              placeholder="e.g. sudo ls"
            ></textarea>
          </label>
          <div class="check-actions">
            <button
              type="button"
              class="btn btn-primary"
              data-testid="safety-check-submit"
              [disabled]="checking() || !checkCommandText().trim()"
              (click)="runCheck()"
            >
              {{ checking() ? 'Checking…' : 'Classify' }}
            </button>
          </div>
          @if (checkError(); as err) {
            <p class="notice" data-testid="safety-check-error">{{ err }}</p>
          }
          @if (checkResult(); as result) {
            <div
              class="check-result"
              data-testid="safety-check-result"
              [attr.data-outcome]="result.outcome"
            >
              <div class="check-outcome" data-testid="safety-check-outcome">
                {{ result.outcome }}
              </div>
              <p class="check-meta" data-testid="safety-check-result-source">
                Source: <strong>{{ result.source }}</strong>
              </p>
              @if (result.matchedRule) {
                <p class="check-meta" data-testid="safety-check-matched-rule">
                  Matched rule: <strong>{{ result.matchedRule }}</strong>
                </p>
              }
            </div>
          }
        </section>

        <section class="rules-panel hub-panel-card" data-testid="safety-rules-panel">
          <div>
            <h2 class="section-title">Block risky access</h2>
            <p class="hint">Use paths for files and folders, tools for integrations, and command rules for terminal text.</p>
          </div>
          @for (field of blockingFields; track field.key) {
            <div class="chip-editor hub-nested-panel" [attr.data-testid]="'safety-chips-' + field.testId">
              <div class="chip-head">
                <div><h3>{{ field.label }}</h3><p>{{ field.description }}</p></div>
              </div>
              <ul class="chip-list" [attr.data-testid]="'safety-chip-list-' + field.testId">
                @for (item of stringLists()[field.key]; track $index) {
                  <li class="chip">
                    <span class="chip-text">{{ item }}</span>
                    <button
                      type="button"
                      class="chip-remove"
                      [attr.data-testid]="'safety-chip-remove-' + field.testId"
                      [disabled]="!canEdit()"
                      (click)="removeChip(field.key, $index)"
                    >
                      Remove
                    </button>
                  </li>
                }
              </ul>
              <div class="chip-add">
                <input
                  class="control"
                  type="text"
                  [attr.data-testid]="'safety-chip-input-' + field.testId"
                  [ngModel]="chipDrafts()[field.key]"
                  (ngModelChange)="setChipDraft(field.key, $event)"
                  [disabled]="!canEdit()"
                  [placeholder]="'Add ' + field.label.toLowerCase()"
                  (keydown.enter)="$event.preventDefault(); addChip(field.key)"
                />
                <button
                  type="button"
                  class="btn btn-secondary"
                  [attr.data-testid]="'safety-chip-add-' + field.testId"
                  [disabled]="!canEdit() || !chipDrafts()[field.key].trim()"
                  (click)="addChip(field.key)"
                >
                  Add
                </button>
              </div>
            </div>
          }

          <div class="row-editor hub-nested-panel" data-testid="safety-custom-rules">
            <div class="chip-head">
              <div><h3>Blocked commands</h3><p>Use a plain match for a phrase or a pattern for a regular expression.</p></div>
              <button
                type="button"
                class="btn btn-secondary"
                data-testid="safety-custom-rule-add"
                [disabled]="!canEdit()"
                (click)="addCustomRule()"
              >
                Add rule
              </button>
            </div>
            @for (rule of customRules(); track $index) {
              <div class="rule-row" [attr.data-testid]="'safety-custom-rule-' + $index">
                <label class="field">
                  <span>Name</span>
                  <input
                    class="control"
                    type="text"
                    [attr.data-testid]="'safety-custom-rule-name-' + $index"
                    [ngModel]="rule.name"
                    (ngModelChange)="updateCustomRule($index, 'name', $event)"
                    [disabled]="!canEdit()"
                  />
                </label>
                <label class="field">
                  <span>Kind</span>
                  <select
                    class="control"
                    [attr.data-testid]="'safety-custom-rule-kind-' + $index"
                    [ngModel]="rule.kind"
                    (ngModelChange)="updateCustomRule($index, 'kind', $event)"
                    [disabled]="!canEdit()"
                  >
                    <option value="match">match</option>
                    <option value="pattern">pattern</option>
                  </select>
                </label>
                <label class="field grow">
                  <span>{{ rule.kind }}</span>
                  <input
                    class="control"
                    type="text"
                    [attr.data-testid]="'safety-custom-rule-value-' + $index"
                    [ngModel]="rule.value"
                    (ngModelChange)="updateCustomRule($index, 'value', $event)"
                    [disabled]="!canEdit()"
                  />
                </label>
                <button
                  type="button"
                  class="btn btn-secondary"
                  [attr.data-testid]="'safety-custom-rule-remove-' + $index"
                  [disabled]="!canEdit()"
                  (click)="removeCustomRule($index)"
                >
                  Remove
                </button>
              </div>
            }
          </div>

          <div class="row-editor hub-nested-panel" data-testid="safety-denied-args">
            <div class="chip-head">
              <div><h3>Blocked arguments</h3><p>Stop a tool when a particular argument contains a sensitive or unsafe value.</p></div>
              <button
                type="button"
                class="btn btn-secondary"
                data-testid="safety-denied-add"
                [disabled]="!canEdit()"
                (click)="addDeniedPattern()"
              >
                Add pattern
              </button>
            </div>
            @for (row of deniedPatterns(); track $index) {
              <div class="rule-row" [attr.data-testid]="'safety-denied-' + $index">
                <label class="field">
                  <span>Tool (optional)</span>
                  <input
                    class="control"
                    type="text"
                    [attr.data-testid]="'safety-denied-tool-' + $index"
                    [ngModel]="row.tool"
                    (ngModelChange)="updateDeniedPattern($index, 'tool', $event)"
                    [disabled]="!canEdit()"
                  />
                </label>
                <label class="field">
                  <span>Argument (optional)</span>
                  <input
                    class="control"
                    type="text"
                    [attr.data-testid]="'safety-denied-argument-' + $index"
                    [ngModel]="row.argument"
                    (ngModelChange)="updateDeniedPattern($index, 'argument', $event)"
                    [disabled]="!canEdit()"
                  />
                </label>
                <label class="field grow">
                  <span>Pattern</span>
                  <input
                    class="control"
                    type="text"
                    [attr.data-testid]="'safety-denied-pattern-' + $index"
                    [ngModel]="row.pattern"
                    (ngModelChange)="updateDeniedPattern($index, 'pattern', $event)"
                    [disabled]="!canEdit()"
                  />
                </label>
                <label class="field">
                  <span>Mode</span>
                  <select
                    class="control"
                    [attr.data-testid]="'safety-denied-mode-' + $index"
                    [ngModel]="row.mode"
                    (ngModelChange)="updateDeniedPattern($index, 'mode', $event)"
                    [disabled]="!canEdit()"
                  >
                    @for (mode of deniedModes; track mode) {
                      <option [value]="mode">{{ mode }}</option>
                    }
                  </select>
                </label>
                <button
                  type="button"
                  class="btn btn-secondary"
                  [attr.data-testid]="'safety-denied-remove-' + $index"
                  [disabled]="!canEdit()"
                  (click)="removeDeniedPattern($index)"
                >
                  Remove
                </button>
              </div>
            }
          </div>

          <details class="advanced-rules hub-nested-panel" data-testid="safety-advanced-rules">
            <summary>Advanced: add narrow exceptions</summary>
            <p class="hint">Exceptions can override a block. Keep them specific and classify an example command before saving.</p>
            @for (field of exceptionFields; track field.key) {
              <div class="chip-editor hub-nested-panel" [attr.data-testid]="'safety-chips-' + field.testId">
                <div class="chip-head"><div><h3>{{ field.label }}</h3><p>{{ field.description }}</p></div></div>
                <ul class="chip-list" [attr.data-testid]="'safety-chip-list-' + field.testId">
                  @for (item of stringLists()[field.key]; track $index) {
                    <li class="chip"><span class="chip-text">{{ item }}</span><button type="button" class="chip-remove" [attr.data-testid]="'safety-chip-remove-' + field.testId" [disabled]="!canEdit()" (click)="removeChip(field.key, $index)">Remove</button></li>
                  }
                </ul>
                <div class="chip-add">
                  <input class="control" type="text" [attr.data-testid]="'safety-chip-input-' + field.testId" [ngModel]="chipDrafts()[field.key]" (ngModelChange)="setChipDraft(field.key, $event)" [disabled]="!canEdit()" [placeholder]="'Add ' + field.label.toLowerCase()" (keydown.enter)="$event.preventDefault(); addChip(field.key)" />
                  <button type="button" class="btn btn-secondary" [attr.data-testid]="'safety-chip-add-' + field.testId" [disabled]="!canEdit() || !chipDrafts()[field.key].trim()" (click)="addChip(field.key)">Add</button>
                </div>
              </div>
            }
          </details>
        </section>

        @if (!capabilities.capabilities().safetyWrites) {
          <p class="notice" data-testid="safety-writes-disabled">
            The server is not bound to a loopback host, so safety writes are disabled.
          </p>
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
      gap: var(--space-4);
      width: 100%;
      flex: 1;
      min-height: 0;
      overflow-y: auto;
      padding-bottom: calc(var(--space-6) + var(--fab-clearance, 4.5rem));
    }
    .head {
      display: flex;
      align-items: flex-start;
      justify-content: space-between;
      gap: var(--space-4);
      margin-bottom: 0;
    }
    .head-text {
      display: flex;
      flex-direction: column;
      gap: var(--space-1);
      min-width: 0;
    }
    .status-banner {
      border: 1px solid var(--border);
      border-radius: var(--radius-md);
      padding: var(--space-3) var(--space-4);
      background: var(--surface);
    }
    .status-banner[data-mode='on'] {
      border-color: var(--accent, #2f6f4e);
    }
    .status-banner[data-mode='dry-run'] {
      border-color: var(--warning, #a67c00);
    }
    .status-banner[data-mode='off'] {
      border-color: var(--danger, #a33);
    }
    .status-mode {
      font-weight: 650;
      font-size: var(--font-size-sm);
    }
    .status-meta {
      margin: var(--space-1) 0 0;
      color: var(--text-muted);
      font-size: var(--font-size-sm);
    }
    .status-path {
      display: block;
      margin-top: var(--space-1);
      font-family: var(--monospace-font, ui-monospace, monospace);
      word-break: break-all;
    }
    .section-title {
      margin: 0 0 var(--space-3);
      font-size: var(--font-size-xs);
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: var(--letter-label);
      color: var(--text-muted);
    }
    .lock-panel,
    .check-panel,
    .rules-panel,
    .profile-panel {
      display: flex;
      flex-direction: column;
      gap: var(--space-3);
    }
    .profile-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(14rem, 1fr));
      gap: var(--space-3);
    }
    .profile-card {
      display: flex;
      flex-direction: column;
      align-items: flex-start;
      gap: var(--space-2);
    }
    .profile-card.profile-applied { border-color: var(--accent, #2f6f4e); }
    .profile-card h3 { margin: 0; font-size: var(--font-size-sm); font-weight: 650; }
    .profile-card p, .chip-head p { margin: 0; color: var(--text-muted); font-size: var(--font-size-xs); line-height: 1.4; }
    .draft-notice {
      margin: 0;
      padding: var(--space-2) var(--space-3);
      border-left: 3px solid var(--warning, #a67c00);
      color: var(--text-muted);
      font-size: var(--font-size-sm);
    }
    .sample-row {
      display: flex;
      flex-wrap: wrap;
      gap: var(--space-2);
    }
    .sample-btn {
      font-family: var(--monospace-font, ui-monospace, monospace);
      font-size: var(--font-size-xs);
    }
    .check-input {
      width: 100%;
      resize: vertical;
      font-family: var(--monospace-font, ui-monospace, monospace);
    }
    .check-actions {
      display: flex;
      gap: var(--space-2);
    }
    .check-result {
      border: 1px solid var(--border);
      border-radius: var(--radius-md);
      padding: var(--space-3) var(--space-4);
      background: var(--surface);
    }
    .check-result[data-outcome='deny'],
    .check-result[data-outcome='fatal'] {
      border-color: var(--danger, #a33);
    }
    .check-result[data-outcome='allow'] {
      border-color: var(--accent, #2f6f4e);
    }
    .check-outcome {
      font-weight: 650;
      font-size: var(--font-size-sm);
      text-transform: uppercase;
      letter-spacing: 0.04em;
    }
    .check-meta {
      margin: var(--space-1) 0 0;
      color: var(--text-muted);
      font-size: var(--font-size-sm);
    }
    .row {
      display: flex;
      flex-wrap: wrap;
      gap: var(--space-3);
    }
    .field {
      display: flex;
      flex-direction: column;
      gap: var(--space-1);
      min-width: 10rem;
    }
    .field.grow {
      flex: 1;
      min-width: 12rem;
    }
    .field span {
      font-size: var(--font-size-xs);
      color: var(--text-muted);
    }
    .hint {
      margin: 0;
      font-size: var(--font-size-sm);
      color: var(--text-muted);
    }
    .hint code {
      font-family: var(--monospace-font, ui-monospace, monospace);
      font-size: 0.92em;
    }
    .chip-editor,
    .row-editor {
      padding: var(--space-3);
      display: flex;
      flex-direction: column;
      gap: var(--space-2);
    }
    .chip-head {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: var(--space-2);
    }
    .chip-head h3 {
      margin: 0;
      font-size: var(--font-size-sm);
      font-weight: 650;
    }
    .advanced-rules {
      display: flex;
      flex-direction: column;
      gap: var(--space-3);
      padding: var(--space-3);
    }
    .advanced-rules summary { cursor: pointer; font-size: var(--font-size-sm); font-weight: 650; }
    .chip-list {
      list-style: none;
      margin: 0;
      padding: 0;
      display: flex;
      flex-wrap: wrap;
      gap: var(--space-2);
    }
    .chip {
      display: inline-flex;
      align-items: center;
      gap: var(--space-2);
      border: 1px solid var(--border);
      border-radius: var(--radius-md);
      padding: 0.25rem 0.45rem 0.25rem 0.6rem;
      font-size: var(--font-size-sm);
      background: var(--surface);
    }
    .chip-text {
      word-break: break-all;
    }
    .chip-remove {
      border: 0;
      background: transparent;
      color: var(--text-muted);
      cursor: pointer;
      font: inherit;
      font-size: var(--font-size-xs);
    }
    .chip-add {
      display: flex;
      gap: var(--space-2);
    }
    .chip-add .control {
      flex: 1;
    }
    .rule-row {
      display: flex;
      flex-wrap: wrap;
      gap: var(--space-2);
      align-items: flex-end;
      padding-top: var(--space-2);
      border-top: 1px solid var(--border);
    }
    .diagnostics {
      margin: 0;
      padding: var(--space-3);
      border: 1px solid var(--danger, #a33);
      border-radius: var(--radius-md);
      background: var(--surface);
      color: var(--text-primary);
      font-family: var(--monospace-font, ui-monospace, monospace);
      font-size: var(--font-size-sm);
      white-space: pre-wrap;
      overflow-x: auto;
    }
    .notice {
      margin: 0;
      padding: var(--space-3);
      border: 1px solid var(--border);
      border-radius: var(--radius-md);
      color: var(--text-muted);
      font-size: var(--font-size-sm);
    }
    .notice-warn {
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      justify-content: space-between;
      gap: var(--space-3);
      border-color: var(--warning, #a67c00);
    }
    .notice-warn p {
      margin: 0;
    }
    .notice-info {
      border-color: var(--border);
      background: var(--surface-muted, var(--surface));
    }
    .notice-info p {
      margin: 0;
    }
    .env-overrides {
      display: flex;
      flex-direction: column;
      gap: var(--space-2);
    }
    .env-list {
      list-style: none;
      margin: 0;
      padding: 0;
      display: flex;
      flex-direction: column;
      gap: var(--space-2);
    }
    .env-item {
      display: flex;
      flex-wrap: wrap;
      gap: var(--space-2);
      align-items: baseline;
      font-size: var(--font-size-sm);
    }
    .env-name {
      font-family: var(--monospace-font, ui-monospace, monospace);
      font-size: 0.92em;
    }
    .env-value {
      font-family: var(--monospace-font, ui-monospace, monospace);
      color: var(--text-muted);
      word-break: break-all;
    }
    @media (max-width: 720px) {
      .head {
        flex-wrap: wrap;
      }
    }
  `,
})
export class SafetyPageComponent implements OnInit {
  readonly api = inject(SafetyApi);
  readonly capabilities = inject(CapabilitiesService);
  private readonly workspaceSelector = inject(WorkspaceSelectorService);

  readonly stringListFields = STRING_LIST_FIELDS;
  readonly blockingFields = STRING_LIST_FIELDS.filter((field) =>
    ['banned_paths', 'banned_tools', 'tool_denylist'].includes(field.key),
  );
  readonly exceptionFields = STRING_LIST_FIELDS.filter((field) => field.key.startsWith('allowed_'));
  readonly deniedModes = DENIED_MODES;
  readonly editHint = EDIT_HINT;
  readonly sampleCommands = SAMPLE_COMMANDS;
  readonly safetyProfiles = SAFETY_PROFILES;

  readonly loading = signal(false);
  readonly loaded = signal(false);
  readonly saving = signal(false);
  readonly loadError = signal<string | null>(null);
  readonly invalidDiagnostics = signal<string | null>(null);
  readonly conflict = signal(false);
  readonly hasUnsavedChanges = signal(false);
  readonly lastAppliedProfile = signal<string | null>(null);

  readonly checkCommandText = signal('');
  readonly checking = signal(false);
  readonly checkResult = signal<SafetyCheckResult | null>(null);
  readonly checkError = signal<string | null>(null);

  readonly status = signal<SafetyStatus | null>(null);
  readonly sha256 = signal('');
  readonly configExists = signal(false);
  readonly configPath = signal('');
  readonly configEnabled = signal(true);
  readonly configDryRun = signal(false);

  readonly stringLists = signal<Record<StringListKey, string[]>>({
    banned_paths: [],
    banned_tools: [],
    tool_denylist: [],
    allowed_tools: [],
    allowed_paths: [],
    allowed_commands: [],
    allowed_patterns: [],
  });
  readonly chipDrafts = signal<Record<StringListKey, string>>({
    banned_paths: '',
    banned_tools: '',
    tool_denylist: '',
    allowed_tools: '',
    allowed_paths: '',
    allowed_commands: '',
    allowed_patterns: '',
  });
  readonly customRules = signal<EditableCustomRule[]>([]);
  readonly deniedPatterns = signal<EditableDeniedPattern[]>([]);

  readonly canEdit = computed(
    () => this.capabilities.capabilities().safetyWrites && !this.conflict() && this.loaded(),
  );

  readonly overrideSourceActive = computed(() => this.status()?.source === 'override');

  readonly activeEnvironmentOverrides = computed(() => {
    const overrides = this.status()?.environmentOverrides;
    if (!overrides) {
      return [] as { name: string; value: string }[];
    }
    return (Object.entries(overrides) as [string, string | null][])
      .filter((entry): entry is [string, string] => entry[1] != null && entry[1] !== '')
      .map(([name, value]) => ({ name, value }));
  });

  readonly enforcementMode = computed(() => {
    const st = this.status();
    if (!st) {
      return 'unknown';
    }
    if (!st.enabled) {
      return 'off';
    }
    if (st.dryRun) {
      return 'dry-run';
    }
    return 'on';
  });

  ngOnInit(): void {
    this.capabilities.load();
    void this.reload();
  }

  enforcementLabel(): string {
    switch (this.enforcementMode()) {
      case 'on':
        return 'Enforcement on';
      case 'dry-run':
        return 'Dry-run (violations logged, not blocked)';
      case 'off':
        return 'Enforcement off';
      default:
        return 'Status unknown';
    }
  }

  private workspaceRoot(): string | undefined {
    const selected = this.workspaceSelector.selectedWorkspacePath();
    if (!selected) {
      return undefined;
    }
    return this.workspaceSelector.workspaces().find((w) => w.path === selected)?.workspaceRoot;
  }

  useSampleCommand(command: string): void {
    this.checkCommandText.set(command);
    this.checkError.set(null);
  }

  async runCheck(): Promise<void> {
    const command = this.checkCommandText().trim();
    if (!command) {
      return;
    }
    this.checking.set(true);
    this.checkError.set(null);
    this.checkResult.set(null);
    try {
      const result = await firstValueFrom(this.api.checkCommand({ command }, this.workspaceRoot()));
      this.checkResult.set(result);
    } catch (err: unknown) {
      if (err instanceof HttpErrorResponse) {
        const body = err.error as { error?: string; message?: string } | string | null;
        const message =
          typeof body === 'string'
            ? body
            : body?.error || body?.message || err.message || `Check failed (${err.status})`;
        this.checkError.set(message);
      } else {
        this.checkError.set(err instanceof Error ? err.message : 'Check failed');
      }
    } finally {
      this.checking.set(false);
    }
  }

  async reload(): Promise<void> {
    this.loading.set(true);
    this.loadError.set(null);
    this.invalidDiagnostics.set(null);
    this.conflict.set(false);
    const root = this.workspaceRoot();
    try {
      const [status, configResponse] = await Promise.all([
        firstValueFrom(this.api.fetchStatus(root)),
        firstValueFrom(this.api.fetchConfig(root)),
      ]);
      this.status.set(status);
      this.applyConfig(
        configResponse.config,
        configResponse.sha256,
        configResponse.exists,
        configResponse.path,
      );
      this.loaded.set(true);
    } catch (err: unknown) {
      this.loadError.set(err instanceof Error ? err.message : 'Failed to load safety config');
      this.loaded.set(true);
    } finally {
      this.loading.set(false);
    }
  }

  private applyConfig(config: SafetyConfig, sha256: string, exists: boolean, path: string): void {
    this.sha256.set(sha256);
    this.configExists.set(exists);
    this.configPath.set(path);
    this.configEnabled.set(config.enabled);
    this.configDryRun.set(config.dry_run);
    this.stringLists.set({
      banned_paths: [...config.banned_paths],
      banned_tools: [...config.banned_tools],
      tool_denylist: [...config.tool_denylist],
      allowed_tools: [...config.allowed_tools],
      allowed_paths: [...config.allowed_paths],
      allowed_commands: [...config.allowed_commands],
      allowed_patterns: [...config.allowed_patterns],
    });
    this.customRules.set(config.custom_rules.map((rule) => this.toEditableCustomRule(rule)));
    this.deniedPatterns.set(config.denied_argument_patterns.map((row) => this.toEditableDenied(row)));
    this.hasUnsavedChanges.set(false);
    this.lastAppliedProfile.set(null);
  }

  private toEditableCustomRule(rule: SafetyCustomRule): EditableCustomRule {
    if (typeof rule.pattern === 'string') {
      return { name: rule.name, kind: 'pattern', value: rule.pattern, target: rule.target ?? 'command' };
    }
    return { name: rule.name, kind: 'match', value: rule.match ?? '', target: rule.target ?? 'command' };
  }

  private toEditableDenied(row: SafetyDeniedArgumentPattern): EditableDeniedPattern {
    return {
      tool: row.tool ?? '',
      argument: row.argument ?? '',
      pattern: row.pattern,
      mode: row.mode ?? 'regex',
    };
  }

  setChipDraft(key: StringListKey, value: string): void {
    this.chipDrafts.update((drafts) => ({ ...drafts, [key]: value }));
  }

  addChip(key: StringListKey): void {
    const value = this.chipDrafts()[key].trim();
    if (!value || !this.canEdit()) {
      return;
    }
    this.stringLists.update((lists) => ({
      ...lists,
      [key]: [...lists[key], value],
    }));
    this.setChipDraft(key, '');
    this.hasUnsavedChanges.set(true);
  }

  removeChip(key: StringListKey, index: number): void {
    if (!this.canEdit()) {
      return;
    }
    this.stringLists.update((lists) => ({
      ...lists,
      [key]: lists[key].filter((_, i) => i !== index),
    }));
    this.hasUnsavedChanges.set(true);
  }

  applyProfile(profile: SafetyProfile): void {
    if (!this.canEdit()) {
      return;
    }
    const paths = profile.paths;
    if (paths) {
      this.stringLists.update((lists) => ({
        ...lists,
        banned_paths: this.mergeUnique(lists.banned_paths, paths),
      }));
    }
    const rulesToAdd = profile.rules;
    if (rulesToAdd) {
      this.customRules.update((rules) => {
        const known = new Set(rules.map((rule) => `${rule.name}\u0000${rule.kind}\u0000${rule.value}`));
        return [...rules, ...rulesToAdd.filter((rule) => !known.has(`${rule.name}\u0000${rule.kind}\u0000${rule.value}`))];
      });
    }
    this.lastAppliedProfile.set(profile.id);
    this.hasUnsavedChanges.set(true);
  }

  private mergeUnique(existing: readonly string[], additions: readonly string[]): string[] {
    return [...existing, ...additions.filter((item) => !existing.includes(item))];
  }

  addCustomRule(): void {
    if (!this.canEdit()) {
      return;
    }
    this.customRules.update((rules) => [
      ...rules,
      { name: '', kind: 'match', value: '', target: 'command' },
    ]);
    this.hasUnsavedChanges.set(true);
  }

  updateCustomRule(index: number, field: keyof EditableCustomRule, value: string): void {
    this.customRules.update((rules) =>
      rules.map((rule, i) => (i === index ? { ...rule, [field]: value } : rule)),
    );
    this.hasUnsavedChanges.set(true);
  }

  removeCustomRule(index: number): void {
    if (!this.canEdit()) {
      return;
    }
    this.customRules.update((rules) => rules.filter((_, i) => i !== index));
    this.hasUnsavedChanges.set(true);
  }

  addDeniedPattern(): void {
    if (!this.canEdit()) {
      return;
    }
    this.deniedPatterns.update((rows) => [
      ...rows,
      { tool: '', argument: '', pattern: '', mode: 'regex' },
    ]);
    this.hasUnsavedChanges.set(true);
  }

  updateDeniedPattern(index: number, field: keyof EditableDeniedPattern, value: string): void {
    this.deniedPatterns.update((rows) =>
      rows.map((row, i) => (i === index ? { ...row, [field]: value } : row)),
    );
    this.hasUnsavedChanges.set(true);
  }

  removeDeniedPattern(index: number): void {
    if (!this.canEdit()) {
      return;
    }
    this.deniedPatterns.update((rows) => rows.filter((_, i) => i !== index));
    this.hasUnsavedChanges.set(true);
  }

  async save(): Promise<void> {
    if (!this.capabilities.capabilities().safetyWrites) {
      return;
    }
    this.saving.set(true);
    this.invalidDiagnostics.set(null);
    this.conflict.set(false);
    const lists = this.stringLists();
    const command: UpdateSafetyConfigCommand = {
      sha256: this.sha256(),
      banned_paths: lists.banned_paths,
      banned_tools: lists.banned_tools,
      tool_denylist: lists.tool_denylist,
      allowed_tools: lists.allowed_tools,
      allowed_paths: lists.allowed_paths,
      allowed_commands: lists.allowed_commands,
      allowed_patterns: lists.allowed_patterns,
      custom_rules: this.customRules().map((rule) => {
        const base = { name: rule.name, target: rule.target || 'command' };
        return rule.kind === 'pattern'
          ? { ...base, pattern: rule.value }
          : { ...base, match: rule.value };
      }),
      denied_argument_patterns: this.deniedPatterns().map((row) => {
        const out: SafetyDeniedArgumentPattern = {
          pattern: row.pattern,
          mode: row.mode || 'regex',
        };
        if (row.tool.trim()) {
          return { ...out, tool: row.tool.trim(), ...(row.argument.trim() ? { argument: row.argument.trim() } : {}) };
        }
        if (row.argument.trim()) {
          return { ...out, argument: row.argument.trim() };
        }
        return out;
      }),
    };
    try {
      const response = await firstValueFrom(this.api.updateConfig(command, this.workspaceRoot()));
      this.sha256.set(response.sha256);
      this.configExists.set(response.exists);
      await this.reload();
    } catch (err: unknown) {
      if (err instanceof HttpErrorResponse && err.status === 409) {
        this.conflict.set(true);
        return;
      }
      if (err instanceof HttpErrorResponse && err.status === 422) {
        const body = err.error as { diagnostics?: string; error?: string } | null;
        this.invalidDiagnostics.set(body?.diagnostics || body?.error || 'Safety config failed validation');
        return;
      }
      if (err instanceof HttpErrorResponse) {
        const body = err.error as { error?: string } | null;
        this.loadError.set(body?.error || err.message);
        return;
      }
      this.loadError.set(err instanceof Error ? err.message : 'Failed to save safety config');
    } finally {
      this.saving.set(false);
    }
  }
}
