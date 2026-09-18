import { CommonModule } from '@angular/common';
import {
  ChangeDetectionStrategy,
  ChangeDetectorRef,
  Component,
  HostListener,
  effect,
  inject,
  input,
} from '@angular/core';
import { RouterLink } from '@angular/router';
import {
  ApiService,
  MetricsBreakdownResponse,
  MetricsBreakdownRunRow,
  MetricsDetailResponse,
  MetricsInsightsSummary,
  MetricsQueryFilters,
  MetricsRunModelRow,
  MetricsSummaryItem,
  SavingsReport,
  WorkspaceRegistry,
} from '../../services/api.service';
import { WorkspaceSelectorService } from '../../services/workspace-selector.service';
import { RequestLifecycleService } from '../../services/request-lifecycle.service';
import { RouteLoadStateComponent } from '../route-load-state/route-load-state.component';
import { ErrorModalComponent } from '../error-modal/error-modal.component';
import { formatElapsedSeconds } from '../../utils/format-elapsed';
import { isAbortError } from '../../utils/request-lifecycle';
import { markInventoryUsable, markSecondaryReady } from '../../utils/perf-diagnostics';

type UsageKind = 'all' | 'plan' | 'orchestration';
type DrillSection = 'runtime' | 'model' | 'runs' | null;

@Component({
  selector: 'ralph-usage-hub',
  standalone: true,
  imports: [
    CommonModule,
    RouterLink,
    RouteLoadStateComponent,
    ErrorModalComponent,
  ],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="usage-hub hub-page">
      <header class="header page-header">
        <div class="title-wrap">
          <h1 class="page-title">Insights</h1>
          <p class="page-lede">What changed in token use for this workspace.</p>
        </div>
        <div class="header-actions">
          @if (isRefreshing) {
            <div class="insights-busy" role="status" aria-live="polite" data-testid="insights-busy">
              <span class="busy-spinner" aria-hidden="true"></span>
              <span>Updating</span>
            </div>
          }
          <button class="btn btn-ghost" type="button" (click)="refresh()">Refresh</button>
        </div>
      </header>

      @if (summaryLoading && !insights) {
        <ralph-route-load-state [loading]="true" [error]="null" [columns]="3" [rowCount]="4" />
      } @else if (summaryError && !insights) {
        <div class="error" data-testid="insights-summary-error" role="alert">
          <ralph-error-modal class="is-embedded" [error]="summaryError" [embedded]="true" [showHeader]="false" />
          <button type="button" class="btn btn-secondary" data-testid="insights-summary-retry" (click)="loadSummary()">
            Retry
          </button>
        </div>
      } @else if (insights && !hasUsageData) {
        <div class="empty-state" data-testid="insights-empty">
          <p class="empty-title">No usage in this scope</p>
          <p class="empty-hint">
            Run a plan or workflow to collect tokens, elapsed time, and tool calls. Filters stay available if you
            already have data outside the current scope.
          </p>
          <div class="empty-actions">
            <a class="btn btn-secondary" routerLink="/plans">Open plans</a>
            @if (hasActiveFilters) {
              <button type="button" class="btn btn-ghost" (click)="clearFilters()">Clear filters</button>
            }
          </div>
        </div>
      } @else if (insights) {
        <section class="answer-panel hub-panel-card" aria-label="Insights summary" data-testid="insights-summary">
          @if (summaryError) {
            <div class="inline-error" role="alert">
              <ralph-error-modal class="is-embedded" [error]="summaryError" [embedded]="true" [showHeader]="false" />
              <button type="button" class="btn btn-ghost" data-testid="insights-summary-retry" (click)="loadSummary()">
                Retry
              </button>
            </div>
          }
          <div class="answer-headline">
            <p class="eyebrow">What changed</p>
            <p class="trend-sentence" [attr.data-direction]="insights.trend.direction">
              {{ trendSentence(insights) }}
            </p>
            <p class="scope-meta">
              {{ insights.date_scope.label }}
              · {{ formatNumber(insights.date_scope.run_count) }} runs
              · {{ insights.units.tokens }}
            </p>
          </div>

          <div class="trend-chart" data-testid="insights-trend-chart" aria-label="Prior versus recent token volume">
            <div class="trend-bar-row">
              <span class="trend-bar-label">Prior</span>
              <span class="trend-bar-track">
                <span class="trend-bar is-prior" [style.width.%]="trendShare(insights.trend.prior_tokens)"></span>
              </span>
              <span class="trend-bar-value" [title]="formatNumber(insights.trend.prior_tokens)">
                {{ formatCompact(insights.trend.prior_tokens) }}
              </span>
            </div>
            <div class="trend-bar-row">
              <span class="trend-bar-label">Recent</span>
              <span class="trend-bar-track">
                <span
                  class="trend-bar is-recent"
                  [attr.data-direction]="insights.trend.direction"
                  [style.width.%]="trendShare(insights.trend.recent_tokens)"
                ></span>
              </span>
              <span class="trend-bar-value" [title]="formatNumber(insights.trend.recent_tokens)">
                {{ formatCompact(insights.trend.recent_tokens) }}
              </span>
            </div>
          </div>

          <div class="headline-grid">
            <div class="metric-tile hub-nested-panel">
              <div class="metric-label">Total tokens</div>
              <div class="metric-value" [title]="formatNumber(insights.headline.total_tokens)">
                {{ formatCompact(insights.headline.total_tokens) }}
              </div>
              <p class="metric-sub">
                {{ formatCompact(insights.headline.input_tokens) }} in /
                {{ formatCompact(insights.headline.output_tokens) }} out /
                {{ formatCompact(insights.headline.cache_read_input_tokens) }} cache
              </p>
            </div>
            <div class="metric-tile hub-nested-panel">
              <div class="metric-label">Elapsed</div>
              <div class="metric-value">{{ formatSeconds(insights.headline.elapsed_seconds) }}</div>
              <p class="metric-sub">{{ formatNumber(insights.headline.run_count) }} runs</p>
            </div>
            <div class="metric-tile hub-nested-panel">
              <div class="metric-label">Cache hit</div>
              <div class="metric-value">{{ formatPercent(insights.headline.cache_hit_ratio) }}</div>
              <p class="metric-sub">{{ formatCompact(insights.headline.tool_calls_total) }} tool calls</p>
            </div>
          </div>

          <div class="drivers-block hub-nested-panel">
            <h2>Cost drivers</h2>
            @if (insights.drivers.length === 0) {
              <p class="quiet-empty">No concentrated drivers in this scope.</p>
            } @else {
              <ul class="driver-list">
                @for (driver of insights.drivers; track driver.kind + '-' + driver.exact_value) {
                  <li>
                    <div class="driver-copy">
                      <span class="driver-kind">{{ driver.kind }}</span>
                      <span class="driver-label" [title]="driver.exact_value">{{ driver.label }}</span>
                      <span class="driver-meta">
                        {{ formatCompact(driver.total_tokens) }}
                        ({{ driver.share_percent }}%) · {{ formatNumber(driver.runs) }} runs
                      </span>
                    </div>
                    <span class="driver-share-track" aria-hidden="true">
                      <span class="driver-share-fill" [style.width.%]="driver.share_percent"></span>
                    </span>
                    <span class="sr-only">Exact value: {{ driver.exact_value }}</span>
                  </li>
                }
              </ul>
            }
          </div>

          @if (insights.anomalies.length > 0) {
            <div class="anomalies-block hub-nested-panel">
              <h2>Watch</h2>
              <ul class="anomaly-list">
                @for (anomaly of insights.anomalies; track anomaly.code) {
                  <li [attr.data-severity]="anomaly.severity">{{ anomaly.message }}</li>
                }
              </ul>
            </div>
          }

          @if (insights.drilldowns.length > 0) {
            <div class="drilldown-links" aria-label="Drill-down links">
              <div class="drilldown-actions">
                @for (link of insights.drilldowns; track link.id) {
                  <button
                    class="btn btn-ghost"
                    type="button"
                    (click)="openDrilldown(link.id)"
                    [attr.data-testid]="'drilldown-' + link.id"
                  >
                    {{ link.label }}
                  </button>
                }
              </div>
            </div>
          }
        </section>
      }

      <section class="filters-section hub-panel-card" aria-label="Refine scope" data-testid="insights-filters">
        <div class="section-head filters-header">
          <h2 class="section-legend">Refine scope</h2>
          <p class="section-hint filters-summary-meta">
            @if (insights) {
              {{ insights.date_scope.label }} · {{ formatNumber(insights.date_scope.run_count) }} runs
            } @else {
              Kind, runtime, model, dates
            }
          </p>
        </div>
        <div class="filters-toolbar">
          <label class="filter-field">
            <span>Kind</span>
            <select
              class="filter-select"
              [value]="filterKind"
              (change)="setFilterKind($any($event.target).value)"
            >
              <option value="all">All</option>
              <option value="plan">Plans</option>
              <option value="orchestration">Orchestrations</option>
            </select>
          </label>
          <label class="filter-field">
            <span>Runtime</span>
            <select
              class="filter-select"
              [value]="filterRuntime"
              (change)="setFilterRuntime($any($event.target).value)"
            >
              <option value="all">All</option>
              @for (runtime of runtimeOptions; track runtime) {
                <option [value]="runtime">{{ runtime }}</option>
              }
            </select>
          </label>
          <label class="filter-field">
            <span>Model</span>
            <select
              class="filter-select"
              [value]="filterModel"
              (change)="setFilterModel($any($event.target).value)"
            >
              <option value="all">All</option>
              @for (model of modelOptions; track model.exact_value) {
                <option [value]="model.exact_value" [title]="model.exact_value">{{ model.label }}</option>
              }
            </select>
          </label>
          <label class="filter-field">
            <span>From</span>
            <input
              class="filter-select"
              type="date"
              [value]="filterDateFrom"
              (change)="setFilterDateFrom($any($event.target).value)"
            />
          </label>
          <label class="filter-field">
            <span>To</span>
            <input
              class="filter-select"
              type="date"
              [value]="filterDateTo"
              (change)="setFilterDateTo($any($event.target).value)"
            />
          </label>
          @if (hasActiveFilters) {
            <button class="btn btn-ghost filter-clear" type="button" (click)="clearFilters()">Clear filters</button>
          }
        </div>
      </section>

      @if (insights && hasUsageData) {
      <section class="breakdown-section hub-panel-card" aria-label="Usage breakdown tables" data-testid="insights-breakdown">
        <div class="breakdown-header section-head">
          <h2 class="section-legend">Breakdown</h2>
          <div class="breakdown-actions">
            @if (breakdownLoading && breakdown) {
              <span class="quiet-empty">Updating tables</span>
            }
            @if (breakdown) {
              <button class="btn btn-ghost" type="button" (click)="downloadBreakdownCsv()">
                Download CSV
              </button>
            }
          </div>
        </div>

        @if (breakdownLoading && !breakdown) {
          <div data-testid="insights-breakdown-loading">
            <ralph-route-load-state [loading]="true" [error]="null" [columns]="5" [rowCount]="5" />
          </div>
        } @else if (breakdownError && !breakdown) {
          <div class="error" data-testid="insights-breakdown-error" role="alert">
            <ralph-error-modal class="is-embedded" [error]="breakdownError" [embedded]="true" [showHeader]="false" />
            <button type="button" class="btn btn-secondary" data-testid="insights-breakdown-retry" (click)="loadBreakdown()">
              Retry
            </button>
          </div>
        } @else if (breakdown) {
          <p class="scope-meta">
            Showing {{ formatNumber(breakdown.filtered_run_count) }} of
            {{ formatNumber(breakdown.total_run_count) }} runs ·
            {{ breakdown.date_scope.label }}
          </p>

          <div class="tables-grid">
            <details
              class="breakdown-panel hub-nested-panel"
              open
              data-testid="insights-panel-runtime"
              [class.is-highlighted]="activeDrill === 'runtime'"
            >
              <summary class="breakdown-panel-summary">
                <span class="breakdown-panel-title">Runtime breakdown</span>
                <span class="breakdown-panel-meta">{{ breakdown.runtime_rows.length }} runtimes</span>
              </summary>
              <div class="breakdown-panel-body">
                @if (breakdown.runtime_rows.length === 0) {
                  <div class="empty">No runtime-level usage data.</div>
                } @else {
                  <div class="usage-table-wrap">
                    <div class="usage-table" role="table" aria-label="Runtime breakdown">
                      <div class="usage-row usage-header runtime-columns" role="row">
                        <span role="columnheader">Runtime</span>
                        <span role="columnheader">Models</span>
                        <span role="columnheader">Runs</span>
                        <span role="columnheader">Total tokens</span>
                        <span role="columnheader">Tool calls</span>
                        <span role="columnheader">Cache hit</span>
                      </div>
                      @for (row of breakdown.runtime_rows; track row.runtime) {
                        <div class="usage-row runtime-columns" role="row">
                          <span class="mono cell-clip" data-label="Runtime" [title]="row.runtime">{{
                            row.runtime
                          }}</span>
                          <span data-label="Models">{{ row.model_count ?? 0 }}</span>
                          <span data-label="Runs">{{ formatNumber(row.runs) }}</span>
                          <span data-label="Total tokens" class="mono">{{
                            formatNumber(row.total_tokens)
                          }}</span>
                          <span data-label="Tool calls">{{ formatNumber(row.tool_calls_total) }}</span>
                          <span data-label="Cache hit">{{ formatPercent(row.cache_hit_ratio) }}</span>
                        </div>
                      }
                    </div>
                  </div>
                }
              </div>
            </details>

            <details
              class="breakdown-panel hub-nested-panel"
              data-testid="insights-panel-model"
              [class.is-highlighted]="activeDrill === 'model'"
            >
              <summary class="breakdown-panel-summary">
                <span class="breakdown-panel-title">Model breakdown</span>
                <span class="breakdown-panel-meta">{{ breakdown.model_rows.length }} runtime/model buckets</span>
              </summary>
              <div class="breakdown-panel-body">
                @if (breakdown.model_rows.length === 0) {
                  <div class="empty">No model-level usage data.</div>
                } @else {
                  <div class="usage-table-wrap">
                    <div class="usage-table" role="table" aria-label="Model breakdown">
                      <div class="usage-row usage-header model-columns" role="row">
                        <span role="columnheader">Runtime</span>
                        <span role="columnheader">Model</span>
                        <span role="columnheader">Runs</span>
                        <span role="columnheader">Total tokens</span>
                        <span role="columnheader">Tool calls</span>
                        <span role="columnheader">Cache hit</span>
                      </div>
                      @for (row of breakdown.model_rows; track row.runtime + '-' + row.model_exact) {
                        <div class="usage-row model-columns" role="row">
                          <span class="mono cell-clip" data-label="Runtime" [title]="row.runtime">{{
                            row.runtime
                          }}</span>
                          <span
                            class="cell-clip"
                            data-label="Model"
                            [title]="row.model_exact || row.model || ''"
                          >
                            {{ row.model_label || row.model || 'Unspecified model' }}
                            <span class="exact-hint">{{ row.model_exact || row.model }}</span>
                          </span>
                          <span data-label="Runs">{{ formatNumber(row.runs) }}</span>
                          <span data-label="Total tokens" class="mono">{{
                            formatNumber(row.total_tokens)
                          }}</span>
                          <span data-label="Tool calls">{{ formatNumber(row.tool_calls_total) }}</span>
                          <span data-label="Cache hit">{{ formatPercent(row.cache_hit_ratio) }}</span>
                        </div>
                      }
                    </div>
                  </div>
                }
              </div>
            </details>

            <details
              class="breakdown-panel hub-nested-panel"
              data-testid="insights-panel-runs"
              [class.is-highlighted]="activeDrill === 'runs'"
            >
              <summary class="breakdown-panel-summary">
                <span class="breakdown-panel-title">Run table</span>
                <span class="breakdown-panel-meta">
                  Page {{ pageLabel }} · sort {{ breakdown.sort.by }} {{ breakdown.sort.dir }}
                </span>
              </summary>
              <div class="breakdown-panel-body">
                @if (breakdown.run_rows.length === 0) {
                  <div class="empty">No runs for this filter.</div>
                } @else {
                  <div class="usage-table-wrap">
                    <div class="usage-table" role="table" aria-label="Run table">
                      <div class="usage-row usage-header run-columns" role="row">
                        <span role="columnheader">
                          <button type="button" class="sort-btn" (click)="sortRuns('plan_key')">Plan</button>
                        </span>
                        <span role="columnheader">Runtime</span>
                        <span role="columnheader">Model</span>
                        <span role="columnheader">
                          <button type="button" class="sort-btn" (click)="sortRuns('total_tokens')">
                            Total tokens
                          </button>
                        </span>
                        <span role="columnheader">Tool calls</span>
                        <span role="columnheader">Elapsed</span>
                        <span role="columnheader">Detail</span>
                      </div>
                      @for (row of breakdown.run_rows; track row.path) {
                        <div
                          class="usage-row run-columns is-clickable"
                          role="row"
                          tabindex="0"
                          [attr.aria-label]="'Open run detail for ' + row.plan_key"
                          [attr.data-testid]="'run-row-' + row.plan_key"
                          (click)="loadDetail(row.plan_key)"
                          (keydown.enter)="loadDetail(row.plan_key)"
                          (keydown.space)="$event.preventDefault(); loadDetail(row.plan_key)"
                        >
                          <span class="mono cell-clip" data-label="Plan" [title]="row.plan_key">{{
                            row.plan_key
                          }}</span>
                          <span class="mono cell-clip" data-label="Runtime" [title]="row.runtime">{{
                            row.runtime
                          }}</span>
                          <span class="cell-clip" data-label="Model" [title]="runModelsTitle(row)">
                            {{ row.model_label }}
                            @if (extraModelCount(row); as extra) {
                              <span class="more-models" [attr.data-testid]="'models-more-' + row.plan_key"
                                >+{{ extra }} more</span
                              >
                            }
                            <span class="exact-hint">{{ row.model_exact }}</span>
                          </span>
                          <span data-label="Total tokens" class="mono">{{
                            formatNumber(row.total_tokens)
                          }}</span>
                          <span data-label="Tool calls">{{ formatNumber(row.tool_calls_total) }}</span>
                          <span data-label="Elapsed">{{ formatSeconds(row.elapsed_seconds) }}</span>
                          <span data-label="Detail">
                            <button
                              class="btn-link"
                              type="button"
                              (click)="$event.stopPropagation(); loadDetail(row.plan_key)"
                              [attr.data-testid]="'detail-' + row.plan_key"
                            >
                              Inspect
                            </button>
                          </span>
                        </div>
                      }
                    </div>
                  </div>
                  <div class="pager">
                    <button
                      class="btn btn-secondary"
                      type="button"
                      [disabled]="pageOffset <= 0"
                      (click)="prevPage()"
                    >
                      Previous
                    </button>
                    <span>{{ pageLabel }}</span>
                    <button
                      class="btn btn-secondary"
                      type="button"
                      [disabled]="!hasNextPage"
                      (click)="nextPage()"
                    >
                      Next
                    </button>
                  </div>
                }
              </div>
            </details>
          </div>
        }
      </section>
      }

      @if (detailLoading || detailError || detail) {
        <div class="hub-modal-backdrop" data-testid="insights-detail-modal" (click)="closeDetail()">
          <section
            class="detail-modal hub-modal-panel hub-modal-panel--compact"
            role="dialog"
            aria-modal="true"
            aria-label="Run detail"
            (click)="$event.stopPropagation()"
          >
            <header class="detail-modal-header">
              <div>
                <p class="eyebrow">Run detail</p>
                @if (detail) {
                  <h2>{{ detail.plan_key }}</h2>
                } @else {
                  <h2>Loading run</h2>
                }
              </div>
              <button type="button" class="detail-modal-close" aria-label="Close run detail" (click)="closeDetail()">Close</button>
            </header>
            @if (detailLoading) {
              <div class="loading" data-testid="insights-detail-loading">Loading run detail...</div>
            } @else if (detailError) {
              <div class="error" role="alert">
                <ralph-error-modal class="is-embedded" [error]="detailError" [embedded]="true" [showHeader]="false" />
              </div>
            } @else if (detail) {
              <section class="detail-panel" aria-label="Run detail" data-testid="insights-detail">
                @if (!detail.item) {
                  <p class="empty">No detail found for this plan key in the selected project.</p>
                } @else {
                  <p class="detail-meta">{{ detail.kind }} · {{ detail.item.runtime || '(unspecified)' }}</p>
                  <a
                    class="detail-plan-link"
                    [routerLink]="['/plan-detail', detail.item.plan_key]"
                    [queryParams]="{ projectRoot: detail.item.project_root }"
                    (click)="closeDetail()"
                    data-testid="insights-detail-plan-link"
                  >
                    Open plan
                  </a>
                  @if (detailModelRows(detail.item); as modelRows) {
                    <div class="detail-models" data-testid="insights-detail-models">
                      <h3 class="detail-models-title">
                        Models used
                        <span class="detail-models-meta">{{ modelRows.length }}</span>
                      </h3>
                      <div class="usage-table-wrap">
                        <div class="usage-table detail-models-table" role="table" aria-label="Models used in this run">
                          <div class="usage-row usage-header detail-model-columns" role="row">
                            <span role="columnheader">Model</span>
                            <span role="columnheader">Runtime</span>
                            <span role="columnheader">Invocations</span>
                            <span role="columnheader">Input</span>
                            <span role="columnheader">Output</span>
                            <span role="columnheader">Cache read</span>
                            <span role="columnheader">Total</span>
                            <span role="columnheader">Tool calls</span>
                            <span role="columnheader">Elapsed</span>
                          </div>
                          @for (row of modelRows; track row.runtime + '-' + row.model_exact) {
                            <div class="usage-row detail-model-columns" role="row">
                              <span class="cell-clip" data-label="Model" [title]="row.model_exact">
                                {{ row.model_label }}
                                @if (showExactModelHint(row.model_label, row.model_exact)) {
                                  <span class="exact-hint">{{ row.model_exact }}</span>
                                }
                              </span>
                              <span class="mono cell-clip" data-label="Runtime">{{ row.runtime }}</span>
                              <span data-label="Invocations">{{ formatNumber(row.invocations) }}</span>
                              <span class="mono" data-label="Input">{{ formatNumber(row.input_tokens) }}</span>
                              <span class="mono" data-label="Output">{{ formatNumber(row.output_tokens) }}</span>
                              <span class="mono" data-label="Cache read">{{
                                formatNumber(row.cache_read_input_tokens)
                              }}</span>
                              <span class="mono" data-label="Total">{{ formatNumber(row.total_tokens) }}</span>
                              <span data-label="Tool calls">{{ formatNumber(row.tool_calls_total) }}</span>
                              <span data-label="Elapsed">{{ formatSeconds(row.elapsed_seconds) }}</span>
                            </div>
                          }
                        </div>
                      </div>
                    </div>
                  } @else {
                    <div class="metric-line">
                      <span>Model</span>
                      <span [title]="detail.item.model || ''">
                        {{ friendlyModel(detail.item.model) }}
                        @if (showExactModelHint(friendlyModel(detail.item.model), detail.item.model || '')) {
                          <span class="exact-hint">{{ detail.item.model || '(unspecified)' }}</span>
                        }
                      </span>
                    </div>
                  }
                  <div class="detail-summary-metrics">
                    <div class="metric-line">
                      <span>Tokens</span>
                      <span>{{
                        formatNumber(
                          detail.item.input_tokens +
                            detail.item.output_tokens +
                            detail.item.cache_creation_input_tokens +
                            detail.item.cache_read_input_tokens
                        )
                      }}</span>
                    </div>
                    <div class="metric-line">
                      <span>Elapsed</span>
                      <span>{{ formatSeconds(detail.item.elapsed_seconds) }}</span>
                    </div>
                    <div class="metric-line">
                      <span>Started</span>
                      <span>{{ detail.item.started_at || '--' }}</span>
                    </div>
                  </div>
                }
              </section>
            }
          </section>
        </div>
      }

      @if (insights && hasUsageData) {
      <section class="savings-panel hub-panel-card" aria-label="Benchmark overview">
        <div class="savings-panel-header section-head">
          <h2 class="section-legend">Benchmark</h2>
          @if (savingsReport?.run_count; as runCount) {
            <span class="savings-panel-meta">Measured across {{ runCount }} runs</span>
          }
        </div>
        @if (savingsLoading && !savingsReport) {
          <p class="quiet-empty">Loading benchmark data...</p>
        } @else if (savingsError && !savingsReport) {
          <div class="error" role="alert">
            <ralph-error-modal class="is-embedded" [error]="savingsError" [embedded]="true" [showHeader]="false" />
          </div>
        } @else if (savingsReport) {
          <div class="headline-grid">
            <div class="metric-tile hub-nested-panel">
              <div class="metric-label">Kept out of model context</div>
              <div class="metric-value" [title]="formatNumber(savingsReport.saved_tokens)">
                ~{{ formatCompact(savingsReport.saved_tokens) }} tokens
              </div>
            </div>
            <div class="metric-tile hub-nested-panel">
              <div class="metric-label">Tool output savings</div>
              <div class="metric-value">
                {{ savingsReport.tool_output_counterfactual.net_savings_percent }}%
              </div>
            </div>
          </div>
        } @else {
          <p class="quiet-empty">Benchmark data is unavailable for this workspace.</p>
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
      display: grid;
      gap: var(--space-4);
      align-content: start;
    }
    .header {
      display: flex;
      justify-content: space-between;
      align-items: flex-start;
      gap: var(--space-4);
      flex-wrap: wrap;
      margin-bottom: 0;
    }
    .header-actions,
    .breakdown-actions,
    .drilldown-actions,
    .pager {
      display: flex;
      gap: 0.5rem;
      flex-wrap: wrap;
      align-items: center;
    }
    .insights-busy {
      display: inline-flex;
      align-items: center;
      justify-self: start;
      gap: 0.5rem;
      padding: 0.4rem 0.65rem;
      border: 1px solid color-mix(in srgb, var(--accent) 35%, var(--border));
      border-radius: 999px;
      background: color-mix(in srgb, var(--accent) 10%, var(--surface));
      color: var(--text-secondary);
      font-size: 0.78rem;
      font-weight: 600;
    }
    .busy-spinner {
      width: 0.8rem;
      height: 0.8rem;
      border: 2px solid color-mix(in srgb, var(--accent) 25%, transparent);
      border-top-color: var(--accent);
      border-radius: 50%;
      animation: insights-spin 0.7s linear infinite;
    }
    @keyframes insights-spin {
      to { transform: rotate(360deg); }
    }
    .answer-panel {
      gap: 1rem;
      background: linear-gradient(
        180deg,
        color-mix(in srgb, var(--accent) 10%, var(--ion-color-step-50, #0d1117)),
        var(--ion-color-step-50, #0d1117) 48%
      );
      border-color: color-mix(in srgb, var(--accent) 32%, var(--ion-color-step-200, #30363d));
    }
    .detail-panel {
      display: grid;
      gap: 0.85rem;
    }
    .breakdown-section,
    .savings-panel,
    .filters-section {
      gap: 0.85rem;
    }
    .filters-header {
      display: flex;
      justify-content: space-between;
      gap: 0.75rem;
      flex-wrap: wrap;
      align-items: baseline;
      margin-bottom: 0;
    }
    .filters-summary-meta {
      margin: 0;
    }
    .filters-toolbar {
      display: flex;
      flex-wrap: wrap;
      gap: var(--space-3);
      margin: 0;
      align-items: end;
    }
    .filter-clear {
      align-self: end;
      min-height: var(--touch-target-min, 44px);
    }
    [data-testid='insights-detail-modal'] {
      z-index: 1000;
    }
    .detail-modal {
      position: relative;
      width: min(100%, 56rem);
      max-height: min(48rem, calc(100vh - 2rem));
      isolation: isolate;
      overflow: auto;
    }
    .detail-meta {
      margin: 0;
      color: var(--text-muted);
      font-size: 0.9rem;
    }
    .detail-modal-header {
      display: flex;
      align-items: flex-start;
      justify-content: space-between;
      gap: 1rem;
      margin-bottom: 1rem;
    }
    .detail-modal-header .eyebrow {
      margin-bottom: 0.2rem;
    }
    .detail-modal-header h2 {
      margin: 0;
      color: var(--text-primary);
      font-size: 1.25rem;
      line-height: 1.25;
      overflow-wrap: anywhere;
    }
    .detail-modal-close {
      flex: 0 0 auto;
      min-height: var(--touch-target-min, 44px);
      padding: 0.4rem 0.75rem;
      border: 1px solid var(--border);
      border-radius: 6px;
      background: var(--surface);
      color: var(--text-primary);
      cursor: pointer;
    }
    .detail-modal-close:focus-visible {
      outline: var(--focus-ring-width, 2px) solid var(--focus-ring-color, var(--accent));
      outline-offset: var(--focus-ring-offset, 2px);
    }
    .detail-modal .detail-panel {
      border: 0;
      padding: 0;
      background: transparent;
    }
    .detail-plan-link {
      display: inline-flex;
      margin: 0;
      color: var(--accent);
      font-size: 0.9rem;
      font-weight: 600;
      text-decoration: underline;
    }
    .detail-plan-link:focus-visible {
      outline: var(--focus-ring-width, 2px) solid var(--focus-ring-color, var(--accent));
      outline-offset: var(--focus-ring-offset, 2px);
    }
    .filter-field {
      display: flex;
      flex-direction: column;
      gap: 0.35rem;
      min-width: min(100%, 9.5rem);
      font-size: var(--font-size-sm);
      font-weight: 600;
      color: var(--text-primary);
    }
    .filter-field span {
      font-size: var(--font-size-xs);
      font-weight: 700;
      text-transform: uppercase;
      letter-spacing: var(--letter-label);
    }
    .scope-meta,
    .metric-sub,
    .savings-panel-meta {
      color: var(--text-muted);
      font-size: 0.82rem;
    }
    .breakdown-header h2,
    .detail-panel h3,
    .savings-panel-header h2,
    .drivers-block h2,
    .anomalies-block h2 {
      margin: 0;
      font-size: var(--font-size-md);
      font-weight: 600;
    }
    .eyebrow {
      margin: 0;
      color: var(--accent);
      font-size: 0.72rem;
      font-weight: 700;
      letter-spacing: 0.1em;
      text-transform: uppercase;
    }
    .breakdown-header,
    .savings-panel-header {
      display: flex;
      justify-content: space-between;
      gap: 0.75rem;
      flex-wrap: wrap;
      align-items: flex-start;
      margin-bottom: 0.15rem;
    }
    .trend-sentence {
      margin: 0.4rem 0 0;
      color: var(--text-primary);
      font-size: clamp(1.25rem, 2.4vw, 1.85rem);
      font-weight: 650;
      line-height: 1.25;
      letter-spacing: -0.02em;
    }
    .trend-chart {
      display: grid;
      gap: 0.45rem;
      max-width: 36rem;
    }
    .trend-bar-row {
      display: grid;
      grid-template-columns: 4.2rem minmax(0, 1fr) auto;
      gap: 0.55rem;
      align-items: center;
    }
    .trend-bar-label,
    .trend-bar-value {
      color: var(--text-muted);
      font-size: 0.75rem;
    }
    .trend-bar-value {
      font-variant-numeric: tabular-nums;
      min-width: 3.2rem;
      text-align: right;
    }
    .trend-bar-track {
      display: block;
      height: 0.55rem;
      overflow: hidden;
      border-radius: 999px;
      background: var(--surface-hover, rgba(255, 255, 255, 0.06));
    }
    .trend-bar {
      display: block;
      height: 100%;
      min-width: 0.35rem;
      border-radius: inherit;
      background: color-mix(in srgb, var(--text-muted) 55%, transparent);
    }
    .trend-bar.is-recent[data-direction='up'] {
      background: var(--accent);
    }
    .trend-bar.is-recent[data-direction='down'] {
      background: color-mix(in srgb, var(--accent) 55%, #16a34a);
    }
    .trend-bar.is-recent[data-direction='flat'],
    .trend-bar.is-recent[data-direction='unknown'] {
      background: color-mix(in srgb, var(--accent) 70%, var(--text-muted));
    }
    .headline-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
      gap: 0.65rem;
    }
    .metric-tile {
      min-width: 0;
      padding: 0.7rem 0.8rem;
    }
    .inline-error {
      display: flex;
      flex-wrap: wrap;
      gap: 0.5rem 0.75rem;
      align-items: center;
      padding: 0.55rem 0.7rem;
      border: 1px solid var(--error, #f85149);
      border-radius: 6px;
      color: var(--error, #f85149);
      font-size: 0.85rem;
    }
    .quiet-empty {
      margin: 0;
      color: var(--text-muted);
      font-size: 0.85rem;
    }
    .metric-label {
      color: var(--text-muted);
      font-size: 0.75rem;
      text-transform: uppercase;
      letter-spacing: 0.03em;
    }
    .metric-value {
      font-size: clamp(1.05rem, 2vw, 1.35rem);
      font-weight: 600;
      margin-top: 0.2rem;
      overflow-wrap: anywhere;
    }
    .metric-sub {
      margin: 0.35rem 0 0;
    }
    .driver-list,
    .anomaly-list {
      list-style: none;
      margin: 0;
      padding: 0;
      display: grid;
      gap: 0.45rem;
    }
    .driver-list li,
    .anomaly-list li {
      display: grid;
      gap: 0.35rem;
      border: 0;
      border-radius: 0;
      padding: 0.35rem 0;
      background: transparent;
    }
    .driver-copy {
      display: flex;
      flex-wrap: wrap;
      gap: 0.35rem 0.7rem;
      align-items: baseline;
    }
    .driver-share-track {
      display: block;
      height: 0.35rem;
      overflow: hidden;
      border-radius: 999px;
      background: var(--surface-hover, rgba(255, 255, 255, 0.06));
    }
    .driver-share-fill {
      display: block;
      height: 100%;
      border-radius: inherit;
      background: color-mix(in srgb, var(--accent) 55%, var(--border));
    }
    .anomaly-list li {
      border-left: 3px solid #b45309;
      padding-left: 0.65rem;
    }
    .driver-kind {
      text-transform: uppercase;
      font-size: 0.7rem;
      color: var(--text-muted);
      letter-spacing: 0.04em;
    }
    .driver-label {
      font-weight: 600;
    }
    .driver-meta,
    .exact-hint {
      color: var(--text-muted);
      font-size: 0.8rem;
    }
    .exact-hint {
      display: block;
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      overflow-wrap: anywhere;
    }
    .anomaly-list li[data-severity='warn'] {
      border-color: #b45309;
    }
    .tables-grid {
      display: grid;
      gap: 0.65rem;
    }
    .breakdown-panel {
      padding: 0;
      gap: 0;
      overflow: hidden;
    }
    .breakdown-panel.is-highlighted {
      border-color: color-mix(in srgb, var(--accent) 55%, var(--border));
      box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--accent) 35%, transparent);
    }
    .breakdown-panel-summary {
      display: grid;
      grid-template-columns: auto minmax(0, 1fr) auto;
      gap: 0.55rem 0.75rem;
      align-items: center;
      padding: 0.7rem 0.85rem;
      cursor: pointer;
      list-style: none;
      min-height: var(--touch-target-min, 44px);
      user-select: none;
    }
    .breakdown-panel-summary::-webkit-details-marker {
      display: none;
    }
    .breakdown-panel-summary::before {
      content: '';
      width: 0.4rem;
      height: 0.4rem;
      border-right: 1.5px solid var(--text-muted);
      border-bottom: 1.5px solid var(--text-muted);
      transform: rotate(-45deg);
      transition: transform 0.12s ease;
    }
    .breakdown-panel[open] > .breakdown-panel-summary::before {
      transform: rotate(45deg);
    }
    .breakdown-panel-title {
      font-size: 0.92rem;
      font-weight: 600;
      color: var(--text-primary);
    }
    .breakdown-panel-meta {
      color: var(--text-muted);
      font-size: 0.78rem;
      text-align: right;
    }
    .breakdown-panel-body {
      display: grid;
      gap: 0.75rem;
      padding: 0 0.85rem 0.85rem;
    }
    .usage-table-wrap {
      width: 100%;
      overflow-x: auto;
      -webkit-overflow-scrolling: touch;
    }
    .usage-table {
      display: grid;
      gap: 0;
      min-width: 0;
      overflow: hidden;
      border: 1px solid var(--border);
      border-radius: var(--radius-md);
    }
    .usage-row {
      display: grid;
      gap: 0.5rem;
      align-items: center;
      padding: 0.65rem 0.75rem;
      border-bottom: 1px solid color-mix(in srgb, var(--border) 88%, transparent);
      font-size: 0.85rem;
    }
    .usage-header {
      background: var(--table-header-bg);
      color: var(--text-muted);
      font-size: 0.75rem;
      text-transform: uppercase;
      letter-spacing: 0.03em;
      border-bottom-width: 2px;
    }
    .usage-row:not(.usage-header):nth-child(even) {
      background: color-mix(in srgb, var(--surface-hover) 55%, transparent);
    }
    .usage-row:not(.usage-header):hover {
      background: var(--table-row-hover);
    }
    .runtime-columns,
    .model-columns {
      grid-template-columns: minmax(0, 1.4fr) repeat(5, minmax(0, 1fr));
    }
    .run-columns {
      grid-template-columns: minmax(0, 1.4fr) minmax(0, 1fr) minmax(0, 1.3fr) repeat(3, minmax(0, 1fr)) auto;
    }
    .usage-row.is-clickable {
      cursor: pointer;
    }
    .usage-row.is-clickable:focus-visible {
      outline: 2px solid var(--accent);
      outline-offset: -2px;
    }
    .more-models {
      display: inline-block;
      margin-left: 0.35rem;
      padding: 0 0.35rem;
      border-radius: 999px;
      background: color-mix(in srgb, var(--accent) 16%, transparent);
      color: var(--accent);
      font-size: 0.72rem;
      white-space: nowrap;
    }
    .detail-models {
      margin-top: var(--space-3);
    }
    .detail-models-title {
      display: flex;
      align-items: center;
      gap: 0.4rem;
      margin: 0 0 0.35rem;
      font-size: 0.9rem;
    }
    .detail-models-meta {
      color: var(--text-muted);
      font-size: 0.78rem;
    }
    .detail-models-table {
      min-width: 52rem;
    }
    .detail-model-columns {
      grid-template-columns: minmax(0, 1.6fr) minmax(0, 1fr) repeat(7, minmax(0, 0.8fr));
    }
    .detail-summary-metrics {
      display: grid;
      gap: 0.15rem;
      margin-top: 0.35rem;
      padding-top: 0.65rem;
      border-top: 1px solid var(--border);
    }
    .cell-clip {
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      min-width: 0;
    }
    .mono {
      font-family: var(--monospace-font);
    }
    .btn-link,
    .sort-btn {
      border: none;
      background: transparent;
      padding: 0;
      text-decoration: underline;
      color: var(--accent);
      cursor: pointer;
      font: inherit;
    }
    .loading,
    .error,
    .empty {
      padding: var(--space-3) 0;
      color: var(--text-muted);
    }
    .error {
      color: #b91c1c;
    }
    .metric-line {
      display: flex;
      justify-content: space-between;
      gap: 0.75rem;
      padding: 0.25rem 0;
      font-size: 0.9rem;
    }
    @media (max-width: 720px) {
      .detail-models-table {
        min-width: 0;
      }
      .usage-table-wrap {
        overflow-x: visible;
      }
      .usage-header {
        display: none;
      }
      .usage-row.runtime-columns,
      .usage-row.model-columns,
      .usage-row.run-columns,
      .usage-row.detail-model-columns {
        display: grid;
        grid-template-columns: 1fr;
        gap: 0.35rem;
        border: 1px solid var(--border);
        border-radius: 8px;
        padding: 0.65rem 0.75rem;
        margin-bottom: 0.55rem;
      }
      .usage-row > span {
        display: flex;
        justify-content: space-between;
        gap: 0.75rem;
        white-space: normal;
        overflow: visible;
        text-overflow: unset;
      }
      .usage-row > span::before {
        content: attr(data-label);
        color: var(--text-muted);
        font-size: 0.72rem;
        text-transform: uppercase;
        letter-spacing: 0.03em;
        flex: 0 0 auto;
      }
      .exact-hint {
        text-align: right;
      }
      .trend-bar-row {
        grid-template-columns: 3.5rem minmax(0, 1fr) auto;
      }
      .header-actions {
        width: 100%;
      }
    }
  `,
})
export class UsageHubComponent {
  readonly paneActive = input(false);

  summaryLoading = false;
  summaryError: unknown = null;
  insights: MetricsInsightsSummary | null = null;

  breakdownLoading = false;
  breakdownError: unknown = null;
  breakdown: MetricsBreakdownResponse | null = null;

  detailLoading = false;
  detailError: unknown = null;
  detail: MetricsDetailResponse | null = null;

  savingsReport: SavingsReport | null = null;
  savingsLoading = false;
  savingsError: unknown = null;

  @HostListener('document:keydown.escape')
  closeDetailOnEscape(): void {
    if (this.detailLoading || this.detailError || this.detail) {
      this.closeDetail();
    }
  }

  runtimeOptions: string[] = [];
  modelOptions: Array<{ label: string; exact_value: string }> = [];
  private detailModelRowsCache: MetricsRunModelRow[] | null = null;
  private detailModelRowsCacheKey = '';
  filterKind: UsageKind = 'all';
  filterRuntime = 'all';
  filterModel = 'all';
  filterDateFrom = '';
  filterDateTo = '';
  pageOffset = 0;
  pageLimit = 25;
  sortBy = 'total_tokens';
  sortDir: 'asc' | 'desc' = 'desc';
  activeDrill: DrillSection = null;

  private readonly apiService = inject(ApiService);
  private readonly cdr = inject(ChangeDetectorRef);
  readonly workspaceSelectorService = inject(WorkspaceSelectorService);
  private readonly requestLifecycle = inject(RequestLifecycleService);

  constructor() {
    effect(() => {
      if (!this.paneActive()) {
        return;
      }
      this.workspaceSelectorService.selectedWorkspacePath();
      this.refresh();
    });
  }

  get pageLabel(): string {
    if (!this.breakdown) {
      return '0 / 0';
    }
    const total = this.breakdown.page.total;
    if (total === 0) {
      return '0 / 0';
    }
    const start = this.breakdown.page.offset + 1;
    const end = Math.min(this.breakdown.page.offset + this.breakdown.page.limit, total);
    return `${start}-${end} / ${total}`;
  }

  get hasNextPage(): boolean {
    if (!this.breakdown) {
      return false;
    }
    return this.breakdown.page.offset + this.breakdown.page.limit < this.breakdown.page.total;
  }

  get hasActiveFilters(): boolean {
    return (
      this.filterKind !== 'all' ||
      this.filterRuntime !== 'all' ||
      this.filterModel !== 'all' ||
      !!this.filterDateFrom ||
      !!this.filterDateTo
    );
  }

  get hasUsageData(): boolean {
    return (this.insights?.headline.run_count ?? 0) > 0;
  }

  get isRefreshing(): boolean {
    return !!(
      this.insights &&
      (this.summaryLoading || this.breakdownLoading || this.savingsLoading)
    );
  }

  refresh(): void {
    this.pageOffset = 0;
    this.detail = null;
    this.detailError = null;
    this.loadSummary();
    this.loadBreakdown();
    this.loadSavings();
  }

  setFilterKind(value: string): void {
    this.filterKind = value === 'plan' || value === 'orchestration' ? value : 'all';
    this.pageOffset = 0;
    this.reloadFiltered();
  }

  setFilterRuntime(value: string): void {
    this.filterRuntime = value?.trim() || 'all';
    this.pageOffset = 0;
    this.reloadFiltered();
  }

  setFilterModel(value: string): void {
    this.filterModel = value?.trim() || 'all';
    this.pageOffset = 0;
    this.reloadFiltered();
  }

  setFilterDateFrom(value: string): void {
    this.filterDateFrom = value?.trim() || '';
    this.pageOffset = 0;
    this.reloadFiltered();
  }

  setFilterDateTo(value: string): void {
    this.filterDateTo = value?.trim() || '';
    this.pageOffset = 0;
    this.reloadFiltered();
  }

  clearFilters(): void {
    this.filterKind = 'all';
    this.filterRuntime = 'all';
    this.filterModel = 'all';
    this.filterDateFrom = '';
    this.filterDateTo = '';
    this.pageOffset = 0;
    this.reloadFiltered();
  }

  openDrilldown(id: string): void {
    if (id === 'runtime' || id === 'model' || id === 'runs') {
      this.activeDrill = id;
      const panel = document.querySelector(`[data-testid="insights-panel-${id}"]`);
      if (panel instanceof HTMLDetailsElement) {
        panel.open = true;
        panel.scrollIntoView?.({ behavior: 'smooth', block: 'start' });
      }
      this.cdr.markForCheck();
    }
  }

  sortRuns(field: string): void {
    if (this.sortBy === field) {
      this.sortDir = this.sortDir === 'asc' ? 'desc' : 'asc';
    } else {
      this.sortBy = field;
      this.sortDir = field === 'plan_key' ? 'asc' : 'desc';
    }
    this.pageOffset = 0;
    this.loadBreakdown();
  }

  prevPage(): void {
    this.pageOffset = Math.max(0, this.pageOffset - this.pageLimit);
    this.loadBreakdown();
  }

  nextPage(): void {
    if (!this.hasNextPage) {
      return;
    }
    this.pageOffset += this.pageLimit;
    this.loadBreakdown();
  }

  loadDetail(planKey: string): void {
    const handle = this.requestLifecycle.start('insights-detail', {
      project: this.workspaceSelectorService.selectedWorkspacePath(),
      planKey,
    });
    this.detailLoading = true;
    this.detailError = null;
    this.detail = null;
    this.cdr.markForCheck();
    const workspaceRoot = this.selectedWorkspaceRoot();
    this.apiService.fetchMetricsDetail(planKey, workspaceRoot, { signal: handle.signal }).subscribe({
      next: (detail) => {
        if (!this.requestLifecycle.isCurrent(handle)) {
          return;
        }
        this.detail = detail;
        this.detailLoading = false;
        this.cdr.markForCheck();
      },
      error: (err) => {
        if (!this.requestLifecycle.isCurrent(handle) || isAbortError(err)) {
          return;
        }
        this.detailLoading = false;
        this.detailError = err;
        this.cdr.markForCheck();
      },
    });
  }

  closeDetail(): void {
    this.requestLifecycle.cancel('insights-detail');
    this.detailLoading = false;
    this.detailError = null;
    this.detail = null;
    this.cdr.markForCheck();
  }

  downloadBreakdownCsv(): void {
    if (!this.breakdown) {
      return;
    }
    const rows: string[][] = [
      [
        'kind',
        'plan_key',
        'runtime',
        'model_label',
        'model_exact',
        'model_count',
        'models_all',
        'total_tokens',
        'tool_calls',
        'elapsed_seconds',
      ],
      ...this.breakdown.run_rows.map((row) => [
        row.kind,
        row.plan_key,
        row.runtime,
        row.model_label,
        row.model_exact,
        String(this.runModelCount(row)),
        (row.models ?? []).map((model) => model.model_exact).join(' | ') || row.model_exact,
        String(row.total_tokens),
        String(row.tool_calls_total),
        String(row.elapsed_seconds),
      ]),
    ];
    const csv = rows.map((cols) => cols.map((c) => `"${String(c).replace(/"/g, '""')}"`).join(',')).join('\n');
    const blob = new Blob([csv], { type: 'text/csv;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement('a');
    anchor.href = url;
    anchor.download = 'insights-breakdown.csv';
    anchor.click();
    URL.revokeObjectURL(url);
  }

  formatNumber(value: number): string {
    if (!Number.isFinite(value)) {
      return '0';
    }
    return new Intl.NumberFormat().format(Math.round(value));
  }

  formatCompact(value: number): string {
    if (!Number.isFinite(value)) {
      return '0';
    }
    const sign = value < 0 ? '-' : '';
    const abs = Math.abs(value);
    const trim = (n: number) => n.toFixed(1).replace(/\.0$/, '');
    if (abs >= 1e12) {
      return `${sign}${trim(abs / 1e12)}T`;
    }
    if (abs >= 1e9) {
      return `${sign}${trim(abs / 1e9)}B`;
    }
    if (abs >= 1e6) {
      return `${sign}${trim(abs / 1e6)}M`;
    }
    if (abs >= 1e3) {
      return `${sign}${trim(abs / 1e3)}K`;
    }
    return this.formatNumber(value);
  }

  trendShare(part: number): number {
    const recent = this.insights?.trend.recent_tokens ?? 0;
    const prior = this.insights?.trend.prior_tokens ?? 0;
    const max = Math.max(recent, prior, 1);
    const safe = Number.isFinite(part) ? Math.max(0, part) : 0;
    return Math.round((safe / max) * 100);
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

  /** Distinct models recorded for a run; falls back to the single summary model. */
  runModelCount(row: MetricsBreakdownRunRow): number {
    const count = row.model_count ?? row.models?.length ?? 0;
    return count > 0 ? count : 1;
  }

  /** Models beyond the one shown in the table cell, for the "+N more" badge. */
  extraModelCount(row: MetricsBreakdownRunRow): number {
    return Math.max(0, this.runModelCount(row) - 1);
  }

  runModelsTitle(row: MetricsBreakdownRunRow): string {
    const models = row.models ?? [];
    if (models.length === 0) {
      return row.model_exact;
    }
    return models.map((model) => `${model.model_exact} (${model.runtime})`).join('\n');
  }

  /** Per-model usage rows for the run detail modal, or null when unavailable. */
  detailModelRows(item: MetricsSummaryItem | null): MetricsRunModelRow[] | null {
    const breakdown = item?.model_breakdown;
    if (!item || !breakdown?.length) {
      this.detailModelRowsCache = null;
      this.detailModelRowsCacheKey = '';
      return null;
    }
    if (this.detailModelRowsCacheKey === item.path && this.detailModelRowsCache) {
      return this.detailModelRowsCache;
    }
    const buckets = new Map<string, MetricsRunModelRow>();
    for (const entry of breakdown) {
      const runtime = (entry.runtime || item.runtime || '').trim() || '(unspecified)';
      const model = (entry.model || item.model || '').trim() || '(unspecified)';
      const key = `${runtime} ${model}`;
      const bucket = buckets.get(key) ?? {
        runtime,
        model,
        model_label: this.friendlyModel(model),
        model_exact: model,
        invocations: 0,
        input_tokens: 0,
        output_tokens: 0,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
        total_tokens: 0,
        tool_calls_total: 0,
        elapsed_seconds: 0,
      };
      bucket.invocations += Math.max(1, entry.invocations ?? 0);
      bucket.input_tokens += entry.input_tokens ?? 0;
      bucket.output_tokens += entry.output_tokens ?? 0;
      bucket.cache_creation_input_tokens += entry.cache_creation_input_tokens ?? 0;
      bucket.cache_read_input_tokens += entry.cache_read_input_tokens ?? 0;
      bucket.total_tokens +=
        (entry.input_tokens ?? 0) +
        (entry.output_tokens ?? 0) +
        (entry.cache_creation_input_tokens ?? 0) +
        (entry.cache_read_input_tokens ?? 0);
      bucket.tool_calls_total += entry.tool_calls_total ?? 0;
      bucket.elapsed_seconds += entry.elapsed_seconds ?? 0;
      buckets.set(key, bucket);
    }
    const rows = Array.from(buckets.values()).sort(
      (a, b) =>
        b.total_tokens - a.total_tokens ||
        b.invocations - a.invocations ||
        a.model_exact.localeCompare(b.model_exact),
    );
    this.detailModelRowsCache = rows;
    this.detailModelRowsCacheKey = item.path;
    return rows;
  }

  friendlyModel(raw: string | undefined): string {
    const exact = (raw ?? '').trim();
    if (!exact) {
      return 'Unspecified model';
    }
    const lower = exact.toLowerCase();
    if (lower.includes('claude') && lower.includes('opus')) {
      return 'Claude Opus';
    }
    if (lower.includes('claude') && lower.includes('sonnet')) {
      return 'Claude Sonnet';
    }
    if (lower.includes('gpt-5') || lower.includes('gpt5')) {
      return 'GPT-5 family';
    }
    if (lower.includes('gpt-4o')) {
      return 'GPT-4o';
    }
    return exact.length > 28 ? `${exact.slice(0, 25)}...` : exact;
  }

  /** Show monospace exact id only when it differs from the friendly label. */
  showExactModelHint(label: string, exact: string): boolean {
    const normalizedLabel = (label ?? '').trim();
    const normalizedExact = (exact ?? '').trim();
    if (!normalizedExact || normalizedExact === '(unspecified)') {
      return false;
    }
    return normalizedExact !== normalizedLabel;
  }

  trendSentence(insights: MetricsInsightsSummary): string {
    const trend = insights.trend;
    if (trend.direction === 'unknown') {
      return 'Not enough dated runs to compute a trend yet.';
    }
    const delta =
      trend.delta_percent === null
        ? `${this.formatCompact(Math.abs(trend.delta_tokens))} tokens`
        : `${Math.abs(trend.delta_percent)}%`;
    if (trend.direction === 'flat') {
      return 'Token volume is roughly flat versus the prior half of this scope.';
    }
    if (trend.direction === 'up') {
      return `Token volume is up ${delta} versus the prior half of this scope.`;
    }
    return `Token volume is down ${delta} versus the prior half of this scope.`;
  }

  private reloadFiltered(): void {
    this.loadSummary();
    this.loadBreakdown();
    this.loadSavings();
  }

  private buildFilters(includePaging = false): MetricsQueryFilters {
    const filters: MetricsQueryFilters = {
      kind: this.filterKind,
      runtime: this.filterRuntime,
      model: this.filterModel,
      dateFrom: this.filterDateFrom || undefined,
      dateTo: this.filterDateTo || undefined,
    };
    const workspaceRoot = this.selectedWorkspaceRoot();
    if (workspaceRoot) {
      filters.workspaceRoot = workspaceRoot;
    }
    if (includePaging) {
      filters.offset = this.pageOffset;
      filters.limit = this.pageLimit;
      filters.sortBy = this.sortBy;
      filters.sortDir = this.sortDir;
    }
    return filters;
  }

  private selectedWorkspaceRoot(): string | undefined {
    const selected = this.workspaceSelectorService.selectedWorkspacePath();
    if (!selected) {
      return undefined;
    }
    const entry = this.workspaceSelectorService.workspaces().find((ws: WorkspaceRegistry) => ws.path === selected);
    return entry?.workspaceRoot || undefined;
  }

  loadSummary(): void {
    const handle = this.requestLifecycle.start('insights-summary', {
      project: this.workspaceSelectorService.selectedWorkspacePath(),
      kind: this.filterKind,
      runtime: this.filterRuntime,
      model: this.filterModel,
      dateFrom: this.filterDateFrom,
      dateTo: this.filterDateTo,
    });
    if (!this.insights) {
      this.summaryLoading = true;
    }
    this.summaryError = null;
    this.cdr.markForCheck();
    this.apiService.fetchMetricsInsightsSummary(this.buildFilters(false), { signal: handle.signal }).subscribe({
      next: (insights) => {
        if (!this.requestLifecycle.isCurrent(handle)) {
          return;
        }
        this.insights = insights;
        this.runtimeOptions = insights.filter_options.runtimes;
        this.modelOptions = insights.filter_options.models;
        this.summaryLoading = false;
        markInventoryUsable('insights');
        this.cdr.markForCheck();
      },
      error: (err) => {
        if (!this.requestLifecycle.isCurrent(handle) || isAbortError(err)) {
          return;
        }
        this.summaryLoading = false;
        this.summaryError = err;
        if (!this.insights) {
          this.insights = null;
        }
        this.cdr.markForCheck();
      },
    });
  }

  loadBreakdown(): void {
    const handle = this.requestLifecycle.start('insights-breakdown', {
      project: this.workspaceSelectorService.selectedWorkspacePath(),
      kind: this.filterKind,
      runtime: this.filterRuntime,
      model: this.filterModel,
      dateFrom: this.filterDateFrom,
      dateTo: this.filterDateTo,
      offset: this.pageOffset,
      limit: this.pageLimit,
      sortBy: this.sortBy,
      sortDir: this.sortDir,
    });
    if (!this.breakdown) {
      this.breakdownLoading = true;
    }
    this.breakdownError = null;
    this.cdr.markForCheck();
    this.apiService.fetchMetricsBreakdown(this.buildFilters(true), { signal: handle.signal }).subscribe({
      next: (breakdown) => {
        if (!this.requestLifecycle.isCurrent(handle)) {
          return;
        }
        this.breakdown = breakdown;
        this.breakdownLoading = false;
        markSecondaryReady('insights');
        this.cdr.markForCheck();
      },
      error: (err) => {
        if (!this.requestLifecycle.isCurrent(handle) || isAbortError(err)) {
          return;
        }
        this.breakdownLoading = false;
        this.breakdownError = err;
        if (!this.breakdown) {
          this.breakdown = null;
        }
        this.cdr.markForCheck();
      },
    });
  }

  private loadSavings(): void {
    this.savingsLoading = true;
    this.savingsError = null;
    const filters: {
      workspaceRoot?: string;
      runtime?: string;
      model?: string;
    } = {};
    const workspaceRoot = this.selectedWorkspaceRoot();
    if (workspaceRoot) {
      filters.workspaceRoot = workspaceRoot;
    }
    if (this.filterRuntime !== 'all') {
      filters.runtime = this.filterRuntime;
    }
    if (this.filterModel !== 'all') {
      filters.model = this.filterModel;
    }
    this.apiService.fetchSavings(filters).subscribe({
      next: (report) => {
        this.savingsReport = report;
        this.savingsLoading = false;
        this.cdr.markForCheck();
      },
      error: (err) => {
        this.savingsError = err;
        this.savingsLoading = false;
        this.cdr.markForCheck();
      },
    });
  }
}
