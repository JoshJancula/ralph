# Dashboard local app: research and requirements (Cursor, research agent)

Execute one TODO at a time. After each, note any verification you ran; fix issues, then mark `[x]` and continue. Artifact namespace for this orchestration is `dashboard` (paths use `.agents/artifacts/dashboard/`).

# Environment

- Runtime: Cursor plan runner with **research** agent (explore codebase and docs; produce `research.md`).
- Final deliverable: non-empty `.agents/artifacts/dashboard/research.md` (orchestrator and agent both require this path).

**Non-negotiable stack constraint (must appear explicitly in `research.md`):** The dashboard will be built from **generic HTML, CSS, and JavaScript only**. End users must **not** install Node.js or npm, run `npm install`, or rely on **node_modules**, bundlers (Webpack, Vite, etc.), or any JS package manager. Optional: a tiny local file/API server in Python stdlib or similar is allowed only to serve files or list directories; the **UI layer** stays plain static HTML/JS.

## TODOs

- [x] Explore how this repo (or target project) lays out `.agents/` (orchestration plans under `.agents/orchestration-plans/`, artifacts, logs under `.agents/logs/`). List which paths the dashboard must surface (plan files, artifact trees, log files).
- [x] Define user-facing goals: open a browser, navigate plans and artifacts, select a log file and see a tail or refresh view. State clearly that the front end is vanilla HTML/CSS/JS with no Node toolchain for users.
- [x] Capture security and scope constraints (read-only browsing of `.agents`, no arbitrary path traversal outside allowed roots, local use only).
- [x] Write `.agents/artifacts/dashboard/research.md` with: executive summary; findings from exploration; a **Requirements** subsection with the no Node/npm/node_modules/bundlers rules; functional requirements; non-goals; suggested directory layout for the implementation stage; acceptance criteria the code-review stage can check (including no `package.json` or `node_modules` for the dashboard).
