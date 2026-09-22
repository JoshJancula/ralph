import { Component, OnDestroy, computed, effect, inject, input, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { RouterModule } from '@angular/router';
import { Subject } from 'rxjs';
import { takeUntil } from 'rxjs/operators';
import { WorkflowsApi } from '../../workflows/workflows-api.service';
import { RunListItem } from '../../workflows/workflow.types';
import { RouteLoadStateComponent } from '../route-load-state/route-load-state.component';
import { RequestLifecycleService } from '../../services/request-lifecycle.service';
import { WorkspaceSelectorService } from '../../services/workspace-selector.service';
import { beginInventoryFetch, isAbortError, shouldShowRouteSkeleton } from '../../utils/request-lifecycle';
import { markInventoryUsable } from '../../utils/perf-diagnostics';

export interface HomeSummaryItem {
  readonly id: string;
  readonly type: 'run' | 'approval' | 'verification-failure' | 'stalled';
  readonly project: string;
  readonly stage: string;
  readonly status: string;
  readonly elapsedSeconds?: number;
  readonly actionLabel: string;
  readonly actionHref: string;
  readonly priority: number;
}

@Component({
  selector: 'ralph-home-hub',
  standalone: true,
  imports: [CommonModule, RouterModule, RouteLoadStateComponent],
  template: `
    <div class="home-hub hub-page">
      @if (loading() || error() || items().length > 0) {
        <header class="page-header">
          <div class="header-brand">
            <img class="home-brand-mark" src="/images/ralph-wizard.jpg" alt="Ralph wizard programmer" width="56" height="36" />
            <div>
              <h1 class="page-title">Home</h1>
              <p class="page-lede">What needs you first, then what to continue.</p>
            </div>
          </div>
        </header>
      }

      <ralph-route-load-state
        [loading]="showLoadingSkeleton()"
        [errorDetail]="error()"
        [columns]="3"
        [rowCount]="4"
        (retry)="loadData()"
      />

      @if (!showLoadingSkeleton() && !error()) {
        @if (items().length === 0) {
          <div class="welcome" data-testid="home-empty">
            <section class="welcome-hero">
              <img
                class="welcome-mascot"
                src="/images/ralph-wizard.jpg"
                alt="Ralph wizard programmer"
                width="283"
                height="178"
              />
              <div class="welcome-copy">
                <p class="eyebrow">Ralph workspace</p>
                <h1>Keep every plan, run, and workflow in view.</h1>
                <p class="description">
                  Nothing needs attention right now. Start with a plan, review live runs, or launch a reusable workflow.
                </p>
              </div>
            </section>

            <section class="starting-grid" aria-label="Getting started">
              <a class="starting-card is-recommended" routerLink="/plans">
                <span class="step">Recommended</span>
                <h2>Plans</h2>
                <p>Find every discovered plan, its current TODO, progress, and latest activity.</p>
                <span class="card-link">Open plan inventory</span>
              </a>
              <a class="starting-card" routerLink="/runs">
                <span class="step">Next</span>
                <h2>Runs</h2>
                <p>Review live, waiting, completed, and failed execution evidence in one place.</p>
                <span class="card-link">Open run history</span>
              </a>
              <a class="starting-card" routerLink="/workflows">
                <span class="step">Then</span>
                <h2>Workflows</h2>
                <p>Choose a reusable delivery shape, inspect its stages, and start a durable run.</p>
                <span class="card-link">Open workflows</span>
              </a>
              <a class="starting-card" routerLink="/docs" data-testid="home-docs-card">
                <span class="step">Reference</span>
                <h2>Docs</h2>
                <p>Browse Ralph guides, workflow references, and dashboard-specific documentation.</p>
                <span class="card-link">Open documentation</span>
              </a>
            </section>

            <section class="cli-panel" aria-labelledby="home-cli-heading" data-testid="home-cli-panel">
              <header class="cli-chrome">
                <div class="cli-traffic" aria-hidden="true">
                  <span class="cli-dot is-close"></span>
                  <span class="cli-dot is-minimize"></span>
                  <span class="cli-dot is-maximize"></span>
                </div>
                <span class="cli-window-title">ralph — zsh</span>
              </header>
              <div class="cli-body">
                <div class="cli-copy">
                  <h2 id="home-cli-heading" class="cli-heading">Prefer the terminal?</h2>
                  <p class="cli-lede">
                    Run these from your Ralph project root (same CLI the dashboard calls). Leaf plans are a template
                    until you add TODOs with your coding agent;
                    <code class="cli-inline">ralph run --plan</code> and
                    <code class="cli-inline">ralph workflow start … --plan</code> also accept plans from Cursor
                    (<code class="cli-inline">~/.cursor/plans/</code>) or Claude Code
                    (<code class="cli-inline">~/.claude/plans/</code>). Workflows are reusable multi-stage runs.
                  </p>
                </div>
                <pre class="cli-screen" data-testid="home-cli-commands"><code><span class="cli-comment"># leaf plan: scaffold, then author checkboxes with your agent, then run</span>
<span class="cli-line"><span class="cli-prompt">$ </span><span class="cli-cmd">ralph create plan --format classic</span></span>
<span class="cli-comment"># open the new .plan.md and add - [ ] tasks (agent or editor) — create only writes the shell</span>
<span class="cli-line"><span class="cli-prompt">$ </span><span class="cli-cmd">ralph run --plan ./my.plan.md</span></span>
<span class="cli-comment"># or Cursor / Claude plans: ~/.cursor/plans/... or ~/.claude/plans/...</span>

<span class="cli-comment"># workflows: bundled or project definitions, multi-stage execution</span>
<span class="cli-line"><span class="cli-prompt">$ </span><span class="cli-cmd">ralph workflow list</span></span>
<span class="cli-line"><span class="cli-prompt">$ </span><span class="cli-cmd">ralph workflow show feature-delivery</span></span>
<span class="cli-line"><span class="cli-prompt">$ </span><span class="cli-cmd">ralph workflow start feature-delivery --task "Your task" --yes</span></span>
<span class="cli-comment"># planInput workflows (e.g. plan-delivery): --plan binds a repo leaf plan or ~/.cursor/plans / ~/.claude/plans</span>
<span class="cli-line"><span class="cli-prompt">$ </span><span class="cli-cmd">ralph workflow start plan-delivery --plan ~/.cursor/plans/your-plan.md --yes</span></span>
<span class="cli-line"><span class="cli-prompt">$ </span><span class="cli-cmd">ralph workflow status &lt;run-id&gt;</span></span>

<span class="cli-comment"># host plugins (Claude Code, Cursor, Codex, OpenCode, Antigravity)</span>
<span class="cli-line"><span class="cli-prompt">$ </span><span class="cli-cmd">ralph plugin list</span></span>
<span class="cli-line"><span class="cli-prompt">$ </span><span class="cli-cmd">ralph plugin status --runtime claude</span></span>
<span class="cli-line"><span class="cli-prompt">$ </span><span class="cli-cmd">ralph plugin install --runtime claude</span></span></code></pre>
                <p class="cli-plugin-note">
                  Install Ralph once per machine with <code class="cli-inline">install.sh --global</code> from a Ralph
                  checkout (CLI and bundle under <code class="cli-inline">$RALPH_HOME</code>; projects register as you
                  work in them). If you need committed <code class="cli-inline">.ralph/</code> files in the repo, run
                  <code class="cli-inline">./install.sh</code> or <code class="cli-inline">install.sh /path/to/repo</code>
                  in that codebase instead. Host runtime plugins are still a separate step via
                  <code class="cli-inline">ralph plugin</code> (pick <code class="cli-inline">--runtime claude</code>,
                  <code class="cli-inline">cursor</code>, <code class="cli-inline">codex</code>,
                  <code class="cli-inline">opencode</code>, or <code class="cli-inline">antigravity</code>). Use
                  <code class="cli-inline">--dry-run</code> to preview, then confirm in a TTY or pass
                  <code class="cli-inline">--yes</code> in CI. See the
                  <a routerLink="/docs">Docs</a> install guide.
                </p>
              </div>
            </section>
          </div>
        } @else {
          <div class="content" data-testid="home-inventory">
            @if (needsYouItems().length > 0) {
              <div class="attention-section">
                <h2 class="section-title">Needs you</h2>
                <div class="card-grid">
                  @for (item of needsYouItems(); track item.id) {
                    <a [routerLink]="item.actionHref" class="card" [class]="item.status">
                      <div class="card-header">
                        <p class="card-title">{{ item.project }}</p>
                        <span class="status-badge" [class]="item.status">{{ item.status }}</span>
                      </div>
                      <p class="card-stage">{{ item.stage }}</p>
                      @if (item.elapsedSeconds !== undefined) {
                        <p class="card-elapsed">{{ formatElapsed(item.elapsedSeconds) }}</p>
                      }
                      <div class="card-action">{{ item.actionLabel }}</div>
                    </a>
                  }
                </div>
              </div>
            }

            @if (continueItems().length > 0) {
              <div class="continue-section">
                <h2 class="section-title">Continue</h2>
                <div class="card-grid">
                  @for (item of continueItems(); track item.id) {
                    <a [routerLink]="item.actionHref" class="card" [class]="item.status">
                      <div class="card-header">
                        <p class="card-title">{{ item.project }}</p>
                        <span class="status-badge" [class]="item.status">{{ item.status }}</span>
                      </div>
                      <p class="card-stage">{{ item.stage }}</p>
                      @if (item.elapsedSeconds !== undefined) {
                        <p class="card-elapsed">{{ formatElapsed(item.elapsedSeconds) }}</p>
                      }
                      <div class="card-action">{{ item.actionLabel }}</div>
                    </a>
                  }
                </div>
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

    .home-hub {
      align-items: stretch;
      justify-content: flex-start;
      background: transparent;
    }

    .welcome {
      display: flex;
      flex-direction: column;
      width: min(100%, 76rem);
      gap: 1.25rem;
      margin: 1rem auto;
    }

    .welcome-hero {
      display: grid;
      grid-template-columns: auto minmax(0, 1fr);
      gap: 1.5rem;
      align-items: center;
      padding: clamp(1.5rem, 4vw, 2.5rem);
      border: 1px solid color-mix(in srgb, var(--border) 84%, transparent);
      border-radius: var(--radius-xl);
      background: linear-gradient(135deg, color-mix(in srgb, var(--accent) 8%, var(--surface)), var(--surface) 58%);
    }

    .welcome-mascot {
      display: block;
      width: min(14rem, 40vw);
      height: auto;
      border-radius: 12px;
      object-fit: cover;
    }

    .welcome-copy {
      min-width: 0;
    }

    .header-brand {
      display: flex;
      align-items: center;
      gap: 0.85rem;
    }

    .home-brand-mark {
      display: block;
      width: 3.5rem;
      height: auto;
      border-radius: 8px;
      object-fit: cover;
      flex: 0 0 auto;
    }

    .eyebrow,
    .step {
      margin: 0 0 0.7rem;
      color: var(--accent);
      font-size: 0.72rem;
      font-weight: 700;
      letter-spacing: 0.1em;
      text-transform: uppercase;
    }

    .welcome h1 {
      max-width: 42rem;
      margin: 0;
      color: var(--text-primary);
      font-size: clamp(1.8rem, 3vw, 2.7rem);
      line-height: 1.1;
      letter-spacing: -0.035em;
    }

    .welcome-hero .description {
      max-width: 42rem;
      margin-top: 1rem;
      font-size: 1rem;
      line-height: 1.55;
    }

    .starting-grid {
      display: grid;
      grid-template-columns: repeat(4, minmax(0, 1fr));
      gap: 0.9rem;
    }

    .starting-card {
      display: flex;
      min-height: 13rem;
      flex-direction: column;
      padding: 1.3rem;
      border: 1px solid var(--border);
      border-radius: var(--radius-lg);
      background: color-mix(in srgb, var(--surface-secondary) 88%, transparent);
      color: var(--text-primary);
      text-decoration: none;
      transition: border-color 0.16s ease, background 0.16s ease, transform 0.16s ease;
    }

    .starting-card.is-recommended {
      border-color: color-mix(in srgb, var(--accent) 50%, var(--border));
      background: color-mix(in srgb, var(--accent) 8%, var(--surface-secondary));
    }

    .starting-card:hover {
      border-color: color-mix(in srgb, var(--accent) 62%, var(--border));
      background: color-mix(in srgb, var(--surface-secondary) 93%, var(--accent));
      transform: translateY(-2px);
    }

    .starting-card h2 {
      margin: 0;
      font-size: 1.05rem;
    }

    .starting-card p {
      margin: 0.55rem 0 1.1rem;
      color: var(--text-muted);
      font-size: 0.87rem;
      line-height: 1.45;
    }

    .card-link {
      margin-top: auto;
      color: var(--accent);
      font-size: 0.84rem;
      font-weight: 650;
    }

    .cli-panel {
      overflow: hidden;
      border: 1px solid color-mix(in srgb, var(--border) 88%, transparent);
      border-radius: var(--radius-lg);
      background: var(--surface);
      box-shadow: 0 14px 40px rgb(0 0 0 / 22%);
    }

    .cli-chrome {
      display: flex;
      align-items: center;
      gap: 0.65rem;
      padding: 0.55rem 0.85rem;
      border-bottom: 1px solid color-mix(in srgb, var(--border) 90%, transparent);
      background: color-mix(in srgb, var(--surface-secondary) 92%, var(--code-bg));
    }

    .cli-traffic {
      display: flex;
      gap: 0.35rem;
    }

    .cli-dot {
      width: 0.62rem;
      height: 0.62rem;
      border-radius: 999px;
      background: color-mix(in srgb, var(--text-muted) 35%, var(--border));
    }

    .cli-dot.is-close {
      background: #ff5f57;
    }

    .cli-dot.is-minimize {
      background: #febc2e;
    }

    .cli-dot.is-maximize {
      background: #28c840;
    }

    .cli-window-title {
      flex: 1;
      min-width: 0;
      color: var(--text-muted);
      font-family: var(--monospace-font);
      font-size: 0.72rem;
      text-align: center;
      letter-spacing: 0.02em;
    }

    .cli-body {
      display: flex;
      flex-direction: column;
      gap: 0.85rem;
      padding: 1rem 1.15rem 1.15rem;
      background: linear-gradient(
        180deg,
        color-mix(in srgb, var(--code-bg) 42%, var(--surface)) 0%,
        color-mix(in srgb, var(--code-bg) 78%, var(--surface)) 100%
      );
    }

    .cli-copy {
      min-width: 0;
    }

    .cli-heading {
      margin: 0;
      color: var(--text-primary);
      font-size: 1rem;
      font-weight: 650;
    }

    .cli-lede {
      margin: 0.35rem 0 0;
      color: var(--text-muted);
      font-size: 0.84rem;
      line-height: 1.45;
    }

    .cli-screen {
      margin: 0;
      padding: 0.85rem 0.95rem;
      overflow-x: auto;
      border: 1px solid color-mix(in srgb, var(--border) 75%, transparent);
      border-radius: 10px;
      background: var(--code-bg);
      color: var(--text-primary);
      font-family: var(--monospace-font);
      font-size: 0.78rem;
      line-height: 1.55;
      tab-size: 2;
      white-space: pre;
    }

    .cli-screen code {
      display: block;
      font: inherit;
      background: transparent;
    }

    .cli-line {
      display: block;
    }

    .cli-prompt {
      color: color-mix(in srgb, var(--accent) 72%, #6ee7a8);
      user-select: none;
    }

    .cli-cmd {
      color: color-mix(in srgb, var(--text-primary) 92%, white);
    }

    .cli-comment {
      display: block;
      color: color-mix(in srgb, var(--text-muted) 88%, var(--accent));
    }

    .cli-plugin-note {
      margin: 0;
      color: var(--text-muted);
      font-size: 0.82rem;
      line-height: 1.5;
    }

    .cli-inline {
      padding: 0.08rem 0.35rem;
      border-radius: 4px;
      background: color-mix(in srgb, var(--code-bg) 55%, var(--surface-secondary));
      color: var(--text-primary);
      font-family: var(--monospace-font);
      font-size: 0.78em;
    }

    .cli-plugin-note a {
      color: var(--accent);
      font-weight: 600;
      text-decoration: none;
    }

    .cli-plugin-note a:hover {
      text-decoration: underline;
    }

    .content {
      display: flex;
      flex-direction: column;
      gap: 2.5rem;
      max-width: 1200px;
      margin: 0 auto;
      width: 100%;
    }

    .section-title {
      margin: 0 0 1rem 0;
      font-size: 1rem;
      font-weight: 600;
      color: var(--text-primary);
    }

    .card-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
      gap: 1rem;
    }

    .card {
      display: flex;
      flex-direction: column;
      gap: 0.75rem;
      padding: 1rem;
      border: 1px solid var(--border);
      border-radius: 6px;
      background: var(--surface-secondary);
      transition: all 0.2s ease;
      text-decoration: none;
      color: inherit;
      cursor: pointer;
    }

    .card:hover {
      border-color: var(--primary);
      box-shadow: 0 2px 8px rgba(0, 0, 0, 0.1);
      transform: translateY(-1px);
    }

    .card.active {
      border-left: 3px solid var(--primary);
    }

    .card.waiting {
      border-left: 3px solid var(--warning);
    }

    .card.failed {
      border-left: 3px solid var(--error);
    }

    .card-header {
      display: flex;
      justify-content: space-between;
      align-items: flex-start;
      gap: 0.5rem;
    }

    .card-title {
      margin: 0;
      font-size: 0.95rem;
      font-weight: 600;
      color: var(--text-primary);
      flex: 1;
    }

    .status-badge {
      font-weight: 500;

      &.active {
        background-color: rgba(74, 144, 226, 0.1);
        color: var(--info);
      }

      &.waiting {
        background-color: rgba(251, 146, 60, 0.1);
        color: var(--warning);
      }

      &.failed {
        background-color: rgba(239, 68, 68, 0.1);
        color: var(--error);
      }
    }

    .card-stage {
      margin: 0;
      font-size: 0.85rem;
      color: var(--text-muted);
    }

    .card-elapsed {
      margin: 0;
      font-size: 0.8rem;
      color: var(--text-secondary);
    }

    .card-action {
      margin-top: 0.5rem;
      padding-top: 0.75rem;
      border-top: 1px solid var(--border);
      font-size: 0.9rem;
      color: var(--primary);
      font-weight: 500;
    }

    .title {
      margin: 0;
      font-size: 1.25rem;
      font-weight: 600;
      color: var(--text-primary);
    }

    .description {
      margin: 0;
      font-size: 0.9rem;
      line-height: 1.45;
      color: var(--text-muted);
    }

    @media (max-width: 1024px) {
      .starting-grid {
        grid-template-columns: repeat(2, minmax(0, 1fr));
      }
    }

    @media (max-width: 720px) {
      .welcome-hero {
        grid-template-columns: 1fr;
        padding: var(--space-5);
      }

      .welcome-mascot {
        width: min(12rem, 55vw);
      }

      .starting-grid {
        grid-template-columns: 1fr;
      }

      .starting-card {
        min-height: 0;
      }

      .cli-screen {
        font-size: 0.72rem;
      }

      .card-grid {
        grid-template-columns: 1fr;
      }

      .content {
        gap: 2rem;
      }

      .card {
        min-height: var(--touch-target-min, 44px);
      }
    }
  `,
})
export class HomeHubComponent implements OnDestroy {
  readonly paneActive = input(false);

  private readonly workflowsApi = inject(WorkflowsApi);
  private readonly requestLifecycle = inject(RequestLifecycleService);
  private readonly workspaceSelector = inject(WorkspaceSelectorService);
  private readonly destroy$ = new Subject<void>();
  private static readonly SLOT = 'home-runs';

  private readonly allItems = signal<HomeSummaryItem[]>([]);
  readonly loading = signal(true);
  readonly hasLoadedOnce = signal(false);
  readonly showLoadingSkeleton = computed(() => shouldShowRouteSkeleton(this.loading(), this.hasLoadedOnce()));
  readonly error = signal<unknown>(null);

  readonly items = this.allItems;

  constructor() {
    effect(() => {
      if (!this.paneActive()) {
        return;
      }
      this.workspaceSelector.selectedWorkspacePath();
      this.loadData();
    });
  }

  readonly needsYouItems = computed(() => {
    return this.allItems().filter(
      (item) =>
        item.type === 'approval' ||
        item.type === 'verification-failure' ||
        item.type === 'stalled'
    );
  });

  readonly continueItems = computed(() => {
    return this.allItems().filter(
      (item) => item.type === 'run'
    );
  });

  ngOnDestroy(): void {
    this.requestLifecycle.cancel(HomeHubComponent.SLOT);
    this.destroy$.next();
    this.destroy$.complete();
  }

  loadData(): void {
    const handle = this.requestLifecycle.start(HomeHubComponent.SLOT, {
      project: this.workspaceSelector.selectedWorkspacePath(),
      view: 'home',
    });
    beginInventoryFetch(this.hasLoadedOnce(), (value) => this.loading.set(value));
    this.error.set(null);

    this.workflowsApi
      .listRuns({}, undefined, { signal: handle.signal })
      .pipe(takeUntil(this.destroy$))
      .subscribe({
        next: (runs) => {
          if (!this.requestLifecycle.isCurrent(handle)) {
            return;
          }
          const items = this.transformRuns(runs);
          this.allItems.set(items);
          this.hasLoadedOnce.set(true);
          this.loading.set(false);
          markInventoryUsable('home');
        },
        error: (err) => {
          if (!this.requestLifecycle.isCurrent(handle) || isAbortError(err)) {
            return;
          }
          this.error.set(err);
          this.hasLoadedOnce.set(true);
          this.loading.set(false);
        },
      });
  }

  private transformRuns(runs: readonly RunListItem[]): HomeSummaryItem[] {
    return runs
      .filter((run) => {
        const activeStates = ['active', 'waiting', 'pending', 'running', 'queued'];
        return activeStates.includes(run.state?.toLowerCase() || '');
      })
      .map((run) => {
        let type: HomeSummaryItem['type'] = 'run';
        let priority = 30;
        let actionLabel = 'Resume run';
        const state = run.state?.toLowerCase() || 'unknown';

        if (state === 'waiting') {
          type = 'approval';
          priority = 10;
          actionLabel = 'Respond to approval';
        }

        const createdMs = Date.parse(run.createdAt);
        const elapsedSeconds = Number.isFinite(createdMs)
          ? Math.max(0, (Date.now() - createdMs) / 1000)
          : undefined;

        const project = run.workflowId || 'Unknown';
        const stage = run.task || run.state || 'Unknown';

        return {
          id: run.runId,
          type,
          project,
          stage,
          status: state,
          elapsedSeconds,
          actionLabel,
          actionHref: `/workflows/runs/${run.runId}`,
          priority,
        };
      })
      .sort((a, b) => a.priority - b.priority)
      .slice(0, 10);
  }

  formatElapsed(seconds?: number): string {
    if (!seconds) return '';
    if (seconds < 60) return `${Math.round(seconds)}s`;
    if (seconds < 3600) return `${Math.round(seconds / 60)}m`;
    return `${Math.round(seconds / 3600)}h`;
  }
}
