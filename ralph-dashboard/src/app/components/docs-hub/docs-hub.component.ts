import { ChangeDetectionStrategy, Component, OnInit, computed, inject, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { RouterLink } from '@angular/router';
import { firstValueFrom } from 'rxjs';

import { ApiService, ListingEntry } from '../../services/api.service';
import { prettifyDocFileName } from '../../utils/prettify-doc-filename';
import { ErrorModalComponent } from '../error-modal/error-modal.component';

interface DocEntry {
  readonly path: string;
  readonly name: string;
  readonly title: string;
  readonly projectRoot: string;
  readonly source: 'Ralph CLI' | 'Ralph Dashboard';
}

/** Documentation for operating Ralph from the CLI and the dashboard UI. */
@Component({
  selector: 'ralph-docs-hub',
  standalone: true,
  imports: [CommonModule, RouterLink, ErrorModalComponent],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="docs-hub hub-page">
      <header class="page-header">
        <div>
          <h1 class="page-title">Docs</h1>
          <p class="page-lede">Choose the command-line reference or the dashboard guide for the job in front of you.</p>
        </div>
      </header>

      <section class="docs-overview" aria-labelledby="docs-overview-title">
        <div>
          <p class="eyebrow">Start here</p>
          <h2 id="docs-overview-title">Two ways to work</h2>
          <p>Use Ralph CLI when you are working in a terminal. Use Ralph Dashboard when you are queuing, automating, or following work visually.</p>
        </div>
        <div class="docs-overview-cards">
          <article><h3>Ralph CLI</h3><p>Commands, plans, workflows, configuration, and framework reference.</p></article>
          <article><h3>Ralph Dashboard</h3><p>Tasks, schedules, runs, workflows, insights, and operator actions in the UI.</p></article>
        </div>
      </section>

      @if (loading() && !hasLoadedOnce()) {
        <p class="docs-state">Loading documentation…</p>
      } @else if (error() && !hasLoadedOnce()) {
        <div class="docs-state error" role="alert">
          <ralph-error-modal class="is-embedded" [error]="error()" [embedded]="true" [showHeader]="false" />
          <button type="button" class="btn btn-secondary" (click)="loadDocs()">Retry</button>
        </div>
      } @else if (error() && hasLoadedOnce()) {
        <div class="docs-state error" role="alert">
          <ralph-error-modal class="is-embedded" [error]="error()" [embedded]="true" [showHeader]="false" />
          <button type="button" class="btn btn-secondary" (click)="loadDocs()">Retry</button>
        </div>
      } @else if (docs().length === 0) {
        <p class="docs-state">No documentation was found in this installation.</p>
      } @else {
        @if (cliDocs().length > 0) {
          <section class="docs-library" aria-labelledby="cli-docs-title" data-testid="cli-docs-library">
            <div class="docs-library-heading"><div><p class="eyebrow">Terminal reference</p><h2 id="cli-docs-title">Ralph CLI</h2></div><span>{{ cliDocs().length }} guides</span></div>
            <p class="library-lede">Plans, workflows, installation, configuration, and command-line operations.</p>
            <div class="docs-list" aria-label="Ralph CLI documentation">
              @for (doc of cliDocs(); track doc.projectRoot + ':' + doc.path) {
                <a class="doc-link" [routerLink]="docLinkCommands(doc)" [queryParams]="{ projectRoot: doc.projectRoot }">
                  <span class="doc-name">{{ doc.title }}</span><span class="doc-path">{{ doc.path }}</span>
                </a>
              }
            </div>
          </section>
        }
        @if (dashboardDocs().length > 0) {
          <section class="docs-library" aria-labelledby="dashboard-docs-title" data-testid="dashboard-docs-library">
            <div class="docs-library-heading"><div><p class="eyebrow">In the app</p><h2 id="dashboard-docs-title">Ralph Dashboard</h2></div><span>{{ dashboardDocs().length }} guides</span></div>
            <p class="library-lede">A practical guide to using the dashboard to organize and supervise work.</p>
            <div class="docs-list" aria-label="Ralph Dashboard documentation">
              @for (doc of dashboardDocs(); track doc.projectRoot + ':' + doc.path) {
                <a class="doc-link" [routerLink]="docLinkCommands(doc)" [queryParams]="{ projectRoot: doc.projectRoot }">
                  <span class="doc-name">{{ doc.title }}</span><span class="doc-path">{{ doc.path }}</span>
                </a>
              }
            </div>
          </section>
        }
      }
    </div>
  `,
  styles: `
    :host { display: flex; flex: 1; min-height: 0; }
    .docs-hub { background: var(--surface); }
    .docs-overview { display: grid; gap: var(--space-4); margin-bottom: var(--space-6); padding: var(--space-5); border: 1px solid var(--border); border-radius: var(--radius-lg); background: var(--surface-secondary); }
    .docs-overview h2, .docs-overview h3, .docs-overview p { margin: 0; }
    .docs-overview > div:first-child { display: grid; gap: var(--space-2); max-width: 42rem; }
    .docs-overview-cards { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: var(--space-3); }
    .docs-overview-cards article { display: grid; gap: var(--space-1); padding: var(--space-3); border-radius: var(--radius-md); background: var(--surface); }
    .docs-overview-cards h3 { font-size: var(--font-size-sm); }
    .docs-overview-cards p { color: var(--text-muted); font-size: var(--font-size-sm); line-height: 1.45; }
    .docs-state { margin: var(--space-5) 0; color: var(--text-muted); }
    .docs-state.error { color: var(--danger); }
    .docs-library { display: grid; gap: var(--space-3); margin-top: var(--space-6); }
    .docs-library-heading { display: flex; align-items: baseline; justify-content: space-between; gap: var(--space-3); }
    .docs-library-heading h2 { margin: 0; font-size: var(--font-size-lg); }
    .docs-library-heading .eyebrow { margin: 0 0 var(--space-1); }
    .docs-library-heading span { color: var(--text-muted); font-size: var(--font-size-sm); }
    .docs-list { display: grid; grid-template-columns: repeat(auto-fill, minmax(16rem, 1fr)); gap: var(--space-3); }
    .doc-link {
      display: flex;
      min-height: 5rem;
      flex-direction: column;
      justify-content: center;
      gap: var(--space-1);
      padding: var(--space-4);
      border: 1px solid var(--border);
      border-radius: var(--radius-lg);
      background: var(--surface-secondary);
      color: var(--text-primary);
      text-decoration: none;
    }
    .doc-link:hover { border-color: var(--accent); background: var(--surface-hover); }
    .doc-link:focus-visible { outline: var(--focus-ring-width) solid var(--focus-ring-color); outline-offset: var(--focus-ring-offset); }
    .doc-name { font-weight: 650; }
    .doc-path { overflow: hidden; color: var(--text-muted); font-family: var(--monospace-font); font-size: var(--font-size-xs); text-overflow: ellipsis; white-space: nowrap; }
    .library-lede { margin: 0; color: var(--text-muted); font-size: var(--font-size-sm); line-height: 1.45; }
    @media (max-width: 720px) { .docs-overview-cards { grid-template-columns: 1fr; } }
  `,
})
export class DocsHubComponent implements OnInit {
  private readonly api = inject(ApiService);

  readonly docs = signal<readonly DocEntry[]>([]);
  readonly cliDocs = computed(() => this.docs().filter((doc) => doc.source === 'Ralph CLI'));
  readonly dashboardDocs = computed(() => this.docs().filter((doc) => doc.source === 'Ralph Dashboard'));
  readonly loading = signal(false);
  readonly hasLoadedOnce = signal(false);
  readonly error = signal<unknown>(null);

  ngOnInit(): void {
    void this.loadDocs();
  }

  docLinkCommands(doc: DocEntry): string[] {
    return ['/docs', 'file', ...doc.path.split('/').filter((part) => part.length > 0)];
  }

  async loadDocs(): Promise<void> {
    if (!this.hasLoadedOnce()) {
      this.loading.set(true);
    }
    this.error.set(null);
    try {
      const [framework, dashboard] = await Promise.all([
        firstValueFrom(this.api.fetchRalphFrameworkProjectRoot()),
        firstValueFrom(this.api.fetchDashboardDocsProjectRoot()),
      ]);
      const sources = [
        ...(framework.projectRoot ? [{ projectRoot: framework.projectRoot, source: 'Ralph CLI' as const }] : []),
        ...(dashboard.projectRoot ? [{ projectRoot: dashboard.projectRoot, source: 'Ralph Dashboard' as const }] : []),
      ];
      if (sources.length === 0) {
        this.docs.set([]);
        return;
      }
      const docs = (await Promise.all(sources.map(({ projectRoot, source }) => this.collectDocs('', projectRoot, source)))).flat();
      this.docs.set(docs.sort((a, b) => a.title.localeCompare(b.title) || a.source.localeCompare(b.source) || a.path.localeCompare(b.path)));
      this.hasLoadedOnce.set(true);
    } catch (error) {
      if (!this.hasLoadedOnce()) {
        this.docs.set([]);
      }
      this.error.set(error);
      this.hasLoadedOnce.set(true);
    } finally {
      this.loading.set(false);
    }
  }

  private async collectDocs(path: string, projectRoot: string, source: DocEntry['source']): Promise<DocEntry[]> {
    const listing = await firstValueFrom(this.api.fetchListing('docs', path, undefined, projectRoot));
    const results: DocEntry[] = [];
    for (const entry of listing.entries) {
      if (entry.type === 'dir') {
        results.push(...await this.collectDocs(entry.path, projectRoot, source));
      } else if (this.isDocument(entry)) {
        results.push({
          name: entry.name,
          title: prettifyDocFileName(entry.name),
          path: entry.path,
          projectRoot,
          source,
        });
      }
    }
    return results;
  }

  private isDocument(entry: ListingEntry): boolean {
    return /\.(md|mdx|txt)$/i.test(entry.name);
  }
}
