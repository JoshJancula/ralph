/** Client-side mirror of the server's assistant API shapes (src/server/assistant/*). */

export type AssistantRole = 'user' | 'assistant' | 'system';

export interface AssistantChatMessage {
  readonly role: AssistantRole;
  readonly content: string;
}

export type AssistantToolKind = 'read' | 'draft' | 'propose';

export type AssistantToolName =
  | 'list_workflows'
  | 'get_workflow'
  | 'list_runs'
  | 'get_run_status'
  | 'list_plans'
  | 'list_tasks'
  | 'list_task_statuses'
  | 'list_schedules'
  | 'list_workflow_templates'
  | 'list_runtimes'
  | 'preview_cron'
  | 'validate_workflow_draft'
  | 'create_task'
  | 'create_tasks'
  | 'update_task'
  | 'launch_task'
  | 'create_workflow'
  | 'create_schedule'
  | 'update_schedule'
  | 'start_workflow'
  | 'cancel_run';

export interface AssistantToolSummary {
  readonly name: AssistantToolName;
  readonly description: string;
  readonly mutating: boolean;
  readonly kind?: AssistantToolKind;
}

/** Server-verified facts about a proposal, computed before the card is shown. */
export interface AssistantCronPreview {
  readonly valid: boolean;
  readonly error?: string;
  readonly upcoming?: readonly string[];
}

export interface AssistantWorkflowPreview {
  readonly valid: boolean;
  readonly diagnostics?: string;
  readonly frontmatter?: string;
}

/** A change the assistant is asking the user to confirm. Nothing has happened yet. */
export interface AssistantProposalView {
  readonly id: string;
  readonly tool: AssistantToolName;
  readonly title: string;
  readonly description: string;
  readonly arguments: Readonly<Record<string, unknown>>;
  readonly preview?: AssistantCronPreview | AssistantWorkflowPreview | unknown;
}

export interface AssistantRuntimeSummary {
  readonly id: string;
  readonly label: string;
  readonly installed: boolean;
}

export interface AssistantModelSummary {
  readonly id: string;
  readonly label: string;
}

export interface AssistantApprovedAction {
  readonly tool: AssistantToolName;
  readonly arguments: Readonly<Record<string, unknown>>;
}

export interface AssistantChatResponse {
  readonly role: 'assistant';
  readonly content: string;
  readonly toolsUsed: readonly AssistantToolName[];
  readonly proposals?: readonly AssistantProposalView[];
  readonly answeredBy: string;
  readonly degraded: boolean;
}
