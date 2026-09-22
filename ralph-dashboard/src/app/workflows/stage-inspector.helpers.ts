import type {
  DisplayGraphNodeKind,
  WorkflowDetail,
  WorkflowDisplayGraphNode,
  WorkflowStageModel,
} from './workflow.types';

const INCLUDE_RE = /\{\{INCLUDE:([A-Za-z0-9][A-Za-z0-9-]*)\}\}/g;

const SUPERVISOR_TYPES = new Set([
  'integrate',
  'join',
  'gate',
  'checkpoint',
  'router',
  'approval',
  'input',
  'consensus',
]);

export type StageWriteCapability = 'read-only' | 'mutation' | 'supervisor';

export interface ArtifactChip {
  readonly path: string;
  readonly required: boolean;
  readonly schema: string | null;
  readonly role: 'input' | 'output';
  /** Condition/status chip label. */
  readonly status: 'required' | 'optional';
}

export interface IncludeFragmentRef {
  readonly name: string;
  readonly body: string | null;
}

export interface StageSourceFocus {
  readonly stageId: string;
  /** 1-based inclusive line numbers into the workflow source file. */
  readonly startLine: number;
  readonly endLine: number;
  readonly text: string;
}

export interface GateBehaviorView {
  readonly kind: 'gate' | 'approval' | 'integrate' | 'join' | 'other-supervisor';
  readonly profile: string | null;
  readonly question: string | null;
  readonly changesTarget: string | null;
  readonly onExhausted: string | null;
}

export interface StageInspectorView {
  readonly stageId: string;
  readonly label: string;
  readonly role: 'agent' | 'supervisor';
  readonly nodeKind: DisplayGraphNodeKind | string;
  readonly stageType: string;
  readonly authored: boolean;
  readonly goal: string;
  readonly dependsOn: readonly string[];
  readonly inputs: readonly ArtifactChip[];
  readonly outputs: readonly ArtifactChip[];
  readonly runtime: string | null;
  readonly model: string | null;
  readonly writeCapability: StageWriteCapability;
  readonly writeScopes: string | null;
  readonly workspaceMode: string | null;
  readonly agentGitAccess: string | null;
  readonly gateBehavior: GateBehaviorView | null;
  readonly rework: {
    readonly loopBackTo: string | null;
    readonly changesTarget: string | null;
    readonly derivedFrom: string | null;
  } | null;
  readonly planRole: 'generate' | 'accept' | 'execute' | null;
  readonly planFrom: string | null;
  readonly planner: { readonly outputMode: string | null; readonly maxTodos: string | null } | null;
  readonly instructionsRaw: string | null;
  readonly includes: readonly IncludeFragmentRef[];
  /** Markdown-ready instructions with INCLUDE tokens expanded or linked. */
  readonly instructionsMarkdown: string | null;
  readonly source: StageSourceFocus | null;
}

interface InspectPathEntry {
  readonly path?: unknown;
  readonly required?: unknown;
  readonly schema?: unknown;
}

interface InspectStageRecord {
  readonly id?: unknown;
  readonly type?: unknown;
  readonly dependsOn?: unknown;
  readonly runtime?: unknown;
  readonly model?: unknown;
  readonly requires?: unknown;
  readonly produces?: unknown;
  readonly writeScopes?: unknown;
  readonly workspaceMode?: unknown;
  readonly agentGitAccess?: unknown;
  readonly loopBackTo?: unknown;
  readonly onExhausted?: unknown;
  readonly changesTarget?: unknown;
  readonly question?: unknown;
  readonly planFrom?: unknown;
  readonly planner?: unknown;
  readonly hasInstructions?: unknown;
}

function asText(value: unknown): string {
  return typeof value === 'string' ? value.trim() : '';
}

function asStringList(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value.map((entry) => asText(entry)).filter(Boolean);
}

function escapeRegex(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function lineIndent(line: string): number {
  const match = /^(\s*)/.exec(line);
  return match ? match[1].length : 0;
}

/**
 * Map a stage id to its authored YAML block line range in the workflow source.
 * Returns null when the stage is derived (e.g. review-approved) or not present.
 */
export function mapStageSourceRange(raw: string, stageId: string): StageSourceFocus | null {
  if (!raw || !stageId) return null;
  const lines = raw.split(/\r?\n/);
  const idPattern = new RegExp(`^(\\s*)-\\s+id:\\s*['\"]?${escapeRegex(stageId)}['\"]?\\s*$`);
  let start = -1;
  let baseIndent = 0;
  for (let i = 0; i < lines.length; i++) {
    const match = idPattern.exec(lines[i] ?? '');
    if (match) {
      start = i;
      baseIndent = match[1]?.length ?? 0;
      break;
    }
  }
  if (start < 0) return null;

  let end = start;
  for (let i = start + 1; i < lines.length; i++) {
    const line = lines[i] ?? '';
    if (line.trim() === '' || line.trim().startsWith('#')) {
      end = i;
      continue;
    }
    const indent = lineIndent(line);
    if (indent === baseIndent && /^\s*-\s+/.test(line)) {
      break;
    }
    if (indent < baseIndent) {
      break;
    }
    end = i;
  }

  return {
    stageId,
    startLine: start + 1,
    endLine: end + 1,
    text: lines.slice(start, end + 1).join('\n'),
  };
}

/**
 * Pull the literal `instructions: |` / `>` block from a stage YAML snippet.
 */
export function extractInstructionsFromStageBlock(block: string): string | null {
  const lines = block.split(/\r?\n/);
  let start = -1;
  let contentIndent = 0;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i] ?? '';
    const match = /^(\s*)instructions:\s*([|>][-+]?)\s*$/.exec(line);
    if (match) {
      start = i + 1;
      contentIndent = (match[1]?.length ?? 0) + 2;
      break;
    }
    const inline = /^(\s*)instructions:\s*(.+)\s*$/.exec(line);
    if (inline && inline[2] && !/^[|>]/.test(inline[2])) {
      const value = inline[2].trim().replace(/^['"]|['"]$/g, '');
      return value || null;
    }
  }
  if (start < 0) return null;

  const collected: string[] = [];
  for (let i = start; i < lines.length; i++) {
    const line = lines[i] ?? '';
    if (line.trim() === '') {
      collected.push('');
      continue;
    }
    const indent = lineIndent(line);
    if (indent < contentIndent) {
      break;
    }
    collected.push(line.slice(contentIndent));
  }
  while (collected.length > 0 && collected[collected.length - 1] === '') {
    collected.pop();
  }
  const text = collected.join('\n').trim();
  return text || null;
}

export function extractStageField(block: string, field: string): string | null {
  const pattern = new RegExp(`^\\s*${escapeRegex(field)}:\\s*(.+?)\\s*$`, 'm');
  const match = pattern.exec(block);
  if (!match?.[1]) return null;
  const value = match[1].trim().replace(/^['"]|['"]$/g, '');
  return value || null;
}

export function listIncludeFragments(text: string): string[] {
  const names: string[] = [];
  const seen = new Set<string>();
  INCLUDE_RE.lastIndex = 0;
  let match: RegExpExecArray | null;
  while ((match = INCLUDE_RE.exec(text)) !== null) {
    const name = match[1] ?? '';
    if (name && !seen.has(name)) {
      seen.add(name);
      names.push(name);
    }
  }
  return names;
}

/**
 * Present INCLUDE tokens as expanded blockquotes when fragment bodies are known,
 * otherwise as linked callouts that keep the fragment name visible.
 */
export function renderInstructionsWithIncludes(
  text: string,
  fragments?: ReadonlyMap<string, string> | null,
): { readonly markdown: string; readonly includes: readonly IncludeFragmentRef[] } {
  const includes: IncludeFragmentRef[] = [];
  const seen = new Set<string>();
  const markdown = text.replace(INCLUDE_RE, (_full, name: string) => {
    const body = fragments?.get(name) ?? null;
    if (!seen.has(name)) {
      seen.add(name);
      includes.push({ name, body });
    }
    if (body) {
      const quoted = body
        .split(/\r?\n/)
        .map((line) => `> ${line}`)
        .join('\n');
      return `\n\n> **Include: \`${name}\`**\n>\n${quoted}\n\n`;
    }
    return `\n\n> **Include fragment:** [\`${name}\`](#fragment-${name})\n\n`;
  });
  return { markdown, includes };
}

function pathEntries(value: unknown, role: 'input' | 'output'): ArtifactChip[] {
  if (!Array.isArray(value)) return [];
  const chips: ArtifactChip[] = [];
  for (const entry of value) {
    if (!entry || typeof entry !== 'object') continue;
    const record = entry as InspectPathEntry;
    const path = asText(record.path);
    if (!path) continue;
    const required = record.required !== false;
    chips.push({
      path,
      required,
      schema: asText(record.schema) || null,
      role,
      status: required ? 'required' : 'optional',
    });
  }
  return chips;
}

function parseWriteScopes(value: unknown): string | null {
  if (value == null) return null;
  if (typeof value === 'string') {
    const trimmed = value.trim();
    return trimmed || null;
  }
  if (Array.isArray(value)) {
    return JSON.stringify(value);
  }
  return String(value);
}

function hasMutationScopes(writeScopes: string | null): boolean {
  if (!writeScopes) return false;
  const normalized = writeScopes.trim();
  if (!normalized || normalized === '[]' || normalized === 'null') return false;
  return true;
}

function goalFromInstructions(instructions: string | null, stageType: string, stageId: string): string {
  if (!instructions) {
    if (SUPERVISOR_TYPES.has(stageType)) {
      return `Supervisor ${stageType} control`;
    }
    return stageId;
  }
  const first = instructions
    .split(/\n/)
    .map((line) => line.trim())
    .find((line) => line.length > 0 && !line.startsWith('{{INCLUDE:'));
  return first || stageId;
}

function findInspectStage(inspect: unknown, stageId: string): InspectStageRecord | null {
  if (!inspect || typeof inspect !== 'object') return null;
  const stages = (inspect as { stages?: unknown }).stages;
  if (!Array.isArray(stages)) return null;
  for (const stage of stages) {
    if (stage && typeof stage === 'object' && asText((stage as InspectStageRecord).id) === stageId) {
      return stage as InspectStageRecord;
    }
  }
  return null;
}

function findModelStage(detail: WorkflowDetail, stageId: string): WorkflowStageModel | null {
  const stages = detail.model?.stages ?? [];
  return stages.find((stage) => stage.id === stageId) ?? null;
}

function findGraphNode(detail: WorkflowDetail, stageId: string): WorkflowDisplayGraphNode | null {
  return detail.displayGraph?.nodes.find((node) => node.id === stageId) ?? null;
}

function plannerView(value: unknown): StageInspectorView['planner'] {
  if (!value || typeof value !== 'object') return null;
  const record = value as { outputMode?: unknown; maxTodos?: unknown };
  return {
    outputMode: asText(record.outputMode) || null,
    maxTodos: record.maxTodos == null ? null : String(record.maxTodos),
  };
}

/**
 * Build the inspector view for a selected stage from inspect topology, display
 * graph metadata, and the raw YAML source (instructions + line offsets).
 */
export function buildStageInspectorView(
  detail: WorkflowDetail,
  stageId: string,
  fragments?: ReadonlyMap<string, string> | null,
): StageInspectorView | null {
  if (!stageId) return null;

  const graphNode = findGraphNode(detail, stageId);
  const inspectStage = findInspectStage(detail.inspect, stageId);
  const modelStage = findModelStage(detail, stageId);
  const source = mapStageSourceRange(detail.raw, stageId);

  if (!graphNode && !inspectStage && !modelStage && !source) {
    return null;
  }

  const stageType =
    asText(inspectStage?.type) ||
    graphNode?.stageType ||
    (modelStage?.kind === 'supervisor' ? modelStage.type : 'agent') ||
    'stage';
  const nodeKind: DisplayGraphNodeKind | string = graphNode?.kind ?? (SUPERVISOR_TYPES.has(stageType) ? stageType : 'agent');
  const isSupervisor =
    SUPERVISOR_TYPES.has(stageType) ||
    SUPERVISOR_TYPES.has(String(nodeKind)) ||
    modelStage?.kind === 'supervisor';

  let instructionsRaw: string | null = null;
  if (modelStage?.kind === 'ordinary' && modelStage.instructions) {
    instructionsRaw = modelStage.instructions;
  } else if (source) {
    instructionsRaw = extractInstructionsFromStageBlock(source.text);
  }

  const includeRender = instructionsRaw
    ? renderInstructionsWithIncludes(instructionsRaw, fragments)
    : { markdown: null as string | null, includes: [] as IncludeFragmentRef[] };

  const dependsOn =
    asStringList(inspectStage?.dependsOn).length > 0
      ? asStringList(inspectStage?.dependsOn)
      : modelStage?.dependsOn
        ? [...modelStage.dependsOn]
        : [];

  const inputs =
    pathEntries(inspectStage?.requires, 'input').length > 0
      ? pathEntries(inspectStage?.requires, 'input')
      : modelStage?.kind === 'ordinary'
        ? modelStage.requires.map((entry) => ({
            path: entry.path,
            required: entry.required,
            schema: null,
            role: 'input' as const,
            status: entry.required ? ('required' as const) : ('optional' as const),
          }))
        : [];

  const outputs =
    pathEntries(inspectStage?.produces, 'output').length > 0
      ? pathEntries(inspectStage?.produces, 'output')
      : modelStage?.kind === 'ordinary'
        ? modelStage.produces.map((entry) => ({
            path: entry.path,
            required: entry.required,
            schema: null,
            role: 'output' as const,
            status: entry.required ? ('required' as const) : ('optional' as const),
          }))
        : [];

  const writeScopes = parseWriteScopes(inspectStage?.writeScopes);
  const writeCapability: StageWriteCapability = isSupervisor
    ? 'supervisor'
    : hasMutationScopes(writeScopes)
      ? 'mutation'
      : 'read-only';

  const question =
    asText(inspectStage?.question) ||
    (modelStage?.kind === 'supervisor' ? modelStage.question : undefined) ||
    null;
  const changesTarget =
    asText(inspectStage?.changesTarget) ||
    graphNode?.changesTarget ||
    (modelStage?.kind === 'supervisor' ? modelStage.changesTarget : undefined) ||
    null;
  const onExhausted = asText(inspectStage?.onExhausted) || null;
  const profile = source ? extractStageField(source.text, 'profile') : null;

  let gateBehavior: GateBehaviorView | null = null;
  if (isSupervisor) {
    const kind: GateBehaviorView['kind'] =
      stageType === 'gate'
        ? 'gate'
        : stageType === 'approval'
          ? 'approval'
          : stageType === 'integrate'
            ? 'integrate'
            : stageType === 'join'
              ? 'join'
              : 'other-supervisor';
    gateBehavior = {
      kind,
      profile,
      question,
      changesTarget,
      onExhausted,
    };
  }

  const loopBackTo = asText(inspectStage?.loopBackTo) || graphNode?.loopBackTo || null;
  const rework =
    loopBackTo || changesTarget || graphNode?.derivedFrom === 'rework'
      ? {
          loopBackTo,
          changesTarget,
          derivedFrom: graphNode?.derivedFrom ?? null,
        }
      : null;

  const runtime =
    asText(inspectStage?.runtime) ||
    (modelStage?.kind === 'ordinary' ? modelStage.runtime : undefined) ||
    null;
  const model =
    asText(inspectStage?.model) ||
    (modelStage?.kind === 'ordinary' ? modelStage.model : undefined) ||
    null;

  return {
    stageId,
    label: graphNode?.label || stageId,
    role: isSupervisor ? 'supervisor' : 'agent',
    nodeKind,
    stageType,
    authored: graphNode?.authored ?? source != null,
    goal: isSupervisor
      ? question || `Supervisor ${stageType} control`
      : goalFromInstructions(instructionsRaw, stageType, stageId),
    dependsOn,
    inputs,
    outputs,
    runtime,
    model,
    writeCapability,
    writeScopes,
    workspaceMode: asText(inspectStage?.workspaceMode) || null,
    agentGitAccess: asText(inspectStage?.agentGitAccess) || null,
    gateBehavior,
    rework,
    planRole: graphNode?.planRole ?? null,
    planFrom: asText(inspectStage?.planFrom) || null,
    planner: plannerView(inspectStage?.planner),
    instructionsRaw,
    includes: includeRender.includes,
    instructionsMarkdown: includeRender.markdown,
    source,
  };
}

/** Lightweight YAML highlighter for the focused source pane (no new deps). */
export function highlightYamlSource(source: string): string {
  return source
    .split(/\r?\n/)
    .map((line) => highlightYamlLine(line))
    .join('\n');
}

function escapeHtml(input: string): string {
  return input
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function highlightYamlLine(line: string): string {
  const escaped = escapeHtml(line);
  const keyMatch = /^(\s*)(-?\s*)([A-Za-z_][\w-]*)(:)(.*)$/.exec(line);
  if (keyMatch) {
    const [, indent, list, key, colon, rest] = keyMatch;
    return `${escapeHtml(indent ?? '')}${escapeHtml(list ?? '')}<span class="tok-key">${escapeHtml(key ?? '')}</span>${escapeHtml(colon ?? '')}${highlightYamlValue(rest ?? '')}`;
  }
  return escaped;
}

function highlightYamlValue(raw: string): string {
  const trimmed = raw.trimStart();
  const lead = raw.slice(0, raw.length - trimmed.length);
  if (/^[|>]/.test(trimmed)) {
    return `${escapeHtml(lead)}<span class="tok-block">${escapeHtml(trimmed)}</span>`;
  }
  if (/^(['"]).*\1$/.test(trimmed) || /^\[.*\]$/.test(trimmed)) {
    return `${escapeHtml(lead)}<span class="tok-string">${escapeHtml(trimmed)}</span>`;
  }
  if (/^(true|false|null)$/i.test(trimmed) || /^-?\d+(\.\d+)?$/.test(trimmed)) {
    return `${escapeHtml(lead)}<span class="tok-literal">${escapeHtml(trimmed)}</span>`;
  }
  return escapeHtml(raw);
}

export function filterSourceLines(
  source: StageSourceFocus,
  query: string,
): { readonly lineNumber: number; readonly text: string; readonly match: boolean }[] {
  const q = query.trim().toLowerCase();
  const lines = source.text.split(/\r?\n/);
  return lines.map((text, index) => {
    const lineNumber = source.startLine + index;
    const match = q.length === 0 ? false : text.toLowerCase().includes(q);
    return { lineNumber, text, match };
  });
}
