/**
 * Hand-written codec for `<id>.workflow.md` frontmatter. No YAML library:
 * project rule forbids new npm dependencies. Parses the public workflow
 * contract used by bundled workflows (see docs/workflow-editor-field-coverage.md)
 * into a typed model; every other frontmatter key is reported in
 * `unsupportedKeys` rather than dropped, so callers can fall back to raw-text
 * editing without losing data.
 *
 * emit() is a no-op byte-for-byte round trip when the structured-edit fields
 * are unchanged from what parse() produced (comparing the editable
 * projection, not the whole model) — an unmodified file must never be
 * re-serialized. Emitting an actual change requires the model to carry no
 * unsupportedKeys; callers with unsupportedKeys must edit raw frontmatter
 * text directly instead of going through this codec.
 *
 * `ralph workflow inspect` (plan-todo) remains the accept/reject authority on
 * save. Local validation helpers mirror safe messages for inline editor UX.
 */

export type SupervisorType =
  | 'integrate'
  | 'join'
  | 'gate'
  | 'checkpoint'
  | 'router'
  | 'approval'
  | 'consensus'
  | 'input';

const SUPERVISOR_TYPES: ReadonlySet<string> = new Set([
  'integrate',
  'join',
  'gate',
  'checkpoint',
  'router',
  'approval',
  'consensus',
  'input',
]);

/** Agent fields that supervisors must never carry in structured edits. */
export const SUPERVISOR_FORBIDDEN_AGENT_FIELDS = [
  'runtime',
  'model',
  'sessionStrategy',
  'instructions',
  'planner',
  'planFrom',
  'planFile',
  'writeScopes',
  'agentGitAccess',
  'loopBackTo',
  'loopCheck',
  'onExhausted',
] as const;

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
  /** gate: verification profile name */
  readonly profile?: string;
  /** integrate (and similar): snapshot | worktree | shared */
  readonly workspaceMode?: string;
  /** approval */
  readonly question?: string;
  /** approval */
  readonly changesTarget?: string;
  /** consensus / join */
  readonly policy?: string;
  readonly quorum?: number;
  readonly minRuntimes?: number;
  readonly voters?: readonly ConsensusVoterModel[];
  /** type: router supervisor block when authored that way */
  readonly router?: RouterModel;
  readonly unsupportedKeys: readonly string[];
}

export type StageModel = OrdinaryStageModel | SupervisorStageModel;

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

export interface WorkflowFrontmatterModel {
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
  readonly stages: readonly StageModel[];
  /**
   * `ralph workflow inspect` rejects a dependency-mode workflow with no
   * top-level todo whose content contains `{{TASK}}`, even when every stage's
   * own instructions already contain it (undocumented in docs/WORKFLOWS.md,
   * confirmed empirically — see port-design.md). Present when the source file
   * authored one; emit() synthesizes a minimal one when absent and stages
   * exist, so the studio UI never has to manage this directly.
   */
  readonly todos: readonly TodoModel[];
  /** Dotted paths outside the structured-edit subset. */
  readonly unsupportedKeys: readonly string[];
  /** Markdown/body content after the closing frontmatter delimiter, verbatim. */
  readonly body: string;
  /** The exact bytes this model was parsed from. Carried through so emit() can detect a no-op edit. */
  readonly sourceRaw: string;
}

export class WorkflowFrontmatterError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'WorkflowFrontmatterError';
  }
}

export type ParseResult =
  | { readonly ok: true; readonly model: WorkflowFrontmatterModel }
  | { readonly ok: false; readonly error: WorkflowFrontmatterError };

// ---------------------------------------------------------------------------
// Generic indentation-based YAML-subset tree
// ---------------------------------------------------------------------------

type YamlValue = string | null | YamlNode[] | Map<string, YamlNode>;

interface YamlNode {
  readonly value: YamlValue;
}

interface Line {
  readonly indent: number;
  readonly text: string;
  readonly raw: string;
}

function stripFrontmatter(raw: string): { frontmatter: string; body: string } | null {
  const normalized = raw.replace(/\r\n/g, '\n');
  if (!normalized.startsWith('---\n') && normalized !== '---') {
    return null;
  }
  const rest = normalized.slice(4);
  const closeMatch = /\n---(\n|$)/.exec(rest);
  if (!closeMatch || closeMatch.index === undefined) {
    return null;
  }
  const frontmatter = rest.slice(0, closeMatch.index);
  const body = rest.slice(closeMatch.index + closeMatch[0].length);
  return { frontmatter, body };
}

function tokenizeLines(text: string): Line[] {
  const lines: Line[] = [];
  for (const raw of text.split('\n')) {
    if (raw.trim().length === 0) {
      continue;
    }
    const trimmedStart = raw.replace(/^ */, '');
    const indent = raw.length - trimmedStart.length;
    lines.push({ indent, text: trimmedStart, raw });
  }
  return lines;
}

/** Parses a block starting at lines[start] with indentation === baseIndent. Returns [node, nextIndex]. */
function parseBlock(lines: readonly Line[], start: number, baseIndent: number): [YamlNode, number] {
  if (start >= lines.length || lines[start]!.indent !== baseIndent) {
    return [{ value: null }, start];
  }
  if (lines[start]!.text.startsWith('- ') || lines[start]!.text === '-') {
    return parseSequence(lines, start, baseIndent);
  }
  return parseMapping(lines, start, baseIndent);
}

function parseSequence(lines: readonly Line[], start: number, indent: number): [YamlNode, number] {
  const items: YamlNode[] = [];
  let i = start;
  while (i < lines.length && lines[i]!.indent === indent && (lines[i]!.text === '-' || lines[i]!.text.startsWith('- '))) {
    const line = lines[i]!;
    const rest = line.text === '-' ? '' : line.text.slice(2);
    if (rest.length === 0) {
      // Item is a nested block on subsequent, deeper-indented lines.
      const [node, next] = parseBlock(lines, i + 1, indent + 2);
      items.push(node);
      i = next;
      continue;
    }
    const colonMatch = /^([A-Za-z0-9_-]+):(\s|$)/.exec(rest);
    if (colonMatch) {
      // "- key: value" opens an inline mapping; the item's effective column
      // is where "key" starts (indent + 2), so sibling "key2: value" lines
      // at that column continue the same mapping entry.
      const virtualIndent = indent + 2;
      const syntheticFirstLine: Line = { indent: virtualIndent, text: rest, raw: line.raw };
      const [node, next] = parseMappingFromLines([syntheticFirstLine, ...lines.slice(i + 1)], 0, virtualIndent);
      items.push(node);
      i = i + 1 + (next - 1);
      continue;
    }
    items.push({ value: parseScalar(rest) });
    i += 1;
  }
  return [{ value: items }, i];
}

function parseMapping(lines: readonly Line[], start: number, indent: number): [YamlNode, number] {
  return parseMappingFromLines(lines, start, indent);
}

function parseMappingFromLines(lines: readonly Line[], start: number, indent: number): [YamlNode, number] {
  const map = new Map<string, YamlNode>();
  let i = start;
  while (i < lines.length && lines[i]!.indent === indent) {
    const line = lines[i]!;
    if (line.text.startsWith('- ') || line.text === '-') {
      break;
    }
    const colonIdx = findKeyColon(line.text);
    if (colonIdx < 0) {
      break;
    }
    const key = line.text.slice(0, colonIdx).trim();
    const rest = line.text.slice(colonIdx + 1).trim();
    if (rest === '|' || rest.startsWith('|')) {
      const [text, next] = parseBlockLiteral(lines, i + 1, indent);
      map.set(key, { value: text });
      i = next;
      continue;
    }
    if (rest.length === 0) {
      const [node, next] = parseBlock(lines, i + 1, indent + 2);
      map.set(key, node);
      i = next;
      continue;
    }
    map.set(key, { value: parseScalar(rest) });
    i += 1;
  }
  return [{ value: map }, i];
}

function findKeyColon(text: string): number {
  let inSingle = false;
  let inDouble = false;
  for (let idx = 0; idx < text.length; idx += 1) {
    const ch = text[idx];
    if (ch === "'" && !inDouble) inSingle = !inSingle;
    else if (ch === '"' && !inSingle) inDouble = !inDouble;
    else if (ch === ':' && !inSingle && !inDouble && (idx === text.length - 1 || text[idx + 1] === ' ')) {
      return idx;
    }
  }
  return -1;
}

function parseBlockLiteral(lines: readonly Line[], start: number, parentIndent: number): [string, number] {
  const contentLines: string[] = [];
  let i = start;
  let blockIndent: number | null = null;
  while (i < lines.length) {
    const line = lines[i]!;
    if (line.indent <= parentIndent) {
      break;
    }
    if (blockIndent === null) {
      blockIndent = line.indent;
    }
    if (line.indent < blockIndent) {
      break;
    }
    contentLines.push(line.raw.slice(blockIndent));
    i += 1;
  }
  return [contentLines.join('\n') + (contentLines.length > 0 ? '\n' : ''), i];
}

function parseScalar(text: string): string {
  const trimmed = text.trim();
  if (trimmed.length >= 2 && trimmed.startsWith('"') && trimmed.endsWith('"')) {
    return trimmed
      .slice(1, -1)
      .replace(/\\"/g, '"')
      .replace(/\\n/g, '\n')
      .replace(/\\\\/g, '\\');
  }
  if (trimmed.length >= 2 && trimmed.startsWith("'") && trimmed.endsWith("'")) {
    return trimmed.slice(1, -1).replace(/''/g, "'");
  }
  return trimmed;
}

function asMap(node: YamlNode | undefined): Map<string, YamlNode> {
  if (node && node.value instanceof Map) {
    return node.value;
  }
  return new Map();
}

function asArray(node: YamlNode | undefined): YamlNode[] {
  if (node && Array.isArray(node.value)) {
    return node.value;
  }
  return [];
}

function asString(node: YamlNode | undefined): string | undefined {
  if (node && typeof node.value === 'string') {
    return node.value;
  }
  return undefined;
}

function asNumber(node: YamlNode | undefined): number | undefined {
  const s = asString(node);
  if (s === undefined) return undefined;
  const n = Number(s);
  return Number.isFinite(n) ? n : undefined;
}

// ---------------------------------------------------------------------------
// Structured-edit subset projection
// ---------------------------------------------------------------------------

const TOP_LEVEL_ALLOWED = new Set(['name', 'overview', 'kind', 'mode', 'defaults', 'planInput', 'pipeline', 'todos']);
const TODO_ALLOWED = new Set(['id', 'stage', 'content', 'verification', 'status']);
const DEFAULTS_ALLOWED = new Set(['runtime', 'model']);
const PIPELINE_ALLOWED = new Set([
  'maxParallel',
  'maxReworkIterations',
  'publishMode',
  'verificationProfiles',
  'stages',
]);
const PLAN_INPUT_ALLOWED = new Set(['stage', 'required']);
const PATH_ENTRY_ALLOWED = new Set(['path', 'required', 'schema']);
const PLANNER_ALLOWED = new Set(['outputMode', 'maxTodos']);
const LOOP_CHECK_ALLOWED = new Set(['path', 'schema']);
const ROUTER_ALLOWED = new Set(['allowedTargets', 'defaultTarget', 'onInvalid', 'terminalOutcomes']);
const VOTER_ALLOWED = new Set(['id', 'runtime', 'model', 'sessionStrategy', 'instructions']);
const VERIFICATION_PROFILE_ALLOWED = new Set(['name', 'steps']);
const VERIFICATION_STEP_ALLOWED = new Set(['name', 'command', 'timeout', 'continueOnFailure', 'requiredArtifacts', 'resourceClass']);
const ORDINARY_STAGE_ALLOWED = new Set([
  'id',
  'dependsOn',
  'runtime',
  'model',
  'instructions',
  'produces',
  'requires',
  'planner',
  'planFrom',
  'workspaceMode',
  'writeScopes',
  'agentGitAccess',
  'loopBackTo',
  'loopCheck',
  'onExhausted',
  'router',
]);
const SUPERVISOR_STAGE_ALLOWED = new Set([
  'id',
  'type',
  'dependsOn',
  'requires',
  'profile',
  'workspaceMode',
  'question',
  'changesTarget',
  'policy',
  'quorum',
  'minRuntimes',
  'voters',
  'router',
]);

function parsePathEntries(node: YamlNode | undefined, prefix: string, unsupported: string[]): PathEntry[] {
  return asArray(node).map((item, index) => {
    const map = asMap(item);
    for (const key of map.keys()) {
      if (!PATH_ENTRY_ALLOWED.has(key)) {
        unsupported.push(`${prefix}[${index}].${key}`);
      }
    }
    const path = asString(map.get('path')) ?? '';
    const requiredRaw = asString(map.get('required'));
    const schema = asString(map.get('schema'));
    return {
      path,
      required: requiredRaw === 'true',
      ...(schema !== undefined ? { schema } : {}),
    };
  });
}

function parseDependsOn(node: YamlNode | undefined): string[] {
  return asArray(node)
    .map((item) => asString(item) ?? '')
    .filter((v) => v.length > 0);
}

/** Accepts block lists or inline JSON-like arrays such as `["**"]`. */
function parseStringList(node: YamlNode | undefined): string[] | undefined {
  if (!node) return undefined;
  if (Array.isArray(node.value)) {
    return node.value
      .map((item) => asString(item) ?? '')
      .filter((v) => v.length > 0);
  }
  if (typeof node.value === 'string') {
    const raw = node.value.trim();
    if (raw.startsWith('[') && raw.endsWith(']')) {
      const inner = raw.slice(1, -1).trim();
      if (inner.length === 0) return [];
      return inner.split(',').map((part) => {
        const trimmed = part.trim();
        if (
          (trimmed.startsWith('"') && trimmed.endsWith('"')) ||
          (trimmed.startsWith("'") && trimmed.endsWith("'"))
        ) {
          return trimmed.slice(1, -1);
        }
        return trimmed;
      }).filter((v) => v.length > 0);
    }
    return [raw];
  }
  return undefined;
}

function parsePlanner(node: YamlNode | undefined, prefix: string, unsupported: string[]): PlannerModel | undefined {
  if (!node) return undefined;
  const map = asMap(node);
  if (map.size === 0 && typeof node.value !== 'object') {
    return undefined;
  }
  for (const key of map.keys()) {
    if (!PLANNER_ALLOWED.has(key)) {
      unsupported.push(`${prefix}.${key}`);
    }
  }
  const outputMode = asString(map.get('outputMode')) ?? 'plan-file';
  const maxTodos = asNumber(map.get('maxTodos'));
  return {
    outputMode,
    ...(maxTodos !== undefined ? { maxTodos } : {}),
  };
}

function parseLoopCheck(node: YamlNode | undefined, prefix: string, unsupported: string[]): LoopCheckModel | undefined {
  if (!node) return undefined;
  const map = asMap(node);
  for (const key of map.keys()) {
    if (!LOOP_CHECK_ALLOWED.has(key)) {
      unsupported.push(`${prefix}.${key}`);
    }
  }
  const path = asString(map.get('path'));
  if (path === undefined) return undefined;
  const schema = asString(map.get('schema'));
  return {
    path,
    ...(schema !== undefined ? { schema } : {}),
  };
}

function parseRouter(node: YamlNode | undefined, prefix: string, unsupported: string[]): RouterModel | undefined {
  if (!node) return undefined;
  const map = asMap(node);
  for (const key of map.keys()) {
    if (!ROUTER_ALLOWED.has(key)) {
      unsupported.push(`${prefix}.${key}`);
    }
  }
  const allowedTargets = parseStringList(map.get('allowedTargets')) ?? [];
  const defaultTarget = asString(map.get('defaultTarget')) ?? '';
  const onInvalid = asString(map.get('onInvalid'));
  const terminalOutcomes = parseStringList(map.get('terminalOutcomes'));
  return {
    allowedTargets,
    defaultTarget,
    ...(onInvalid !== undefined ? { onInvalid } : {}),
    ...(terminalOutcomes !== undefined ? { terminalOutcomes } : {}),
  };
}

function parseVoters(node: YamlNode | undefined, prefix: string, unsupported: string[]): ConsensusVoterModel[] | undefined {
  if (!node) return undefined;
  return asArray(node).map((item, index) => {
    const map = asMap(item);
    for (const key of map.keys()) {
      if (!VOTER_ALLOWED.has(key)) {
        unsupported.push(`${prefix}[${index}].${key}`);
      }
    }
    const instructions = asString(map.get('instructions'));
    return {
      id: asString(map.get('id')) ?? '',
      runtime: asString(map.get('runtime')),
      model: asString(map.get('model')),
      sessionStrategy: asString(map.get('sessionStrategy')),
      instructions: instructions !== undefined ? instructions.replace(/\n$/, '') : undefined,
    };
  });
}

function parseVerificationProfiles(node: YamlNode | undefined, unsupported: string[]): VerificationProfileModel[] | undefined {
  if (!node) return undefined;
  return asArray(node).map((item, index) => {
    const map = asMap(item);
    for (const key of map.keys()) {
      if (!VERIFICATION_PROFILE_ALLOWED.has(key)) {
        unsupported.push(`pipeline.verificationProfiles[${index}].${key}`);
      }
    }
    const steps = asArray(map.get('steps')).map((stepNode, stepIndex) => {
      const stepMap = asMap(stepNode);
      for (const key of stepMap.keys()) {
        if (!VERIFICATION_STEP_ALLOWED.has(key)) {
          unsupported.push(`pipeline.verificationProfiles[${index}].steps[${stepIndex}].${key}`);
        }
      }
      return {
        name: asString(stepMap.get('name')) ?? '',
        command: asString(stepMap.get('command')) ?? '',
        ...(asNumber(stepMap.get('timeout')) !== undefined ? { timeout: asNumber(stepMap.get('timeout')) } : {}),
      };
    });
    return {
      name: asString(map.get('name')) ?? '',
      steps,
    };
  });
}

function parsePlanInput(node: YamlNode | undefined, unsupported: string[]): PlanInputModel | undefined {
  if (!node) return undefined;
  const map = asMap(node);
  for (const key of map.keys()) {
    if (!PLAN_INPUT_ALLOWED.has(key)) {
      unsupported.push(`planInput.${key}`);
    }
  }
  const stage = asString(map.get('stage'));
  if (stage === undefined) return undefined;
  const requiredRaw = asString(map.get('required'));
  return {
    stage,
    required: requiredRaw === 'true',
  };
}

function parseTodo(node: YamlNode, index: number, unsupported: string[]): TodoModel {
  const map = asMap(node);
  for (const key of map.keys()) {
    if (!TODO_ALLOWED.has(key)) {
      unsupported.push(`todos[${index}].${key}`);
    }
  }
  const content = asString(map.get('content'));
  return {
    id: asString(map.get('id')) ?? '',
    stage: asString(map.get('stage')) ?? '',
    content: content !== undefined ? content.replace(/\n$/, '') : '',
    verification: asString(map.get('verification')) ?? '',
    status: asString(map.get('status')) ?? 'pending',
  };
}

function parseStage(node: YamlNode, index: number, unsupported: string[]): StageModel {
  const map = asMap(node);
  const id = asString(map.get('id')) ?? '';
  const typeRaw = asString(map.get('type'));
  const stagePrefix = `pipeline.stages[${index}]`;

  if (typeRaw && SUPERVISOR_TYPES.has(typeRaw)) {
    for (const key of map.keys()) {
      if (!SUPERVISOR_STAGE_ALLOWED.has(key)) {
        unsupported.push(`${stagePrefix}.${key}`);
      }
    }
    const requires = map.has('requires') ? parsePathEntries(map.get('requires'), `${stagePrefix}.requires`, unsupported) : undefined;
    const voters = map.has('voters') ? parseVoters(map.get('voters'), `${stagePrefix}.voters`, unsupported) : undefined;
    const router = map.has('router') ? parseRouter(map.get('router'), `${stagePrefix}.router`, unsupported) : undefined;
    return {
      id,
      kind: 'supervisor',
      type: typeRaw as SupervisorType,
      dependsOn: parseDependsOn(map.get('dependsOn')),
      ...(requires !== undefined ? { requires } : {}),
      profile: asString(map.get('profile')),
      workspaceMode: asString(map.get('workspaceMode')),
      question: asString(map.get('question')),
      changesTarget: asString(map.get('changesTarget')),
      policy: asString(map.get('policy')),
      quorum: asNumber(map.get('quorum')),
      minRuntimes: asNumber(map.get('minRuntimes')),
      ...(voters !== undefined ? { voters } : {}),
      ...(router !== undefined ? { router } : {}),
      unsupportedKeys: [],
    };
  }

  for (const key of map.keys()) {
    if (!ORDINARY_STAGE_ALLOWED.has(key)) {
      unsupported.push(`${stagePrefix}.${key}`);
    }
  }
  const instructions = asString(map.get('instructions'));
  const writeScopes = parseStringList(map.get('writeScopes'));
  const planner = map.has('planner') ? parsePlanner(map.get('planner'), `${stagePrefix}.planner`, unsupported) : undefined;
  const loopCheck = map.has('loopCheck') ? parseLoopCheck(map.get('loopCheck'), `${stagePrefix}.loopCheck`, unsupported) : undefined;
  const router = map.has('router') ? parseRouter(map.get('router'), `${stagePrefix}.router`, unsupported) : undefined;
  return {
    id,
    kind: 'ordinary',
    dependsOn: parseDependsOn(map.get('dependsOn')),
    runtime: asString(map.get('runtime')),
    model: asString(map.get('model')),
    sessionStrategy: asString(map.get('sessionStrategy')),
    instructions: instructions !== undefined ? instructions.replace(/\n$/, '') : undefined,
    produces: parsePathEntries(map.get('produces'), `${stagePrefix}.produces`, unsupported),
    requires: parsePathEntries(map.get('requires'), `${stagePrefix}.requires`, unsupported),
    ...(planner !== undefined ? { planner } : {}),
    planFrom: asString(map.get('planFrom')),
    workspaceMode: asString(map.get('workspaceMode')),
    ...(writeScopes !== undefined ? { writeScopes } : {}),
    agentGitAccess: asString(map.get('agentGitAccess')),
    loopBackTo: asString(map.get('loopBackTo')),
    ...(loopCheck !== undefined ? { loopCheck } : {}),
    onExhausted: asString(map.get('onExhausted')),
    ...(router !== undefined ? { router } : {}),
    unsupportedKeys: [],
  };
}

export function parseWorkflowFrontmatter(raw: string): ParseResult {
  const split = stripFrontmatter(raw);
  if (!split) {
    return { ok: false, error: new WorkflowFrontmatterError('File does not start with a "---" YAML frontmatter block') };
  }
  let root: Map<string, YamlNode>;
  try {
    const lines = tokenizeLines(split.frontmatter);
    if (lines.length === 0) {
      return { ok: false, error: new WorkflowFrontmatterError('Frontmatter block is empty') };
    }
    const [node] = parseMapping(lines, 0, lines[0]!.indent);
    root = asMap(node);
  } catch (error: unknown) {
    return {
      ok: false,
      error: new WorkflowFrontmatterError(
        `Failed to parse frontmatter: ${error instanceof Error ? error.message : 'unknown error'}`,
      ),
    };
  }

  const unsupported: string[] = [];
  for (const key of root.keys()) {
    if (!TOP_LEVEL_ALLOWED.has(key)) {
      unsupported.push(key);
    }
  }

  const defaultsMap = asMap(root.get('defaults'));
  for (const key of defaultsMap.keys()) {
    if (!DEFAULTS_ALLOWED.has(key)) {
      unsupported.push(`defaults.${key}`);
    }
  }

  const pipelineMap = asMap(root.get('pipeline'));
  for (const key of pipelineMap.keys()) {
    if (!PIPELINE_ALLOWED.has(key)) {
      unsupported.push(`pipeline.${key}`);
    }
  }

  const stageNodes = asArray(pipelineMap.get('stages'));
  const stages = stageNodes.map((node, index) => parseStage(node, index, unsupported));

  const todoNodes = asArray(root.get('todos'));
  const todos = todoNodes.map((node, index) => parseTodo(node, index, unsupported));

  const planInput = root.has('planInput') ? parsePlanInput(root.get('planInput'), unsupported) : undefined;
  const verificationProfiles = pipelineMap.has('verificationProfiles')
    ? parseVerificationProfiles(pipelineMap.get('verificationProfiles'), unsupported)
    : undefined;

  const model: WorkflowFrontmatterModel = {
    name: asString(root.get('name')),
    overview: asString(root.get('overview')),
    kind: asString(root.get('kind')),
    mode: asString(root.get('mode')),
    defaultsRuntime: asString(defaultsMap.get('runtime')),
    defaultsModel: asString(defaultsMap.get('model')),
    ...(planInput !== undefined ? { planInput } : {}),
    maxParallel: asNumber(pipelineMap.get('maxParallel')),
    maxReworkIterations: asNumber(pipelineMap.get('maxReworkIterations')),
    publishMode: asString(pipelineMap.get('publishMode')),
    ...(verificationProfiles !== undefined ? { verificationProfiles } : {}),
    stages,
    todos,
    unsupportedKeys: unsupported,
    body: split.body,
    sourceRaw: raw,
  };
  return { ok: true, model };
}

// ---------------------------------------------------------------------------
// Emission
// ---------------------------------------------------------------------------

interface EditableProjection {
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
  readonly stages: readonly StageModel[];
  readonly todos: readonly TodoModel[];
}

function editableProjection(model: WorkflowFrontmatterModel): EditableProjection {
  return {
    name: model.name,
    overview: model.overview,
    kind: model.kind,
    mode: model.mode,
    defaultsRuntime: model.defaultsRuntime,
    defaultsModel: model.defaultsModel,
    planInput: model.planInput,
    maxParallel: model.maxParallel,
    maxReworkIterations: model.maxReworkIterations,
    publishMode: model.publishMode,
    verificationProfiles: model.verificationProfiles,
    stages: model.stages,
    todos: model.todos,
  };
}

/** One todo referencing {{TASK}} on the first ordinary stage — satisfies `ralph workflow inspect`'s undocumented requirement without exposing todos in the UI. */
function synthesizeTodos(stages: readonly StageModel[]): TodoModel[] {
  const firstOrdinary = stages.find((stage): stage is OrdinaryStageModel => stage.kind === 'ordinary');
  if (!firstOrdinary) {
    return [];
  }
  return [
    {
      id: `${firstOrdinary.id}-todo`,
      stage: firstOrdinary.id,
      content: 'Complete {{TASK}}.',
      verification: 'Confirm the stage produced its expected output.',
      status: 'pending',
    },
  ];
}

function deepEqual(a: unknown, b: unknown): boolean {
  return JSON.stringify(a) === JSON.stringify(b);
}

const PLAIN_SAFE = /^[A-Za-z0-9][A-Za-z0-9._/-]*$/;
const RESERVED_WORDS = new Set(['true', 'false', 'null', 'yes', 'no', '~']);

function yamlScalar(value: string): string {
  if (value.length === 0) {
    return '""';
  }
  if (PLAIN_SAFE.test(value) && !RESERVED_WORDS.has(value.toLowerCase()) && !/^-?\d+(\.\d+)?$/.test(value)) {
    return value;
  }
  const escaped = value.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n');
  return `"${escaped}"`;
}

function indentBlockLiteral(text: string, indent: string): string {
  const withTrailingNewline = text.endsWith('\n') ? text : `${text}\n`;
  const lines = withTrailingNewline.replace(/\n$/, '').split('\n');
  return lines.map((line) => (line.length > 0 ? `${indent}${line}` : indent.length > 0 ? indent.trimEnd() : '')).join('\n');
}

function emitPathEntries(entries: readonly PathEntry[], indent: string): string[] {
  if (entries.length === 0) {
    return [];
  }
  const out: string[] = [];
  for (const entry of entries) {
    out.push(`${indent}- path: ${yamlScalar(entry.path)}`);
    out.push(`${indent}  required: ${entry.required ? 'true' : 'false'}`);
    if (entry.schema !== undefined) {
      out.push(`${indent}  schema: ${yamlScalar(entry.schema)}`);
    }
  }
  return out;
}

function emitStringListInline(values: readonly string[]): string {
  const parts = values.map((value) => {
    if (PLAIN_SAFE.test(value) && !RESERVED_WORDS.has(value.toLowerCase())) {
      return `"${value}"`;
    }
    return yamlScalar(value);
  });
  return `[${parts.join(', ')}]`;
}

function emitRouter(router: RouterModel, indent: string): string[] {
  const lines: string[] = [`${indent}router:`];
  lines.push(`${indent}  allowedTargets:`);
  for (const target of router.allowedTargets) {
    lines.push(`${indent}    - ${yamlScalar(target)}`);
  }
  lines.push(`${indent}  defaultTarget: ${yamlScalar(router.defaultTarget)}`);
  if (router.onInvalid !== undefined) {
    lines.push(`${indent}  onInvalid: ${yamlScalar(router.onInvalid)}`);
  }
  if (router.terminalOutcomes && router.terminalOutcomes.length > 0) {
    lines.push(`${indent}  terminalOutcomes:`);
    for (const outcome of router.terminalOutcomes) {
      lines.push(`${indent}    - ${yamlScalar(outcome)}`);
    }
  }
  return lines;
}

function emitVoters(voters: readonly ConsensusVoterModel[], indent: string): string[] {
  const lines: string[] = [`${indent}voters:`];
  for (const voter of voters) {
    lines.push(`${indent}  - id: ${yamlScalar(voter.id)}`);
    if (voter.runtime !== undefined) lines.push(`${indent}    runtime: ${yamlScalar(voter.runtime)}`);
    if (voter.model !== undefined) lines.push(`${indent}    model: ${yamlScalar(voter.model)}`);
    if (voter.sessionStrategy !== undefined) {
      lines.push(`${indent}    sessionStrategy: ${yamlScalar(voter.sessionStrategy)}`);
    }
    if (voter.instructions !== undefined) {
      lines.push(`${indent}    instructions: |`);
      lines.push(indentBlockLiteral(voter.instructions, `${indent}      `));
    }
  }
  return lines;
}

function emitStage(stage: StageModel, indent: string): string[] {
  const lines: string[] = [];
  lines.push(`${indent}- id: ${yamlScalar(stage.id)}`);
  if (stage.kind === 'supervisor') {
    lines.push(`${indent}  type: ${stage.type}`);
    if (stage.policy !== undefined) lines.push(`${indent}  policy: ${yamlScalar(stage.policy)}`);
    if (stage.quorum !== undefined) lines.push(`${indent}  quorum: ${stage.quorum}`);
    if (stage.minRuntimes !== undefined) lines.push(`${indent}  minRuntimes: ${stage.minRuntimes}`);
    if (stage.profile !== undefined) lines.push(`${indent}  profile: ${yamlScalar(stage.profile)}`);
    if (stage.workspaceMode !== undefined) {
      lines.push(`${indent}  workspaceMode: ${yamlScalar(stage.workspaceMode)}`);
    }
    if (stage.dependsOn.length > 0) {
      lines.push(`${indent}  dependsOn:`);
      for (const dep of stage.dependsOn) {
        lines.push(`${indent}    - ${yamlScalar(dep)}`);
      }
    }
    if (stage.requires && stage.requires.length > 0) {
      lines.push(`${indent}  requires:`);
      lines.push(...emitPathEntries(stage.requires, `${indent}    `));
    }
    if (stage.question !== undefined) {
      lines.push(`${indent}  question: ${yamlScalar(stage.question)}`);
    }
    if (stage.changesTarget !== undefined) {
      lines.push(`${indent}  changesTarget: ${yamlScalar(stage.changesTarget)}`);
    }
    if (stage.voters && stage.voters.length > 0) {
      lines.push(...emitVoters(stage.voters, `${indent}  `));
    }
    if (stage.router) {
      lines.push(...emitRouter(stage.router, `${indent}  `));
    }
    return lines;
  }
  if (stage.instructions !== undefined) {
    lines.push(`${indent}  instructions: |`);
    lines.push(indentBlockLiteral(stage.instructions, `${indent}    `));
  }
  if (stage.dependsOn.length > 0) {
    lines.push(`${indent}  dependsOn:`);
    for (const dep of stage.dependsOn) {
      lines.push(`${indent}    - ${yamlScalar(dep)}`);
    }
  }
  if (stage.runtime !== undefined) {
    lines.push(`${indent}  runtime: ${yamlScalar(stage.runtime)}`);
  }
  if (stage.model !== undefined) {
    lines.push(`${indent}  model: ${yamlScalar(stage.model)}`);
  }
  if (stage.sessionStrategy !== undefined) {
    lines.push(`${indent}  sessionStrategy: ${yamlScalar(stage.sessionStrategy)}`);
  }
  if (stage.requires.length > 0) {
    lines.push(`${indent}  requires:`);
    lines.push(...emitPathEntries(stage.requires, `${indent}    `));
  }
  if (stage.planner) {
    lines.push(`${indent}  planner:`);
    lines.push(`${indent}    outputMode: ${yamlScalar(stage.planner.outputMode)}`);
    if (stage.planner.maxTodos !== undefined) {
      lines.push(`${indent}    maxTodos: ${stage.planner.maxTodos}`);
    }
  }
  if (stage.planFrom !== undefined) {
    lines.push(`${indent}  planFrom: ${yamlScalar(stage.planFrom)}`);
  }
  if (stage.workspaceMode !== undefined) {
    lines.push(`${indent}  workspaceMode: ${yamlScalar(stage.workspaceMode)}`);
  }
  if (stage.writeScopes !== undefined) {
    lines.push(`${indent}  writeScopes: ${emitStringListInline(stage.writeScopes)}`);
  }
  if (stage.agentGitAccess !== undefined) {
    lines.push(`${indent}  agentGitAccess: ${yamlScalar(stage.agentGitAccess)}`);
  }
  if (stage.produces.length > 0) {
    lines.push(`${indent}  produces:`);
    lines.push(...emitPathEntries(stage.produces, `${indent}    `));
  }
  if (stage.loopBackTo !== undefined) {
    lines.push(`${indent}  loopBackTo: ${yamlScalar(stage.loopBackTo)}`);
  }
  if (stage.loopCheck) {
    lines.push(`${indent}  loopCheck:`);
    lines.push(`${indent}    path: ${yamlScalar(stage.loopCheck.path)}`);
    if (stage.loopCheck.schema !== undefined) {
      lines.push(`${indent}    schema: ${yamlScalar(stage.loopCheck.schema)}`);
    }
  }
  if (stage.onExhausted !== undefined) {
    lines.push(`${indent}  onExhausted: ${yamlScalar(stage.onExhausted)}`);
  }
  if (stage.router) {
    lines.push(...emitRouter(stage.router, `${indent}  `));
  }
  return lines;
}

function emitVerificationProfiles(profiles: readonly VerificationProfileModel[], indent: string): string[] {
  const lines: string[] = [`${indent}verificationProfiles:`];
  for (const profile of profiles) {
    lines.push(`${indent}  - name: ${yamlScalar(profile.name)}`);
    lines.push(`${indent}    steps:`);
    for (const step of profile.steps) {
      lines.push(`${indent}      - name: ${yamlScalar(step.name)}`);
      lines.push(`${indent}        command: ${yamlScalar(step.command)}`);
      if (step.timeout !== undefined) {
        lines.push(`${indent}        timeout: ${step.timeout}`);
      }
    }
  }
  return lines;
}

/**
 * Regenerates frontmatter text for the structured-edit subset only. Throws
 * `WorkflowFrontmatterError` if the model carries unsupportedKeys — such a
 * file must be edited as raw text, never through structured emission, since
 * this function has no way to preserve content it did not parse.
 */
export function emitWorkflowFrontmatter(model: WorkflowFrontmatterModel): string {
  const original = parseWorkflowFrontmatter(model.sourceRaw);
  if (original.ok && deepEqual(editableProjection(original.model), editableProjection(model))) {
    return model.sourceRaw;
  }
  if (model.unsupportedKeys.length > 0) {
    throw new WorkflowFrontmatterError(
      `Cannot emit structured frontmatter for a model with unsupported keys: ${model.unsupportedKeys.join(', ')}`,
    );
  }

  const lines: string[] = ['---'];
  if (model.name !== undefined) lines.push(`name: ${yamlScalar(model.name)}`);
  if (model.overview !== undefined) lines.push(`overview: ${yamlScalar(model.overview)}`);
  lines.push(`kind: ${model.kind ?? 'workflow'}`);
  if (model.mode !== undefined) lines.push(`mode: ${model.mode}`);
  if (model.defaultsRuntime !== undefined || model.defaultsModel !== undefined) {
    lines.push('defaults:');
    if (model.defaultsRuntime !== undefined) lines.push(`  runtime: ${yamlScalar(model.defaultsRuntime)}`);
    if (model.defaultsModel !== undefined) lines.push(`  model: ${yamlScalar(model.defaultsModel)}`);
  }
  if (model.planInput) {
    lines.push('planInput:');
    lines.push(`  stage: ${yamlScalar(model.planInput.stage)}`);
    lines.push(`  required: ${model.planInput.required ? 'true' : 'false'}`);
  }
  lines.push('pipeline:');
  if (model.maxParallel !== undefined) lines.push(`  maxParallel: ${model.maxParallel}`);
  if (model.maxReworkIterations !== undefined) lines.push(`  maxReworkIterations: ${model.maxReworkIterations}`);
  if (model.publishMode !== undefined) lines.push(`  publishMode: ${yamlScalar(model.publishMode)}`);
  if (model.verificationProfiles && model.verificationProfiles.length > 0) {
    lines.push(...emitVerificationProfiles(model.verificationProfiles, '  '));
  }
  lines.push('  stages:');
  for (const stage of model.stages) {
    lines.push(...emitStage(stage, '    '));
  }
  const todos = model.todos.length > 0 ? model.todos : synthesizeTodos(model.stages);
  if (todos.length > 0) {
    lines.push('todos:');
    for (const todo of todos) {
      lines.push(`  - id: ${yamlScalar(todo.id)}`);
      lines.push(`    stage: ${yamlScalar(todo.stage)}`);
      lines.push('    content: |');
      lines.push(indentBlockLiteral(todo.content, '      '));
      lines.push(`    verification: ${yamlScalar(todo.verification)}`);
      lines.push(`    status: ${yamlScalar(todo.status)}`);
    }
  }
  lines.push('---');

  const body = model.body.startsWith('\n') || model.body.length === 0 ? model.body : `\n${model.body}`;
  return `${lines.join('\n')}${body}`;
}
