import {
  ChangeDetectionStrategy,
  ChangeDetectorRef,
  Component,
  OnInit,
  inject,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { IonSpinner } from '@ionic/angular/standalone';
import {
  ApiService,
  BrokeredChildState,
  GraphNodeAttempt,
  GraphNodeState,
  GraphRunDetail,
  GraphRunSummary,
  NativeSubagentEvent,
} from '../../services/api.service';

interface GraphNodeRow {
  nodeId: string;
  type: string;
  runtime: string;
  status: string;
  attempts: number;
  duration: string;
  mode?: string;
  frozenBase?: string;
  scopes?: string;
  gateOutcome?: string;
  nativeSubagentMode?: string;
  crossRuntimeMode?: string;
  repairEpoch?: string;
  integrationInputs?: string[];
  changesetManifest?: string;
  changesetHash?: string;
  workspacePath?: string;
  conflictArtifact?: string;
  admissionSummary?: Record<string, unknown>;
  publishReadiness?: Record<string, unknown>;
  brokeredChildren?: BrokeredChildState[];
  nativeSubagentEvents?: NativeSubagentEvent[];
}

const STATE_COLORS: Record<string, string> = {
  pending: '#888',
  ready: '#5599ee',
  running: '#2255cc',
  succeeded: '#2a8a2a',
  failed: '#bb2222',
  blocked: '#cc7700',
  skipped: '#aaaaaa',
  'awaiting-ack': '#ddbb00',
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
    const runtime = String(stage['runtime'] ?? '');
    const safeId = sanitizeMermaidId(id);
    const meta = metadataByNodeId.get(id);
    const extraLines: string[] = [];
    if (meta?.workspaceMode) extraLines.push(`mode=${meta.workspaceMode}`);
    if (meta?.frozenBase) extraLines.push(`base=${meta.frozenBase.slice(0, 16)}`);
    if (meta?.writeScopes?.length) extraLines.push(`scopes=${meta.writeScopes[0]}${meta.writeScopes.length > 1 ? '+' : ''}`);
    if (meta?.gateOutcome) extraLines.push(`gate=${meta.gateOutcome}`);
    if (meta?.repairEpoch && meta.repairEpoch !== 'stage') extraLines.push(`epoch=${meta.repairEpoch}`);
  if (meta?.changesetHash) extraLines.push(`hash=${meta.changesetHash.slice(0, 16)}`);
  if (meta?.conflictArtifact) extraLines.push(`conflict=${meta.conflictArtifact.split('/').pop() ?? meta.conflictArtifact}`);
  if (meta?.admissionSummary?.['reason']) extraLines.push(`admission=${String(meta.admissionSummary['reason'])}`);
  if (meta?.publishReadiness?.['status']) extraLines.push(`publish=${String(meta.publishReadiness['status'])}`);
  if (meta?.brokeredChildren && meta.brokeredChildren.length > 0) {
    extraLines.push(`children=${meta.brokeredChildren.length}`);
  }
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

  // These are observation-only children, deliberately outside graphNodes so
  // neither native helpers nor brokered runs become peers in the frozen DAG.
  for (const node of detail.nodes) {
    const parent = sanitizeMermaidId(node.nodeId);
    const children = [
      ...(node.nativeSubagentEvents ?? []).map((event, index) => ({
        id: `${parent}_native_${index}`,
        label: `native helper\\n${event.event}`,
      })),
      ...(node.brokeredChildren ?? []).map((child) => ({
        id: `${parent}_brokered_${sanitizeMermaidId(child.delegationId)}`,
        label: `brokered child\\n${child.runtime ?? '-'} / ${child.status}`,
      })),
    ];
    if (children.length === 0) continue;
    lines.push(`  subgraph ${parent}_children["${node.nodeId} children (ledger/runtime-owned)"]`);
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
  imports: [CommonModule, IonSpinner],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="graph-hub">
      <div class="header">
        <h2>Graph Runs</h2>
      </div>

      @if (error) {
        <div class="error">{{ error }}</div>
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
          <div class="error">{{ detailError }}</div>
        } @else if (detail) {
          <div class="detail-panel">
            <h3 class="detail-title">
              {{ detail.namespace }} / {{ detail.runId }}
              <span class="badge-status" [style.background]="statusColor(runStatus())">{{ runStatus() }}</span>
            </h3>

            @if (detail.usage || detail.concurrencyReductions?.length) {
              <div class="run-observability">
                @if (detail.usage) {
                  <span><strong>usage:</strong> parent={{ detail.usage.parent | json }}, brokered={{ detail.usage.brokeredChildren | json }}, total={{ detail.usage.total | json }}</span>
                }
                @if (detail.concurrencyReductions?.length) {
                  <span><strong>concurrency reduced by:</strong> {{ detail.concurrencyReductions!.join(', ') }}</span>
                }
              </div>
            }

            <div class="node-table-wrap">
              <table class="node-table" aria-label="Node status table">
                <thead>
                  <tr>
                    <th>Node</th>
                    <th>Type</th>
                    <th>Runtime</th>
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
                        <td colspan="9" class="nested-cell">
                          <strong>integration inputs:</strong>
                          @for (input of row.integrationInputs; track input) {
                            <code class="nested-code">{{ input | slice:input.lastIndexOf('/') + 1 }}</code>
                          }
                        </td>
                      </tr>
                    }
                    @if (row.workspacePath || row.nativeSubagentMode || row.crossRuntimeMode || row.repairEpoch) {
                      <tr class="row-nested">
                        <td colspan="9" class="nested-cell">
                          @if (row.workspacePath) { <strong>workspace:</strong> <code class="nested-code">{{ row.workspacePath }}</code> }
                          @if (row.nativeSubagentMode) { <span>native={{ row.nativeSubagentMode }}</span> }
                          @if (row.crossRuntimeMode) { <span>cross-runtime={{ row.crossRuntimeMode }}</span> }
                          @if (row.repairEpoch) { <span>repair epoch={{ row.repairEpoch }}</span> }
                        </td>
                      </tr>
                    }
                    @if (row.changesetManifest) {
                      <tr class="row-nested">
                        <td colspan="9" class="nested-cell">
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
                        <td colspan="9" class="nested-cell">
                          <strong>conflict:</strong>
                          <code class="nested-code">{{ row.conflictArtifact | slice:row.conflictArtifact.lastIndexOf('/') + 1 }}</code>
                        </td>
                      </tr>
                    }
                    @if (row.admissionSummary) {
                      <tr class="row-nested">
                        <td colspan="9" class="nested-cell">
                          <strong>admission:</strong>
                          runtime={{ row.admissionSummary['runtime'] ?? '-' }},
                          requested={{ row.admissionSummary['requestedSlots'] ?? '-' }},
                          used={{ row.admissionSummary['runtimeUsed'] ?? '-' }},
                          cap={{ row.admissionSummary['effectiveRuntimeCap'] ?? '-' }},
                          reason={{ row.admissionSummary['reason'] ?? '-' }}
                        </td>
                      </tr>
                    }
                    @if (row.brokeredChildren?.length) {
                      <tr class="row-nested">
                        <td colspan="9" class="nested-cell">
                          <strong>brokered children:</strong>
                          @for (child of row.brokeredChildren; track child.delegationId) {
                            <span class="child-badge">
                              {{ child.delegationId | slice:child.delegationId.lastIndexOf('-') + 1 }}
                              <span class="child-runtime">{{ child.runtime ?? '-' }}</span>
                              <span class="child-status">{{ child.status }}</span>
                            </span>
                          }
                        </td>
                      </tr>
                    }
                    @if (row.nativeSubagentEvents?.length) {
                      <tr class="row-nested">
                        <td colspan="9" class="nested-cell">
                          <strong>native helpers:</strong>
                          @for (event of row.nativeSubagentEvents; track event.event + (event.timestamp ?? '')) {
                            <span class="child-badge">{{ event.event }} {{ event.timestamp ?? '' }}</span>
                          }
                        </td>
                      </tr>
                    }
                  }
                </tbody>
              </table>
            </div>

            <div class="dag-section">
              <h4>DAG (mermaid)</h4>
              <pre class="dag-pre"><code>{{ mermaidText }}</code></pre>
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
      overflow-y: auto;
    }
    .header h2 {
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
    .empty-state {
      padding: 3rem 2rem;
      text-align: center;
      color: var(--text-muted);
      background: var(--surface);
      border-radius: 8px;
      border: 1px solid var(--border);
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
    .run-card.selected {
      border-color: var(--accent);
      background: var(--surface-hover);
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
      overflow-x: auto;
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
    .dag-section h4 {
      margin: 0 0 0.5rem;
      font-size: 0.85rem;
      font-weight: 600;
      color: var(--text-muted);
      text-transform: uppercase;
      letter-spacing: 0.04em;
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
  `,
})
export class GraphHubComponent implements OnInit {
  runs: GraphRunSummary[] = [];
  loading = false;
  error = '';

  detail: GraphRunDetail | null = null;
  nodeRows: GraphNodeRow[] = [];
  mermaidText = '';
  detailLoading = false;
  detailError = '';

  private selectedRunKey = '';
  private readonly api = inject(ApiService);
  private readonly cdr = inject(ChangeDetectorRef);

  ngOnInit(): void {
    this.fetchRuns();
  }

  fetchRuns(): void {
    this.loading = true;
    this.error = '';
    this.cdr.markForCheck();

    this.api.fetchGraphRuns().subscribe({
      next: (resp) => {
        this.runs = resp.runs;
        this.loading = false;
        this.cdr.markForCheck();
      },
      error: (err: { error?: { error?: string }; status?: number }) => {
        this.error = err.error?.error ?? 'Failed to load graph runs';
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
    this.detailError = '';
    this.detailLoading = true;
    this.cdr.markForCheck();

    this.api.fetchGraphRunDetail(run.namespace, run.runId).subscribe({
      next: (detail) => {
        this.detail = detail;
        this.nodeRows = this.buildNodeRows(detail);
        this.mermaidText = buildMermaid(detail);
        this.detailLoading = false;
        this.cdr.markForCheck();
      },
      error: (err: { error?: { error?: string } }) => {
        this.detailError = err.error?.error ?? 'Failed to load run detail';
        this.detailLoading = false;
        this.cdr.markForCheck();
      },
    });
  }

  isSelected(run: GraphRunSummary): boolean {
    return this.selectedRunKey === `${run.namespace}/${run.runId}`;
  }

  runStatus(): string {
    if (!this.detail) {
      return 'unknown';
    }
    return String(this.detail.run['status'] ?? 'unknown');
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
        type: typeByNodeId.get(id) ?? 'stage',
        runtime: runtimeByNodeId.get(id) ?? '',
        status: ns?.status ?? 'pending',
        attempts: ns?.attempts.length ?? 0,
        duration: fmtDuration(lastAttempt),
        mode: ns?.workspaceMode,
        workspacePath: ns?.workspacePath,
        frozenBase: ns?.frozenBase,
        scopes: ns?.writeScopes?.length ? `${ns.writeScopes[0]}${ns.writeScopes.length > 1 ? ` +${ns.writeScopes.length - 1}` : ''}` : undefined,
        gateOutcome: ns?.gateOutcome,
        nativeSubagentMode: ns?.nativeSubagentMode,
        crossRuntimeMode: ns?.crossRuntimeMode,
        repairEpoch: ns?.repairEpoch,
        integrationInputs: ns?.integrationInputs,
        changesetManifest: ns?.changesetManifest,
        changesetHash: ns?.changesetHash,
        conflictArtifact: ns?.conflictArtifact,
        admissionSummary: ns?.admissionSummary,
        publishReadiness: ns?.publishReadiness,
        brokeredChildren: ns?.brokeredChildren,
        nativeSubagentEvents: ns?.nativeSubagentEvents,
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
        type: typeByNodeId.get(n.nodeId) ?? 'stage',
        runtime: runtimeByNodeId.get(n.nodeId) ?? '',
        status: n.status,
        attempts: n.attempts.length,
        duration: fmtDuration(lastAttempt),
        mode: n.workspaceMode,
        workspacePath: n.workspacePath,
        frozenBase: n.frozenBase,
        scopes: n.writeScopes?.length ? `${n.writeScopes[0]}${n.writeScopes.length > 1 ? ` +${n.writeScopes.length - 1}` : ''}` : undefined,
        gateOutcome: n.gateOutcome,
        nativeSubagentMode: n.nativeSubagentMode,
        crossRuntimeMode: n.crossRuntimeMode,
        repairEpoch: n.repairEpoch,
        integrationInputs: n.integrationInputs,
        changesetManifest: n.changesetManifest,
        changesetHash: n.changesetHash,
        conflictArtifact: n.conflictArtifact,
        admissionSummary: n.admissionSummary,
        publishReadiness: n.publishReadiness,
        brokeredChildren: n.brokeredChildren,
        nativeSubagentEvents: n.nativeSubagentEvents,
      });
    }

    return rows;
  }
}
