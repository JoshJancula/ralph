/**
 * Ralph OpenCode runtime hooks (telemetry, optional bash rewrite, optional output compaction).
 *
 * Loaded via temp OPENCODE_CONFIG plugin array. Requires RALPH_BASH_LIB_DIR or
 * WORKSPACE/.ralph/bash-lib for Python helpers.
 *
 * Headless `opencode run --agent build` (OpenCode 1.14.35, 2026-06-04): plugin injects
 * but `tool.execute.before` / `tool.execute.after` are unproven on the Ralph plan path.
 * Ralph records native_hooks_reason=plugin_injected_mutation_unproven; use MCP proxy
 * compaction for reliable token reduction. See SPIKE-output-mutation.md in this directory.
 */

function truthy(value) {
  if (value == null || value === "") return false;
  const normalized = String(value).trim().toLowerCase();
  return normalized === "1" || normalized === "true" || normalized === "yes" || normalized === "on";
}

function hookTelemetryEnabled() {
  const hookTelemetry = process.env.RALPH_HOOK_TELEMETRY;
  if (hookTelemetry === "0" || hookTelemetry === "false" || hookTelemetry === "no" || hookTelemetry === "off") {
    return false;
  }
  if (truthy(hookTelemetry)) return true;
  return true;
}

function bashLibDir(directory) {
  if (process.env.RALPH_BASH_LIB_DIR) {
    return process.env.RALPH_BASH_LIB_DIR;
  }
  const workspace = process.env.WORKSPACE || directory || "";
  if (workspace) {
    return `${workspace}/.ralph/bash-lib`;
  }
  return "";
}

function pythonDir(directory) {
  if (process.env.RALPH_PY_DIR) {
    return process.env.RALPH_PY_DIR;
  }
  const workspace = process.env.WORKSPACE || directory || "";
  if (workspace) {
    return `${workspace}/.ralph/python`;
  }
  return "";
}

async function runPythonJson(script, payload) {
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

async function rewriteCommand(libDir, command) {
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

function byteCount(text) {
  return new TextEncoder().encode(text || "").length;
}

async function appendTelemetry({ workspace, planKey, command, originalBytes, compactedBytes, compactionSkipped }) {
  if (!hookTelemetryEnabled()) return;
  const logPath = process.env.RALPH_BASH_TELEMETRY_LOG;
  if (!logPath) return;
  const commandHash = await Bun.crypto.digest("SHA-256", new TextEncoder().encode(command || "")).then((buf) =>
    Array.from(new Uint8Array(buf))
      .map((b) => b.toString(16).padStart(2, "0"))
      .join(""),
  );
  const record = {
    timestamp: new Date().toISOString(),
    workspace: workspace || "",
    planKey: planKey || "opencode-hook",
    runtime: "opencode",
    commandHash,
    originalBytes,
    compactedBytes: compactedBytes ?? originalBytes,
    compactionSkipped: compactionSkipped !== false,
  };
  await Bun.write(logPath, `${JSON.stringify(record)}\n`, { append: true }).catch(() => {});
}

function nativeResultCompactEnabled() {
  const nativeResultCompact = process.env.RALPH_NATIVE_RESULT_COMPACT;
  if (nativeResultCompact === "0" || nativeResultCompact === "false") return false;
  if (truthy(nativeResultCompact)) return true;
  return truthy(process.env.RALPH_BASH_COMPACT) || truthy(process.env.RALPH_PROXY_SHELL_COMPACT);
}

const EXPLORATION_TOOLS = new Set(["read", "grep", "glob", "search", "bash"]);

function envelopePreview(compactedText) {
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

function applyCompactedCarriers(output, compactedText, tool) {
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

async function runBashJson(script, payload) {
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
  libDir,
  tool,
  text,
  workspace,
  planKey,
  toolArgs,
  title,
  path,
) {
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

export const RalphRuntimeHooks = async ({ directory }) => {
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
            const footer =
              `[ralph: bash output compacted; set RALPH_BASH_COMPACT=0 to disable; plan ${planKey}]`;
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
