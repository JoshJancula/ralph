import { Plugin } from "@opencode-ai/plugin";

function truthy(value: string | undefined | null): boolean {
  if (value == null || value === "") return false;
  const normalized = String(value).trim().toLowerCase();
  return normalized === "1" || normalized === "true" || normalized === "yes" || normalized === "on";
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

const EXPLORATION_TOOLS = new Set(["read", "grep", "glob", "search"]);

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
): Promise<string | null> {
  const script = `${libDir}/native-hook/native-result-compact-cli.sh`;
  const compacted = await runBashJson(script, {
    tool_name: tool,
    text,
    workspace,
    plan_key: planKey,
  });
  if (compacted?.applied && typeof compacted.compacted === "string") {
    return compacted.compacted;
  }
  return null;
}

export const RalphRuntimeHooks: Plugin = async ({ directory }) => {
  const libDir = bashLibDir(directory);

  return {
    "tool.execute.before": async (input, output) => {
      if (input.tool !== "bash") return;
      if (!truthy(process.env.RALPH_BASH_REWRITE)) return;
      if (!libDir) return;
      const command = output.args?.command;
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

        if (truthy(process.env.RALPH_BASH_COMPACT) && libDir) {
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
            output.output = compactedText;
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
      );
      if (compactedText) {
        output.output = compactedText;
      }
    },
  };
};
