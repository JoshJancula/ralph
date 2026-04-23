import { CommonModule } from '@angular/common';
import { ChangeDetectionStrategy, ChangeDetectorRef, Component, OnInit, inject } from '@angular/core';
import { IonCard, IonCardContent, IonCardHeader, IonCardSubtitle, IonCardTitle, IonSpinner } from '@ionic/angular/standalone';

import { ApiService, MetricsSummary, MetricsSummaryItem, ModelBreakdownItem } from '../../services/api.service';
import { NavService } from '../../services/nav.service';
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
}

interface StatItem {
  label: string;
  value: string;
}

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
          <p>Token usage breakdown by runtime and model.</p>
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
                    <span>Cache hit</span>
                    <span>Peak turn</span>
                  </div>
                  @for (row of runtimeRows; track row.runtime) {
                    <div class="usage-row runtime-columns">
                      <span class="mono">{{ row.runtime }}</span>
                      <span>{{ row.model_count }}</span>
                      <span>{{ formatNumber(row.runs) }}</span>
                      <span>{{ formatNumber(row.invocations) }}</span>
                      <span>{{ formatNumber(row.input_tokens) }}</span>
                      <span>{{ formatNumber(row.output_tokens) }}</span>
                      <span>{{ formatNumber(row.cache_read_input_tokens) }}</span>
                      <span class="mono">{{ formatNumber(row.total_tokens) }}</span>
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
                    <span>Cache hit</span>
                    <span>Peak turn</span>
                  </div>
                  @for (row of modelRows; track row.runtime + '-' + row.model) {
                    <div class="usage-row model-columns">
                      <span class="mono">{{ row.runtime }}</span>
                      <span class="mono">{{ row.model }}</span>
                      <span>{{ formatNumber(row.runs) }}</span>
                      <span>{{ formatNumber(row.invocations) }}</span>
                      <span>{{ formatNumber(row.input_tokens) }}</span>
                      <span>{{ formatNumber(row.output_tokens) }}</span>
                      <span>{{ formatNumber(row.cache_read_input_tokens) }}</span>
                      <span class="mono">{{ formatNumber(row.total_tokens) }}</span>
                      <span>{{ formatPercent(row.cache_hit_ratio) }}</span>
                      <span>{{ formatPeakTurn(row.max_turn_total_tokens) }}</span>
                    </div>
                  }
                </div>
              }
            </ion-card-content>
          </ion-card>
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
    .usage-table {
      display: grid;
      gap: 0.5rem;
      overflow-x: auto;
    }
    .usage-row {
      display: grid;
      gap: 0.7rem;
      align-items: center;
      font-size: 0.88rem;
      min-width: 860px;
    }
    .runtime-columns {
      grid-template-columns: 1fr 0.55fr 0.55fr 0.8fr 0.8fr 0.8fr 0.95fr 0.95fr 0.8fr 0.8fr;
    }
    .model-columns {
      grid-template-columns: 0.9fr 1.5fr 0.55fr 0.8fr 0.8fr 0.8fr 0.95fr 0.95fr 0.8fr 0.8fr;
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
  `,
})
export class UsageHubComponent implements OnInit {
  loading = false;
  error = '';
  summary: MetricsSummary | null = null;
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

  ngOnInit(): void {
    this.refresh();
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
    this.cdr.markForCheck();

    this.apiService.fetchMetricsSummary().subscribe({
      next: (summary) => {
        this.summary = summary;
        this.totalRunCount = summary.plans.length + summary.orchestrations.length;
        this.recomputeRuntimeOptions(summary);
        this.recomputeModelOptions(summary);
        this.applyFilters(summary);
        this.loading = false;
        this.cdr.markForCheck();
      },
      error: (err) => {
        this.loading = false;
        this.error = err.error?.error || 'Failed to load usage metrics';
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
        this.cdr.markForCheck();
      },
    });
  }

  setFilterKind(value: string): void {
    this.filterKind = this.normalizeKindFilter(value);
    this.recomputeRuntimeOptions(this.summary);
    this.recomputeModelOptions(this.summary);
    this.applyFilters();
    this.cdr.markForCheck();
  }

  setFilterRuntime(value: string): void {
    this.filterRuntime = this.normalizeSelection(value);
    this.recomputeModelOptions(this.summary);
    this.applyFilters();
    this.cdr.markForCheck();
  }

  setFilterModel(value: string): void {
    this.filterModel = this.normalizeSelection(value);
    this.applyFilters();
    this.cdr.markForCheck();
  }

  setFilterDateFrom(value: string): void {
    this.filterDateFrom = value?.trim() || '';
    this.recomputeRuntimeOptions(this.summary);
    this.recomputeModelOptions(this.summary);
    this.applyFilters();
    this.cdr.markForCheck();
  }

  setFilterDateTo(value: string): void {
    this.filterDateTo = value?.trim() || '';
    this.recomputeRuntimeOptions(this.summary);
    this.recomputeModelOptions(this.summary);
    this.applyFilters();
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

  formatPeakTurn(tokens: number): string {
    if (!Number.isFinite(tokens) || tokens <= 0) {
      return '--';
    }
    return this.formatNumber(tokens);
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
      return;
    }

    const records = this.buildRunRecords(summary);
    this.totalRunCount = records.length;
    const fromMs = this.parseDateStartMs(this.filterDateFrom);
    const toMs = this.parseDateEndMs(this.filterDateTo);
    const filtered = records
      .filter((record) => this.passesKindFilter(record))
      .filter((record) => this.passesDateFilter(record.startedAtMs, fromMs, toMs))
      .map((record) => ({
        run: record,
        entries: record.breakdown.filter((entry) => this.matchesRuntimeModel(entry)),
      }))
      .filter((match) => match.entries.length > 0);

    this.filteredRunCount = filtered.length;
    this.detailedBreakdownRuns = filtered.filter((match) => match.run.hasDetailedBreakdown).length;
    this.inferredBreakdownRuns = filtered.length - this.detailedBreakdownRuns;

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
        };
        modelBucket.invocations += this.normalizeInvocations(entry.invocations);
        modelBucket.runKeys.add(runKey);
        modelBucket.elapsed_seconds += this.toNumber(entry.elapsed_seconds);
        modelBucket.input_tokens += this.toNumber(entry.input_tokens);
        modelBucket.output_tokens += this.toNumber(entry.output_tokens);
        modelBucket.cache_creation_input_tokens += this.toNumber(entry.cache_creation_input_tokens);
        modelBucket.cache_read_input_tokens += this.toNumber(entry.cache_read_input_tokens);
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
        };
        runtimeBucket.models.add(model);
        runtimeBucket.invocations += this.normalizeInvocations(entry.invocations);
        runtimeBucket.runKeys.add(runKey);
        runtimeBucket.elapsed_seconds += this.toNumber(entry.elapsed_seconds);
        runtimeBucket.input_tokens += this.toNumber(entry.input_tokens);
        runtimeBucket.output_tokens += this.toNumber(entry.output_tokens);
        runtimeBucket.cache_creation_input_tokens += this.toNumber(entry.cache_creation_input_tokens);
        runtimeBucket.cache_read_input_tokens += this.toNumber(entry.cache_read_input_tokens);
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
    for (const record of this.buildRunRecords(summary)) {
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
    for (const record of this.buildRunRecords(summary)) {
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

  private toNumber(value: number): number {
    return Number.isFinite(value) ? value : 0;
  }

  private round4(value: number): number {
    return Math.round(value * 10000) / 10000;
  }
}
