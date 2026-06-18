import { CommonModule } from '@angular/common';
import {
  ChangeDetectionStrategy,
  ChangeDetectorRef,
  Component,
  OnInit,
  effect,
  inject,
} from '@angular/core';
import { IonCard, IonCardContent, IonCardHeader, IonCardSubtitle, IonCardTitle, IonSpinner } from '@ionic/angular/standalone';

import { forkJoin, of } from 'rxjs';
import { catchError } from 'rxjs/operators';

import {
  ApiService,
  DiscoverPatternSummary,
  MetricsSummary,
  MetricsSummaryItem,
  ModelBreakdownItem,
  RuntimeOverlayMetrics,
  SavingsBucket,
  SavingsPathName,
  SavingsReport,
  WorkspaceRegistry,
  ToolCallClassificationMetrics,
} from '../../services/api.service';
import { NavService } from '../../services/nav.service';
import { WorkspaceSelectorService } from '../../services/workspace-selector.service';
import { formatElapsedSeconds } from '../../utils/format-elapsed';

interface UsageModelRow {
  runtime: string;
  model: string;
  invocations: number;
  runs: number;
  elapsed_seconds: number;
  input_tokens: number;
  output_tokens: number;
  cache_creation_input_tokens: number;
  cache_read_input_tokens: number;
  max_turn_total_tokens: number;
  tool_calls_total: number;
  cache_hit_ratio: number;
  total_tokens: number;
}

interface UsageRuntimeRow {
  runtime: string;
  model_count: number;
  invocations: number;
  runs: number;
  elapsed_seconds: number;
  input_tokens: number;
  output_tokens: number;
  cache_creation_input_tokens: number;
  cache_read_input_tokens: number;
  max_turn_total_tokens: number;
  tool_calls_total: number;
  cache_hit_ratio: number;
  total_tokens: number;
}

interface MutableModelBucket {
  runtime: string;
  model: string;
  invocations: number;
  runKeys: Set<string>;
  elapsed_seconds: number;
  input_tokens: number;
  output_tokens: number;
  cache_creation_input_tokens: number;
  cache_read_input_tokens: number;
  max_turn_total_tokens: number;
  tool_calls_total: number;
}

interface MutableRuntimeBucket {
  runtime: string;
  models: Set<string>;
  invocations: number;
  runKeys: Set<string>;
  elapsed_seconds: number;
  input_tokens: number;
  output_tokens: number;
  cache_creation_input_tokens: number;
  cache_read_input_tokens: number;
  max_turn_total_tokens: number;
  tool_calls_total: number;
}

interface StatItem {
  label: string;
  value: string;
}

interface DiscoverPlanEntry {
  plan_key: string;
  patterns: DiscoverPatternSummary[];
  limitations: string[];
}

interface OverlayRunRow {
  kind: Exclude<UsageKind, 'all'>;
  plan_key: string;
  stage_id?: string;
  runtime?: string;
  overlay: RuntimeOverlayMetrics;
}

interface ToolCallRunRow {
  kind: Exclude<UsageKind, 'all'>;
  plan_key: string;
  stage_id?: string;
  runtime?: string;
  tool_calls: ToolCallClassificationMetrics;
}

interface SavingsPathEntry {
  name: SavingsPathName;
  label: string;
  saved_tokens: number;
  saved_bytes: number;
  count: number;
  savings_percent?: number;
}

const SAVINGS_PATH_ORDER: SavingsPathName[] = [
  'pre_tool_rewrite',
  'hook_compaction',
  'proxy_shell_compaction',
  'result_windowing',
];

type UsageKind = 'all' | 'plan' | 'orchestration';

interface UsageRunRecord {
  kind: Exclude<UsageKind, 'all'>;
  item: MetricsSummaryItem;
  breakdown: ModelBreakdownItem[];
  hasDetailedBreakdown: boolean;
  startedAtMs: number | null;
}

@Component({
  selector: 'ralph-usage-hub',
  standalone: true,
  imports: [CommonModule, IonCard, IonCardContent, IonCardHeader, IonCardSubtitle, IonCardTitle, IonSpinner],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="usage-hub">
      <div class="header">
        <div class="title-wrap">
          <h2>Usage</h2>
          <p>Token and tool-call totals from plan logs, by runtime and model. Open this view with the chart icon in the header.</p>
        </div>
        <div class="header-actions">
          <button class="btn-secondary" (click)="goToPlans()">Back to Plans</button>
          <button class="btn-primary" (click)="refresh()">Refresh</button>
        </div>
      </div>

      @if (loading) {
        <div class="loading">
          <ion-spinner name="crescent"></ion-spinner>
          <span>Loading usage metrics...</span>
        </div>
      } @else if (error) {
        <div class="error">{{ error }}</div>
      } @else if (summary) {
        <section class="filters-section">
          <div class="filters-grid">
            <label class="filter-field">
              <span>Kind</span>
              <select [value]="filterKind" (change)="setFilterKind($any($event.target).value)">
                <option value="all">All</option>
                <option value="plan">Plans</option>
                <option value="orchestration">Orchestrations</option>
              </select>
            </label>

            <label class="filter-field">
              <span>Runtime</span>
              <select [value]="filterRuntime" (change)="setFilterRuntime($any($event.target).value)">
                <option value="all">All</option>
                @for (runtime of runtimeOptions; track runtime) {
                  <option [value]="runtime">{{ runtime }}</option>
                }
              </select>
            </label>

            <label class="filter-field">
              <span>Model</span>
              <select [value]="filterModel" (change)="setFilterModel($any($event.target).value)">
                <option value="all">All</option>
                @for (model of modelOptions; track model) {
                  <option [value]="model">{{ model }}</option>
                }
              </select>
            </label>

            <label class="filter-field">
              <span>From Date</span>
              <input type="date" [value]="filterDateFrom" (change)="setFilterDateFrom($any($event.target).value)" />
            </label>

            <label class="filter-field">
              <span>To Date</span>
              <input type="date" [value]="filterDateTo" (change)="setFilterDateTo($any($event.target).value)" />
            </label>
          </div>
          <div class="filters-meta">
            <span>Showing {{ formatNumber(filteredRunCount) }} of {{ formatNumber(totalRunCount) }} runs</span>
            <button class="btn-secondary" type="button" (click)="clearFilters()">Clear Filters</button>
          </div>
        </section>

        <section class="overview-grid">
          @for (stat of statRows; track stat.label) {
            <ion-card>
              <ion-card-content>
                <div class="metric-label">{{ stat.label }}</div>
                <div class="metric-value">{{ stat.value }}</div>
              </ion-card-content>
            </ion-card>
          }
        </section>

        <section class="savings-panel" aria-label="Benchmark overview">
          <div class="savings-panel-header">
            <h3>Benchmark</h3>
            <span class="savings-panel-meta" *ngIf="savingsReport?.run_count">
              Measured across {{ savingsReport.run_count }} runs
              <span *ngIf="formatSavingsDateRange(savingsReport.date_range)">
                • {{ formatSavingsDateRange(savingsReport.date_range) }}
              </span>
            </span>
          </div>
          @if (savingsLoading) {
            <div class="loading">Loading benchmark data...</div>
          } @else if (savingsError) {
            <div class="error">{{ savingsError }}</div>
          } @else if (savingsReport) {
            <div class="savings-headline">
              <ion-card>
                <ion-card-content>
                  <div class="metric-label">Kept out of model context</div>
                  <div class="metric-value">
                    ~{{ formatNumber(savingsReport.saved_tokens) }} tokens /
                    ~{{ formatNumber(savingsReport.saved_bytes) }} bytes
                  </div>
                  <p class="savings-sentence">
                    Kept ~{{ formatNumber(savingsReport.saved_tokens) }} tokens (~{{ formatNumber(savingsReport.saved_bytes) }} bytes)
                    out of model context
                  </p>
                </ion-card-content>
              </ion-card>
            </div>
            <div class="savings-breakdown-grid">
              @if (savingsPathEntries.length === 0) {
                <div class="empty">No path-level savings recorded.</div>
              } @else {
                @for (pathEntry of savingsPathEntries; track pathEntry.name) {
                  <ion-card>
                    <ion-card-header>
                      <ion-card-title>{{ pathEntry.label }}</ion-card-title>
                    </ion-card-header>
                    <ion-card-content>
                      <div class="metric-line">
                        <span>Tokens</span>
                        <span>{{ formatNumber(pathEntry.saved_tokens) }}</span>
                      </div>
                      <div class="metric-line">
                        <span>Bytes</span>
                        <span>{{ formatNumber(pathEntry.saved_bytes) }}</span>
                      </div>
                      @if (pathEntry.count > 0) {
                        <div class="metric-line">
                          <span>Events</span>
                          <span>{{ pathEntry.count }}</span>
                        </div>
                      }
                      @if (pathEntry.savings_percent && pathEntry.savings_percent > 0) {
                        <div class="metric-line">
                          <span>Savings</span>
                          <span>{{ pathEntry.savings_percent }}%</span>
                        </div>
                      }
                    </ion-card-content>
                  </ion-card>
                }
              }
            </div>
            <div class="savings-context-efficiency">
              <ion-card>
                <ion-card-content>
                  <div class="metric-label">Context efficiency</div>
                  <div class="metric-value">{{ formatPercent(savingsReport.cache.cache_hit_ratio) }}</div>
                  <div class="metric-line">
                    <span>Cache reads</span>
                    <span>{{ formatNumber(savingsReport.cache.cache_read_tokens) }} tokens</span>
                  </div>
                </ion-card-content>
              </ion-card>
            </div>
          } @else {
            <div class="empty">Benchmark data unavailable.</div>
          }
        </section>

        @if (isShowingAllWorkspaces() && summary.projects && summary.projects.length > 1) {
          <section class="project-rollups" aria-label="Per-project usage rollups">
            <h3 class="project-rollups-title">By project</h3>
            <div class="project-rollups-grid">
              @for (proj of summary.projects; track proj.workspace_root) {
                <ion-card>
                  <ion-card-header>
                    <ion-card-title>{{ proj.label }}</ion-card-title>
                    <ion-card-subtitle>{{ proj.workspace_root }}</ion-card-subtitle>
                  </ion-card-header>
                  <ion-card-content>
                    <div class="project-rollup-metrics">
                      <div class="project-rollup-metric">
                        <span class="metric-label">Elapsed</span>
                        <span class="metric-value">{{ formatSeconds(proj.overall.elapsed_seconds) }}</span>
                      </div>
                      <div class="project-rollup-metric">
                        <span class="metric-label">Total tokens</span>
                        <span class="metric-value">{{
                          formatNumber(
                            proj.overall.input_tokens +
                              proj.overall.output_tokens +
                              proj.overall.cache_creation_input_tokens +
                              proj.overall.cache_read_input_tokens
                          )
                        }}</span>
                      </div>
                      <div class="project-rollup-metric">
                        <span class="metric-label">Cache hit</span>
                        <span class="metric-value">{{ formatPercent(proj.overall.cache_hit_ratio) }}</span>
                      </div>
                      <div class="project-rollup-metric">
                        <span class="metric-label">Peak turn</span>
                        <span class="metric-value">{{ formatPeakTurn(proj.overall.max_turn_total_tokens) }}</span>
                      </div>
                      <div class="project-rollup-metric">
                        <span class="metric-label">Tool calls</span>
                        <span class="metric-value">{{ formatNumber(proj.overall.tool_calls_total ?? 0) }}</span>
                      </div>
                    </div>
                  </ion-card-content>
                </ion-card>
              }
            </div>
          </section>
        }

        <section class="quality-note">
          <span>{{ detailedBreakdownRuns }} runs include model-level breakdown.</span>
          <span>{{ inferredBreakdownRuns }} runs are inferred from summary-level runtime/model fields.</span>
        </section>

        <section class="tables-grid">
          <ion-card>
            <ion-card-header>
              <ion-card-title>Runtime Breakdown</ion-card-title>
              <ion-card-subtitle>{{ runtimeRows.length }} runtimes</ion-card-subtitle>
            </ion-card-header>
            <ion-card-content>
              @if (runtimeRows.length === 0) {
                <div class="empty">No runtime-level usage data available.</div>
              } @else {
                <div class="usage-table">
                  <div class="usage-row usage-header runtime-columns">
                    <span>Runtime</span>
                    <span>Models</span>
                    <span>Runs</span>
                    <span>Invocations</span>
                    <span>Input</span>
                    <span>Output</span>
                    <span>Cache Read</span>
                    <span>Total</span>
                    <span>Tool calls</span>
                    <span>Cache hit</span>
                    <span>Peak turn</span>
                  </div>
                  @for (row of runtimeRows; track row.runtime) {
                    <div class="usage-row runtime-columns">
                      <span class="mono cell-clip" [title]="row.runtime">{{ row.runtime }}</span>
                      <span>{{ row.model_count }}</span>
                      <span>{{ formatNumber(row.runs) }}</span>
                      <span>{{ formatNumber(row.invocations) }}</span>
                      <span>{{ formatNumber(row.input_tokens) }}</span>
                      <span>{{ formatNumber(row.output_tokens) }}</span>
                      <span>{{ formatNumber(row.cache_read_input_tokens) }}</span>
                      <span class="mono">{{ formatNumber(row.total_tokens) }}</span>
                      <span>{{ formatNumber(row.tool_calls_total) }}</span>
                      <span>{{ formatPercent(row.cache_hit_ratio) }}</span>
                      <span>{{ formatPeakTurn(row.max_turn_total_tokens) }}</span>
                    </div>
                  }
                </div>
              }
            </ion-card-content>
          </ion-card>

          <ion-card>
            <ion-card-header>
              <ion-card-title>Runtime + Model Breakdown</ion-card-title>
              <ion-card-subtitle>{{ modelRows.length }} runtime/model buckets</ion-card-subtitle>
            </ion-card-header>
            <ion-card-content>
              @if (modelRows.length === 0) {
                <div class="empty">No runtime/model breakdown data available.</div>
              } @else {
                <div class="usage-table">
                  <div class="usage-row model-columns usage-header">
                    <span>Runtime</span>
                    <span>Model</span>
                    <span>Runs</span>
                    <span>Invocations</span>
                    <span>Input</span>
                    <span>Output</span>
                    <span>Cache Read</span>
                    <span>Total</span>
                    <span>Tool calls</span>
                    <span>Cache hit</span>
                    <span>Peak turn</span>
                  </div>
                  @for (row of modelRows; track row.runtime + '-' + row.model) {
                    <div class="usage-row model-columns">
                      <span class="mono cell-clip" [title]="row.runtime">{{ row.runtime }}</span>
                      <span class="mono cell-clip" [title]="row.model">{{ row.model }}</span>
                      <span>{{ formatNumber(row.runs) }}</span>
                      <span>{{ formatNumber(row.invocations) }}</span>
                      <span>{{ formatNumber(row.input_tokens) }}</span>
                      <span>{{ formatNumber(row.output_tokens) }}</span>
                      <span>{{ formatNumber(row.cache_read_input_tokens) }}</span>
                      <span class="mono">{{ formatNumber(row.total_tokens) }}</span>
                      <span>{{ formatNumber(row.tool_calls_total) }}</span>
                      <span>{{ formatPercent(row.cache_hit_ratio) }}</span>
                      <span>{{ formatPeakTurn(row.max_turn_total_tokens) }}</span>
                    </div>
                  }
                </div>
              }
            </ion-card-content>
          </ion-card>

          @if (isShowingAllWorkspaces() && summary.plans.length > 0) {
            <ion-card>
              <ion-card-header>
                <ion-card-title>Plan Runs</ion-card-title>
                <ion-card-subtitle>{{ summary.plans.length }} plan runs</ion-card-subtitle>
              </ion-card-header>
              <ion-card-content>
                <div class="usage-table">
                  <div class="usage-row usage-header plan-columns">
                    <span>Workspace</span>
                    <span>Plan Key</span>
                    <span>Runtime</span>
                    <span>Model</span>
                    <span>Input</span>
                    <span>Output</span>
                    <span>Cache Read</span>
                    <span>Total</span>
                    <span>Tool calls</span>
                    <span>Cache hit</span>
                  </div>
                  @for (run of summary.plans; track run.path) {
                    <div class="usage-row plan-columns">
                      <span class="cell-clip" [title]="getWorkspaceDisplayName(run.path)">{{
                        getWorkspaceDisplayName(run.path)
                      }}</span>
                      <span class="mono cell-clip" [title]="run.plan_key">{{ run.plan_key }}</span>
                      <span class="mono cell-clip" [title]="run.runtime || '(unspecified)'">{{
                        run.runtime || '(unspecified)'
                      }}</span>
                      <span class="mono cell-clip" [title]="run.model || '(unspecified)'">{{
                        run.model || '(unspecified)'
                      }}</span>
                      <span>{{ formatNumber(run.input_tokens) }}</span>
                      <span>{{ formatNumber(run.output_tokens) }}</span>
                      <span>{{ formatNumber(run.cache_read_input_tokens) }}</span>
                      <span class="mono">{{ formatNumber(run.input_tokens + run.output_tokens + run.cache_creation_input_tokens + run.cache_read_input_tokens) }}</span>
                      <span>{{ formatNumber(run.tool_calls_total ?? 0) }}</span>
                      <span>{{ formatPercent(run.cache_hit_ratio) }}</span>
                    </div>
                  }
                </div>
              </ion-card-content>
            </ion-card>
          }

          @if (overlayRunRows.length > 0) {
            <ion-card>
              <ion-card-header>
                <ion-card-title>Runtime overlay effectiveness</ion-card-title>
                <ion-card-subtitle>{{ overlayRunRows.length }} runs with overlay telemetry</ion-card-subtitle>
              </ion-card-header>
              <ion-card-content>
                <div class="usage-table">
                  <div class="usage-row usage-header overlay-columns">
                    <span>Kind</span>
                    <span>Plan key</span>
                    <span>Stage</span>
                    <span>Native hooks</span>
                    <span>MCP</span>
                    <span>Compactions</span>
                    <span>Rewrites</span>
                    <span>Bytes saved</span>
                    <span>Mode</span>
                    <span>Warnings</span>
                  </div>
                  @for (row of overlayRunRows; track row.kind + row.plan_key + (row.stage_id ?? '')) {
                    <div class="usage-row overlay-columns">
                      <span>{{ row.kind }}</span>
                      <span class="mono cell-clip" [title]="row.plan_key">{{ row.plan_key }}</span>
                      <span class="mono cell-clip" [title]="row.stage_id || '(root)'">{{ row.stage_id || '(root)' }}</span>
                      <span>{{ formatOverlayEffective(row.overlay.native_hooks_effective) }}</span>
                      <span>{{ formatOverlayEffective(row.overlay.mcp_effective) }}</span>
                      <span>{{ formatNumber(row.overlay.hook_compactions) }}</span>
                      <span>{{ formatNumber(row.overlay.hook_rewrites) }}</span>
                      <span>{{ formatNumber(row.overlay.hook_bytes_saved) }}</span>
                      <span class="mono cell-clip" [title]="row.overlay.runtime_overlay_mode || '(none)'">{{
                        row.overlay.runtime_overlay_mode || '(none)'
                      }}</span>
                      <span class="cell-clip" [title]="formatOverlayWarnings(row.overlay)">{{
                        formatOverlayWarnings(row.overlay)
                      }}</span>
                    </div>
                  }
                </div>
              </ion-card-content>
            </ion-card>
          }

          @if (toolCallRunRows.length > 0) {
            <ion-card>
              <ion-card-header>
                <ion-card-title>Tool call classification</ion-card-title>
                <ion-card-subtitle>{{ toolCallRunRows.length }} runs with classified tool-call counters</ion-card-subtitle>
              </ion-card-header>
              <ion-card-content>
                <div class="usage-table">
                  <div class="usage-row usage-header tool-call-columns">
                    <span>Kind</span>
                    <span>Plan key</span>
                    <span>Stage</span>
                    <span>Proxy</span>
                    <span>Knowledge</span>
                    <span>Compat read</span>
                    <span>Native read</span>
                    <span>Search</span>
                    <span>Shell</span>
                    <span>Hook rewrite</span>
                    <span>Hook compact</span>
                  </div>
                  @for (row of toolCallRunRows; track row.kind + row.plan_key + (row.stage_id ?? '')) {
                    <div class="usage-row tool-call-columns">
                      <span>{{ row.kind }}</span>
                      <span class="mono cell-clip" [title]="row.plan_key">{{ row.plan_key }}</span>
                      <span class="mono cell-clip" [title]="row.stage_id || '(root)'">{{ row.stage_id || '(root)' }}</span>
                      <span>{{ formatNumber(row.tool_calls.ralph_proxy_calls) }}</span>
                      <span>{{ formatNumber(row.tool_calls.ralph_knowledge_calls) }}</span>
                      <span>{{ formatNumber(row.tool_calls.native_read_compatibility_calls) }}</span>
                      <span>{{ formatNumber(row.tool_calls.native_file_read_calls) }}</span>
                      <span>{{ formatNumber(row.tool_calls.native_search_calls) }}</span>
                      <span>{{ formatNumber(row.tool_calls.native_shell_calls) }}</span>
                      <span>{{ formatNumber(row.tool_calls.runtime_hook_rewrite_calls) }}</span>
                      <span>{{ formatNumber(row.tool_calls.runtime_hook_compaction_calls) }}</span>
                    </div>
                  }
                </div>
              </ion-card-content>
            </ion-card>
          }

          @if (discoverEntries.length > 0) {
            <ion-card>
              <ion-card-header>
                <ion-card-title>Discover patterns</ion-card-title>
                <ion-card-subtitle>Sequence and usage patterns from invocation logs (no whole-file-read detection)</ion-card-subtitle>
              </ion-card-header>
              <ion-card-content>
                @for (entry of discoverEntries; track entry.plan_key) {
                  <div class="discover-plan-block">
                    <div class="discover-plan-title mono">{{ entry.plan_key }}</div>
                    @if (entry.patterns.length === 0) {
                      <div class="empty">No sequence-level patterns detected.</div>
                    } @else {
                      <ul class="discover-pattern-list">
                        @for (pattern of entry.patterns; track pattern.pattern_id) {
                          <li>
                            <span class="mono">{{ pattern.pattern_id }}</span>
                            <span> ({{ pattern.count }})</span>
                            @if (pattern.description) {
                              <span class="discover-desc"> — {{ pattern.description }}</span>
                            }
                          </li>
                        }
                      </ul>
                    }
                  </div>
                }
              </ion-card-content>
            </ion-card>
          }

          @if (isShowingAllWorkspaces() && summary.orchestrations.length > 0) {
            <ion-card>
              <ion-card-header>
                <ion-card-title>Orchestration Runs</ion-card-title>
                <ion-card-subtitle>{{ summary.orchestrations.length }} orchestration runs</ion-card-subtitle>
              </ion-card-header>
              <ion-card-content>
                <div class="usage-table">
                  <div class="usage-row usage-header orch-columns">
                    <span>Workspace</span>
                    <span>Plan Key</span>
                    <span>Stage ID</span>
                    <span>Runtime</span>
                    <span>Model</span>
                    <span>Input</span>
                    <span>Output</span>
                    <span>Cache Read</span>
                    <span>Total</span>
                    <span>Tool calls</span>
                    <span>Cache hit</span>
                  </div>
                  @for (run of summary.orchestrations; track run.path) {
                    <div class="usage-row orch-columns">
                      <span class="cell-clip" [title]="getWorkspaceDisplayName(run.path)">{{
                        getWorkspaceDisplayName(run.path)
                      }}</span>
                      <span class="mono cell-clip" [title]="run.plan_key">{{ run.plan_key }}</span>
                      <span class="mono cell-clip" [title]="run.stage_id || '(root)'">{{
                        run.stage_id || '(root)'
                      }}</span>
                      <span class="mono cell-clip" [title]="run.runtime || '(unspecified)'">{{
                        run.runtime || '(unspecified)'
                      }}</span>
                      <span class="mono cell-clip" [title]="run.model || '(unspecified)'">{{
                        run.model || '(unspecified)'
                      }}</span>
                      <span>{{ formatNumber(run.input_tokens) }}</span>
                      <span>{{ formatNumber(run.output_tokens) }}</span>
                      <span>{{ formatNumber(run.cache_read_input_tokens) }}</span>
                      <span class="mono">{{ formatNumber(run.input_tokens + run.output_tokens + run.cache_creation_input_tokens + run.cache_read_input_tokens) }}</span>
                      <span>{{ formatNumber(run.tool_calls_total ?? 0) }}</span>
                      <span>{{ formatPercent(run.cache_hit_ratio) }}</span>
                    </div>
                  }
                </div>
              </ion-card-content>
            </ion-card>
          }
        </section>
      }
    </div>
  `,
  styles: `
    :host {
      display: flex;
      flex: 1;
      min-height: 0;
    }
    .usage-hub {
      flex: 1;
      min-height: 0;
      overflow-y: auto;
      padding: 2rem;
      display: grid;
      gap: 1rem;
    }
    .header {
      display: flex;
      justify-content: space-between;
      align-items: flex-end;
      gap: 1rem;
      flex-wrap: wrap;
    }
    .title-wrap h2 {
      margin: 0;
      font-size: 1.75rem;
      font-weight: 600;
    }
    .title-wrap p {
      margin: 0.35rem 0 0;
      color: var(--text-muted);
      font-size: 0.9rem;
    }
    .header-actions {
      display: flex;
      gap: 0.5rem;
    }
    .filters-section {
      display: grid;
      gap: 0.8rem;
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 0.9rem;
      background: var(--surface);
    }
    .filters-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(170px, 1fr));
      gap: 0.7rem;
    }
    .filter-field {
      display: grid;
      gap: 0.28rem;
      font-size: 0.8rem;
      color: var(--text-muted);
    }
    .filter-field span {
      color: var(--text-muted);
      text-transform: uppercase;
      letter-spacing: 0.03em;
      font-size: 0.72rem;
    }
    .filter-field select,
    .filter-field input {
      background: var(--surface);
      color: var(--text-primary);
      border: 1px solid var(--border);
      border-radius: 6px;
      padding: 0.45rem 0.55rem;
      font-size: 0.85rem;
    }
    .filters-meta {
      display: flex;
      justify-content: space-between;
      align-items: center;
      gap: 0.75rem;
      flex-wrap: wrap;
      color: var(--text-muted);
      font-size: 0.82rem;
    }
    .overview-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(170px, 1fr));
      gap: 1rem;
    }
    .savings-panel {
      padding: 1rem;
      border: 1px solid var(--border);
      border-radius: 8px;
      background: var(--surface);
      display: grid;
      gap: 0.8rem;
    }
    .savings-panel-header {
      display: flex;
      justify-content: space-between;
      align-items: baseline;
      flex-wrap: wrap;
      gap: 0.35rem;
    }
    .savings-panel-header h3 {
      margin: 0;
      font-size: 1.25rem;
    }
    .savings-panel-meta {
      color: var(--text-muted);
      font-size: 0.86rem;
    }
    .savings-headline,
    .savings-context-efficiency {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
      gap: 1rem;
    }
    .savings-breakdown-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
      gap: 0.8rem;
    }
    .savings-sentence {
      margin-top: 0.4rem;
      font-size: 0.9rem;
      color: var(--text-muted);
    }
    .metric-line {
      display: flex;
      justify-content: space-between;
      gap: 0.4rem;
      font-size: 0.85rem;
      color: var(--text-muted);
    }
    .metric-line span:last-child {
      color: var(--text-primary);
      font-weight: 600;
    }
    .project-rollups {
      display: grid;
      gap: 0.75rem;
    }
    .project-rollups-title {
      margin: 0;
      font-size: 1.15rem;
      font-weight: 600;
      color: var(--text-primary);
    }
    .project-rollups-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(260px, 1fr));
      gap: 1rem;
    }
    .project-rollup-metrics {
      display: grid;
      grid-template-columns: repeat(3, minmax(0, 1fr));
      gap: 0.75rem;
    }
    .project-rollup-metric {
      display: flex;
      flex-direction: column;
      gap: 0.25rem;
    }
    .project-rollup-metric .metric-label {
      margin-bottom: 0;
    }
    .project-rollup-metric .metric-value {
      font-size: 1rem;
    }
    ion-card {
      --background: var(--surface);
      --color: var(--text-primary);
      margin: 0;
      border: 1px solid var(--border);
      border-radius: 8px;
      box-shadow: none;
    }
    .metric-label {
      color: var(--text-muted);
      font-size: 0.78rem;
      text-transform: uppercase;
      letter-spacing: 0.04em;
      margin-bottom: 0.35rem;
    }
    .metric-value {
      font-size: 1.25rem;
      font-weight: 600;
      font-family: var(--monospace-font);
    }
    .quality-note {
      display: flex;
      flex-wrap: wrap;
      gap: 1rem;
      color: var(--text-muted);
      font-size: 0.85rem;
      padding: 0.75rem 0.9rem;
      border: 1px solid var(--border);
      border-radius: 8px;
      background: var(--surface);
    }
    .tables-grid {
      display: grid;
      grid-template-columns: 1fr;
      gap: 1rem;
    }
    :host ion-card-content:has(.usage-table) {
      --padding-start: 12px;
      --padding-end: 12px;
      --padding-top: 12px;
      --padding-bottom: 12px;
    }
    .usage-table {
      display: grid;
      gap: 0;
      overflow-x: auto;
      border: 1px solid var(--border);
      border-radius: 8px;
      background: var(--surface-muted);
    }
    .usage-row {
      display: grid;
      gap: 0.7rem;
      align-items: center;
      font-size: 0.88rem;
      min-width: 940px;
      padding: 0.48rem 0.65rem;
      border-bottom: 1px solid var(--border);
      background: var(--surface);
    }
    .usage-row:nth-child(even):not(.usage-header) {
      background: var(--surface-muted);
    }
    .usage-row:last-child {
      border-bottom: none;
    }
    .usage-row.usage-header {
      padding-bottom: 0.55rem;
      border-bottom: 2px solid var(--border);
      background: var(--surface-muted);
    }
    .cell-clip {
      min-width: 0;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .runtime-columns {
      grid-template-columns: 1fr 0.55fr 0.55fr 0.8fr 0.8fr 0.8fr 0.95fr 0.95fr 0.75fr 0.8fr 0.8fr;
    }
    .model-columns {
      grid-template-columns: 0.9fr 1.5fr 0.55fr 0.8fr 0.8fr 0.8fr 0.95fr 0.95fr 0.75fr 0.8fr 0.8fr;
    }
    .plan-columns {
      grid-template-columns: 1fr 1.2fr 0.9fr 1.2fr 0.8fr 0.8fr 0.95fr 0.95fr 0.75fr 0.8fr;
    }
    .orch-columns {
      grid-template-columns: 1fr 1.2fr 0.9fr 0.9fr 1.2fr 0.8fr 0.8fr 0.95fr 0.95fr 0.75fr 0.8fr;
    }
    .overlay-columns {
      grid-template-columns: 0.7fr 1.1fr 0.7fr 0.7fr 0.5fr 0.7fr 0.7fr 0.8fr 0.7fr 1.4fr;
    }
    .tool-call-columns {
      grid-template-columns: 0.7fr 1.1fr 0.7fr 0.6fr 0.7fr 0.7fr 0.7fr 0.6fr 0.6fr 0.7fr 0.7fr;
    }
    .usage-header {
      font-size: 0.78rem;
      text-transform: uppercase;
      letter-spacing: 0.04em;
      color: var(--text-muted);
      opacity: 0.9;
    }
    .mono {
      font-family: var(--monospace-font);
    }
    .loading,
    .empty,
    .error {
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 1rem;
      background: var(--surface);
    }
    .loading {
      display: flex;
      align-items: center;
      gap: 0.75rem;
      color: var(--text-muted);
    }
    .error {
      color: var(--danger);
      border-color: rgba(255, 0, 0, 0.35);
      background: rgba(255, 0, 0, 0.08);
    }
    .empty {
      color: var(--text-muted);
    }
    button {
      padding: 0.5rem 1rem;
      border: none;
      border-radius: 4px;
      cursor: pointer;
      font-size: 0.85rem;
      transition: background 0.2s ease;
    }
    .btn-primary {
      background: var(--accent);
      color: var(--button-text);
    }
    .btn-primary:hover {
      background: var(--accent-hover);
    }
    .btn-secondary {
      background: var(--surface-hover);
      color: var(--text-primary);
      border: 1px solid var(--border);
    }
    .btn-secondary:hover {
      background: var(--border);
    }
    .discover-plan-block + .discover-plan-block {
      margin-top: 1rem;
      padding-top: 1rem;
      border-top: 1px solid var(--border);
    }
    .discover-plan-title {
      font-weight: 600;
      margin-bottom: 0.35rem;
    }
    .discover-pattern-list {
      margin: 0;
      padding-left: 1.25rem;
      font-size: 0.9rem;
    }
    .discover-desc {
      color: var(--text-muted);
    }
  `,
})
export class UsageHubComponent implements OnInit {
  loading = false;
  error = '';
  summary: MetricsSummary | null = null;
  discoverEntries: DiscoverPlanEntry[] = [];
  overlayRunRows: OverlayRunRow[] = [];
  toolCallRunRows: ToolCallRunRow[] = [];
  savingsReport: SavingsReport | null = null;
  savingsPathEntries: SavingsPathEntry[] = [];
  savingsLoading = false;
  savingsError = '';
  statRows: StatItem[] = [];
  runtimeRows: UsageRuntimeRow[] = [];
  modelRows: UsageModelRow[] = [];
  detailedBreakdownRuns = 0;
  inferredBreakdownRuns = 0;
  totalRunCount = 0;
  filteredRunCount = 0;
  runtimeOptions: string[] = [];
  modelOptions: string[] = [];
  filterKind: UsageKind = 'all';
  filterRuntime = 'all';
  filterModel = 'all';
  filterDateFrom = '';
  filterDateTo = '';

  private readonly apiService = inject(ApiService);
  private readonly navService = inject(NavService);
  private readonly cdr = inject(ChangeDetectorRef);
  readonly workspaceSelectorService = inject(WorkspaceSelectorService);
  private skipWorkspaceReloadEffect = true;

  constructor() {
    effect(() => {
      this.workspaceSelectorService.selectedWorkspacePath();
      if (this.skipWorkspaceReloadEffect) {
        return;
      }
      this.refresh();
    });
  }

  ngOnInit(): void {
    this.refresh();
    queueMicrotask(() => {
      this.skipWorkspaceReloadEffect = false;
    });
  }

  goToPlans(): void {
    this.navService.navigate('plans');
  }

  refresh(): void {
    this.loading = true;
    this.error = '';
    this.summary = null;
    this.statRows = [];
    this.runtimeRows = [];
    this.modelRows = [];
    this.detailedBreakdownRuns = 0;
    this.inferredBreakdownRuns = 0;
    this.totalRunCount = 0;
    this.filteredRunCount = 0;
    this.runtimeOptions = [];
    this.modelOptions = [];
    this.discoverEntries = [];
    this.overlayRunRows = [];
    this.toolCallRunRows = [];
    this.savingsReport = null;
    this.savingsPathEntries = [];
    this.savingsLoading = false;
    this.savingsError = '';
    this.cdr.markForCheck();

    this.apiService.fetchMetricsSummary().subscribe({
      next: (summary) => {
        this.summary = summary;
        this.totalRunCount = this.countWorkspaceScopedRecords(summary);
        this.recomputeRuntimeOptions(summary);
        this.recomputeModelOptions(summary);
        this.applyFilters(summary);
        this.loadDiscoverReports(this.getFilteredPlans(summary));
        this.loadSavings();
        this.loading = false;
        this.cdr.markForCheck();
      },
      error: (err) => {
        this.loading = false;
        this.error = err.error?.error || 'Failed to load usage metrics';
        this.summary = null;
        this.discoverEntries = [];
        this.overlayRunRows = [];
        this.toolCallRunRows = [];
        this.statRows = [];
        this.runtimeRows = [];
        this.modelRows = [];
        this.detailedBreakdownRuns = 0;
        this.inferredBreakdownRuns = 0;
        this.totalRunCount = 0;
        this.filteredRunCount = 0;
        this.runtimeOptions = [];
        this.modelOptions = [];
        this.cdr.markForCheck();
      },
    });
  }

  private getFilteredPlans(summary: MetricsSummary | null): MetricsSummaryItem[] {
    if (!summary) {
      return [];
    }
    return summary.plans.filter((plan) =>
      this.passesWorkspaceScopeFilter({
        kind: 'plan',
        item: plan,
        breakdown: [],
        hasDetailedBreakdown: false,
        startedAtMs: null,
      }),
    );
  }

  private loadDiscoverReports(plans: MetricsSummaryItem[]): void {
    const targets = plans.slice(0, 8);
    if (targets.length === 0) {
      this.discoverEntries = [];
      return;
    }
    forkJoin(
      targets.map((plan) =>
        this.apiService.fetchDiscoverReport(plan.plan_key, plan.workspace_root).pipe(
          catchError(() => of(null)),
        ),
      ),
    ).subscribe((responses) => {
      this.discoverEntries = responses
        .filter((response): response is NonNullable<typeof response> => response !== null)
        .map((response) => ({
          plan_key: response.plan_key,
          patterns: response.report.sequence_patterns ?? [],
          limitations: response.report.limitations ?? [],
        }))
        .filter(
          (entry) =>
            entry.patterns.length > 0 ||
            entry.limitations.some((line) => line.includes('whole_file_reads')),
        );
      this.cdr.markForCheck();
    });
  }

  private loadSavings(): void {
    const filters = this.buildSavingsFilters();
    this.savingsLoading = true;
    this.savingsError = '';
    this.savingsReport = null;
    this.savingsPathEntries = [];
    this.apiService.fetchSavings(filters).subscribe({
      next: (report) => {
        this.savingsReport = report;
        this.savingsPathEntries = this.buildSavingsPathEntries(report);
        this.savingsLoading = false;
        this.cdr.markForCheck();
      },
      error: (err) => {
        this.savingsError = err.error?.error || 'Failed to load savings data';
        this.savingsLoading = false;
        this.cdr.markForCheck();
      },
    });
  }

  private buildSavingsFilters(): {
    workspaceRoot?: string;
    runtime?: string;
    model?: string;
    plan?: string;
  } {
    const filters: {
      workspaceRoot?: string;
      runtime?: string;
      model?: string;
      plan?: string;
    } = {};
    const workspace = this.getSelectedWorkspaceEntry();
    if (workspace?.workspaceRoot) {
      filters.workspaceRoot = workspace.workspaceRoot;
    }
    if (this.filterRuntime !== 'all') {
      filters.runtime = this.filterRuntime;
    }
    if (this.filterModel !== 'all') {
      filters.model = this.filterModel;
    }
    if (workspace?.planKey) {
      filters.plan = workspace.planKey;
    }
    return filters;
  }

  private buildSavingsPathEntries(report: SavingsReport): SavingsPathEntry[] {
    const perPath = report.per_path ?? {};
    return SAVINGS_PATH_ORDER.map((pathName) => {
      const bucket: SavingsBucket = perPath[pathName] ?? {
        pre_optimization_bytes: 0,
        post_optimization_bytes: 0,
        saved_bytes: 0,
        count: 0,
        pre_optimization_tokens: 0,
        post_optimization_tokens: 0,
        saved_tokens: 0,
        token_cap_triggers: 0,
      };
      return {
        name: pathName,
        label: this.formatSavingsPathLabel(pathName),
        saved_tokens: bucket.saved_tokens,
        saved_bytes: bucket.saved_bytes,
        count: bucket.count,
        savings_percent: bucket.savings_percent,
      };
    }).filter((entry) => entry.saved_tokens > 0 || entry.saved_bytes > 0);
  }

  private getSelectedWorkspaceEntry(): WorkspaceRegistry | undefined {
    const selected = this.workspaceSelectorService.selectedWorkspacePath();
    if (!selected) {
      return undefined;
    }
    return this.workspaceSelectorService.workspaces().find((ws) => ws.path === selected);
  }

  private formatSavingsPathLabel(pathName: SavingsPathName): string {
    return pathName
      .split('_')
      .map((segment) => segment.charAt(0).toUpperCase() + segment.slice(1))
      .join(' ');
  }

  setFilterKind(value: string): void {
    this.filterKind = this.normalizeKindFilter(value);
    this.recomputeRuntimeOptions(this.summary);
    this.recomputeModelOptions(this.summary);
    this.applyFilters();
    if (this.summary) {
      this.loadDiscoverReports(this.getFilteredPlans(this.summary));
    }
    this.loadSavings();
    this.cdr.markForCheck();
  }

  setFilterRuntime(value: string): void {
    this.filterRuntime = this.normalizeSelection(value);
    this.recomputeModelOptions(this.summary);
    this.applyFilters();
    this.loadSavings();
    this.cdr.markForCheck();
  }

  setFilterModel(value: string): void {
    this.filterModel = this.normalizeSelection(value);
    this.applyFilters();
    this.loadSavings();
    this.cdr.markForCheck();
  }

  setFilterDateFrom(value: string): void {
    this.filterDateFrom = value?.trim() || '';
    this.recomputeRuntimeOptions(this.summary);
    this.recomputeModelOptions(this.summary);
    this.applyFilters();
    this.loadSavings();
    this.cdr.markForCheck();
  }

  setFilterDateTo(value: string): void {
    this.filterDateTo = value?.trim() || '';
    this.recomputeRuntimeOptions(this.summary);
    this.recomputeModelOptions(this.summary);
    this.applyFilters();
    this.loadSavings();
    this.cdr.markForCheck();
  }

  clearFilters(): void {
    this.filterKind = 'all';
    this.filterRuntime = 'all';
    this.filterModel = 'all';
    this.filterDateFrom = '';
    this.filterDateTo = '';
    this.recomputeRuntimeOptions(this.summary);
    this.recomputeModelOptions(this.summary);
    this.applyFilters();
    this.loadSavings();
    this.cdr.markForCheck();
  }

  formatNumber(value: number): string {
    if (!Number.isFinite(value)) {
      return '0';
    }
    return new Intl.NumberFormat().format(Math.round(value));
  }

  formatSeconds(value: number): string {
    return formatElapsedSeconds(value);
  }

  formatPercent(ratio: number): string {
    if (!Number.isFinite(ratio) || ratio <= 0) {
      return '--';
    }
    return `${(ratio * 100).toFixed(1)}%`;
  }

  formatSavingsDateRange(range: { started_at: string | null; ended_at: string | null }): string {
    const started = range.started_at ? range.started_at.split('T')[0] : '';
    const ended = range.ended_at ? range.ended_at.split('T')[0] : '';
    if (started && ended) {
      return `${started} → ${ended}`;
    }
    return started || ended || '';
  }

  formatPeakTurn(tokens: number): string {
    if (!Number.isFinite(tokens) || tokens <= 0) {
      return '--';
    }
    return this.formatNumber(tokens);
  }

  formatOverlayEffective(effective: boolean): string {
    return effective ? 'yes' : 'no';
  }

  formatOverlayWarnings(overlay: RuntimeOverlayMetrics): string {
    if (!overlay.runtime_overlay_warnings.length) {
      return '--';
    }
    return overlay.runtime_overlay_warnings.join('; ');
  }

  private applyFilters(summary = this.summary): void {
    if (!summary) {
      this.runtimeRows = [];
      this.modelRows = [];
      this.statRows = [];
      this.totalRunCount = 0;
      this.filteredRunCount = 0;
      this.detailedBreakdownRuns = 0;
      this.inferredBreakdownRuns = 0;
      this.overlayRunRows = [];
      this.toolCallRunRows = [];
      return;
    }

    let records = this.buildRunRecords(summary);
    records = records.filter((record) => this.passesWorkspaceScopeFilter(record));
    this.totalRunCount = records.length;
    const fromMs = this.parseDateStartMs(this.filterDateFrom);
    const toMs = this.parseDateEndMs(this.filterDateTo);
    const scopedRuns = records
      .filter((record) => this.passesKindFilter(record))
      .filter((record) => this.passesDateFilter(record.startedAtMs, fromMs, toMs));
    const filtered = scopedRuns
      .map((record) => ({
        run: record,
        entries: record.breakdown.filter((entry) => this.matchesRuntimeModel(entry)),
      }))
      .filter((match) => match.entries.length > 0);

    this.filteredRunCount = filtered.length;
    this.detailedBreakdownRuns = filtered.filter((match) => match.run.hasDetailedBreakdown).length;
    this.inferredBreakdownRuns = filtered.length - this.detailedBreakdownRuns;
    this.overlayRunRows = scopedRuns
      .filter((run) => run.item.overlay !== undefined)
      .map((run) => ({
        kind: run.kind,
        plan_key: run.item.plan_key,
        stage_id: run.item.stage_id,
        runtime: run.item.runtime,
        overlay: run.item.overlay as RuntimeOverlayMetrics,
      }))
      .sort((a, b) => a.plan_key.localeCompare(b.plan_key) || (a.stage_id ?? '').localeCompare(b.stage_id ?? ''));

    this.toolCallRunRows = scopedRuns
      .filter((run) => run.item.tool_calls !== undefined)
      .map((run) => ({
        kind: run.kind,
        plan_key: run.item.plan_key,
        stage_id: run.item.stage_id,
        runtime: run.item.runtime,
        tool_calls: run.item.tool_calls as ToolCallClassificationMetrics,
      }))
      .sort((a, b) => a.plan_key.localeCompare(b.plan_key) || (a.stage_id ?? '').localeCompare(b.stage_id ?? ''));

    this.buildBreakdowns(filtered);
  }

  private buildBreakdowns(
    filtered: Array<{
      run: UsageRunRecord;
      entries: ModelBreakdownItem[];
    }>,
  ): void {
    const modelBuckets = new Map<string, MutableModelBucket>();
    const runtimeBuckets = new Map<string, MutableRuntimeBucket>();

    for (const match of filtered) {
      const runKey = match.run.item.path;
      for (const entry of match.entries) {
        const runtime = this.normalizeRuntime(entry.runtime);
        const model = this.normalizeModel(entry.model);
        const modelKey = `${runtime}\u0000${model}`;
        const modelBucket = modelBuckets.get(modelKey) ?? {
          runtime,
          model,
          invocations: 0,
          runKeys: new Set<string>(),
          elapsed_seconds: 0,
          input_tokens: 0,
          output_tokens: 0,
          cache_creation_input_tokens: 0,
          cache_read_input_tokens: 0,
          max_turn_total_tokens: 0,
          tool_calls_total: 0,
        };
        modelBucket.invocations += this.normalizeInvocations(entry.invocations);
        modelBucket.runKeys.add(runKey);
        modelBucket.elapsed_seconds += this.toNumber(entry.elapsed_seconds);
        modelBucket.input_tokens += this.toNumber(entry.input_tokens);
        modelBucket.output_tokens += this.toNumber(entry.output_tokens);
        modelBucket.cache_creation_input_tokens += this.toNumber(entry.cache_creation_input_tokens);
        modelBucket.cache_read_input_tokens += this.toNumber(entry.cache_read_input_tokens);
        modelBucket.tool_calls_total += this.toNumber(entry.tool_calls_total);
        const modelMaxTurn = this.toNumber(entry.max_turn_total_tokens);
        if (modelMaxTurn > modelBucket.max_turn_total_tokens) {
          modelBucket.max_turn_total_tokens = modelMaxTurn;
        }
        modelBuckets.set(modelKey, modelBucket);

        const runtimeBucket = runtimeBuckets.get(runtime) ?? {
          runtime,
          models: new Set<string>(),
          invocations: 0,
          runKeys: new Set<string>(),
          elapsed_seconds: 0,
          input_tokens: 0,
          output_tokens: 0,
          cache_creation_input_tokens: 0,
          cache_read_input_tokens: 0,
          max_turn_total_tokens: 0,
          tool_calls_total: 0,
        };
        runtimeBucket.models.add(model);
        runtimeBucket.invocations += this.normalizeInvocations(entry.invocations);
        runtimeBucket.runKeys.add(runKey);
        runtimeBucket.elapsed_seconds += this.toNumber(entry.elapsed_seconds);
        runtimeBucket.input_tokens += this.toNumber(entry.input_tokens);
        runtimeBucket.output_tokens += this.toNumber(entry.output_tokens);
        runtimeBucket.cache_creation_input_tokens += this.toNumber(entry.cache_creation_input_tokens);
        runtimeBucket.cache_read_input_tokens += this.toNumber(entry.cache_read_input_tokens);
        runtimeBucket.tool_calls_total += this.toNumber(entry.tool_calls_total);
        const runtimeMaxTurn = this.toNumber(entry.max_turn_total_tokens);
        if (runtimeMaxTurn > runtimeBucket.max_turn_total_tokens) {
          runtimeBucket.max_turn_total_tokens = runtimeMaxTurn;
        }
        runtimeBuckets.set(runtime, runtimeBucket);
      }
    }

    this.modelRows = Array.from(modelBuckets.values())
      .map((bucket) => {
        const totalInput = bucket.input_tokens + bucket.cache_creation_input_tokens + bucket.cache_read_input_tokens;
        const totalTokens =
          bucket.input_tokens +
          bucket.output_tokens +
          bucket.cache_creation_input_tokens +
          bucket.cache_read_input_tokens;
        return {
          runtime: bucket.runtime,
          model: bucket.model,
          invocations: bucket.invocations,
          runs: bucket.runKeys.size,
          elapsed_seconds: bucket.elapsed_seconds,
          input_tokens: bucket.input_tokens,
          output_tokens: bucket.output_tokens,
          cache_creation_input_tokens: bucket.cache_creation_input_tokens,
          cache_read_input_tokens: bucket.cache_read_input_tokens,
          max_turn_total_tokens: bucket.max_turn_total_tokens,
          tool_calls_total: bucket.tool_calls_total,
          cache_hit_ratio: totalInput > 0 ? this.round4(bucket.cache_read_input_tokens / totalInput) : 0,
          total_tokens: totalTokens,
        };
      })
      .sort(
        (a, b) =>
          b.total_tokens - a.total_tokens ||
          a.runtime.localeCompare(b.runtime) ||
          a.model.localeCompare(b.model),
      );

    this.runtimeRows = Array.from(runtimeBuckets.values())
      .map((bucket) => {
        const totalInput = bucket.input_tokens + bucket.cache_creation_input_tokens + bucket.cache_read_input_tokens;
        const totalTokens =
          bucket.input_tokens +
          bucket.output_tokens +
          bucket.cache_creation_input_tokens +
          bucket.cache_read_input_tokens;
        return {
          runtime: bucket.runtime,
          model_count: bucket.models.size,
          invocations: bucket.invocations,
          runs: bucket.runKeys.size,
          elapsed_seconds: bucket.elapsed_seconds,
          input_tokens: bucket.input_tokens,
          output_tokens: bucket.output_tokens,
          cache_creation_input_tokens: bucket.cache_creation_input_tokens,
          cache_read_input_tokens: bucket.cache_read_input_tokens,
          max_turn_total_tokens: bucket.max_turn_total_tokens,
          tool_calls_total: bucket.tool_calls_total,
          cache_hit_ratio: totalInput > 0 ? this.round4(bucket.cache_read_input_tokens / totalInput) : 0,
          total_tokens: totalTokens,
        };
      })
      .sort((a, b) => b.total_tokens - a.total_tokens || a.runtime.localeCompare(b.runtime));

    const runtimeTotals = this.runtimeRows.reduce(
      (acc, row) => {
        acc.invocations += row.invocations;
        acc.elapsed_seconds += row.elapsed_seconds;
        acc.input_tokens += row.input_tokens;
        acc.output_tokens += row.output_tokens;
        acc.cache_creation_input_tokens += row.cache_creation_input_tokens;
        acc.cache_read_input_tokens += row.cache_read_input_tokens;
        acc.tool_calls_total += row.tool_calls_total;
        if (row.max_turn_total_tokens > acc.max_turn_total_tokens) {
          acc.max_turn_total_tokens = row.max_turn_total_tokens;
        }
        return acc;
      },
      {
        invocations: 0,
        elapsed_seconds: 0,
        input_tokens: 0,
        output_tokens: 0,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
        max_turn_total_tokens: 0,
        tool_calls_total: 0,
      },
    );

    const totalInput =
      runtimeTotals.input_tokens +
      runtimeTotals.cache_creation_input_tokens +
      runtimeTotals.cache_read_input_tokens;
    const cacheHitRatio = totalInput > 0 ? this.round4(runtimeTotals.cache_read_input_tokens / totalInput) : 0;

    this.statRows = [
      { label: 'Runs', value: this.formatNumber(this.filteredRunCount) },
      { label: 'Invocations', value: this.formatNumber(runtimeTotals.invocations) },
      { label: 'Input Tokens', value: this.formatNumber(runtimeTotals.input_tokens) },
      { label: 'Output Tokens', value: this.formatNumber(runtimeTotals.output_tokens) },
      { label: 'Cache Created', value: this.formatNumber(runtimeTotals.cache_creation_input_tokens) },
      { label: 'Cache Read', value: this.formatNumber(runtimeTotals.cache_read_input_tokens) },
      { label: 'Tool Calls', value: this.formatNumber(runtimeTotals.tool_calls_total) },
      { label: 'Cache Hit', value: this.formatPercent(cacheHitRatio) },
      { label: 'Peak Turn', value: this.formatPeakTurn(runtimeTotals.max_turn_total_tokens) },
      { label: 'Elapsed', value: this.formatSeconds(runtimeTotals.elapsed_seconds) },
    ];
  }

  private buildRunRecords(summary: MetricsSummary): UsageRunRecord[] {
    const records: UsageRunRecord[] = [];
    for (const item of summary.plans) {
      records.push({
        kind: 'plan',
        item,
        breakdown: this.resolveRunBreakdown(item),
        hasDetailedBreakdown: Array.isArray(item.model_breakdown) && item.model_breakdown.length > 0,
        startedAtMs: this.resolveStartedAtMs(item),
      });
    }
    for (const item of summary.orchestrations) {
      records.push({
        kind: 'orchestration',
        item,
        breakdown: this.resolveRunBreakdown(item),
        hasDetailedBreakdown: Array.isArray(item.model_breakdown) && item.model_breakdown.length > 0,
        startedAtMs: this.resolveStartedAtMs(item),
      });
    }
    return records;
  }

  private recomputeRuntimeOptions(summary: MetricsSummary | null): void {
    if (!summary) {
      this.runtimeOptions = [];
      this.filterRuntime = 'all';
      return;
    }
    const fromMs = this.parseDateStartMs(this.filterDateFrom);
    const toMs = this.parseDateEndMs(this.filterDateTo);
    const runtimes = new Set<string>();
    for (const record of this.buildRunRecords(summary).filter((r) => this.passesWorkspaceScopeFilter(r))) {
      if (!this.passesKindFilter(record)) {
        continue;
      }
      if (!this.passesDateFilter(record.startedAtMs, fromMs, toMs)) {
        continue;
      }
      for (const entry of record.breakdown) {
        runtimes.add(this.normalizeRuntime(entry.runtime));
      }
    }
    this.runtimeOptions = Array.from(runtimes.values()).sort((a, b) => a.localeCompare(b));
    if (this.filterRuntime !== 'all' && !this.runtimeOptions.includes(this.filterRuntime)) {
      this.filterRuntime = 'all';
    }
  }

  private recomputeModelOptions(summary: MetricsSummary | null): void {
    if (!summary) {
      this.modelOptions = [];
      this.filterModel = 'all';
      return;
    }
    const fromMs = this.parseDateStartMs(this.filterDateFrom);
    const toMs = this.parseDateEndMs(this.filterDateTo);
    const models = new Set<string>();
    for (const record of this.buildRunRecords(summary).filter((r) => this.passesWorkspaceScopeFilter(r))) {
      if (!this.passesKindFilter(record)) {
        continue;
      }
      if (!this.passesDateFilter(record.startedAtMs, fromMs, toMs)) {
        continue;
      }
      for (const entry of record.breakdown) {
        const runtime = this.normalizeRuntime(entry.runtime);
        if (this.filterRuntime !== 'all' && runtime !== this.filterRuntime) {
          continue;
        }
        models.add(this.normalizeModel(entry.model));
      }
    }
    this.modelOptions = Array.from(models.values()).sort((a, b) => a.localeCompare(b));
    if (this.filterModel !== 'all' && !this.modelOptions.includes(this.filterModel)) {
      this.filterModel = 'all';
    }
  }

  private passesKindFilter(record: UsageRunRecord): boolean {
    return this.filterKind === 'all' || record.kind === this.filterKind;
  }

  private matchesRuntimeModel(entry: ModelBreakdownItem): boolean {
    const runtime = this.normalizeRuntime(entry.runtime);
    const model = this.normalizeModel(entry.model);
    const runtimeMatch = this.filterRuntime === 'all' || runtime === this.filterRuntime;
    const modelMatch = this.filterModel === 'all' || model === this.filterModel;
    return runtimeMatch && modelMatch;
  }

  private passesDateFilter(
    startedAtMs: number | null,
    fromMs: number | null,
    toMs: number | null,
  ): boolean {
    if (fromMs === null && toMs === null) {
      return true;
    }
    if (startedAtMs === null) {
      return false;
    }
    if (fromMs !== null && startedAtMs < fromMs) {
      return false;
    }
    if (toMs !== null && startedAtMs > toMs) {
      return false;
    }
    return true;
  }

  private parseDateStartMs(value: string): number | null {
    if (!value) {
      return null;
    }
    const timestamp = new Date(`${value}T00:00:00`).getTime();
    return Number.isFinite(timestamp) ? timestamp : null;
  }

  private parseDateEndMs(value: string): number | null {
    if (!value) {
      return null;
    }
    const timestamp = new Date(`${value}T23:59:59.999`).getTime();
    return Number.isFinite(timestamp) ? timestamp : null;
  }

  private resolveRunBreakdown(run: MetricsSummaryItem): ModelBreakdownItem[] {
    if (Array.isArray(run.model_breakdown) && run.model_breakdown.length > 0) {
      return run.model_breakdown;
    }

    return [
      {
        runtime: run.runtime || 'unknown',
        model: run.model || '(summary)',
        invocations: 1,
        elapsed_seconds: run.elapsed_seconds,
        input_tokens: run.input_tokens,
        output_tokens: run.output_tokens,
        cache_creation_input_tokens: run.cache_creation_input_tokens,
        cache_read_input_tokens: run.cache_read_input_tokens,
        max_turn_total_tokens: run.max_turn_total_tokens,
        cache_hit_ratio: run.cache_hit_ratio,
      },
    ];
  }

  private resolveStartedAtMs(run: MetricsSummaryItem): number | null {
    const source = run.started_at || run.ended_at;
    if (!source) {
      return null;
    }
    const timestamp = Date.parse(source);
    return Number.isFinite(timestamp) ? timestamp : null;
  }

  private normalizeKindFilter(value: string): UsageKind {
    if (value === 'plan' || value === 'orchestration') {
      return value;
    }
    return 'all';
  }

  private normalizeSelection(value: string): string {
    const normalized = value?.trim() || 'all';
    return normalized.length > 0 ? normalized : 'all';
  }

  private normalizeRuntime(runtime: string): string {
    const value = runtime.trim();
    return value.length > 0 ? value : 'unknown';
  }

  private normalizeModel(model: string): string {
    const value = model.trim();
    return value.length > 0 ? value : '(unspecified)';
  }

  private normalizeInvocations(value: number): number {
    const parsed = this.toNumber(value);
    if (!Number.isFinite(parsed) || parsed <= 0) {
      return 1;
    }
    return Math.max(1, Math.round(parsed));
  }

  private toNumber(value: number | undefined | null): number {
    if (value === undefined || value === null) {
      return 0;
    }
    return Number.isFinite(value) ? value : 0;
  }

  private round4(value: number): number {
    return Math.round(value * 10000) / 10000;
  }

  getWorkspaceDisplayName(metricPath: string): string {
    const workspacePath = this.workspaceSelectorService.getWorkspaceForMetricPath(metricPath);
    if (!workspacePath) {
      return '(unknown)';
    }
    const entry = this.workspaceSelectorService.workspaces().find((w) => w.path === workspacePath);
    return entry?.label ?? (workspacePath.split('/').pop() || workspacePath);
  }

  isShowingAllWorkspaces(): boolean {
    return this.workspaceSelectorService.selectedWorkspacePath() === null &&
           this.workspaceSelectorService.workspaces().length > 1;
  }

  private passesWorkspaceScopeFilter(record: UsageRunRecord): boolean {
    const selected = this.workspaceSelectorService.selectedWorkspacePath();
    if (!selected) {
      return true;
    }
    const entry = this.workspaceSelectorService.workspaces().find((w) => w.path === selected);
    if (!entry?.workspaceRoot) {
      return true;
    }
    return record.item.workspace_root === entry.workspaceRoot;
  }

  private countWorkspaceScopedRecords(summary: MetricsSummary): number {
    let records = this.buildRunRecords(summary);
    records = records.filter((r) => this.passesWorkspaceScopeFilter(r));
    return records.length;
  }
}
