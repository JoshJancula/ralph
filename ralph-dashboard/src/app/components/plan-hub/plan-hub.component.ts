import { ChangeDetectionStrategy, ChangeDetectorRef, Component, OnInit, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { IonSpinner, IonCard, IonCardHeader, IonCardTitle, IonCardSubtitle, IonCardContent } from '@ionic/angular/standalone';
import { ApiService, MetricsSummary, MetricsSummaryItem } from '../../services/api.service';
import { NavService } from '../../services/nav.service';
import { PlanLogResolutionService } from '../../services/plan-log-resolution.service';

interface PlanItem {
  name: string;
  path: string;
  mtime: number;
  hasLogs: boolean;
}

type PlanCardRow = PlanItem & { folderMetrics: MetricsSummaryItem | null; mtimeLabel: string };

interface StatItem {
  label: string;
  value: string;
}

@Component({
  selector: 'ralph-plan-hub',
  standalone: true,
  imports: [CommonModule, IonSpinner, IonCard, IonCardHeader, IonCardTitle, IonCardSubtitle, IonCardContent],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="plan-hub">
      <div class="header">
        <h2>Plans</h2>
      </div>
      @if (metricsLoading) {
        <div class="metrics-loading">Loading metrics...</div>
      } @else if (metricsError) {
        <div class="metrics-error">{{ metricsError }}</div>
      } @else if (metricsSummary) {
        <section class="metrics-section">
          <div class="metrics-overall">
            @for (stat of overallStatRows; track stat.label) {
              <ion-card>
                <ion-card-content>
                  <div class="metric-label">{{ stat.label }}</div>
                  <div class="metric-value">{{ stat.value }}</div>
                </ion-card-content>
              </ion-card>
            }
          </div>

          <div class="metrics-grid">
            <ion-card>
              <ion-card-header>
                <ion-card-title>Plan Metrics</ion-card-title>
                <ion-card-subtitle>{{ metricsSummary.plans.length }} plan runs</ion-card-subtitle>
              </ion-card-header>
              <ion-card-content>
                @if (metricsSummary.plans.length === 0) {
                  <div class="metrics-empty">No plan metrics found</div>
                } @else {
                  <div class="metrics-table">
                    <div class="metrics-table-row metrics-table-header">
                      <span>Plan</span>
                      <span>Elapsed</span>
                      <span>Tokens</span>
                      <span>Cache hit</span>
                      <span>Peak turn</span>
                    </div>
                    @for (item of metricsSummary.plans; track item.path) {
                      <div class="metrics-table-row">
                        <span>{{ item.plan_key }}</span>
                        <span>{{ formatSeconds(item.elapsed_seconds) }}</span>
                        <span>{{ formatTokens(item) }}</span>
                        <span>{{ formatPercent(item.cache_hit_ratio) }}</span>
                        <span>{{ formatPeakTurn(item.max_turn_total_tokens) }}</span>
                      </div>
                    }
                  </div>
                }
              </ion-card-content>
            </ion-card>

            <ion-card>
              <ion-card-header>
                <ion-card-title>Orchestration Metrics</ion-card-title>
                <ion-card-subtitle>{{ metricsSummary.orchestrations.length }} orchestration runs</ion-card-subtitle>
              </ion-card-header>
              <ion-card-content>
                @if (metricsSummary.orchestrations.length === 0) {
                  <div class="metrics-empty">No orchestration metrics found</div>
                } @else {
                  <div class="metrics-table">
                    <div class="metrics-table-row metrics-table-header">
                      <span>Orchestration</span>
                      <span>Elapsed</span>
                      <span>Tokens</span>
                      <span>Cache hit</span>
                      <span>Peak turn</span>
                    </div>
                    @for (item of metricsSummary.orchestrations; track item.path) {
                      <div class="metrics-table-row">
                        <span>{{ item.artifact_ns }}</span>
                        <span>{{ formatSeconds(item.elapsed_seconds) }}</span>
                        <span>{{ formatTokens(item) }}</span>
                        <span>{{ formatPercent(item.cache_hit_ratio) }}</span>
                        <span>{{ formatPeakTurn(item.max_turn_total_tokens) }}</span>
                      </div>
                    }
                  </div>
                }
              </ion-card-content>
            </ion-card>
          </div>
        </section>
      }
      @if (error) {
        <div class="error">{{ error }}</div>
      } @else if (loading) {
        <div class="loading">
          <ion-spinner name="crescent"></ion-spinner>
          <span>Loading plans...</span>
        </div>
      } @else if (planCards.length === 0) {
        <div class="empty-state">No plan directories found</div>
      } @else {
        <div class="plan-list">
          @for (row of planCards; track row.name) {
            <ion-card>
              <ion-card-header>
                <ion-card-title>{{ row.name }}</ion-card-title>
                <ion-card-subtitle>{{ row.mtimeLabel }}</ion-card-subtitle>
              </ion-card-header>
              <ion-card-content>
                @if (metricsLoading) {
                  <div class="plan-folder-metrics-empty">Loading usage metrics...</div>
                } @else if (metricsError) {
                  <div class="plan-folder-metrics-empty">Usage metrics failed to load.</div>
                } @else if (metricsSummary) {
                  @if (row.folderMetrics) {
                    <div class="plan-folder-metrics" aria-label="Usage for this log folder">
                      <div class="plan-folder-metric">
                        <span class="plan-folder-metric-label">Elapsed</span>
                        <span class="plan-folder-metric-value">{{ formatSeconds(row.folderMetrics.elapsed_seconds) }}</span>
                      </div>
                      <div class="plan-folder-metric">
                        <span class="plan-folder-metric-label">Tokens</span>
                        <span class="plan-folder-metric-value">{{ formatTokens(row.folderMetrics) }}</span>
                      </div>
                      <div class="plan-folder-metric">
                        <span class="plan-folder-metric-label">Cache hit</span>
                        <span class="plan-folder-metric-value">{{ formatPercent(row.folderMetrics.cache_hit_ratio) }}</span>
                      </div>
                      @if (row.folderMetrics.max_turn_total_tokens > 0) {
                        <div class="plan-folder-metric">
                          <span class="plan-folder-metric-label">Peak turn</span>
                          <span class="plan-folder-metric-value">{{ formatPeakTurn(row.folderMetrics.max_turn_total_tokens) }}</span>
                        </div>
                      }
                    </div>
                  } @else {
                    <div class="plan-folder-metrics-empty">No usage summary for this log folder yet.</div>
                  }
                }
                <div class="plan-actions">
                  <button class="btn-primary" (click)="openPlan(row)">Open Plan</button>
                  @if (row.hasLogs) {
                    <button class="btn-secondary" (click)="viewLogs(row)">View Logs</button>
                  }
                </div>
              </ion-card-content>
            </ion-card>
          }
        </div>
      }
    </div>
  `,
  styles: `
    :host {
      display: flex;
      flex: 1;
      min-height: 0;
    }
    .plan-hub {
      flex: 1;
      min-height: 0;
      padding: 2rem;
      overflow-y: auto;
    }
    .header {
      margin-bottom: 2rem;
    }
    .header h2 {
      margin: 0;
      font-size: 1.75rem;
      font-weight: 600;
    }
    .metrics-section {
      display: grid;
      gap: 1rem;
      margin-bottom: 2rem;
    }
    .metrics-overall {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
      gap: 1rem;
    }
    .metrics-overall ion-card {
      margin: 0;
    }
    .metric-label {
      color: var(--text-muted);
      font-size: 0.85rem;
      margin-bottom: 0.35rem;
    }
    .metric-value {
      font-size: 1.4rem;
      font-weight: 600;
      font-family: var(--monospace-font);
    }
    .metrics-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));
      gap: 1rem;
    }
    .metrics-table {
      display: grid;
      gap: 0.5rem;
    }
    .metrics-table-row {
      display: grid;
      grid-template-columns: 1.4fr 0.8fr 0.9fr 0.7fr 0.7fr;
      gap: 0.75rem;
      align-items: center;
      font-size: 0.9rem;
    }
    .metrics-table-header {
      color: var(--text-muted);
      font-size: 0.8rem;
      text-transform: uppercase;
      letter-spacing: 0.04em;
    }
    .metrics-empty,
    .metrics-loading,
    .metrics-error {
      padding: 1rem;
      border-radius: 4px;
      margin-bottom: 1rem;
    }
    .metrics-loading,
    .metrics-empty {
      color: var(--text-muted);
      background: var(--surface);
      border: 1px solid var(--border);
    }
    .metrics-error {
      color: var(--danger);
      background: rgba(255, 0, 0, 0.1);
    }
    .error {
      color: var(--danger);
      padding: 1rem;
      background: rgba(255, 0, 0, 0.1);
      border-radius: 4px;
    }
    .loading {
      min-height: 220px;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      gap: 0.75rem;
      padding: 3rem 2rem;
      color: var(--text-muted);
    }
    .empty-state {
      min-height: 220px;
      display: flex;
      align-items: center;
      justify-content: center;
      color: var(--text-muted);
      padding: 3rem 2rem;
      text-align: center;
      background: var(--surface);
      border-radius: 8px;
      border: 1px solid var(--border);
    }
    .plan-list {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
      gap: 1rem;
    }
    ion-card {
      --background: var(--surface);
      --color: var(--text-primary);
      border: 1px solid var(--border);
      border-radius: 8px;
      box-shadow: none;
      margin: 0;
    }
    ion-card-title {
      font-size: 1rem;
      font-weight: 500;
      font-family: var(--monospace-font);
    }
    ion-card-subtitle {
      font-size: 0.8rem;
      color: var(--text-muted);
    }
    .plan-folder-metrics {
      display: flex;
      flex-wrap: wrap;
      gap: 1rem;
      margin-bottom: 0.75rem;
      font-size: 0.85rem;
    }
    .plan-folder-metric {
      display: flex;
      flex-direction: column;
      gap: 0.15rem;
    }
    .plan-folder-metric-label {
      color: var(--text-muted);
      font-size: 0.75rem;
      text-transform: uppercase;
      letter-spacing: 0.04em;
    }
    .plan-folder-metric-value {
      font-family: var(--monospace-font);
      font-weight: 600;
    }
    .plan-folder-metrics-empty {
      color: var(--text-muted);
      font-size: 0.8rem;
      margin-bottom: 0.75rem;
    }
    .plan-actions {
      display: flex;
      gap: 0.5rem;
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
      color: #fff;
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
export class PlanHubComponent implements OnInit {
  items: PlanItem[] = [];
  planCards: PlanCardRow[] = [];
  metricsSummary: MetricsSummary | null = null;
  overallStatRows: StatItem[] = [];
  loading = false;
  metricsLoading = false;
  error = '';
  metricsError = '';

  private apiService = inject(ApiService);
  private navService = inject(NavService);
  private planLogResolution = inject(PlanLogResolutionService);
  private cdr = inject(ChangeDetectorRef);

  ngOnInit(): void {
    this.fetchPlans();
    this.fetchMetrics();
  }

  fetchPlans(): void {
    this.loading = true;
    this.error = '';
    this.cdr.markForCheck();

    // Fetch plan log directories
    this.apiService.fetchListing('logs', '').subscribe({
      next: (response) => {
        // Filter for directories (these are the plan folders)
        this.items = response.entries
          .filter((entry) => entry.type === 'dir')
          .map((entry) => ({
            name: entry.name,
            path: entry.path,
            mtime: entry.mtime,
            hasLogs: true, // Since we're now using logs dir for plans, all have logs
          }))
          .sort((a, b) => b.mtime - a.mtime);
        this.loading = false;
        this.rebuildPlanFolderMetrics();
        this.cdr.markForCheck();
      },
      error: (err) => {
        this.error = err.error?.error || 'Failed to load plans';
        this.loading = false;
        this.rebuildPlanFolderMetrics();
        this.cdr.markForCheck();
      },
    });
  }

  fetchMetrics(): void {
    this.metricsLoading = true;
    this.metricsError = '';
    this.cdr.markForCheck();

    this.apiService.fetchMetricsSummary().subscribe({
      next: (summary) => {
        this.metricsSummary = summary;
        this.metricsLoading = false;
        this.overallStatRows = this.buildOverallStatRows(summary);
        this.rebuildPlanFolderMetrics();
        this.cdr.markForCheck();
      },
      error: (err) => {
        this.metricsError = err.error?.error || 'Failed to load metrics';
        this.metricsLoading = false;
        this.metricsSummary = null;
        this.overallStatRows = [];
        this.rebuildPlanFolderMetrics();
        this.cdr.markForCheck();
      },
    });
  }

  openPlan(item: PlanItem): void {
    const directory = this.planLogResolution.resolvePlanDirectory(item.path);
    if (!directory) {
      return;
    }

    const planFile = `${directory}.md`;
    this.navService.navigate('plans', '', planFile);
  }

  viewLogs(item: PlanItem): void {
    const dir = this.planLogResolution.resolvePlanDirectory(item.path);
    if (!dir) {
      return;
    }

    this.planLogResolution.resolveLatestLogTarget(dir).subscribe({
      next: (target) => {
        this.navService.navigate('logs', target.directory, target.file);
      },
    });
  }

  formatNumber(value: number): string {
    return new Intl.NumberFormat().format(value);
  }

  formatSeconds(value: number): string {
    if (!Number.isFinite(value)) {
      return '0s';
    }

    return `${value.toFixed(1)}s`;
  }

  formatTokens(item: MetricsSummaryItem): string {
    return this.formatNumber(
      item.input_tokens + item.output_tokens + item.cache_creation_input_tokens + item.cache_read_input_tokens,
    );
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

  private rebuildPlanFolderMetrics(): void {
    const summary = this.metricsSummary;
    this.planCards = this.items.map((item) => ({
      ...item,
      folderMetrics: summary ? this.aggregateForFolder(summary, item.name) : null,
      mtimeLabel: this.formatMtimeLabel(item.mtime),
    }));
  }

  private formatMtimeLabel(mtimeMs: number): string {
    const d = new Date(mtimeMs);
    const pad = (n: number) => n.toString().padStart(2, '0');
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
  }

  private buildOverallStatRows(summary: MetricsSummary): StatItem[] {
    return [
      { label: 'Input Tokens', value: this.formatNumber(summary.overall.input_tokens) },
      { label: 'Output Tokens', value: this.formatNumber(summary.overall.output_tokens) },
      { label: 'Cache Created', value: this.formatNumber(summary.overall.cache_creation_input_tokens) },
      { label: 'Cache Read', value: this.formatNumber(summary.overall.cache_read_input_tokens) },
      { label: 'Cache Hit Rate', value: this.formatPercent(summary.overall.cache_hit_ratio) },
      { label: 'Peak Turn', value: this.formatPeakTurn(summary.overall.max_turn_total_tokens) },
      { label: 'Elapsed Time', value: this.formatSeconds(summary.overall.elapsed_seconds) },
    ];
  }

  private aggregateForFolder(summary: MetricsSummary, folderName: string): MetricsSummaryItem | null {
    const seenPaths = new Set<string>();
    const matches: MetricsSummaryItem[] = [];

    const consider = (row: MetricsSummaryItem): void => {
      if (seenPaths.has(row.path)) {
        return;
      }
      if (row.plan_key === folderName || row.artifact_ns === folderName) {
        seenPaths.add(row.path);
        matches.push(row);
      }
    };

    for (const row of summary.plans) {
      consider(row);
    }
    for (const row of summary.orchestrations) {
      consider(row);
    }

    if (matches.length === 0) {
      return null;
    }

    const aggInput = matches.reduce((acc, m) => acc + m.input_tokens, 0);
    const aggCacheRead = matches.reduce((acc, m) => acc + m.cache_read_input_tokens, 0);
    const aggCacheCreate = matches.reduce((acc, m) => acc + m.cache_creation_input_tokens, 0);
    const aggTotal = aggInput + aggCacheRead + aggCacheCreate;
    const aggCacheHitRatio = aggTotal > 0 ? Math.round((aggCacheRead / aggTotal) * 10000) / 10000 : 0;
    const aggMaxTurn = matches.reduce((max, m) => Math.max(max, m.max_turn_total_tokens), 0);

    return {
      path: matches.map((m) => m.path).join('|'),
      plan_key: folderName,
      artifact_ns: folderName,
      elapsed_seconds: matches.reduce((acc, m) => acc + m.elapsed_seconds, 0),
      input_tokens: aggInput,
      output_tokens: matches.reduce((acc, m) => acc + m.output_tokens, 0),
      cache_creation_input_tokens: aggCacheCreate,
      cache_read_input_tokens: aggCacheRead,
      max_turn_total_tokens: aggMaxTurn,
      cache_hit_ratio: aggCacheHitRatio,
    };
  }
}
