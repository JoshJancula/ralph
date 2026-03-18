const state = {
  root: "plans",
  path: "",
  selectedFile: null,
  logOffset: 0,
  autoRefreshTimer: null,
};

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
};

function setStatus(message, isError = false) {
  elements.status.textContent = message;
  elements.status.dataset.error = isError ? "true" : "false";
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
  elements.filePath.textContent = "Select a file to view its contents.";
  elements.fileContent.textContent = "";
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
    if (state.root === "logs" && append) {
      elements.fileContent.textContent += payload.content;
    } else {
      elements.fileContent.textContent = payload.content;
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

window.addEventListener("beforeunload", stopAutoRefresh);

switchRoot(state.root);
