const state = {
  root: "docs",
  path: "",
  selectedFile: null,
  logOffset: 0,
  autoRefreshTimer: null,
  markdownView: true,
  selectedFileIsMarkdown: false,
  currentRawContent: "",
  selectedFileIsAgentConfig: false,
  availableSkills: [],
  userSelectedFile: false,
};

let markdownRenderer = null;

function ensureMarkdownRenderer() {
  if (markdownRenderer) {
    return markdownRenderer;
  }
  if (typeof markdownit !== "undefined") {
    const md = markdownit({
      html: true,
      linkify: true,
      typographer: true,
    });
    markdownRenderer = (content) => md.render(content);
    return markdownRenderer;
  }
  if (typeof marked !== "undefined") {
    markdownRenderer = (content) =>
      marked.parse(content, {
        gfm: true,
        headerIds: false,
        mangle: false,
      });
    return markdownRenderer;
  }
  return null;
}

const elements = {
  rootTabs: Array.from(document.querySelectorAll(".root-tab")),
  refreshButton: document.getElementById("refresh-button"),
  autoRefresh: document.getElementById("auto-refresh"),
  upButton: document.getElementById("up-button"),
  currentPath: document.getElementById("current-path"),
  entryList: document.getElementById("entry-list"),
  filePath: document.getElementById("file-path"),
  fileContent: document.getElementById("file-content"),
  status: document.getElementById("status"),
  markdownToggle: document.getElementById("markdown-toggle"),
  workflowPanel: document.getElementById("workflow-editor-panel"),
  workflowTextarea: document.getElementById("workflow-textarea"),
  skillsSection: document.querySelector(".skills-section"),
  skillList: document.getElementById("skill-list"),
  agentSkillSelect: document.getElementById("agent-skill-select"),
  agentAddSkillButton: document.getElementById("agent-add-skill"),
  agentConfigPanel: document.getElementById("agent-config-panel"),
  agentConfigTextarea: document.getElementById("agent-config-textarea"),
  agentConfigSaveButton: document.getElementById("agent-config-save"),
  workflowType: document.getElementById("workflow-type"),
};

const AGENT_ROOT_KEYS = ["cursor_agents", "claude_agents", "codex_agents"];
const SKILL_ROOT_MAP = {
  cursor_agents: "cursor_skills",
  claude_agents: "claude_skills",
  codex_agents: "codex_skills",
};

function setStatus(message, isError = false) {
  elements.status.textContent = message;
  elements.status.dataset.error = isError ? "true" : "false";
}

function isMarkdownPath(path) {
  return typeof path === "string" && path.toLowerCase().endsWith(".md");
}

function updateMarkdownToggle() {
  if (!elements.markdownToggle) {
    return;
  }
  const visible = state.selectedFileIsMarkdown;
  elements.markdownToggle.hidden = !visible;
  if (!visible) {
    return;
  }
  elements.markdownToggle.textContent = state.markdownView ? "Show source" : "Show rendered";
}

function renderMermaidDiagrams(container) {
  if (typeof mermaid === "undefined") {
    return;
  }
  const rawCodeBlocks = Array.from(
    container.querySelectorAll("pre code.language-mermaid")
  );
  if (!rawCodeBlocks.length) {
    return;
  }
  rawCodeBlocks.forEach((code) => {
    const diagram = document.createElement("div");
    diagram.className = "mermaid";
    diagram.textContent = code.textContent || "";
    const pre = code.parentElement;
    if (pre && pre.parentElement) {
      pre.parentElement.replaceChild(diagram, pre);
    } else if (code.parentElement) {
      code.parentElement.replaceChild(diagram, code);
    }
  });
  try {
    mermaid.init(undefined, Array.from(container.querySelectorAll(".mermaid")));
  } catch (error) {
    console.error("Mermaid render failed", error);
    setStatus(`Mermaid render error: ${error.message}`, true);
  }
}

function renderViewerContent() {
  const content = state.currentRawContent || "";
  const renderer = ensureMarkdownRenderer();
  if (state.selectedFileIsMarkdown && state.markdownView && renderer) {
    try {
      const html = renderer(content);
      elements.fileContent.innerHTML = html;
      elements.fileContent.classList.add("rendered-markdown", "markdown-content");
      elements.fileContent.classList.remove("raw-markdown");
      renderMermaidDiagrams(elements.fileContent);
      return;
    } catch (error) {
      console.error("Markdown render failed", error);
      setStatus(`Markdown render error: ${error.message}`, true);
    }
  }
  elements.fileContent.textContent = content;
  elements.fileContent.classList.remove("rendered-markdown");
  if (state.selectedFileIsMarkdown) {
    elements.fileContent.classList.add("raw-markdown");
  } else {
    elements.fileContent.classList.remove("raw-markdown");
  }
}

function isWorkflowFile(path) {
  return typeof path === "string" && path.toLowerCase().endsWith(".orch.json");
}

function getWorkflowTypeText(path) {
  if (!path) {
    return "";
  }
  if (path.toLowerCase().endsWith(".orch.json")) {
    return "Orchestration workflow (multi-stage)";
  }
  if (path.toLowerCase().endsWith(".plan.md")) {
    return "Worker plan (single-agent)";
  }
  if (path.toLowerCase().endsWith(".md")) {
    return "Markdown document";
  }
  return "";
}

function updateWorkflowEditor() {
  if (elements.newWorkflowButton) {
    elements.newWorkflowButton.hidden = state.root !== "plans";
  }
  const showEditor =
    state.root === "plans" &&
    state.selectedFileIsWorkflow &&
    elements.workflowPanel;
  if (elements.workflowPanel) {
    elements.workflowPanel.hidden = !showEditor;
  }
  if (elements.workflowSaveButton) {
    elements.workflowSaveButton.disabled = !showEditor;
  }
  if (elements.workflowTextarea && showEditor) {
    elements.workflowTextarea.value = state.currentRawContent;
  }
}

async function putFile(root, path, content) {
  const response = await fetch("/api/file", {
    method: "PUT",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    cache: "no-store",
    body: JSON.stringify({ root, path, content }),
  });
  const payload = await response.json();
  if (!response.ok) {
    throw new Error(payload.error || "Failed to save file");
  }
  return payload;
}

function isAgentConfigFile(path) {
  return typeof path === "string" && path.toLowerCase().endsWith("config.json");
}

function updateAgentConfigPanel() {
  const showEditor =
    state.root && AGENT_ROOT_KEYS.includes(state.root) && state.selectedFileIsAgentConfig;
  if (elements.agentConfigPanel) {
    elements.agentConfigPanel.hidden = !showEditor;
  }
  if (elements.agentConfigTextarea && showEditor) {
    elements.agentConfigTextarea.value = state.currentRawContent;
  }
  if (elements.agentConfigSaveButton) {
    elements.agentConfigSaveButton.disabled = !showEditor;
  }
  if (elements.agentSkillSelect) {
    elements.agentSkillSelect.disabled = !showEditor || state.availableSkills.length === 0;
  }
  if (elements.agentAddSkillButton) {
    elements.agentAddSkillButton.disabled =
      !showEditor || state.availableSkills.length === 0 || !elements.agentSkillSelect?.value;
  }
}

function renderSkillList(entries) {
  if (!elements.skillList) {
    return;
  }
  elements.skillList.innerHTML = "";
  if (!entries.length) {
    if (elements.skillsSection) {
      elements.skillsSection.hidden = true;
    }
    return;
  }
  if (elements.skillsSection) {
    elements.skillsSection.hidden = false;
  }
  entries.forEach((entry) => {
    const item = document.createElement("li");
    item.textContent = entry.type === "directory" ? `${entry.path}/` : entry.path;
    elements.skillList.append(item);
  });
}

function renderSkillOptions() {
  if (!elements.agentSkillSelect) {
    return;
  }
  elements.agentSkillSelect.innerHTML = '<option value="">Pick a skill</option>';
  state.availableSkills.forEach((skill) => {
    const option = document.createElement("option");
    option.value = skill;
    option.textContent = skill;
    elements.agentSkillSelect?.append(option);
  });
  const hasOptions = state.availableSkills.length > 0;
  elements.agentSkillSelect.disabled = !hasOptions;
  if (elements.agentAddSkillButton) {
    elements.agentAddSkillButton.disabled = !hasOptions;
  }
  updateAgentConfigPanel();
}

async function refreshSkillsForAgentRoot(rootKey) {
  const skillRoot = SKILL_ROOT_MAP[rootKey];
  if (!skillRoot) {
    clearSkillList();
    return;
  }
  try {
    const payload = await apiRequest("/api/list", {
      root: skillRoot,
      path: "",
    });
    const skillEntries = payload.entries.filter((entry) => entry.type === "file");
    state.availableSkills = skillEntries.map((entry) => entry.path);
    renderSkillList(skillEntries);
    renderSkillOptions();
    if (elements.skillsSection) {
      elements.skillsSection.hidden = false;
    }
  } catch (error) {
    console.error("Failed to load skills", error);
    clearSkillList();
  }
}

function clearSkillList() {
  state.availableSkills = [];
  renderSkillList([]);
  if (elements.skillsSection) {
    elements.skillsSection.hidden = true;
  }
  renderSkillOptions();
  updateAgentConfigPanel();
}

async function maybeLoadSkills() {
  if (AGENT_ROOT_KEYS.includes(state.root)) {
    await refreshSkillsForAgentRoot(state.root);
  } else {
    clearSkillList();
  }
}

function buildQuery(params) {
  const query = new URLSearchParams();
  Object.entries(params).forEach(([key, value]) => {
    query.set(key, value);
  });
  return query.toString();
}

async function apiRequest(path, params) {
  const response = await fetch(`${path}?${buildQuery(params)}`, {
    headers: { Accept: "application/json" },
    cache: "no-store",
  });

  const payload = await response.json();
  if (!response.ok) {
    throw new Error(payload.error || "Request failed");
  }
  return payload;
}

function renderEntries(entries) {
    elements.entryList.innerHTML = "";
    if (!entries.length) {
      const empty = document.createElement("li");
      empty.className = "empty-state";
      empty.textContent = "Nothing here yet.";
      elements.entryList.append(empty);
      return;
    }

    entries.forEach((entry) => {
      const item = document.createElement("li");
      const button = document.createElement("button");
      button.type = "button";
      button.className = `entry entry-${entry.type}`;
      button.textContent = entry.type === "directory" ? `${entry.name}/` : entry.name;
      button.addEventListener("click", async () => {
        if (entry.type === "directory") {
          state.path = entry.path;
          stopAutoRefresh();
          clearViewer();
          await loadDirectory();
          return;
        }

        state.userSelectedFile = true;
        state.selectedFile = entry.path;
        state.logOffset = 0;
        await loadFile(false);
        syncAutoRefresh();
      });
      item.append(button);
      elements.entryList.append(item);
    });
}

function clearViewer() {
  state.selectedFile = null;
  state.logOffset = 0;
  state.currentRawContent = "";
  state.selectedFileIsMarkdown = false;
  state.selectedFileIsWorkflow = false;
  state.selectedFileIsAgentConfig = false;
  state.userSelectedFile = false;
  state.workflowEditorForced = false;
  elements.filePath.textContent = "Select a file to view its contents.";
  elements.fileContent.textContent = "";
  updateMarkdownToggle();
  updateWorkflowEditor();
  updateAgentConfigPanel();
}

async function loadDirectory() {
  setStatus("Loading...");
  try {
    const payload = await apiRequest("/api/list", {
      root: state.root,
      path: state.path,
    });
    elements.currentPath.textContent = `${state.root} / ${payload.path}`;
    elements.upButton.disabled = payload.path === ".";
    elements.upButton.dataset.parent = payload.parent;
    renderEntries(payload.entries);
    await autoSelectFirstEntry(payload.entries);
    await maybeLoadSkills();
    setStatus("");
  } catch (error) {
    setStatus(error.message, true);
    renderEntries([]);
  }
}

async function loadFile(append) {
  if (!state.selectedFile) {
    return;
  }

  setStatus(state.root === "logs" && append ? "Polling log..." : "Loading file...");
  try {
    const payload = await apiRequest("/api/file", {
      root: state.root,
      path: state.selectedFile,
      offset: state.root === "logs" && append ? String(state.logOffset) : "0",
    });

    elements.filePath.textContent = `${state.root} / ${payload.path}`;
    const workflowLabel = getWorkflowTypeText(state.selectedFile || payload.path);
    if (elements.workflowType) {
      elements.workflowType.textContent = workflowLabel;
      elements.workflowType.hidden = !workflowLabel;
    }
    if (state.root === "logs" && append) {
      elements.fileContent.textContent += payload.content;
      elements.fileContent.scrollTop = elements.fileContent.scrollHeight;
    } else {
      state.currentRawContent = payload.content;
      state.selectedFileIsMarkdown = isMarkdownPath(state.selectedFile);
      state.selectedFileIsWorkflow = isWorkflowFile(state.selectedFile);
      updateMarkdownToggle();
      renderViewerContent();
      updateWorkflowEditor();
      state.selectedFileIsAgentConfig = isAgentConfigFile(state.selectedFile);
      updateAgentConfigPanel();
    }
    state.logOffset = payload.next_offset;
    if (state.root === "logs") {
      elements.fileContent.scrollTop = elements.fileContent.scrollHeight;
    }
    setStatus("");
  } catch (error) {
    setStatus(error.message, true);
  }
}

function stopAutoRefresh() {
  if (state.autoRefreshTimer) {
    window.clearInterval(state.autoRefreshTimer);
    state.autoRefreshTimer = null;
  }
}

async function autoSelectFirstEntry(entries) {
  if (state.userSelectedFile) {
    return;
  }
  const firstFile = entries.find((entry) => entry.type === "file");
  if (firstFile) {
    state.selectedFile = firstFile.path;
    state.logOffset = 0;
    await loadFile(false);
    return;
  }
  const firstDir = entries.find((entry) => entry.type === "directory");
  if (firstDir) {
    state.path = firstDir.path;
    state.userSelectedFile = false;
    const payload = await apiRequest("/api/list", {
      root: state.root,
      path: state.path,
    });
    renderEntries(payload.entries);
    await autoSelectFirstEntry(payload.entries);
  }
}

function syncAutoRefresh() {
  stopAutoRefresh();
  if (state.root !== "logs" || !elements.autoRefresh.checked || !state.selectedFile) {
    return;
  }

  state.autoRefreshTimer = window.setInterval(() => {
    loadFile(true);
  }, 2000);
}

async function switchRoot(nextRoot) {
  state.root = nextRoot;
  if (nextRoot !== "workflow-builder") {
    state.workflowEditorForced = false;
  }
  state.path = "";
  clearViewer();
  elements.rootTabs.forEach((button) => {
    button.classList.toggle("active", button.dataset.root === nextRoot);
  });
  elements.autoRefresh.disabled = nextRoot !== "logs";
  if (nextRoot !== "logs") {
    elements.autoRefresh.checked = false;
  }
  stopAutoRefresh();
  await loadDirectory();
}

elements.rootTabs.forEach((button) => {
  button.addEventListener("click", () => {
    if (button.dataset.root !== state.root) {
      switchRoot(button.dataset.root);
    }
  });
});

elements.refreshButton.addEventListener("click", async () => {
  await loadDirectory();
  if (state.selectedFile) {
    state.logOffset = 0;
    await loadFile(false);
    syncAutoRefresh();
  }
});

elements.autoRefresh.addEventListener("change", () => {
  if (!state.selectedFile) {
    elements.autoRefresh.checked = false;
  }
  syncAutoRefresh();
});

elements.upButton.addEventListener("click", async () => {
  state.path = elements.upButton.dataset.parent || "";
  await loadDirectory();
});

elements.workflowSaveButton?.addEventListener("click", async () => {
  if (!state.selectedFile || !state.selectedFileIsWorkflow || !elements.workflowTextarea) {
    return;
  }
  let parsed;
  try {
    parsed = JSON.parse(elements.workflowTextarea.value);
  } catch (error) {
    setStatus(`Invalid JSON: ${error.message}`, true);
    return;
  }
  const normalized = JSON.stringify(parsed, null, 2);
  try {
    setStatus("Saving workflow...");
    await putFile(state.root, state.selectedFile, normalized);
    state.currentRawContent = normalized;
    renderViewerContent();
    state.selectedFileIsWorkflow = true;
    updateWorkflowEditor();
    setStatus("Workflow saved.");
  } catch (error) {
    setStatus(error.message, true);
  }
});

elements.newWorkflowButton?.addEventListener("click", async () => {
  const defaultName = `workflow-${Date.now()}.orch.json`;
  const input = window.prompt(
    "Enter workflow filename (relative to plans root)",
    defaultName,
  );
  if (!input) {
    return;
  }
  const trimmed = input.trim();
  if (!trimmed) {
    return;
  }
  if (trimmed.includes("..")) {
    setStatus("Filename cannot contain '..'", true);
    return;
  }
  const relative = trimmed.replace(/^\/+/, "");
  const filename = relative.toLowerCase().endsWith(".orch.json")
    ? relative
    : `${relative}.orch.json`;
  try {
    setStatus("Creating workflow...");
    const template = await fetchWorkflowTemplate("orchestration");
    await putFile("plans", filename, template.content);
    await loadDirectory();
    state.selectedFile = filename;
    state.logOffset = 0;
    await loadFile(false);
    setStatus("Workflow created.");
  } catch (error) {
    setStatus(error.message, true);
  }
});

elements.agentSkillSelect?.addEventListener("change", () => {
  updateAgentConfigPanel();
});

elements.agentAddSkillButton?.addEventListener("click", () => {
  if (!elements.agentSkillSelect || !elements.agentConfigTextarea) {
    return;
  }
  const skillPath = elements.agentSkillSelect.value;
  if (!skillPath) {
    return;
  }
  let parsed;
  try {
    parsed = JSON.parse(elements.agentConfigTextarea.value || "{}");
  } catch (error) {
    setStatus("Fix JSON before adding a skill", true);
    return;
  }
  if (!Array.isArray(parsed.skills)) {
    parsed.skills = parsed.skills ? [parsed.skills] : [];
  }
  if (!parsed.skills.includes(skillPath)) {
    parsed.skills.push(skillPath);
    elements.agentConfigTextarea.value = JSON.stringify(parsed, null, 2);
    updateAgentConfigPanel();
  }
});

elements.agentConfigSaveButton?.addEventListener("click", async () => {
  if (!state.selectedFile || !state.selectedFileIsAgentConfig || !elements.agentConfigTextarea) {
    return;
  }
  let parsed;
  try {
    parsed = JSON.parse(elements.agentConfigTextarea.value);
  } catch (error) {
    setStatus(`Invalid JSON: ${error.message}`, true);
    return;
  }
  const normalized = JSON.stringify(parsed, null, 2);
  try {
    setStatus("Saving agent config...");
    await putFile(state.root, state.selectedFile, normalized);
    state.currentRawContent = normalized;
    renderViewerContent();
    updateAgentConfigPanel();
    setStatus("Agent config saved.");
  } catch (error) {
    setStatus(error.message, true);
  }
});

if (elements.markdownToggle) {
  elements.markdownToggle.addEventListener("click", () => {
    state.markdownView = !state.markdownView;
    updateMarkdownToggle();
    renderViewerContent();
  });
}

window.addEventListener("beforeunload", stopAutoRefresh);

switchRoot(state.root);
