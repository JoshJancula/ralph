import { ChangeDetectionStrategy, Component, OnInit, computed, inject, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { ActivatedRoute, RouterLink } from '@angular/router';
import { firstValueFrom } from 'rxjs';
import {
  ApiService,
  DiscoverReport,
  ListingEntry,
  PlanRunDetail,
  PlanRunEvidenceEntry,
  PlanRunListItem,
  WorkspaceRegistry,
} from '../../services/api.service';
import { WorkspaceSelectorService } from '../../services/workspace-selector.service';
import { NavService } from '../../services/nav.service';
import { ErrorModalComponent } from '../error-modal/error-modal.component';
import { formatElapsedSeconds } from '../../utils/format-elapsed';
import {
  concisePlanRunEvidencePath,
  formatEvidenceByteSize,
  groupPlanRunEvidence,
} from '../../utils/plan-run-evidence-groups';

function normalizeProjectRoot(path: string): string {
  return path.replace(/\\/g, '/').replace(/\/+$/, '');
}

function planKeyFromPath(planPath: string): string {
  const normalized = planPath.replace(/\\/g, '/');
  return normalized.slice(normalized.lastIndexOf('/') + 1).replace(/\.md$/i, '');
}

function findingText(entry: Record<string, unknown>): string {
  const summary = entry['summary'] ?? entry['description'] ?? entry['finding'] ?? entry['id'];
  return typeof summary === 'string' && summary ? summary : JSON.stringify(entry);
}

@Component({
  selector: 'ralph-plan-logs',
  standalone: true,
  imports: [CommonModule, RouterLink, ErrorModalComponent],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="plan-logs hub-page" data-testid="plan-runs-page">
      <a class="back-link" [routerLink]="['/plan-detail', planPath() || '.']" [queryParams]="{ projectRoot: projectRoot() }">Back to plan</a>
      <header class="page-header">
        <div>
          <h1 class="page-title">Plan runs</h1>
          <p class="page-lede">Select a run, then inspect attributed evidence. Every file opens in the log or file viewer.</p>
        </div>
      </header>
      @if (loading()) {
        <p class="state">Loading runs…</p>
      } @else if (error()) {
        <div class="error-embed" role="alert">
          <ralph-error-modal class="is-embedded" [error]="error()" [embedded]="true" [showHeader]="false" />
        </div>
      } @else if (runs().length === 0) {
        <p class="state" data-testid="plan-runs-empty">
          No runs have been recorded for this plan yet. Run <code>ralph run --plan &lt;plan&gt;</code> to create logs under this plan key.
        </p>
      } @else {
        <section class="run-list" data-testid="plan-runs-list">
          @for (run of runs(); track run.runId) {
            <a
              class="run-card"
              [class.selected]="run.runId === selectedRunId()"
              [routerLink]="['/plan-runs', run.runId]"
              [queryParams]="{ projectRoot: projectRoot(), plan: planPath() }"
              data-testid="plan-run-card"
            >
              <div class="run-card-head">
                <strong class="run-id">{{ run.runId }}</strong>
                <span class="status-badge">{{ run.status }}</span>
              </div>
              @if (run.source === 'legacy') {
                <span class="compat-badge" data-testid="run-card-legacy-badge">Legacy layout</span>
              }
              <p class="run-card-meta">
                {{ run.runtime || 'runtime unset' }} · {{ run.model || 'model unset' }}
              </p>
              <p class="run-card-meta">
                {{ durationLabel(run) }}
                · todos {{ run.todosDone ?? '—' }} / {{ run.todosTotal ?? '—' }}
                · tokens {{ run.inputTokens + run.outputTokens }}
              </p>
            </a>
          }
        </section>

        @if (detail(); as d) {
          <article class="run-detail" data-testid="plan-run-detail">
            <header class="run-overview hub-panel-card" data-testid="run-overview">
              <div class="run-overview-head">
                <h2 class="page-title" data-testid="run-headline-status">{{ d.status }}</h2>
                @if (d.source === 'legacy') {
                  <span class="compat-badge" data-testid="run-legacy-badge">Legacy compatibility</span>
                } @else {
                  <span class="source-badge" data-testid="run-manifest-badge">Manifest-backed</span>
                }
              </div>
              <p class="run-id-line">{{ d.runId }}</p>
              @if (d.source === 'legacy') {
                <p class="state legacy-note" data-testid="run-legacy-note">
                  Attributed from plan-level logs (synthetic run). Full evidence for this layout is shown below.
                </p>
              }
              @if (selectedRun(); as card) {
                <p class="run-timing" data-testid="run-timing">
                  @if (card.startedAt || card.endedAt) {
                    {{ card.startedAt || 'start unknown' }} → {{ card.endedAt || 'end unknown' }}
                  } @else {
                    Timing not recorded for this run.
                  }
                </p>
              }
            </header>

            <section class="usage-tiles" data-testid="run-usage-tiles">
              <div class="tile"><span>Input tokens</span><strong>{{ d.usage.inputTokens }}</strong></div>
              <div class="tile"><span>Output tokens</span><strong>{{ d.usage.outputTokens }}</strong></div>
              <div class="tile"><span>Duration</span><strong>{{ durationFromUsage(d) }}</strong></div>
              <div class="tile"><span>Todos</span><strong>{{ d.usage.todosDone ?? '—' }} / {{ d.usage.todosTotal ?? '—' }}</strong></div>
            </section>

            <section class="hub-panel-card evidence-panel" data-testid="run-evidence">
              <div class="evidence-panel-head">
                <h3>Run evidence</h3>
                <span class="evidence-count" data-testid="run-evidence-count">{{ d.files.evidence.length }} files</span>
              </div>
              @if (d.files.evidence.length === 0) {
                <p class="state" data-testid="run-evidence-empty">
                  No evidence files were discovered for this run. Check the Logs sidebar or run the plan again.
                </p>
              } @else {
                @for (group of evidenceGroups(); track group.id) {
                  <div class="evidence-group" [attr.data-testid]="'run-evidence-group-' + group.id">
                    <h4>{{ group.title }} ({{ group.entries.length }})</h4>
                    <ul class="evidence-list">
                      @for (entry of group.entries; track entry.id) {
                        <li class="evidence-row">
                          <button
                            type="button"
                            class="evidence-link"
                            data-testid="run-evidence-open"
                            [attr.data-evidence-category]="entry.category"
                            (click)="openEvidence(entry)"
                          >
                            {{ entry.label }}
                          </button>
                          <span class="path" [attr.title]="entry.path">{{ concisePath(entry.path, d.planKey) }}</span>
                          <span class="evidence-meta">{{ entry.format }} · {{ formatSize(entry.sizeBytes) }}</span>
                        </li>
                      }
                    </ul>
                  </div>
                }
              }
            </section>

            <section class="hub-panel-card" data-testid="run-timeline">
              <h3>Timeline</h3>
              @if (d.timeline.length === 0) {
                <p class="state">No timeline events. Invocation history may be missing for older runs.</p>
              } @else {
                <ul>
                  @for (event of d.timeline; track event.at + event.prose) {
                    <li>{{ event.at }} — {{ event.prose }}</li>
                  }
                </ul>
              }
            </section>

            @if (d.operatorNext; as next) {
              <section class="hub-panel-card" data-testid="run-operator-next">
                <h3>Next action</h3>
                <p>{{ next.label }}</p>
                <p class="state">{{ next.description }}</p>
              </section>
            }

            <section class="hub-panel-card" data-testid="run-resume">
              <h3>Resume</h3>
              <p data-testid="run-resume-count">{{ d.resume.resumableTodoCount }} TODOs have exact sessions that can be resumed.</p>
              <p class="state">Copy this command. The dashboard does not launch runs.</p>
              <pre data-testid="run-resume-command">{{ d.resume.command }}</pre>
            </section>

            <section class="hub-panel-card" data-testid="run-artifacts">
              <h3>Artifacts</h3>
              @if (artifacts().length === 0) {
                <p class="state" data-testid="run-artifacts-empty">No artifacts in this namespace. Generated outputs live under Artifacts in the sidebar.</p>
              } @else {
                <ul class="file-list">
                  @for (entry of artifacts(); track entry.path) {
                    <li>
                      <button type="button" class="artifact-link" data-testid="run-artifact-file" (click)="openArtifact(entry)">
                        {{ entry.name }}
                      </button>
                      <span class="path">{{ entry.name }}</span>
                    </li>
                  }
                </ul>
              }
            </section>

            <section class="hub-panel-card" data-testid="run-discover">
              <h3>Discover findings</h3>
              @if (!discoverReport()) {
                <p class="state" data-testid="run-discover-missing">No discover report for this plan. Open discover-report.json from evidence when present.</p>
              } @else {
                <div data-testid="discover-sequence-patterns">
                  <h4>Sequence patterns</h4>
                  @if ((discoverReport()?.sequence_patterns ?? []).length === 0) {
                    <p class="state">None</p>
                  } @else {
                    <ul>
                      @for (pattern of discoverReport()!.sequence_patterns!; track pattern.pattern_id) {
                        <li>{{ pattern.pattern_id }} ({{ pattern.count }}){{ pattern.description ? ' — ' + pattern.description : '' }}</li>
                      }
                    </ul>
                  }
                </div>
                <div data-testid="discover-aggregate-findings">
                  <h4>Aggregate findings</h4>
                  @if ((discoverReport()?.aggregate_findings ?? []).length === 0) {
                    <p class="state">None</p>
                  } @else {
                    <ul>
                      @for (finding of discoverReport()!.aggregate_findings!; track $index) {
                        <li>{{ findingText(finding) }}</li>
                      }
                    </ul>
                  }
                </div>
                <div data-testid="discover-runtime-differences">
                  <h4>Runtime differences</h4>
                  @if ((discoverReport()?.runtime_differences ?? []).length === 0) {
                    <p class="state">None</p>
                  } @else {
                    <ul>
                      @for (finding of discoverReport()!.runtime_differences!; track $index) {
                        <li>{{ findingText(finding) }}</li>
                      }
                    </ul>
                  }
                </div>
                <div data-testid="discover-high-token">
                  <h4>High token, low cache</h4>
                  @if ((discoverReport()?.high_token_low_cache_invocations ?? []).length === 0) {
                    <p class="state">None</p>
                  } @else {
                    <ul>
                      @for (finding of discoverReport()!.high_token_low_cache_invocations!; track $index) {
                        <li>{{ findingText(finding) }}</li>
                      }
                    </ul>
                  }
                </div>
              }
            </section>
          </article>
        }
      }
    </div>
  `,
  styles: `
    :host { display:flex; flex:1; min-height:0; }
    .plan-logs { background:var(--surface); }
    .state { color:var(--text-muted); }
    .error-embed { max-width: 40rem; }
    .run-list { display:grid; gap:var(--space-2); margin-bottom:var(--space-5); }
    .run-card {
      display:grid; gap:var(--space-1);
      padding:var(--space-3) var(--space-4); border:1px solid var(--border);
      border-radius:var(--radius-md); color:var(--text-primary); text-decoration:none;
    }
    .run-card.selected, .run-card:hover { border-color:var(--accent); background:var(--surface-hover); }
    .run-card-head { display:flex; justify-content:space-between; gap:var(--space-3); align-items:flex-start; }
    .run-id { word-break:break-all; font-size:var(--font-size-sm); }
    .run-card-meta { color:var(--text-muted); font-size:var(--font-size-sm); margin:0; }
    .status-badge, .compat-badge, .source-badge {
      font-size:var(--font-size-xs); padding:var(--space-1) var(--space-2);
      border-radius:var(--radius-sm); border:1px solid var(--border); text-transform:lowercase;
    }
    .compat-badge { color:var(--text-muted); background:var(--surface-hover); }
    .source-badge { color:var(--text-primary); }
    .run-detail { display:grid; gap:var(--space-4); }
    .run-overview-head { display:flex; flex-wrap:wrap; gap:var(--space-2); align-items:center; justify-content:space-between; }
    .run-id-line { font-family:var(--monospace-font); font-size:var(--font-size-sm); word-break:break-all; margin:0; }
    .run-timing { font-size:var(--font-size-sm); color:var(--text-muted); margin:0; }
    .legacy-note { margin:var(--space-2) 0 0; }
    .usage-tiles { display:grid; grid-template-columns:repeat(auto-fit, minmax(8rem, 1fr)); gap:var(--space-2); }
    .tile {
      border:1px solid var(--border); border-radius:var(--radius-md);
      padding:var(--space-3); display:grid; gap:var(--space-1);
    }
    .tile span { color:var(--text-muted); font-size:var(--font-size-xs); }
    .evidence-panel-head { display:flex; justify-content:space-between; align-items:baseline; gap:var(--space-2); }
    .evidence-count { color:var(--text-muted); font-size:var(--font-size-sm); }
    .evidence-group { margin-top:var(--space-4); }
    .evidence-group:first-of-type { margin-top:var(--space-2); }
    .evidence-group h4 { margin:0 0 var(--space-2); font-size:var(--font-size-sm); }
    .evidence-list { list-style:none; padding:0; margin:0; display:grid; gap:var(--space-2); }
    .evidence-row {
      display:grid; gap:var(--space-1);
      grid-template-columns:minmax(0, 1fr);
      padding:var(--space-2) 0; border-bottom:1px solid var(--border);
    }
    .evidence-row:last-child { border-bottom:none; }
    @media (min-width: 40rem) {
      .evidence-row {
        grid-template-columns:minmax(8rem, 1.2fr) minmax(0, 1.5fr) auto;
        align-items:center; gap:var(--space-3);
      }
    }
    .path { color:var(--text-muted); font-family:var(--monospace-font); font-size:var(--font-size-xs); overflow:hidden; text-overflow:ellipsis; }
    .evidence-meta { color:var(--text-muted); font-size:var(--font-size-xs); white-space:nowrap; }
    .file-list { list-style:none; padding:0; margin:0; display:grid; gap:var(--space-2); }
    .file-list li { display:flex; justify-content:space-between; gap:var(--space-3); flex-wrap:wrap; }
    .evidence-link, .artifact-link {
      background:none; border:none; padding:0; color:var(--accent); cursor:pointer;
      text-align:left; font:inherit; text-decoration:underline;
    }
    h4 { margin:var(--space-3) 0 var(--space-1); font-size:var(--font-size-sm); }
  `,
})
export class PlanLogsComponent implements OnInit {
  private readonly api = inject(ApiService);
  private readonly route = inject(ActivatedRoute);
  private readonly workspaceSelector = inject(WorkspaceSelectorService);
  private readonly nav = inject(NavService);

  readonly runs = signal<readonly PlanRunListItem[]>([]);
  readonly detail = signal<PlanRunDetail | null>(null);
  readonly discoverReport = signal<DiscoverReport | null>(null);
  readonly artifacts = signal<readonly ListingEntry[]>([]);
  readonly loading = signal(true);
  readonly error = signal<unknown>(null);
  readonly planPath = signal('');
  readonly projectRoot = signal<string | null>(null);
  readonly workspaceRoot = signal<string | null>(null);
  readonly selectedRunId = signal('');

  readonly selectedRun = computed(() => {
    const id = this.selectedRunId();
    return this.runs().find((run) => run.runId === id);
  });

  readonly evidenceGroups = computed(() => {
    const evidence = this.detail()?.files.evidence ?? [];
    return groupPlanRunEvidence(evidence);
  });

  findingText = findingText;
  concisePath = concisePlanRunEvidencePath;
  formatSize = formatEvidenceByteSize;

  openEvidence(entry: PlanRunEvidenceEntry): void {
    this.nav.navigate(
      entry.target.root,
      '',
      entry.target.path,
      this.workspaceRoot(),
      this.projectRoot(),
    );
  }

  openArtifact(entry: ListingEntry): void {
    const slash = entry.path.lastIndexOf('/');
    const dir = slash >= 0 ? entry.path.slice(0, slash) : '';
    this.nav.navigate(
      'artifacts',
      dir || null,
      entry.path,
      this.workspaceRoot(),
      this.projectRoot(),
    );
  }

  durationLabel(run: PlanRunListItem): string {
    if (run.elapsedSeconds != null) {
      return formatElapsedSeconds(run.elapsedSeconds);
    }
    return 'duration unknown';
  }

  durationFromUsage(detail: PlanRunDetail): string {
    if (detail.usage.elapsedSeconds != null) {
      return formatElapsedSeconds(detail.usage.elapsedSeconds);
    }
    return 'unknown';
  }

  async ngOnInit(): Promise<void> {
    const planPath = this.route.snapshot.paramMap.get('file') ?? this.route.snapshot.queryParamMap.get('plan') ?? '';
    const runIdParam = this.route.snapshot.paramMap.get('runId') ?? '';
    const projectRoot = this.route.snapshot.queryParamMap.get('projectRoot');
    this.planPath.set(planPath);
    this.projectRoot.set(projectRoot);
    this.selectedRunId.set(runIdParam);

    try {
      const workspaces = await firstValueFrom(this.api.fetchWorkspaces());
      const workspace = this.resolveWorkspace(workspaces, projectRoot);
      if (!workspace) {
        throw new Error(
          projectRoot
            ? 'The plan workspace is unavailable for the selected project.'
            : 'Select a project before opening plan logs, or open the plan from the inventory so its project is known.',
        );
      }

      if (this.workspaceSelector.selectedWorkspacePath() !== workspace.projectRoot) {
        this.workspaceSelector.selectWorkspace(workspace.projectRoot);
      }

      this.workspaceRoot.set(workspace.workspaceRoot);
      this.projectRoot.set(workspace.projectRoot);

      if (runIdParam) {
        const detail = await firstValueFrom(this.api.fetchPlanRunDetail(runIdParam, workspace.workspaceRoot));
        this.detail.set(detail);
        this.planPath.set(planPath || detail.planKey);
        const listed = await firstValueFrom(this.api.fetchPlanRuns(detail.planKey, workspace.workspaceRoot));
        this.runs.set(listed.items);
        await this.loadDiscover(detail);
        await this.loadArtifacts(detail.planKey);
        return;
      }

      const planKey = planKeyFromPath(planPath);
      const listed = await firstValueFrom(this.api.fetchPlanRuns(planKey, workspace.workspaceRoot));
      this.runs.set(listed.items);
      const first = listed.items[0];
      if (first) {
        this.selectedRunId.set(first.runId);
        const detail = await firstValueFrom(this.api.fetchPlanRunDetail(first.runId, workspace.workspaceRoot));
        this.detail.set(detail);
        await this.loadDiscover(detail);
        await this.loadArtifacts(detail.planKey);
      }
    } catch (error) {
      this.error.set(error);
    } finally {
      this.loading.set(false);
    }
  }

  private async loadDiscover(detail: PlanRunDetail): Promise<void> {
    if (!detail.planKey) {
      this.discoverReport.set(null);
      return;
    }
    try {
      const report = await firstValueFrom(this.api.fetchDiscoverReport(detail.planKey, this.workspaceRoot() ?? undefined));
      this.discoverReport.set(report.report);
    } catch {
      this.discoverReport.set(null);
    }
  }

  private artifactsListPath(planKey: string): string {
    return planKey.replace(/^artifacts\//, '');
  }

  private async loadArtifacts(planKey: string): Promise<void> {
    if (!planKey) {
      this.artifacts.set([]);
      return;
    }
    try {
      const listing = await firstValueFrom(
        this.api.fetchListing('artifacts', this.artifactsListPath(planKey), this.workspaceRoot() ?? undefined),
      );
      this.artifacts.set(listing.entries.filter((entry) => entry.type === 'file'));
    } catch {
      this.artifacts.set([]);
    }
  }

  private resolveWorkspace(
    workspaces: readonly WorkspaceRegistry[],
    projectRoot: string | null,
  ): WorkspaceRegistry | undefined {
    if (projectRoot) {
      const target = normalizeProjectRoot(projectRoot);
      return workspaces.find((item) => normalizeProjectRoot(item.projectRoot) === target);
    }

    const selected = this.workspaceSelector.selectedWorkspacePath();
    if (selected) {
      const target = normalizeProjectRoot(selected);
      return workspaces.find((item) => normalizeProjectRoot(item.projectRoot) === target);
    }

    return undefined;
  }
}
