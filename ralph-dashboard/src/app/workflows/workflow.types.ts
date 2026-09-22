/**
 * Client-side mirror of the server's `WorkflowFrontmatterModel` shape
 * (src/server/workflow-frontmatter.ts) and the workflow-api.ts response
 * bodies. Duplicated rather than imported: the client bundle must not pull
 * in server-only node:fs/node:child_process code. See port-design.md "API".
 */

export type WorkflowScope = 'project' | 'global' | 'bundled';
export type WritableWorkflowScope = 'project' | 'global';

export interface WorkflowScopeEntry {
  readonly scope: WorkflowScope;
  readonly overview: string;
}

export interface WorkflowShadowRef {
  readonly scope: WorkflowScope;
}

/** Where the loaded definition is stored. Project overrides retain their owning project. */
export interface WorkflowOrigin {
  readonly kind: WorkflowScope;
  readonly projectRoot: string | null;
  readonly workspaceRoot: string | null;
  readonly sourcePath: string | null;
}

export type WorkflowMode = 'sequential' | 'dependency';
export type SupervisorType =
  | 'integrate'
  | 'join'
  | 'gate'
  | 'checkpoint'
  | 'router'
  | 'approval'
  | 'consensus'
  | 'input';

/** Catalog facts derived server-side from the resolved definition (see workflow-catalog.ts). */
export interface WorkflowCatalogMeta {
  readonly purpose: string;
  readonly expectedOutcome: string;
  readonly mode: string | null;
  readonly stageCount: number;
  readonly executableStageCount: number;
  readonly supervisorStageCount: number;
  readonly requiresSuppliedPlan: boolean;
  readonly writes: boolean;
  readonly hasHumanGates: boolean;
}

export interface WorkflowInheritRef {
  readonly scope: WorkflowScope;
  readonly explanation: string;
}

export interface WorkflowListItem {
  readonly id: string;
  /** Winning scope for runs (project -> global -> bundled). */
  readonly scope: WorkflowScope;
  readonly effectiveScope?: WorkflowScope;
  readonly availableScopes?: readonly WorkflowScopeEntry[];
  readonly overview: string;
  readonly editable: boolean;
  readonly catalog?: WorkflowCatalogMeta;
  /** Present when project/global overrides a lower layer; never set for bundled. */
  readonly inheritsFrom?: WorkflowInheritRef | null;
}

export interface PathEntry {
  readonly path: string;
  readonly required: boolean;
  readonly schema?: string;
}

export interface PlannerModel {
  readonly outputMode: string;
  readonly maxTodos?: number;
}

export interface LoopCheckModel {
  readonly path: string;
  readonly schema?: string;
}

export interface RouterModel {
  readonly allowedTargets: readonly string[];
  readonly defaultTarget: string;
  readonly onInvalid?: string;
  readonly terminalOutcomes?: readonly string[];
}

export interface ConsensusVoterModel {
  readonly id: string;
  readonly runtime?: string;
  readonly model?: string;
  readonly sessionStrategy?: string;
  readonly instructions?: string;
}

export interface OrdinaryStageModel {
  readonly id: string;
  readonly kind: 'ordinary';
  readonly dependsOn: readonly string[];
  readonly runtime?: string;
  readonly model?: string;
  readonly sessionStrategy?: string;
  readonly instructions?: string;
  readonly produces: readonly PathEntry[];
  readonly requires: readonly PathEntry[];
  readonly planner?: PlannerModel;
  readonly planFrom?: string;
  readonly workspaceMode?: string;
  readonly writeScopes?: readonly string[];
  readonly agentGitAccess?: string;
  readonly loopBackTo?: string;
  readonly loopCheck?: LoopCheckModel;
  readonly onExhausted?: string;
  readonly router?: RouterModel;
  readonly unsupportedKeys: readonly string[];
}

export interface SupervisorStageModel {
  readonly id: string;
  readonly kind: 'supervisor';
  readonly type: SupervisorType;
  readonly dependsOn: readonly string[];
  readonly requires?: readonly PathEntry[];
  readonly profile?: string;
  readonly workspaceMode?: string;
  readonly question?: string;
  readonly changesTarget?: string;
  readonly policy?: string;
  readonly quorum?: number;
  readonly minRuntimes?: number;
  readonly voters?: readonly ConsensusVoterModel[];
  readonly router?: RouterModel;
  readonly unsupportedKeys: readonly string[];
}

export type WorkflowStageModel = OrdinaryStageModel | SupervisorStageModel;

export interface TodoModel {
  readonly id: string;
  readonly stage: string;
  readonly content: string;
  readonly verification: string;
  readonly status: string;
}

export interface VerificationStepModel {
  readonly name: string;
  readonly command: string;
  readonly timeout?: number;
}

export interface VerificationProfileModel {
  readonly name: string;
  readonly steps: readonly VerificationStepModel[];
}

export interface PlanInputModel {
  readonly stage: string;
  readonly required: boolean;
}

export interface WorkflowModel {
  readonly name?: string;
  readonly overview?: string;
  readonly kind?: string;
  readonly mode?: string;
  readonly defaultsRuntime?: string;
  readonly defaultsModel?: string;
  readonly planInput?: PlanInputModel;
  readonly maxParallel?: number;
  readonly maxReworkIterations?: number;
  readonly publishMode?: string;
  readonly verificationProfiles?: readonly VerificationProfileModel[];
  readonly stages: readonly WorkflowStageModel[];
  readonly todos: readonly TodoModel[];
  readonly unsupportedKeys: readonly string[];
  readonly body: string;
  readonly sourceRaw: string;
}

export interface WorkflowDetail {
  readonly id: string;
  /** Scope of the bytes currently loaded (may differ from the effective winner). */
  readonly scope: WorkflowScope;
  readonly effectiveScope?: WorkflowScope;
  readonly availableScopes?: readonly WorkflowScopeEntry[];
  readonly shadowedBy?: WorkflowShadowRef;
  /** Source ownership for the loaded layer, not merely the winning layer. */
  readonly origin?: WorkflowOrigin;
  readonly raw: string;
  readonly sha256: string;
  readonly inspect: unknown;
  readonly mermaid: string;
  /** Topology projected from inspect + rework unrolling (same rules as the runner). */
  readonly displayGraph?: WorkflowDisplayGraph;
  /** Present when the definition cannot produce a display graph. */
  readonly graphError?: WorkflowDisplayGraphError;
  /** Present when the file uses only the structured-edit subset (see port-design.md). */
  readonly model?: WorkflowModel;
  /** Present (possibly empty pre-parse-error) otherwise; the file must be edited as raw text. */
  readonly unsupportedKeys?: readonly string[];
  readonly parseError?: string;
}

export type DisplayGraphEdgeKind =
  | 'dependency'
  | 'sequential'
  | 'plan-handoff'
  | 'rework-passed'
  | 'rework-changes-required'
  | 'rework'
  | 'request-changes';

export type DisplayGraphNodeKind =
  | 'agent'
  | 'planner'
  | 'plan-consumer'
  | 'gate'
  | 'approval'
  | 'integrate'
  | 'join'
  | 'checkpoint'
  | 'router'
  | 'input'
  | 'consensus'
  | 'stage';

export interface WorkflowDisplayGraphNode {
  readonly id: string;
  readonly label: string;
  readonly kind: DisplayGraphNodeKind;
  readonly stageType: string;
  readonly authored: boolean;
  readonly derivedFrom: 'stage' | 'rework' | 'join';
  readonly planRole: 'generate' | 'accept' | 'execute' | null;
  readonly waveIndex: number;
  readonly loopBackTo: string | null;
  readonly changesTarget: string | null;
}

export interface WorkflowDisplayGraphEdge {
  readonly from: string;
  readonly to: string;
  readonly kind: DisplayGraphEdgeKind;
  readonly label: string | null;
  readonly scheduleEdge: boolean;
}

export interface WorkflowDisplayGraph {
  readonly workflowId: string;
  readonly mode: 'sequential' | 'dependency';
  readonly sourceKind: string;
  readonly sourcePath: string;
  readonly maxReworkIterations: number | null;
  readonly nodes: readonly WorkflowDisplayGraphNode[];
  readonly edges: readonly WorkflowDisplayGraphEdge[];
  readonly waves: readonly (readonly string[])[];
}

export interface WorkflowDisplayGraphError {
  readonly code: string;
  readonly message: string;
  readonly diagnostics: string;
  readonly sourcePath: string | null;
  readonly sourceKind: string | null;
  readonly line: number | null;
  readonly column: number | null;
}

export interface RunListItem {
  readonly runId: string;
  readonly workflowId: string;
  readonly mode: string;
  readonly entryKind: string;
  readonly state: string;
  readonly createdAt: string;
  readonly task?: string;
  readonly sourceKind?: string;
  readonly graphRunLink: { readonly namespace: string; readonly runId: string } | null;
  readonly executionKind?: 'workflow' | 'leaf-plan';
  /** Workspace that produced this row when the dashboard aggregates projects. */
  readonly workspaceRoot?: string;
  readonly projectRoot?: string;
}

export interface RunsInventoryResponse {
  readonly runs: readonly RunListItem[];
  /** Requested workspace root, or null when the response merges workspaces. */
  readonly workspaceRoot: string | null;
  /** Registered workspace entries omitted because their state root is missing. */
  readonly skipped: number;
}

export interface RunStatus {
  readonly schemaVersion: number;
  readonly run: Record<string, unknown>;
  readonly stages: readonly Record<string, unknown>[];
  readonly diagnosis: Record<string, unknown>;
  readonly nextAction: unknown;
  readonly detail?: WorkflowRunDetailView;
}

export type OperatorActionKind = 'respond' | 'resume' | 'reset' | 'cancel' | 'none' | 'other';
export type ActionRequestStatus = 'outstanding' | 'answered' | 'consumed' | 'cancelled';

export interface StageMapEntry {
  readonly id: string;
  readonly state: string;
  readonly attempt: number;
  readonly stageKind: string;
  readonly todoProgress: { readonly completed: number; readonly total: number; readonly currentTodoId: string | null } | null;
  readonly requiredEvidence: readonly string[];
  readonly producedEvidence: readonly string[];
  readonly actionRequestId: string | null;
  readonly requestState: string | null;
  readonly nextPermittedAction: string | null;
  readonly sourcePlanPath: string | null;
  readonly controlPlanPath: string | null;
  readonly planSourceKind: string | null;
  readonly reasonCode: string | null;
  readonly summary: string | null;
  readonly reworkRound: number;
  readonly logScope: string | null;
}

export interface RunTimelineEvent {
  readonly id: string;
  readonly timestamp: string;
  readonly type: string;
  readonly stageId: string | null;
  readonly message: string;
}

export interface OperatorNextAction {
  readonly kind: OperatorActionKind;
  readonly label: string;
  readonly description: string;
  readonly enabled: boolean;
  readonly disabledReason: string | null;
  readonly stageId: string | null;
  readonly requestId: string | null;
  readonly resetStageId: string | null;
  readonly argv: readonly string[];
}

export interface RunActionDetail {
  readonly requestId: string;
  readonly kind: string;
  readonly stageId: string | null;
  readonly question: string;
  readonly status: ActionRequestStatus;
  readonly choices: readonly string[];
  readonly decision: string | null;
  readonly decidedAt: string | null;
  readonly message: string | null;
  readonly enabled: boolean;
  readonly disabledReason: string | null;
}

export interface WorkflowRunDetailView {
  readonly stageMap: readonly StageMapEntry[];
  readonly timeline: readonly RunTimelineEvent[];
  readonly operatorNext: OperatorNextAction;
  readonly actions: readonly RunActionDetail[];
}

export interface RuntimeDescriptor {
  readonly id: string;
  readonly installed: boolean;
}

export interface ModelDescriptor {
  readonly id: string;
  readonly label: string;
}

export interface DashboardCapabilities {
  readonly workflowWrites: boolean;
  readonly workflowRuns: boolean;
  readonly assistant: boolean;
  readonly safetyWrites: boolean;
}

export interface CreateWorkflowCommand {
  readonly id: string;
  readonly scope: WritableWorkflowScope;
  readonly name?: string;
  readonly overview?: string;
  readonly kind?: string;
  readonly mode?: WorkflowMode;
  readonly defaults?: { readonly runtime?: string; readonly model?: string };
  readonly planInput?: PlanInputModel;
  readonly pipeline: {
    readonly maxParallel?: number;
    readonly maxReworkIterations?: number;
    readonly publishMode?: string;
    readonly verificationProfiles?: readonly VerificationProfileModel[];
    readonly stages: readonly WorkflowStageModel[];
  };
  readonly todos?: readonly TodoModel[];
}

export interface UpdateWorkflowCommand {
  readonly sha256: string;
  readonly model?: WorkflowModel;
  readonly raw?: string;
}

export interface CustomizeWorkflowCommand {
  readonly targetScope: WritableWorkflowScope;
  readonly sourceScope?: 'bundled' | 'global';
}

export interface CustomizeWorkflowResponse {
  readonly scope: WritableWorkflowScope;
  readonly sha256: string;
  readonly created?: boolean;
}

export interface WorkflowRoutingPatch {
  readonly sha256: string;
  readonly defaults?: { readonly runtime?: string | null; readonly model?: string | null; readonly clear?: boolean } | null;
  readonly stages?: Readonly<
    Record<string, { readonly runtime?: string | null; readonly model?: string | null; readonly clear?: boolean } | null>
  >;
}

export interface StartWorkflowCommand {
  readonly task: string;
  readonly runtime?: string;
  readonly model?: string;
}

export interface StartWorkflowResponse {
  readonly runId?: string;
  readonly status?: 'pending';
  readonly logPath: string;
}

export type ActionDecision = 'approve' | 'request-changes' | 'cancel' | 'answer';

export interface RespondActionCommand {
  readonly requestId: string;
  readonly decision: ActionDecision;
  readonly message?: string;
}

export interface ResetRunCommand {
  readonly stage?: string;
  readonly all?: boolean;
}

export interface ApiErrorBody {
  readonly error: string;
  readonly diagnostics?: string;
}
