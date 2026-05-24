import {
  ChangeDetectionStrategy,
  ChangeDetectorRef,
  Component,
  OnInit,
  inject,
  effect,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { IonSpinner, IonCard, IonCardHeader, IonCardTitle, IonCardSubtitle, IonCardContent } from '@ionic/angular/standalone';
import { ApiService, MetricsSummary, MetricsSummaryItem, MetricsSummaryOverall } from '../../services/api.service';
import { NavService } from '../../services/nav.service';
import { PlanLogResolutionService } from '../../services/plan-log-resolution.service';
import { WorkspaceSelectorService } from '../../services/workspace-selector.service';
import { formatElapsedSeconds } from '../../utils/format-elapsed';
import {
  buildPlanFolderMetricLookup,
  lookupFolderMetricRows,
  rollupFolderMetrics,
} from './plan-hub-folder-metrics';

interface PlanItem {
  name: string;
  path: string;
  mtime: number;
  hasLogs: boolean;
  /** Aggregate logs listing scope (absolute `.ralph-workspace` path) when multiple roots are merged. */
  workspaceRoot?: string;
}

type PlanCardRow = PlanItem & { folderMetrics: MetricsSummaryItem | null; mtimeLabel: string };

interface PlanSection {
  key: string;
  label: string;
  workspaceRoot: string | undefined;
  rows: PlanCardRow[];
}

const INITIAL_PLAN_ROWS_PER_SECTION = 75;
const PLAN_ROWS_LOAD_MORE_STEP = 75;

@Component({
  selector: 'ralph-plan-hub',
  standalone: true,
  imports: [CommonModule, IonSpinner, IonCard, IonCardHeader, IonCardTitle, IonCardSubtitle, IonCardContent],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="plan-hub">
      <div class="header">
        <h2>Plans</h2>
        <div class="header-actions">
          <button class="btn-secondary" (click)="openUsage()">Usage Details</button>
        </div>
      </div>
      @if (error) {
        <div class="error">{{ error }}</div>
      } @else if (loading) {
        <div class="loading">
          <ion-spinner name="crescent"></ion-spinner>
          <span>Loading plans...</span>
        </div>
      } @else if (planSections.length === 0 || totalPlanRows() === 0) {
        <div class="empty-state">No plan directories found</div>
      } @else {
        @if (!metricsLoading && !metricsError && metricsSummary && displayOverallMetrics()) {
          <ion-card class="overall-metrics-card">
            <ion-card-header>
              <ion-card-title>{{ overallMetricsTitle() }}</ion-card-title>
            </ion-card-header>
            <ion-card-content>
              <div class="overall-metrics" aria-label="Overall usage metrics">
                <div class="overall-metric">
                  <span class="overall-metric-label">Total Elapsed</span>
                  <span class="overall-metric-value">{{ formatSeconds(displayOverallMetrics()!.elapsed_seconds) }}</span>
                </div>
                <div class="overall-metric">
                  <span class="overall-metric-label">Total Tokens</span>
                  <span class="overall-metric-value">{{ formatOverallTokens(displayOverallMetrics()!) }}</span>
                </div>
                <div class="overall-metric">
                  <span class="overall-metric-label">Cache Hit Ratio</span>
                  <span class="overall-metric-value">{{ formatPercent(displayOverallMetrics()!.cache_hit_ratio) }}</span>
                </div>
                <div class="overall-metric">
                  <span class="overall-metric-label">Peak Turn</span>
                  <span class="overall-metric-value">{{ formatPeakTurn(displayOverallMetrics()!.max_turn_total_tokens) }}</span>
                </div>
                <div class="overall-metric">
                  <span class="overall-metric-label">Tool Calls</span>
                  <span class="overall-metric-value">{{ formatNumber(displayOverallMetrics()?.tool_calls_total ?? 0) }}</span>
                </div>
              </div>
            </ion-card-content>
          </ion-card>
        }
        @for (section of planSections; track section.key) {
          <div class="plan-section">
            @if (planSections.length > 1) {
              <h3 class="plan-section-title">{{ section.label }}</h3>
            }
            <div class="plan-list">
              @for (row of visibleRowsForSection(section); track row.path + (row.workspaceRoot ?? '')) {
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
                          @if ((row.folderMetrics.tool_calls_total ?? 0) > 0) {
                            <div class="plan-folder-metric">
                              <span class="plan-folder-metric-label">Tool calls</span>
                              <span class="plan-folder-metric-value">{{ formatNumber(row.folderMetrics.tool_calls_total ?? 0) }}</span>
                            </div>
                          }
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
            @if (remainingRowsInSection(section) > 0) {
              <div class="plan-section-more">
                <button type="button" class="btn-secondary" (click)="showMoreForSection(section)">
                  Show {{ showMoreCount(section) }} more
                </button>
                <span class="plan-section-more-meta">{{ remainingRowsInSection(section) }} not shown</span>
              </div>
            }
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
    .plan-hub {
      flex: 1;
      min-height: 0;
      padding: 2rem;
      overflow-y: auto;
    }
    .header {
      margin-bottom: 2rem;
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 1rem;
      flex-wrap: wrap;
    }
    .header h2 {
      margin: 0;
      font-size: 1.75rem;
      font-weight: 600;
    }
    .header-actions {
      display: flex;
      gap: 0.5rem;
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
    .overall-metrics-card {
      margin-bottom: 2rem;
      --background: var(--surface);
      --color: var(--text-primary);
      border: 1px solid var(--border);
      border-radius: 8px;
      box-shadow: none;
    }
    .overall-metrics {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
      gap: 1.5rem;
      font-size: 0.9rem;
    }
    .overall-metric {
      display: flex;
      flex-direction: column;
      gap: 0.25rem;
    }
    .overall-metric-label {
      color: var(--text-muted);
      font-size: 0.75rem;
      text-transform: uppercase;
      letter-spacing: 0.04em;
    }
    .overall-metric-value {
      color: var(--text-primary);
      font-family: var(--monospace-font);
      font-weight: 600;
      font-size: 1.1rem;
    }
    .plan-section {
      margin-bottom: 2rem;
    }
    .plan-section:last-child {
      margin-bottom: 0;
    }
    .plan-section-title {
      margin: 0 0 1rem;
      font-size: 1.15rem;
      font-weight: 600;
      color: var(--text-primary);
    }
    .plan-section-more {
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      gap: 0.75rem;
      margin-top: 0.75rem;
    }
    .plan-section-more-meta {
      font-size: 0.8rem;
      color: var(--text-muted);
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
      color: var(--text-primary);
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
export class PlanHubComponent implements OnInit {
  items: PlanItem[] = [];
  planCards: PlanCardRow[] = [];
  planSections: PlanSection[] = [];
  metricsSummary: MetricsSummary | null = null;
  loading = false;
  metricsLoading = false;
  error = '';
  metricsError = '';

  /** Visible row cap per `PlanSection.key`; reset when plan list or metrics rebuild. */
  private sectionVisibleRowCap: Record<string, number> = {};

  private apiService = inject(ApiService);
  private navService = inject(NavService);
  private planLogResolution = inject(PlanLogResolutionService);
  private workspaceSelector = inject(WorkspaceSelectorService);
  private cdr = inject(ChangeDetectorRef);
  private skipWorkspaceReloadEffect = true;

  constructor() {
    effect(() => {
      this.workspaceSelector.selectedWorkspacePath();
      if (this.skipWorkspaceReloadEffect) {
        return;
      }
      this.fetchPlans();
    });
  }

  ngOnInit(): void {
    this.fetchPlans();
    this.fetchMetrics();
    queueMicrotask(() => {
      this.skipWorkspaceReloadEffect = false;
    });
  }

  fetchPlans(): void {
    this.loading = true;
    this.error = '';
    this.cdr.markForCheck();

    const selectedProject = this.workspaceSelector.selectedWorkspacePath();
    const registryEntry = selectedProject
      ? this.workspaceSelector.workspaces().find((w) => w.path === selectedProject)
      : undefined;
    const scopedWorkspaceRoot = registryEntry?.workspaceRoot;

    this.apiService.fetchListing('logs', '', scopedWorkspaceRoot).subscribe({
      next: (response) => {
        // Filter for directories (these are the plan folders)
        this.items = response.entries
          .filter((entry) => entry.type === 'dir')
          .map((entry) => ({
            name: entry.name,
            path: entry.path,
            mtime: entry.mtime,
            hasLogs: true, // Since we're now using logs dir for plans, all have logs
            workspaceRoot: entry.workspaceRoot,
          }))
          .sort((a, b) => b.mtime - a.mtime);
        this.loading = false;
        this.rebuildPlanFolderMetrics();
        this.cdr.markForCheck();
      },
      error: (err) => {
        const missingLogsMessage =
          'Logs directory not found (.ralph-workspace/logs). Run a plan or set RALPH_DASHBOARD_WORKSPACE_ROOT to the workspace before loading plans.';
        this.error =
          err.status === 404 ? missingLogsMessage : err.error?.error || 'Failed to load plans';
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
        this.rebuildPlanFolderMetrics();
        this.cdr.markForCheck();
      },
      error: (err) => {
        this.metricsError = err.error?.error || 'Failed to load metrics';
        this.metricsLoading = false;
        this.metricsSummary = null;
        this.rebuildPlanFolderMetrics();
        this.cdr.markForCheck();
      },
    });
  }

  openUsage(): void {
    this.navService.navigate('usage');
  }

  openPlan(item: PlanItem): void {
    const directory = this.planLogResolution.resolvePlanDirectory(item.path);
    if (!directory) {
      return;
    }

    const planFile = `${directory}.md`;
    this.navService.navigate('plans', '', planFile, null, this.projectRootForPlanItem(item));
  }

  viewLogs(row: PlanItem | PlanCardRow): void {
    const dir = this.planLogResolution.resolvePlanDirectory(row.path);
    if (!dir) {
      return;
    }

    const ws =
      ('folderMetrics' in row && row.folderMetrics?.workspace_root?.trim()) ||
      row.workspaceRoot?.trim() ||
      undefined;
    this.planLogResolution.resolveLatestLogTarget(dir, ws).subscribe({
      next: (target) => {
        if (target.file) {
          const dirArg = target.directory ?? '';
          this.navService.navigate('logs', dirArg, target.file, ws ?? null);
        } else if (target.directory) {
          this.navService.navigate('logs', target.directory, null, ws ?? null);
        } else {
          this.navService.navigate('logs', null, null, ws ?? null);
        }
      },
    });
  }

  formatNumber(value: number): string {
    return new Intl.NumberFormat().format(value);
  }

  formatSeconds(value: number): string {
    return formatElapsedSeconds(value);
  }

  formatTokens(item: MetricsSummaryItem): string {
    const total =
      item.input_tokens + item.output_tokens + item.cache_creation_input_tokens + item.cache_read_input_tokens;
    if (total <= 0) {
      return '--';
    }
    return this.formatNumber(total);
  }

  formatOverallTokens(overall: MetricsSummaryOverall): string {
    const total =
      overall.input_tokens + overall.output_tokens + overall.cache_creation_input_tokens + overall.cache_read_input_tokens;
    if (total <= 0) {
      return '--';
    }
    return this.formatNumber(total);
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

  overallMetricsTitle(): string {
    const selected = this.workspaceSelector.selectedWorkspacePath();
    if (selected) {
      const entry = this.workspaceSelector.workspaces().find((w) => w.path === selected);
      if (entry) {
        return `Overall Metrics (${entry.label})`;
      }
    }
    return 'Overall Metrics';
  }

  displayOverallMetrics(): MetricsSummaryOverall | null {
    const summary = this.metricsSummary;
    if (!summary?.overall) {
      return null;
    }
    const selected = this.workspaceSelector.selectedWorkspacePath();
    const entry = selected ? this.workspaceSelector.workspaces().find((w) => w.path === selected) : undefined;
    if (entry?.workspaceRoot && summary.projects?.length) {
      const rollup = summary.projects.find((p) => p.workspace_root === entry.workspaceRoot);
      if (rollup?.overall) {
        return rollup.overall;
      }
    }
    return summary.overall;
  }

  totalPlanRows(): number {
    return this.planSections.reduce((sum, s) => sum + s.rows.length, 0);
  }

  visibleRowsForSection(section: PlanSection): PlanCardRow[] {
    const cap = this.sectionVisibleRowCap[section.key] ?? INITIAL_PLAN_ROWS_PER_SECTION;
    return section.rows.slice(0, Math.min(cap, section.rows.length));
  }

  remainingRowsInSection(section: PlanSection): number {
    const cap = this.sectionVisibleRowCap[section.key] ?? INITIAL_PLAN_ROWS_PER_SECTION;
    return Math.max(0, section.rows.length - cap);
  }

  showMoreCount(section: PlanSection): number {
    return Math.min(PLAN_ROWS_LOAD_MORE_STEP, this.remainingRowsInSection(section));
  }

  showMoreForSection(section: PlanSection): void {
    const cur = this.sectionVisibleRowCap[section.key] ?? INITIAL_PLAN_ROWS_PER_SECTION;
    const next = Math.min(cur + PLAN_ROWS_LOAD_MORE_STEP, section.rows.length);
    this.sectionVisibleRowCap = { ...this.sectionVisibleRowCap, [section.key]: next };
    this.cdr.markForCheck();
  }

  private rebuildPlanFolderMetrics(): void {
    this.sectionVisibleRowCap = {};
    const summary = this.metricsSummary;
    const lookup = summary ? buildPlanFolderMetricLookup(summary) : null;
    this.planCards = this.items.map((item) => ({
      ...item,
      folderMetrics: lookup
        ? rollupFolderMetrics(lookupFolderMetricRows(lookup, item.name, item.workspaceRoot), item.name)
        : null,
      mtimeLabel: this.formatMtimeLabel(item.mtime),
    }));
    this.planSections = this.groupPlanCardsIntoSections(this.planCards);
  }

  private groupPlanCardsIntoSections(rows: PlanCardRow[]): PlanSection[] {
    const order: string[] = [];
    const map = new Map<string, PlanCardRow[]>();
    for (const row of rows) {
      const key = row.workspaceRoot ?? '__default__';
      if (!map.has(key)) {
        order.push(key);
        map.set(key, []);
      }
      map.get(key)!.push(row);
    }
    return order.map((key) => ({
      key,
      label: key === '__default__' ? 'Workspace' : this.sectionLabelForWorkspaceRoot(key),
      workspaceRoot: key === '__default__' ? undefined : key,
      rows: map.get(key)!,
    }));
  }

  private sectionLabelForWorkspaceRoot(workspaceRoot: string): string {
    const entry = this.workspaceSelector.workspaces().find((w) => w.workspaceRoot === workspaceRoot);
    return entry?.label ?? workspaceRoot.split('/').filter(Boolean).pop() ?? workspaceRoot;
  }

  private projectRootForPlanItem(item: PlanItem): string | null {
    const ws = item.workspaceRoot?.trim();
    if (!ws) {
      return null;
    }
    const entry = this.workspaceSelector.workspaces().find((w) => w.workspaceRoot === ws);
    return entry?.projectRoot ?? null;
  }

  private formatMtimeLabel(mtimeMs: number): string {
    const d = new Date(mtimeMs);
    const pad = (n: number) => n.toString().padStart(2, '0');
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
  }

}
