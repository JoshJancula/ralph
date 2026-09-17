import { Component, Input, OnDestroy, OnInit, computed, effect, inject, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { IonSpinner, IonButton } from '@ionic/angular/standalone';
import { Router, RouterModule, ActivatedRoute } from '@angular/router';
import { ApiService, FileChunk } from '../../services/api.service';
import { NavService } from '../../services/nav.service';
import { PlanParserService, ParsedPlan } from '../../services/plan-parser.service';
import { WorkspaceSelectorService } from '../../services/workspace-selector.service';
import { ResourceError } from '../../../shared/resource-error';
import { markdownToHtml } from '../../utils/markdown-to-html';
import { DomSanitizer, SafeHtml } from '@angular/platform-browser';
import { Subscription } from 'rxjs';
import { ErrorModalComponent } from '../error-modal/error-modal.component';

type ViewMode = 'rendered' | 'source' | 'diff';

@Component({
  selector: 'app-plan-detail',
  standalone: true,
  imports: [
    CommonModule,
    IonSpinner,
    IonButton,
    RouterModule,
    ErrorModalComponent,
  ],
  templateUrl: './plan-detail.component.html',
  styleUrls: ['./plan-detail.component.scss'],
})
export class PlanDetailComponent implements OnInit, OnDestroy {
  private readonly api = inject(ApiService);
  private readonly nav = inject(NavService);
  private readonly parser = inject(PlanParserService);
  private readonly sanitizer = inject(DomSanitizer);
  private readonly route = inject(ActivatedRoute);
  private readonly router = inject(Router);
  private readonly workspaceSelector = inject(WorkspaceSelectorService);

  @Input() root = signal<string>('plans');
  @Input() filePath = signal<string>('');
  @Input() controlCopyPath = signal<string | null>(null);
  @Input() projectRoot = signal<string | null>(null);

  viewMode = signal<ViewMode>('rendered');
  loading = signal<boolean>(false);
  error = signal<ResourceError | null>(null);

  primaryContent = signal<string>('');
  controlCopyContent = signal<string | null>(null);
  parsedPlan = signal<ParsedPlan | null>(null);
  selectedTodoIndex = signal<number | null>(null);

  primarySafeHtml = signal<SafeHtml | null>(null);
  sourceLineNumbers = computed(() => this.generateLineNumbers(this.primaryContent()));

  diffHtml = signal<SafeHtml | null>(null);

  isMutableControlCopy = signal<boolean>(false);
  activeRunId = signal<string | null>(null);
  activeRunProcessCount = signal<number | null>(null);
  activityDiscoveryError = signal<string | null>(null);
  private activityTimer: ReturnType<typeof setInterval> | null = null;
  private activityEnabled = false;

  showDiffMode = computed(() => {
    return this.controlCopyContent() !== null && this.controlCopyPath() !== null;
  });

  selectedTodo = computed(() => {
    const idx = this.selectedTodoIndex();
    const plan = this.parsedPlan();
    if (idx !== null && plan && idx < plan.todos.length) {
      return plan.todos[idx];
    }
    return null;
  });

  private loadSequence = 0;
  private loadSubscription: Subscription | null = null;

  constructor() {
    effect((onCleanup) => {
      const root = this.root();
      const filePath = this.filePath();

      if (!root || !filePath) {
        this.reset();
        return;
      }

      const subscription = this.loadPlanFiles(root, filePath);
      onCleanup(() => subscription.unsubscribe());
    });
  }

  ngOnInit(): void {
    // The component is also embedded by focused file-view tests and previews.
    // Registry polling belongs only to the routed plan-detail view.
    this.activityEnabled = this.route.snapshot?.routeConfig?.path === 'plan-detail/:file';
    // Query params (projectRoot, controlCopy) are read before the :file path param so the
    // load effect they gate never fires with a stale/default project scope on first load.
    this.route.queryParams.subscribe((params) => {
      const controlPath = params['controlCopy'];
      if (controlPath) {
        this.controlCopyPath.set(controlPath);
      }
      const projectRoot = params['projectRoot'];
      if (projectRoot) {
        this.projectRoot.set(projectRoot);
        if (this.workspaceSelector.selectedWorkspacePath() !== projectRoot) {
          this.workspaceSelector.selectWorkspace(projectRoot);
        }
      }
    });

    this.route.params.subscribe((params) => {
      const file = params['file'];
      if (file) {
        this.filePath.set(file);
      }
    });

    if (this.controlCopyPath()) {
      this.loadControlCopyContent();
    }
    if (this.activityEnabled) this.activityTimer = setInterval(() => this.refreshRunStatus(), 30_000);
  }

  ngOnDestroy(): void {
    if (this.activityTimer) clearInterval(this.activityTimer);
    this.loadSubscription?.unsubscribe();
  }

  selectTodo(index: number): void {
    this.selectedTodoIndex.set(index);
  }

  toggleViewMode(mode: ViewMode): void {
    if (mode === 'diff' && !this.showDiffMode()) {
      return;
    }
    this.viewMode.set(mode);
    if (mode === 'rendered' && this.primarySafeHtml() === null) {
      this.renderMarkdown();
    }
  }

  viewLogs(): void {
    void this.router.navigate(['/plan-detail', this.filePath(), 'logs'], {
      queryParams: { projectRoot: this.projectRoot() ?? this.nav.activeProjectRoot() ?? undefined },
    });
  }

  runPlan(): void {
    this.api.runLeafPlan(this.filePath(), this.projectRoot() ?? this.nav.activeProjectRoot() ?? undefined).subscribe({
      next: ({ run }) => this.activeRunId.set(run.id),
    });
  }

  stopPlan(): void {
    this.api.stopLeafPlan(this.filePath(), this.projectRoot() ?? this.nav.activeProjectRoot() ?? undefined).subscribe({
      next: () => { this.activeRunId.set(null); this.activeRunProcessCount.set(null); },
    });
  }

  private loadPlanFiles(root: string, filePath: string): Subscription {
    const requestToken = ++this.loadSequence;
    this.loading.set(true);
    this.error.set(null);

    return this.api
      .fetchFile(
        root,
        filePath,
        0,
        this.nav.activeWorkspaceRoot() ?? undefined,
        this.projectRoot() ?? this.nav.activeProjectRoot() ?? undefined,
      )
      .subscribe({
        next: (chunk) => {
          if (requestToken !== this.loadSequence) {
            return;
          }

          this.primaryContent.set(chunk.content);
          const parsed = this.parser.parsePlan(chunk.content);
          this.parsedPlan.set(parsed);
          this.refreshRunStatus();

          if (this.viewMode() === 'rendered') {
            void this.renderMarkdown();
          }

          this.loading.set(false);
        },
        error: (err) => {
          if (requestToken !== this.loadSequence) {
            return;
          }

          if (err && typeof err === 'object' && 'code' in err && 'title' in err) {
            this.error.set(err as ResourceError);
          } else {
            this.error.set({
              code: 'UNKNOWN',
              message: 'Failed to load plan',
              title: 'Error Loading Plan',
              explanation: 'An unexpected error occurred while loading the plan.',
              recoverable: true,
              suggestedActions: ['RETRY', 'RETURN_TO_PLANS'],
            });
          }
          this.loading.set(false);
        },
      });
  }

  private refreshRunStatus(): void {
    if (!this.activityEnabled) return;
    const path = this.filePath();
    if (!path) return;
    this.api.fetchLeafPlanRun(path, this.projectRoot() ?? this.nav.activeProjectRoot() ?? undefined).subscribe({
      next: ({ activeRun, activityDiscoveryError }) => {
        this.activeRunId.set(activeRun?.id ?? null);
        this.activeRunProcessCount.set(activeRun?.liveProcesses ?? null);
        this.activityDiscoveryError.set(activityDiscoveryError ?? null);
      },
      error: () => this.activityDiscoveryError.set('Unable to refresh Ralph process activity.'),
    });
  }

  private loadControlCopyContent(): void {
    const controlPath = this.controlCopyPath();
    if (!controlPath) return;

    this.api
      .fetchFile(
        'plans',
        controlPath,
        0,
        this.nav.activeWorkspaceRoot() ?? undefined,
        this.projectRoot() ?? this.nav.activeProjectRoot() ?? undefined,
      )
      .subscribe({
        next: (chunk) => {
          this.controlCopyContent.set(chunk.content);
          this.isMutableControlCopy.set(true);
          if (this.viewMode() === 'diff') {
            this.generateDiff();
          }
        },
        error: () => {
          this.controlCopyContent.set(null);
        },
      });
  }

  private async renderMarkdown(): Promise<void> {
    const content = this.primaryContent();
    if (!content) {
      this.primarySafeHtml.set(null);
      return;
    }

    const html = markdownToHtml(content);
    const doc = new DOMParser().parseFromString(html, 'text/html');

    this.primarySafeHtml.set(this.sanitizer.bypassSecurityTrustHtml(doc.body.innerHTML));
  }

  private generateDiff(): void {
    const primary = this.primaryContent();
    const control = this.controlCopyContent();

    if (!primary || !control) {
      return;
    }

    const diffText = this.createSimpleDiff(primary, control);
    const html = markdownToHtml(`\`\`\`diff\n${diffText}\n\`\`\``);
    const doc = new DOMParser().parseFromString(html, 'text/html');
    this.diffHtml.set(this.sanitizer.bypassSecurityTrustHtml(doc.body.innerHTML));
  }

  private createSimpleDiff(original: string, modified: string): string {
    const origLines = original.split('\n');
    const modLines = modified.split('\n');
    const diffLines: string[] = [];

    const maxLength = Math.max(origLines.length, modLines.length);

    for (let i = 0; i < maxLength; i++) {
      const origLine = origLines[i] ?? '';
      const modLine = modLines[i] ?? '';

      if (origLine === modLine) {
        diffLines.push(` ${origLine}`);
      } else {
        if (origLine) {
          diffLines.push(`-${origLine}`);
        }
        if (modLine) {
          diffLines.push(`+${modLine}`);
        }
      }
    }

    return diffLines.join('\n');
  }

  private generateLineNumbers(content: string): string[] {
    return content.split('\n').map((_, i) => String(i + 1));
  }

  private reset(): void {
    this.loading.set(false);
    this.error.set(null);
    this.primaryContent.set('');
    this.controlCopyContent.set(null);
    this.parsedPlan.set(null);
    this.selectedTodoIndex.set(null);
    this.primarySafeHtml.set(null);
    this.diffHtml.set(null);
  }

  performErrorAction(action: string): void {
    switch (action) {
      case 'RETRY':
        this.loadPlanFiles(this.root(), this.filePath());
        break;
      case 'RETURN_TO_PLANS':
        this.nav.navigate('plans');
        break;
    }
  }

  handleContentClick(event: MouseEvent): void {
    const anchor = (event.target as HTMLElement).closest('a');
    if (!anchor) return;

    const href = anchor.getAttribute('href');
    if (
      !href ||
      href.startsWith('http://') ||
      href.startsWith('https://') ||
      href.startsWith('//') ||
      href.startsWith('mailto:')
    ) {
      return;
    }

    event.preventDefault();

    const [filePart] = href.split('#');
    if (!filePart) return;

    const currentFile = this.filePath();
    const currentRoot = this.root();

    const currentDir = currentFile.split('/').filter(Boolean).slice(0, -1);
    const targetParts = filePart.startsWith('/')
      ? filePart.slice(1).split('/')
      : [...currentDir, ...filePart.split('/')];

    const resolved: string[] = [];
    for (const part of targetParts) {
      if (part === '..') {
        resolved.pop();
      } else if (part !== '.' && part !== '') {
        resolved.push(part);
      }
    }

    const targetPath = resolved.join('/');
    if (!targetPath) return;

    this.nav.navigate(
      currentRoot,
      null,
      targetPath,
      this.nav.activeWorkspaceRoot(),
      this.nav.activeProjectRoot(),
    );
  }
}
