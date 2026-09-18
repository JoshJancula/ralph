import {
  ChangeDetectionStrategy,
  ChangeDetectorRef,
  Component,
  effect,
  inject,
  input,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { IonSpinner } from '@ionic/angular/standalone';
import { DomSanitizer, type SafeHtml } from '@angular/platform-browser';
import {
  ApiService,
  DelegatedRunRecord,
  GraphDiffChange,
  GraphDiffNodeResult,
  GraphNodeAttempt,
  GraphNodeState,
  GraphRunDetail,
  GraphRunDiffResponse,
  GraphRunSummary,
} from '../../services/api.service';
import { ErrorModalComponent } from '../error-modal/error-modal.component';

interface GraphNodeRow {
  nodeId: string;
  type: string;
  runtime: string;
  role?: string;
  modelSource?: string;
  status: string;
  attempts: number;
  duration: string;
  mode?: string;
  frozenBase?: string;
  scopes?: string;
  gateOutcome?: string;
  nativeSubagents?: string;
  crossRuntimeMode?: string;
  repairEpoch?: string;
  integrationInputs?: string[];
  changesetManifest?: string;
  changesetHash?: string;
  workspacePath?: string;
  conflictArtifact?: string;
  admissionSummary?: Record<string, unknown>;
  publishReadiness?: Record<string, unknown>;
  delegatedRuns?: DelegatedRunRecord[];
}

const STATE_COLORS: Record<string, string> = {
  pending: '#888',
  ready: '#5599ee',
  running: '#2255cc',
  succeeded: '#2a8a2a',
  failed: '#bb2222',
  blocked: '#cc7700',
  skipped: '#aaaaaa',
  queued: '#aa77cc',
  cancelled: '#555',
};

function sanitizeMermaidId(id: string): string {
  return id.replace(/[^a-zA-Z0-9_-]/g, '_');
}

function fmtDuration(attempt: GraphNodeAttempt | undefined): string {
  if (!attempt?.startedAt) {
    return '-';
  }
  const start = Date.parse(attempt.startedAt);
  if (!Number.isFinite(start)) {
    return '-';
  }
  const end = attempt.finishedAt ? Date.parse(attempt.finishedAt) : Date.now();
  if (!Number.isFinite(end)) {
    return '-';
  }
  const secs = Math.round((end - start) / 1000);
  if (secs < 60) {
    return `${secs}s`;
  }
  const mins = Math.floor(secs / 60);
  const rem = secs % 60;
  return `${mins}m${rem}s`;
}

function buildMermaid(detail: GraphRunDetail): string {
  const graph = detail.graph as Record<string, unknown>;
  const graphNodes = Array.isArray(graph['nodes'])
    ? (graph['nodes'] as Array<Record<string, unknown>>)
    : [];
  const graphEdges = Array.isArray(graph['edges'])
    ? (graph['edges'] as Array<Record<string, unknown>>)
    : [];

  const stateByNodeId = new Map<string, string>();
  const metadataByNodeId = new Map<string, GraphNodeState>();
  for (const n of detail.nodes) {
    stateByNodeId.set(n.nodeId, n.status);
    metadataByNodeId.set(n.nodeId, n);
  }

  const lines: string[] = ['flowchart TD'];

  // Class definitions matching graph-status.sh colors
  for (const [state, color] of Object.entries(STATE_COLORS)) {
    const cls = `state_${state.replace(/-/g, '_')}`;
    lines.push(`  classDef ${cls} fill:${color},color:#fff`);
  }

  // Node definitions, with v2 metadata annotations when available.
  for (const gn of graphNodes) {
    const id = String(gn['id'] ?? '');
    const type = String(gn['type'] ?? 'stage');
    const stage = (gn['stage'] as Record<string, unknown>) ?? {};
    const safeId = sanitizeMermaidId(id);
    const meta = metadataByNodeId.get(id);
    const runtime = String(meta?.runtime ?? stage['runtime'] ?? '');
    const role = meta?.role ?? (typeof stage['role'] === 'string' ? stage['role'] : undefined);
    const extraLines: string[] = [];
    extraLines.push(role ? `project role=${role}` : 'roleless');
    if (meta?.modelSource) extraLines.push(`model=${meta.modelSource}`);
    if (meta?.workspaceMode) extraLines.push(`mode=${meta.workspaceMode}`);
    if (meta?.frozenBase) extraLines.push(`base=${meta.frozenBase.slice(0, 16)}`);
    if (meta?.writeScopes?.length) extraLines.push(`scopes=${meta.writeScopes[0]}${meta.writeScopes.length > 1 ? '+' : ''}`);
    if (meta?.gateOutcome) extraLines.push(`gate=${meta.gateOutcome}`);
    if (meta?.repairEpoch && meta.repairEpoch !== 'stage') extraLines.push(`epoch=${meta.repairEpoch}`);
  if (meta?.changesetHash) extraLines.push(`hash=${meta.changesetHash.slice(0, 16)}`);
  if (meta?.conflictArtifact) extraLines.push(`conflict=${meta.conflictArtifact.split('/').pop() ?? meta.conflictArtifact}`);
  if (meta?.admissionSummary?.['reason']) extraLines.push(`admission=${String(meta.admissionSummary['reason'])}`);
  if (meta?.publishReadiness?.['status']) extraLines.push(`publish=${String(meta.publishReadiness['status'])}`);
    if (meta?.nativeSubagents) extraLines.push(`nativeSubagents=${meta.nativeSubagents}`);
  const label = `"${id}\\n${runtime}${extraLines.length ? '\\n' + extraLines.join('\\n') : ''}"`;
    const state = stateByNodeId.get(id) ?? 'pending';
    const cls = `state_${state.replace(/-/g, '_')}`;
    // Use diamond shape for barrier/join nodes
    const shape = type === 'consensus-barrier' ? `{${label}}` : `[${label}]`;
    lines.push(`  ${safeId}${shape}:::${cls}`);
  }

  // Edges
  const realNodeIds = new Set(graphNodes.map((n) => String(n['id'] ?? '')));
  for (const edge of graphEdges) {
    const from = String(edge['from'] ?? '');
    const to = String(edge['to'] ?? '');
    if (realNodeIds.has(from) && realNodeIds.has(to)) {
      lines.push(`  ${sanitizeMermaidId(from)} --> ${sanitizeMermaidId(to)}`);
    }
  }

  // Delegated runs are observation-only and deliberately outside graphNodes so
  // they do not become peers in the frozen DAG. Native inherited work has no
  // child record and must not be represented as a graph child.
  for (const node of detail.nodes) {
    const parent = sanitizeMermaidId(node.nodeId);
    const children = (node.delegatedRuns ?? []).map((run) => ({
      id: `${parent}_delegated_${sanitizeMermaidId(run.delegatedRunId)}`,
      label: `delegated run\\n${run.runtime} / ${run.status}`,
    }));
    if (children.length === 0) continue;
    lines.push(`  subgraph ${parent}_delegated["${node.nodeId} delegated runs (ledger-owned)"]`);
    for (const child of children) {
      lines.push(`    ${child.id}(["${child.label}"])`);
      lines.push(`    ${parent} -.-> ${child.id}`);
    }
    lines.push('  end');
  }

  return lines.join('\n');
}

@Component({
  selector: 'ralph-graph-hub',
  standalone: true,
  imports: [CommonModule, IonSpinner, ErrorModalComponent],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="graph-hub">
      <div class="header">
        <h1 class="page-title">Graph Runs</h1>
      </div>

      @if (error) {
        <div class="error" role="alert">
          <ralph-error-modal class="is-embedded" [error]="error" [embedded]="true" [showHeader]="false" />
        </div>
      } @else if (loading) {
        <div class="loading">
          <ion-spinner name="crescent"></ion-spinner>
          <span>Loading graph runs...</span>
        </div>
      } @else if (runs.length === 0) {
        <div class="empty-state">
          No graph runs found. Run a graph plan with <code>ralph graph run</code> to see results here.
        </div>
      } @else {
        <div class="run-list">
          @for (run of runs; track run.namespace + '/' + run.runId) {
            <div
              class="run-card"
              [class.selected]="isSelected(run)"
              (click)="selectRun(run)"
              (keydown.enter)="selectRun(run)"
              (keydown.space)="$event.preventDefault(); selectRun(run)"
              tabindex="0"
              role="button"
              [attr.aria-pressed]="isSelected(run)"
              [attr.aria-label]="run.namespace + ' / ' + run.runId"
            >
              <div class="run-card-header">
                <span class="run-namespace">{{ run.namespace }}</span>
                @if (run.isLatest) {
                  <span class="badge-latest">latest</span>
                }
                <span class="badge-status" [style.background]="statusColor(run.status)">{{ run.status }}</span>
              </div>
              <div class="run-meta">
                <span class="run-id">{{ run.runId }}</span>
                <span class="run-nodes">{{ run.nodeCount }} node{{ run.nodeCount !== 1 ? 's' : '' }}</span>
                @if (run.startedAt) {
                  <span class="run-started">{{ fmtDate(run.startedAt) }}</span>
                }
              </div>
            </div>
          }
        </div>

        @if (detailLoading) {
          <div class="detail-loading">
            <ion-spinner name="crescent"></ion-spinner>
            <span>Loading run detail...</span>
          </div>
        } @else if (detailError) {
          <div class="error" role="alert">
            <ralph-error-modal class="is-embedded" [error]="detailError" [embedded]="true" [showHeader]="false" />
          </div>
        } @else if (detail) {
          <div class="detail-panel">
            <h3 class="detail-title">
              {{ detail.namespace }} / {{ detail.runId }}
              <span class="badge-status" [style.background]="statusColor(runStatus())">{{ runStatus() }}</span>
            </h3>

            @if (detail.usage || detail.concurrencyReductions?.length) {
              <div class="run-observability">
                @if (detail.usage) {
                  <span><strong>usage:</strong> parent={{ formatUsage(detail.usage.parent) }}, delegated runs={{ formatUsage(detail.usage.delegatedRuns ?? {}) }}, total={{ formatUsage(detail.usage.total) }}</span>
                }
                @if (detail.concurrencyReductions?.length) {
                  <span><strong>concurrency reduced by:</strong> {{ detail.concurrencyReductions!.join(', ') }}</span>
                }
              </div>
            }

            <div class="node-table-wrap scroll-contain">
              <table class="node-table" aria-label="Node status table">
                <thead>
                  <tr>
                    <th>Node</th>
                    <th>Type</th>
                    <th>Runtime</th>
                    <th>Role</th>
                    <th>Model source</th>
                    <th>State</th>
                    <th>Attempts</th>
                    <th>Duration</th>
                    <th>Mode</th>
                    <th>Base</th>
                    <th>Scopes / Gate</th>
                  </tr>
                </thead>
                <tbody>
                  @for (row of nodeRows; track row.nodeId) {
                    <tr [class]="'row-state-' + row.status">
                      <td class="cell-mono">{{ row.nodeId }}</td>
                      <td>{{ row.type }}</td>
                      <td>{{ row.runtime || '-' }}</td>
                      <td>{{ row.role ? 'project role: ' + row.role : 'roleless' }}</td>
                      <td>{{ row.modelSource || '-' }}</td>
                      <td>
                        <span class="state-badge" [style.background]="statusColor(row.status)">{{ row.status }}</span>
                      </td>
                      <td>{{ row.attempts }}</td>
                      <td>{{ row.duration }}</td>
                      <td>{{ row.mode || '-' }}</td>
                      <td>{{ row.frozenBase ? (row.frozenBase | slice:0:16) : '-' }}</td>
                      <td>
                        @if (row.gateOutcome) {
                          gate={{ row.gateOutcome }}
                        } @else if (row.scopes) {
                          {{ row.scopes }}
                        } @else {
                          -
                        }
                      </td>
                    </tr>
                    @if (row.integrationInputs?.length) {
                      <tr class="row-nested">
                        <td colspan="11" class="nested-cell">
                          <strong>integration inputs:</strong>
                          @for (input of row.integrationInputs; track input) {
                            <code class="nested-code">{{ input | slice:input.lastIndexOf('/') + 1 }}</code>
                          }
                        </td>
                      </tr>
                    }
                    @if (row.workspacePath || row.nativeSubagents || row.crossRuntimeMode || row.repairEpoch) {
                      <tr class="row-nested">
                        <td colspan="11" class="nested-cell">
                          @if (row.workspacePath) { <strong>agent workspace:</strong> <code class="nested-code">{{ row.workspacePath }}</code> }
                          @if (row.nativeSubagents) { <span>native subagents={{ row.nativeSubagents }}</span> }
                          @if (row.crossRuntimeMode) { <span>cross-runtime={{ row.crossRuntimeMode }}</span> }
                          @if (row.repairEpoch) { <span>repair epoch={{ row.repairEpoch }}</span> }
                        </td>
                      </tr>
                    }
                    @if (row.changesetManifest) {
                      <tr class="row-nested">
                        <td colspan="11" class="nested-cell">
                          <strong>changeset:</strong>
                          <code class="nested-code">{{ row.changesetManifest | slice:row.changesetManifest.lastIndexOf('/') + 1 }}</code>
                          @if (row.changesetHash) {
                            <span class="hash-status">hash={{ row.changesetHash | slice:0:16 }}</span>
                          }
                          @if (row.publishReadiness?.['status']) {
                            <span class="publish-status">publish={{ row.publishReadiness!['status'] }}</span>
                          }
                        </td>
                      </tr>
                    }
                    @if (row.conflictArtifact) {
                      <tr class="row-nested">
                        <td colspan="11" class="nested-cell">
                          <strong>conflict:</strong>
                          <code class="nested-code">{{ row.conflictArtifact | slice:row.conflictArtifact.lastIndexOf('/') + 1 }}</code>
                        </td>
                      </tr>
                    }
                    @if (row.admissionSummary) {
                      <tr class="row-nested">
                        <td colspan="11" class="nested-cell">
                          <strong>admission:</strong>
                          runtime={{ row.admissionSummary['runtime'] ?? '-' }},
                          requested={{ row.admissionSummary['requestedSlots'] ?? '-' }},
                          used={{ row.admissionSummary['runtimeUsed'] ?? '-' }},
                          cap={{ row.admissionSummary['effectiveRuntimeCap'] ?? '-' }},
                          reason={{ row.admissionSummary['reason'] ?? '-' }}
                        </td>
                      </tr>
                    }
                    @if (row.delegatedRuns?.length) {
                      <tr class="row-nested">
                        <td colspan="11" class="nested-cell">
                          <strong>delegated runs:</strong>
                          @for (run of row.delegatedRuns; track run.delegatedRunId) {
                            <span class="child-badge">
                              {{ run.delegatedRunId | slice:run.delegatedRunId.lastIndexOf('-') + 1 }}
                              <span class="child-runtime">{{ run.runtime }} / {{ run.role ? 'project role: ' + run.role : 'roleless' }} / {{ run.workspaceMode }}</span>
                              <span class="child-status">{{ run.status }}</span>
                              @if (run.verification) { <span>verification={{ run.verification }}</span> }
                              <span>usage={{ formatUsage(run.usage) }}</span>
                            </span>
                          }
                        </td>
                      </tr>
                    }
                  }
                </tbody>
              </table>
            </div>

            <div class="changeset-diff-section">
              <div class="dag-header">
                <h4>Changeset Diff</h4>
                <span class="muted">Node file changes from stored manifests</span>
              </div>

              @if (diffLoading) {
                <div class="detail-loading">
                  <ion-spinner name="crescent"></ion-spinner>
                  <span>Loading changeset diff...</span>
                </div>
              } @else if (diffError) {
                <div class="error" role="alert">
                  <ralph-error-modal class="is-embedded" [error]="diffError" [embedded]="true" [showHeader]="false" />
                </div>
              } @else if (diff) {
                @if (diff.truncated) {
                  <div class="diff-banner truncated" role="status">
                    Diff truncated — per-file or aggregate size limits were hit. Partial unified text may end with
                    <code>...[truncated]</code>.
                  </div>
                }

                <div class="diff-panels">
                  <div class="diff-panel diff-node-panel" role="listbox" aria-label="Graph nodes">
                    <div class="diff-panel-label">Nodes</div>
                    @for (node of diff.nodes; track node.nodeId) {
                      <button
                        type="button"
                        class="diff-list-item"
                        role="option"
                        [class.selected]="selectedDiffNodeId === node.nodeId"
                        [attr.aria-selected]="selectedDiffNodeId === node.nodeId"
                        (click)="selectDiffNode(node.nodeId)"
                      >
                        <span class="diff-list-primary">{{ node.nodeId }}</span>
                        <span class="diff-list-meta">{{ diffNodeSummary(node) }}</span>
                      </button>
                    }
                  </div>

                  <div class="diff-panel diff-file-panel" role="listbox" aria-label="Changed files">
                    <div class="diff-panel-label">Changed files</div>
                    @if (!selectedDiffNode) {
                      <div class="diff-empty">Select a node</div>
                    } @else if (!selectedDiffNode.changesetManifest) {
                      <div class="diff-empty" data-state="no-changeset">No changeset for this node</div>
                    } @else if (selectedDiffNode.changes.length === 0) {
                      <div class="diff-empty" data-state="no-changes">No changes</div>
                    } @else {
                      @for (change of selectedDiffNode.changes; track change.path + ':' + change.operation) {
                        <button
                          type="button"
                          class="diff-list-item"
                          role="option"
                          [class.selected]="selectedDiffPath === change.path"
                          [attr.aria-selected]="selectedDiffPath === change.path"
                          (click)="selectDiffFile(change.path)"
                        >
                          <span class="diff-list-primary">{{ change.path }}</span>
                          <span class="diff-list-meta">
                            {{ change.operation }}
                            @if (change.binary) {
                              <span class="diff-chip binary">binary</span>
                            }
                            @if (change.unavailable) {
                              <span class="diff-chip unavailable">unavailable</span>
                            }
                          </span>
                        </button>
                      }
                    }
                  </div>

                  <div class="diff-panel diff-text-panel" aria-label="Unified diff">
                    <div class="diff-panel-label">Unified diff</div>
                    @if (!selectedDiffChange) {
                      <div class="diff-empty">Select a changed file</div>
                    } @else if (selectedDiffChange.binary) {
                      <div class="diff-state" data-state="binary" role="status">
                        Binary file — metadata only; content is not shown.
                      </div>
                      <dl class="diff-meta-dl">
                        <div><dt>path</dt><dd>{{ selectedDiffChange.path }}</dd></div>
                        <div><dt>operation</dt><dd>{{ selectedDiffChange.operation }}</dd></div>
                        @if (selectedDiffChange.beforeSha256) {
                          <div><dt>before</dt><dd class="cell-mono">{{ selectedDiffChange.beforeSha256 | slice:0:16 }}</dd></div>
                        }
                        @if (selectedDiffChange.afterSha256) {
                          <div><dt>after</dt><dd class="cell-mono">{{ selectedDiffChange.afterSha256 | slice:0:16 }}</dd></div>
                        }
                      </dl>
                    } @else if (selectedDiffChange.unavailable) {
                      <div class="diff-state" data-state="unavailable" role="status">
                        Content unavailable — before content could not be verified or read. Metadata only.
                      </div>
                      <dl class="diff-meta-dl">
                        <div><dt>path</dt><dd>{{ selectedDiffChange.path }}</dd></div>
                        <div><dt>operation</dt><dd>{{ selectedDiffChange.operation }}</dd></div>
                      </dl>
                    } @else if (!selectedDiffChange.unifiedDiff) {
                      <div class="diff-state" data-state="no-changes" role="status">
                        No unified diff text for this entry.
                      </div>
                    } @else {
                      @if (selectedDiffChange.unifiedDiff.includes('...[truncated]')) {
                        <div class="diff-banner truncated subtle" role="status">This file's unified diff was truncated.</div>
                      }
                      <pre class="unified-diff" tabindex="0">{{ selectedDiffChange.unifiedDiff }}</pre>
                    }
                  </div>
                </div>
              }
            </div>

            <div class="dag-section">
              <div class="dag-header">
                <h4>DAG</h4>
                <span class="muted">Rendered workflow graph</span>
              </div>
              @if (mermaidSvg) {
                <div class="dag-diagram" [innerHTML]="mermaidSvg"></div>
              }
              <details class="dag-source">
                <summary>Mermaid source</summary>
                <pre class="dag-pre"><code>{{ mermaidText }}</code></pre>
              </details>
            </div>
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
    .graph-hub {
      flex: 1;
      min-height: 0;
      padding: 2rem;
      overflow-x: hidden;
      overflow-y: auto;
      width: 100%;
      box-sizing: border-box;
    }
    .header h1 {
      margin: 0 0 1.5rem;
      font-size: 1.75rem;
      font-weight: 600;
    }
    .error {
      color: var(--danger);
      padding: 1rem;
      background: rgba(255, 0, 0, 0.1);
      border-radius: 4px;
    }
    .loading, .detail-loading {
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      gap: 0.75rem;
      padding: 3rem 2rem;
      color: var(--text-muted);
    }
    .run-list {
      display: flex;
      flex-direction: column;
      gap: 0.5rem;
      margin-bottom: 1.5rem;
    }
    .run-card {
      padding: 0.75rem 1rem;
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 6px;
      cursor: pointer;
    }
    .run-card:hover {
      background: var(--surface-hover);
    }
    .run-card:focus-visible {
      outline: var(--focus-ring-width, 2px) solid var(--focus-ring-color, var(--accent));
      outline-offset: 2px;
    }
    .run-card-header {
      display: flex;
      align-items: center;
      gap: 0.5rem;
      margin-bottom: 0.25rem;
    }
    .run-namespace {
      font-weight: 600;
      font-family: var(--monospace-font);
    }
    .badge-latest {
      font-size: 0.7rem;
      padding: 0.1rem 0.35rem;
      border-radius: 3px;
      background: var(--accent);
      color: var(--button-text);
    }
    .badge-status, .state-badge {
      font-size: 0.7rem;
      padding: 0.1rem 0.35rem;
      border-radius: 3px;
      color: #fff;
    }
    .run-meta {
      display: flex;
      gap: 1rem;
      font-size: 0.8rem;
      color: var(--text-muted);
    }
    .run-id {
      font-family: var(--monospace-font);
    }
    .detail-panel {
      margin-top: 1rem;
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 1.25rem;
      background: var(--surface);
    }
    .run-observability {
      display: flex;
      flex-direction: column;
      gap: 0.3rem;
      margin: -0.25rem 0 1rem;
      color: var(--text-muted);
      font-size: 0.78rem;
      font-family: var(--monospace-font);
    }
    .detail-title {
      margin: 0 0 1rem;
      font-size: 1rem;
      font-family: var(--monospace-font);
      display: flex;
      align-items: center;
      gap: 0.5rem;
      flex-wrap: wrap;
    }
    .node-table-wrap {
      max-width: 100%;
      overflow-x: auto;
      -webkit-overflow-scrolling: touch;
      margin-bottom: 1.5rem;
    }
    .node-table {
      width: 100%;
      border-collapse: collapse;
      font-size: 0.85rem;
    }
    .node-table th {
      text-align: left;
      padding: 0.4rem 0.75rem;
      background: var(--surface-hover);
      border-bottom: 1px solid var(--border);
      font-size: 0.75rem;
      text-transform: uppercase;
      letter-spacing: 0.04em;
      color: var(--text-muted);
    }
    .node-table td {
      padding: 0.4rem 0.75rem;
      border-bottom: 1px solid var(--border);
      color: var(--text-primary);
    }
    .cell-mono {
      font-family: var(--monospace-font);
    }
    .dag-section {
      min-width: 0;
    }
    .dag-header {
      display: flex;
      align-items: baseline;
      justify-content: space-between;
      gap: 0.75rem;
      margin-bottom: 0.5rem;
    }
    .dag-header h4 {
      margin: 0;
      font-size: 0.85rem;
      font-weight: 600;
      color: var(--text-muted);
      text-transform: uppercase;
      letter-spacing: 0.04em;
    }
    .dag-diagram {
      min-height: 12rem;
      overflow: auto;
      padding: 1rem;
      border: 1px solid var(--border);
      border-radius: 8px;
      background: var(--surface);
    }
    .dag-diagram svg {
      display: block;
      width: auto;
      min-width: 0;
      max-width: 100%;
      height: auto;
      max-height: 30rem;
      margin: 0 auto;
    }
    .dag-source {
      margin-top: 0.5rem;
    }
    .dag-source summary {
      color: var(--text-muted);
      cursor: pointer;
      font-size: 0.78rem;
    }
    .dag-pre {
      background: var(--surface-hover);
      border: 1px solid var(--border);
      border-radius: 4px;
      padding: 1rem;
      overflow-x: auto;
      font-family: var(--monospace-font);
      font-size: 0.8rem;
      line-height: 1.5;
      white-space: pre;
      color: var(--text-primary);
      margin: 0;
    }
    .row-nested td {
      background: var(--surface-hover);
      padding-top: 0.25rem;
      padding-bottom: 0.25rem;
      font-size: 0.75rem;
    }
    .nested-cell {
      display: flex;
      gap: 0.5rem;
      align-items: center;
      flex-wrap: wrap;
    }
    .nested-code {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 3px;
      padding: 0.1rem 0.35rem;
      font-family: var(--monospace-font);
    }
    .publish-status,
    .hash-status {
      color: var(--text-muted);
      margin-left: 0.5rem;
    }
    .child-badge {
      display: inline-flex;
      align-items: center;
      gap: 0.25rem;
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 3px;
      padding: 0.1rem 0.35rem;
      margin-right: 0.35rem;
    }
    .child-runtime {
      color: var(--text-muted);
    }
    .child-status {
      text-transform: uppercase;
      font-size: 0.75rem;
    }
    .changeset-diff-section {
      margin-bottom: 1.5rem;
      min-width: 0;
    }
    .diff-banner {
      margin: 0 0 0.75rem;
      padding: 0.5rem 0.75rem;
      border-radius: 4px;
      font-size: 0.8rem;
      border: 1px solid var(--border);
    }
    .diff-banner.truncated {
      background: rgba(204, 119, 0, 0.15);
      border-color: #cc7700;
      color: var(--text-primary);
    }
    .diff-banner.subtle {
      margin-bottom: 0.5rem;
      font-size: 0.75rem;
    }
    .diff-panels {
      display: grid;
      grid-template-columns: minmax(10rem, 1fr) minmax(12rem, 1.2fr) minmax(16rem, 2fr);
      gap: 0.75rem;
      min-height: 14rem;
      align-items: stretch;
    }
    @media (max-width: 900px) {
      .diff-panels {
        grid-template-columns: 1fr;
      }
    }
    .diff-panel {
      border: 1px solid var(--border);
      border-radius: 6px;
      background: var(--surface);
      display: flex;
      flex-direction: column;
      min-height: 0;
      max-height: 22rem;
      overflow: auto;
    }
    .diff-panel-label {
      position: sticky;
      top: 0;
      z-index: 1;
      padding: 0.4rem 0.65rem;
      font-size: 0.7rem;
      text-transform: uppercase;
      letter-spacing: 0.04em;
      color: var(--text-muted);
      background: var(--surface-hover);
      border-bottom: 1px solid var(--border);
    }
    .diff-list-item {
      display: flex;
      flex-direction: column;
      align-items: flex-start;
      gap: 0.15rem;
      width: 100%;
      text-align: left;
      padding: 0.45rem 0.65rem;
      border: 0;
      border-bottom: 1px solid var(--border);
      background: transparent;
      color: var(--text-primary);
      cursor: pointer;
      font: inherit;
    }
    .diff-list-item:hover {
      background: var(--surface-hover);
    }
    .diff-list-item.selected {
      background: rgba(85, 153, 238, 0.15);
      outline: 1px solid var(--accent, #5599ee);
      outline-offset: -1px;
    }
    .diff-list-item:focus-visible {
      outline: var(--focus-ring-width, 2px) solid var(--focus-ring-color, var(--accent));
      outline-offset: -2px;
    }
    .diff-list-primary {
      font-family: var(--monospace-font);
      font-size: 0.78rem;
      word-break: break-all;
    }
    .diff-list-meta {
      font-size: 0.7rem;
      color: var(--text-muted);
      display: flex;
      flex-wrap: wrap;
      gap: 0.35rem;
      align-items: center;
    }
    .diff-chip {
      font-size: 0.65rem;
      padding: 0.05rem 0.3rem;
      border-radius: 3px;
      text-transform: uppercase;
      letter-spacing: 0.03em;
    }
    .diff-chip.binary {
      background: rgba(170, 119, 204, 0.25);
      color: var(--text-primary);
    }
    .diff-chip.unavailable {
      background: rgba(187, 34, 34, 0.2);
      color: var(--text-primary);
    }
    .diff-empty,
    .diff-state {
      padding: 0.75rem;
      font-size: 0.8rem;
      color: var(--text-muted);
    }
    .diff-state[data-state='binary'],
    .diff-state[data-state='unavailable'],
    .diff-state[data-state='no-changes'] {
      color: var(--text-primary);
      background: var(--surface-hover);
      border-bottom: 1px solid var(--border);
    }
    .diff-meta-dl {
      margin: 0;
      padding: 0.75rem;
      font-size: 0.78rem;
      display: flex;
      flex-direction: column;
      gap: 0.35rem;
    }
    .diff-meta-dl > div {
      display: grid;
      grid-template-columns: 5rem 1fr;
      gap: 0.5rem;
    }
    .diff-meta-dl dt {
      margin: 0;
      color: var(--text-muted);
    }
    .diff-meta-dl dd {
      margin: 0;
      word-break: break-all;
    }
    .unified-diff {
      margin: 0;
      padding: 0.75rem;
      overflow: auto;
      flex: 1;
      font-family: var(--monospace-font);
      font-size: 0.75rem;
      line-height: 1.45;
      white-space: pre;
      color: var(--text-primary);
      background: var(--surface-hover);
    }
    .muted {
      color: var(--text-muted);
      font-size: 0.78rem;
    }
  `,
})
export class GraphHubComponent {
  readonly paneActive = input(false);

  runs: GraphRunSummary[] = [];
  loading = false;
  hasLoadedOnce = false;
  error: unknown = null;

  detail: GraphRunDetail | null = null;
  nodeRows: GraphNodeRow[] = [];
  mermaidText = '';
  detailLoading = false;
  detailError: unknown = null;

  diff: GraphRunDiffResponse | null = null;
  diffLoading = false;
  diffError: unknown = null;
  selectedDiffNodeId: string | null = null;
  selectedDiffPath: string | null = null;

  private selectedRunKey = '';
  private readonly api = inject(ApiService);
  private readonly cdr = inject(ChangeDetectorRef);
  private readonly sanitizer = inject(DomSanitizer);
  private mermaidImportPromise: Promise<MermaidClient | null> | null = null;
  mermaidSvg: SafeHtml | null = null;

  constructor() {
    effect(() => {
      if (!this.paneActive()) {
        return;
      }
      this.fetchRuns();
    });
  }

  fetchRuns(): void {
    if (!this.hasLoadedOnce) {
      this.loading = true;
    }
    this.error = null;
    this.cdr.markForCheck();

    this.api.fetchGraphRuns().subscribe({
      next: (resp) => {
        this.runs = resp.runs;
        this.hasLoadedOnce = true;
        this.loading = false;
        this.cdr.markForCheck();
      },
      error: (err: unknown) => {
        this.error = err;
        this.hasLoadedOnce = true;
        this.loading = false;
        this.cdr.markForCheck();
      },
    });
  }

  selectRun(run: GraphRunSummary): void {
    const key = `${run.namespace}/${run.runId}`;
    if (this.selectedRunKey === key) {
      return;
    }
    this.selectedRunKey = key;
    this.detail = null;
    this.detailError = null;
    this.detailLoading = true;
    this.diff = null;
    this.diffError = null;
    this.diffLoading = true;
    this.selectedDiffNodeId = null;
    this.selectedDiffPath = null;
    this.cdr.markForCheck();

    this.api.fetchGraphRunDetail(run.namespace, run.runId).subscribe({
      next: (detail) => {
        this.detail = detail;
        this.nodeRows = this.buildNodeRows(detail);
        this.mermaidText = buildMermaid(detail);
        this.mermaidSvg = null;
        this.detailLoading = false;
        this.cdr.markForCheck();
        void this.renderMermaid();
      },
      error: (err: unknown) => {
        this.detailError = err;
        this.detailLoading = false;
        this.cdr.markForCheck();
      },
    });

    this.api.fetchGraphRunDiff(run.namespace, run.runId).subscribe({
      next: (diff) => {
        this.diff = diff;
        this.diffLoading = false;
        this.applyDefaultDiffSelection(diff);
        this.cdr.markForCheck();
      },
      error: (err: unknown) => {
        this.diffError = err;
        this.diffLoading = false;
        this.cdr.markForCheck();
      },
    });
  }

  get selectedDiffNode(): GraphDiffNodeResult | null {
    if (!this.diff || !this.selectedDiffNodeId) {
      return null;
    }
    return this.diff.nodes.find((n) => n.nodeId === this.selectedDiffNodeId) ?? null;
  }

  get selectedDiffChange(): GraphDiffChange | null {
    const node = this.selectedDiffNode;
    if (!node || !this.selectedDiffPath) {
      return null;
    }
    return node.changes.find((c) => c.path === this.selectedDiffPath) ?? null;
  }

  selectDiffNode(nodeId: string): void {
    this.selectedDiffNodeId = nodeId;
    const node = this.selectedDiffNode;
    this.selectedDiffPath = node?.changes[0]?.path ?? null;
    this.cdr.markForCheck();
  }

  selectDiffFile(path: string): void {
    this.selectedDiffPath = path;
    this.cdr.markForCheck();
  }

  diffNodeSummary(node: GraphDiffNodeResult): string {
    if (!node.changesetManifest) {
      return 'no changeset';
    }
    if (node.changes.length === 0) {
      return 'no changes';
    }
    const n = node.changes.length;
    return `${n} file${n === 1 ? '' : 's'}`;
  }

  private applyDefaultDiffSelection(diff: GraphRunDiffResponse): void {
    const withChanges = diff.nodes.find((n) => n.changes.length > 0);
    const fallback = withChanges ?? diff.nodes[0] ?? null;
    this.selectedDiffNodeId = fallback?.nodeId ?? null;
    this.selectedDiffPath = fallback?.changes[0]?.path ?? null;
  }

  isSelected(run: GraphRunSummary): boolean {
    return this.selectedRunKey === `${run.namespace}/${run.runId}`;
  }

  private async renderMermaid(): Promise<void> {
    const source = this.mermaidText.trim();
    if (!source) {
      return;
    }
    const client = await this.loadMermaidClient();
    if (!client) {
      return;
    }
    client.initialize({
      startOnLoad: false,
      theme: typeof document !== 'undefined' && document.body.classList.contains('theme-light') ? 'default' : 'dark',
      securityLevel: 'strict',
      fontFamily: 'inherit',
    });
    try {
      const result = await client.render(`graph-${Math.random().toString(36).slice(2, 10)}`, source);
      const svg = typeof result === 'string' ? result : result.svg;
      this.mermaidSvg = this.sanitizer.bypassSecurityTrustHtml(svg);
      this.cdr.markForCheck();
    } catch {
      this.mermaidSvg = null;
      this.cdr.markForCheck();
    }
  }

  private async loadMermaidClient(): Promise<MermaidClient | null> {
    if (!this.mermaidImportPromise) {
      this.mermaidImportPromise = import('mermaid')
        .then((mod) => (mod.default ?? mod) as MermaidClient)
        .catch(() => null);
    }
    return this.mermaidImportPromise;
  }

  runStatus(): string {
    if (!this.detail) {
      return 'unknown';
    }
    return String(this.detail.run['status'] ?? 'unknown');
  }

  formatUsage(usage: Record<string, number>): string {
    const entries = Object.entries(usage);
    return entries.length === 0 ? '-' : entries.map(([key, value]) => `${key}=${value}`).join(', ');
  }

  statusColor(status: string): string {
    return STATE_COLORS[status] ?? '#888';
  }

  fmtDate(iso: string): string {
    const d = new Date(iso);
    if (!Number.isFinite(d.getTime())) {
      return iso;
    }
    const pad = (n: number) => n.toString().padStart(2, '0');
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
  }

  private buildNodeRows(detail: GraphRunDetail): GraphNodeRow[] {
    const graph = detail.graph as Record<string, unknown>;
    const graphNodes = Array.isArray(graph['nodes'])
      ? (graph['nodes'] as Array<Record<string, unknown>>)
      : [];

    const graphOrder = graphNodes.map((n) => String(n['id'] ?? ''));
    const typeByNodeId = new Map<string, string>();
    const runtimeByNodeId = new Map<string, string>();
    for (const gn of graphNodes) {
      const id = String(gn['id'] ?? '');
      typeByNodeId.set(id, String(gn['type'] ?? 'stage'));
      const stage = (gn['stage'] as Record<string, unknown>) ?? {};
      runtimeByNodeId.set(id, String(stage['runtime'] ?? ''));
    }

    const stateByNodeId = new Map<string, GraphNodeState>();
    for (const n of detail.nodes) {
      stateByNodeId.set(n.nodeId, n);
    }

    const rows: GraphNodeRow[] = [];
    const seen = new Set<string>();

    // Emit in graph order first
    for (const id of graphOrder) {
      seen.add(id);
      const ns = stateByNodeId.get(id);
      const lastAttempt = ns?.attempts[ns.attempts.length - 1];
      rows.push({
        nodeId: id,
        type: this.displayNodeType(typeByNodeId.get(id) ?? 'stage'),
        runtime: ns?.runtime ?? runtimeByNodeId.get(id) ?? '',
        role: ns?.role ?? this.roleByNodeId(graphNodes, id),
        modelSource: ns?.modelSource,
        status: ns?.status ?? 'pending',
        attempts: ns?.attempts.length ?? 0,
        duration: fmtDuration(lastAttempt),
        mode: ns?.workspaceMode,
        workspacePath: ns?.workspacePath,
        frozenBase: ns?.frozenBase,
        scopes: ns?.writeScopes?.length ? `${ns.writeScopes[0]}${ns.writeScopes.length > 1 ? ` +${ns.writeScopes.length - 1}` : ''}` : undefined,
        gateOutcome: ns?.gateOutcome,
        nativeSubagents: ns?.nativeSubagents,
        crossRuntimeMode: ns?.crossRuntimeMode,
        repairEpoch: ns?.repairEpoch,
        integrationInputs: ns?.integrationInputs,
        changesetManifest: ns?.changesetManifest,
        changesetHash: ns?.changesetHash,
        conflictArtifact: ns?.conflictArtifact,
        admissionSummary: ns?.admissionSummary,
        publishReadiness: ns?.publishReadiness,
        delegatedRuns: ns?.delegatedRuns,
      });
    }

    // Append any node-state files not in graph.json (should not normally happen)
    for (const n of detail.nodes) {
      if (seen.has(n.nodeId)) {
        continue;
      }
      const lastAttempt = n.attempts[n.attempts.length - 1];
      rows.push({
        nodeId: n.nodeId,
        type: this.displayNodeType(typeByNodeId.get(n.nodeId) ?? 'stage'),
        runtime: n.runtime ?? runtimeByNodeId.get(n.nodeId) ?? '',
        role: n.role ?? this.roleByNodeId(graphNodes, n.nodeId),
        modelSource: n.modelSource,
        status: n.status,
        attempts: n.attempts.length,
        duration: fmtDuration(lastAttempt),
        mode: n.workspaceMode,
        workspacePath: n.workspacePath,
        frozenBase: n.frozenBase,
        scopes: n.writeScopes?.length ? `${n.writeScopes[0]}${n.writeScopes.length > 1 ? ` +${n.writeScopes.length - 1}` : ''}` : undefined,
        gateOutcome: n.gateOutcome,
        nativeSubagents: n.nativeSubagents,
        crossRuntimeMode: n.crossRuntimeMode,
        repairEpoch: n.repairEpoch,
        integrationInputs: n.integrationInputs,
        changesetManifest: n.changesetManifest,
        changesetHash: n.changesetHash,
        conflictArtifact: n.conflictArtifact,
        admissionSummary: n.admissionSummary,
        publishReadiness: n.publishReadiness,
        delegatedRuns: n.delegatedRuns,
      });
    }

    return rows;
  }

  private displayNodeType(type: string): string {
    return type === 'agent' ? 'agent node' : type;
  }

  private roleByNodeId(
    graphNodes: Array<Record<string, unknown>>,
    nodeId: string,
  ): string | undefined {
    const graphNode = graphNodes.find((node) => String(node['id'] ?? '') === nodeId);
    const stage = graphNode?.['stage'];
    return stage && typeof stage === 'object' && typeof (stage as Record<string, unknown>)['role'] === 'string'
      ? String((stage as Record<string, unknown>)['role'])
      : undefined;
  }
}

interface MermaidClient {
  initialize(options: Record<string, unknown>): void;
  render(id: string, source: string): Promise<string | { svg: string }>;
}
