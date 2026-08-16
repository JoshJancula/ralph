# GENERATED from bundle/.opencode/plugins/ralph-runtime-hooks.ts by scripts/sync-plugin-assets.sh - edit the canonical file
import type { Plugin } from "@opencode-ai/plugin";

function truthy(value: string | undefined | null): boolean {
  if (value == null || value === "") return false;
  const normalized = String(value).trim().toLowerCase();
  return normalized === "1" || normalized === "true" || normalized === "yes" || normalized === "on";
}

function ralphModeOff(): boolean {
  switch ((process.env.RALPH_MODE || "no").trim().toLowerCase()) {
    case "no":
    case "off":
    case "false":
    case "0":
      return true;
    default:
      return false;
  }
}

function isExecutionTool(tool: string): boolean {
  const normalized = String(tool || "").trim().toLowerCase();
  return normalized === "bash" || normalized === "shell" || normalized === "command_execution";
}

async function runProcess(
  argv: string[],
  options: { stdin?: string; env?: NodeJS.ProcessEnv } = {},
): Promise<{ stdout: string; exitCode: number }> {
  const env = options.env || process.env;
  const bun = (globalThis as { Bun?: { spawn: Function } }).Bun;
  if (bun && typeof bun.spawn === "function") {
    const proc = bun.spawn(argv, {
      stdin: options.stdin != null ? new Blob([options.stdin]) : "ignore",
      stdout: "pipe",
      stderr: "pipe",
      env,
    });
    const [stdout, exitCode] = await Promise.all([
      new Response(proc.stdout).text(),
      proc.exited,
    ]);
    return { stdout, exitCode: Number(exitCode) };
  }
  const { spawn } = await import("node:child_process");
  return await new Promise((resolve, reject) => {
    const child = spawn(argv[0], argv.slice(1), {
      env,
      stdio: ["pipe", "pipe", "pipe"],
    });
    const chunks: Buffer[] = [];
    child.stdout.on("data", (chunk: Buffer) => chunks.push(chunk));
    child.stderr.resume();
    child.on("error", reject);
    child.on("close", (code) => {
      resolve({ stdout: Buffer.concat(chunks).toString("utf8"), exitCode: code ?? 1 });
    });
    if (options.stdin != null) {
      child.stdin.end(options.stdin);
    } else {
      child.stdin.end();
    }
  });
}

async function evaluateKillswitch(
  libDir: string,
  tool: string,
  argumentsText: string,
): Promise<{ decision: string; applied: boolean }> {
  if (ralphModeOff()) {
    await recordKillswitch(tool, "skip", false);
    return { decision: "skip", applied: false };
  }
  if (!isExecutionTool(tool)) {
    await recordKillswitch(tool, "nudge", false);
    return { decision: "nudge", applied: false };
  }
  if (!libDir) {
    return { decision: "allow", applied: false };
  }
  const core = `${libDir}/killswitch/killswitch-core.sh`;
  const event = JSON.stringify({
    schemaVersion: 1,
    source: "native-hook",
    runtime: "opencode",
    tool,
    action: "execute",
    effect: "write",
    resource: "",
    arguments: argumentsText || "",
  });
  const script = [
    'set -uo pipefail',
    'core="$1"',
    'event="$2"',
    'record_path="${RALPH_KILLSWITCH_HOOK_RECORD:-}"',
    'tool="$3"',
    '[[ -f "$core" ]] || exit 0',
    '# shellcheck source=/dev/null',
    'source "$core"',
    'killswitch_evaluate "$event" >/dev/null',
    'decision="${KILLSWITCH_DECISION:-allow}"',
    'applied=false',
    'if [[ "$decision" == "fatal" ]]; then applied=true; fi',
    'if [[ -n "$record_path" ]] && command -v jq >/dev/null 2>&1; then',
    '  jq -nc --arg runtime opencode --arg tool "$tool" --arg decision "$decision" --argjson applied "$applied" --arg source native-hook \'{runtime:$runtime,tool:$tool,decision:$decision,applied:$applied,source:$source}\' >>"$record_path" 2>/dev/null || true',
    'fi',
    'printf "%s\\n" "$decision"',
    'if [[ "$decision" == "fatal" ]]; then',
    '  killswitch_apply_decision fatal',
    'fi',
  ].join("\n");
  const result = await runProcess(["bash", "-c", script, "ralph-opencode-killswitch", core, event, tool], {
    env: process.env,
  });
  const decision = result.stdout.trim().split("\n").pop() || "allow";
  return { decision, applied: decision === "fatal" };
}

async function recordKillswitch(tool: string, decision: string, applied: boolean): Promise<void> {
  const recordPath = process.env.RALPH_KILLSWITCH_HOOK_RECORD;
  if (!recordPath) return;
  const line =
    JSON.stringify({
      runtime: "opencode",
      tool,
      decision,
      applied,
      source: "native-hook",
    }) + "\n";
  const bun = (globalThis as { Bun?: { write: Function } }).Bun;
  if (bun && typeof bun.write === "function") {
    await bun.write(recordPath, line, { append: true }).catch(() => {});
    return;
  }
  const { appendFile } = await import("node:fs/promises");
  await appendFile(recordPath, line).catch(() => {});
}

function hookTelemetryEnabled(): boolean {
  const hookTelemetry = process.env.RALPH_HOOK_TELEMETRY;
  if (hookTelemetry === "0" || hookTelemetry === "false" || hookTelemetry === "no" || hookTelemetry === "off") {
    return false;
  }
  if (truthy(hookTelemetry)) return true;
  return true;
}

function bashLibDir(directory: string): string {
  if (process.env.RALPH_BASH_LIB_DIR) {
    return process.env.RALPH_BASH_LIB_DIR;
  }
  const workspace = process.env.WORKSPACE || directory || "";
  if (workspace) {
    return `${workspace}/.ralph/bash-lib`;
  }
  const ralphHome = process.env.RALPH_HOME || "";
  if (ralphHome) {
    return `${ralphHome}/bundle/.ralph/bash-lib`;
  }
  return "";
}

async function runPythonJson(script: string, payload: any): Promise<any> {
  const proc = Bun.spawn(["python3", script, "compact"], {
    stdin: new Blob([JSON.stringify(payload)]),
    stdout: "pipe",
    stderr: "pipe",
    env: process.env,
  });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  if (exitCode !== 0) {
    return null;
  }
  const line = stdout.trim().split("\n").pop();
  if (!line) return null;
  try {
    return JSON.parse(line);
  } catch {
    return null;
  }
}

async function rewriteCommand(libDir: string, command: string): Promise<string> {
  const script = `${libDir}/shell-command-rewrite.py`;
  const proc = Bun.spawn(["python3", script, "rewrite"], {
    stdin: new Blob([JSON.stringify({ command })]),
    stdout: "pipe",
    stderr: "pipe",
    env: process.env,
  });
  const stdout = await new Response(proc.stdout).text();
  const exitCode = await proc.exited;
  if (exitCode !== 0) return command;
  const line = stdout.trim().split("\n").pop();
  if (!line) return command;
  try {
    const parsed = JSON.parse(line);
    if (parsed.rewritten && parsed.rewritten_command) {
      return parsed.rewritten_command;
    }
  } catch {
    /* fail open */
  }
  return command;
}

function byteCount(text: string | undefined | null): number {
  return new TextEncoder().encode(text || "").length;
}

async function appendTelemetry(options: {
  workspace?: string;
  planKey?: string;
  command?: string;
  originalBytes: number;
  compactedBytes: number;
  compactionSkipped: boolean;
}): Promise<void> {
  if (!hookTelemetryEnabled()) return;
  const logPath = process.env.RALPH_BASH_TELEMETRY_LOG;
  if (!logPath) return;
  const commandHash = await Bun.crypto
    .digest("SHA-256", new TextEncoder().encode(options.command || ""))
    .then((buf) => Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join(""));
  const record = {
    timestamp: new Date().toISOString(),
    workspace: options.workspace || "",
    planKey: options.planKey || "opencode-hook",
    runtime: "opencode",
    commandHash,
    originalBytes: options.originalBytes,
    compactedBytes: options.compactedBytes ?? options.originalBytes,
    compactionSkipped: options.compactionSkipped !== false,
  };
  await Bun.write(logPath, `${JSON.stringify(record)}\n`, { append: true }).catch(() => {});
}

function nativeResultCompactEnabled(): boolean {
  const nativeResultCompact = process.env.RALPH_NATIVE_RESULT_COMPACT;
  if (nativeResultCompact === "0" || nativeResultCompact === "false") return false;
  if (truthy(nativeResultCompact)) return true;
  return truthy(process.env.RALPH_BASH_COMPACT) || truthy(process.env.RALPH_PROXY_SHELL_COMPACT);
}

const EXPLORATION_TOOLS = new Set(["read", "grep", "glob", "search", "bash"]);

function envelopePreview(compactedText: string): string {
  try {
    const envelope = JSON.parse(compactedText);
    if (typeof envelope.preview === "string" && envelope.preview) {
      return envelope.preview;
    }
  } catch {
    /* not JSON envelope */
  }
  return compactedText;
}

function applyCompactedCarriers(
  output: { title: string; output: string; metadata: any },
  compactedText: string,
  tool: string,
): void {
  output.output = compactedText;
  const preview = envelopePreview(compactedText);
  const titleSeed = typeof output.title === "string" && output.title ? output.title : tool;
  output.title = preview.length > 120 ? `${preview.slice(0, 120)}...` : preview || titleSeed;
  const baseMeta =
    output.metadata != null && typeof output.metadata === "object" && !Array.isArray(output.metadata)
      ? { ...output.metadata }
      : {};
  baseMeta.output = compactedText;
  baseMeta.ralph_compacted = true;
  output.metadata = baseMeta;
}

async function runBashJson(script: string, payload: any): Promise<any> {
  const proc = Bun.spawn(["bash", script], {
    stdin: new Blob([JSON.stringify(payload)]),
    stdout: "pipe",
    stderr: "pipe",
    env: process.env,
  });
  const [stdout, exitCode] = await Promise.all([new Response(proc.stdout).text(), proc.exited]);
  if (exitCode !== 0) return null;
  const line = stdout.trim().split("\n").pop();
  if (!line) return null;
  try {
    return JSON.parse(line);
  } catch {
    return null;
  }
}

async function compactExplorationOutput(
  libDir: string,
  tool: string,
  text: string,
  workspace: string,
  planKey: string,
  toolArgs: Record<string, unknown> | undefined,
  title: string,
  path: string,
): Promise<string | null> {
  const script = `${libDir}/native-hook/native-result-compact-cli.sh`;
  const compacted = await runBashJson(script, {
    tool_name: tool,
    text,
    workspace,
    plan_key: planKey,
    tool_args: toolArgs ?? {},
    title,
    path,
  });
  if (compacted?.applied && typeof compacted.compacted === "string") {
    return compacted.compacted;
  }
  return null;
}

export const RalphRuntimeHooks: Plugin = async ({ directory }) => {
  const libDir = bashLibDir(directory);

  return {
    "permission.ask": async (input, output) => {
      const tool = String(input?.type || input?.metadata?.tool || "");
      const argumentsText = String(
        input?.pattern || input?.title || input?.metadata?.command || "",
      );
      const result = await evaluateKillswitch(libDir, tool, argumentsText);
      if (result.decision === "fatal") {
        output.status = "deny";
      }
    },

    "tool.execute.before": async (input, output) => {
      const command = typeof output.args?.command === "string" ? output.args.command : "";
      const result = await evaluateKillswitch(libDir, input.tool, command);
      if (result.decision === "fatal") {
        throw new Error("Ralph killswitch denied this tool");
      }
      if (input.tool !== "bash") return;
      if (!truthy(process.env.RALPH_BASH_REWRITE)) return;
      if (!libDir) return;
      if (typeof command !== "string" || !command) return;
      output.args.command = await rewriteCommand(libDir, command);
    },

    "tool.execute.after": async (input, output) => {
      const workspace = process.env.WORKSPACE || directory || "";
      const planKey = process.env.RALPH_PLAN_KEY || process.env.RALPH_ARTIFACT_NS || "opencode-hook";

      if (input.tool === "bash") {
        const command = typeof input.args?.command === "string" ? input.args.command : "";
        const originalText = typeof output.output === "string" ? output.output : "";
        const originalBytes = byteCount(originalText);

        let compactedText = originalText;
        let compactionSkipped = true;

        if (nativeResultCompactEnabled() && libDir && originalText) {
          const nativeCompacted = await compactExplorationOutput(
            libDir,
            "bash",
            originalText,
            workspace,
            planKey,
            input.args,
            typeof output.title === "string" ? output.title : "",
            "",
          );
          if (nativeCompacted) {
            applyCompactedCarriers(output, nativeCompacted, input.tool);
            compactedText = nativeCompacted;
            compactionSkipped = false;
          }
        }

        if (compactionSkipped && truthy(process.env.RALPH_BASH_COMPACT) && libDir) {
          const compactScript = `${libDir}/shell-output-compact.py`;
          const compacted = await runPythonJson(compactScript, {
            command,
            stdout: originalText,
            stderr: "",
            exit_status: 0,
          });
          if (compacted?.status === "compacted") {
            const parts = [compacted.stdout || "", compacted.stderr || ""].filter(Boolean);
            compactedText = parts.join("\n");
            const footer = `[ralph: bash output compacted; set RALPH_BASH_COMPACT=0 to disable; plan ${planKey}]`;
            if (compactedText && !compactedText.endsWith("\n")) {
              compactedText += "\n";
            }
            compactedText += footer;
            applyCompactedCarriers(output, compactedText, input.tool);
            compactionSkipped = false;
          }
        }

        await appendTelemetry({
          workspace,
          planKey,
          command,
          originalBytes,
          compactedBytes: byteCount(compactedText),
          compactionSkipped,
        });
        return;
      }

      if (!EXPLORATION_TOOLS.has(input.tool)) return;
      if (!nativeResultCompactEnabled() || !libDir) return;
      const originalText = typeof output.output === "string" ? output.output : "";
      if (!originalText) return;
      const compactedText = await compactExplorationOutput(
        libDir,
        input.tool,
        originalText,
        workspace,
        planKey,
        input.args,
        typeof output.title === "string" ? output.title : "",
        typeof input.args?.path === "string" ? input.args.path : "",
      );
      if (compactedText) {
        applyCompactedCarriers(output, compactedText, input.tool);
      }
    },
  };
};
