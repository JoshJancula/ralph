## Dashboard Audit Findings

### 1. Express API exposes the entire workspace without authentication (ASVS V1.1, V1.2.1)
- `/api/list`, `/api/file`, `/api/roots`, `/api/workspace`, `/api/metrics/summary` all run on the same `express` instance (`ralph-dashboard/src/server/dashboard-api.ts`) and return directory listings, file contents, and session/log metadata to any caller. `startDashboardServer` defaults to `127.0.0.1` but honors `HOST=0.0.0.0` (`ralph-dashboard/src/server.ts` lines 45‑67), so a misconfigured deployment opens a large attack surface. Add authentication/authorization checks or bind to a Unix socket, and document the localhost-only assumption in the server startup docs.

### 2. Root-guard logic can be bypassed via symlinks (ASVS V4.4.1)
- `resolveUnderRoot` calls `normalizeRelPath` to reject `..` segments but resolves the candidate path via `path.resolve` without calling `fs.realpath`. A symlink under an allowed root that points outside the workspace will still resolve and pass `assertContainedInRoot`, because `relative(resolvedRoot, resolvedTarget)` compares logical paths—even if the target is outside, the relative path may remain inside (especially when the symlink name itself is inside). Explicitly resolve the candidate with `realpathSync` and compare to the real root to prevent symlink escapes.

### 3. Markdown rendering relies on a custom sanitizer but still trusts generated DOM (ASVS V6.3.1)
- `FileViewerComponent` runs `markdownToHtml`, parses it into a DOM, calls `sanitizeHtmlDocument`, then calls `DomSanitizer.bypassSecurityTrustHtml(doc.body.innerHTML)` twice before and after rendering Mermaid (`ralph-dashboard/src/app/components/file-viewer/file-viewer.component.ts` lines 223‑248). The custom `sanitizeHtmlDocument` removes a fixed list of tags/attributes and some `javascript:`/`data:` URLs, but it still allows `<svg>` (added by Mermaid) and relies entirely on string matching, making it easy to miss namespace-based script vectors or future attributes. Moreover, Mermaid diagrams are inserted via `container.innerHTML = svg` (`file-viewer.component.ts` lines 287‑297) and are not re-sanitized after injection. Treat generated HTML as untrusted, add `DomSanitizer.sanitize`, or run a hardened sanitizer (DOMPurify) before bypassing Angular’s security context.

### 4. Log viewer renders raw log lines via `[innerHTML]` with inline `<mark>` tags (ASVS V6.3.1)
- `LogViewerComponent.applySearch` splits log lines and reassembles them with `<mark>` wrappers before storing them in `filteredLines` (`ralph-dashboard/src/app/components/log-viewer/log-viewer.component.ts` lines 167‑218). The template binds those strings with `[innerHTML]="line"` (`log-viewer.component.html` lines 90‑93), so any `log` content that already contains HTML, scripts, or SVG will be executed in the browser. Even when not searching, `prettyMode` renders `filteredPrettyHtml` (derived from `markdownToHtml`) directly via `[innerHTML]` (`log-viewer.component.html` lines 78‑84). Apply a sanitizer (e.g., Angular `DomSanitizer.bypassSecurityTrustHtml` only after calling `DomSanitizer.sanitize`) or remove `[innerHTML]` usage to avoid DOM XSS from malicious log content.

### 5. Missing defense headers and rate limiting (ASVS V13, V9.2)
- The Express server only sets `X-Content-Type-Options: nosniff` when serving static assets (`server.ts` lines 69‑77). There is no CSP, HSTS, Referrer-Policy, or frame-ancestor guard for the API or SPA. A future host binding to a non-localhost interface becomes more dangerous without these headers, and the APIs accept large files/logs without rate limiting, which can lead to DoS if exposed. Add a minimal CSP (even `default-src 'self'`) and optional rate limiting/log throttling on file APIs.

### Recommended Tests
- Add `supertest` coverage for `/api/list` and `/api/file` to prove the root guard rejects path traversal, hidden files, and symlink escapes.
- Feed `FileViewerComponent` renderer a markdown payload that includes `<svg><script>…</script></svg>` or `href="javascript:"` to ensure `sanitizeHtmlDocument` removes it before `bypassSecurityTrustHtml`.
- Insert log entries containing `</span><script>` into `LogViewer` and confirm the sanitized view does not execute or render the script.
- Test that `/api/metrics/summary` tolerates corrupted JSON files to avoid server crashes (ASVS V10.6).

### Next Steps
1. Tighten `resolveUnderRoot` by realpathing both the root and candidate before containment checks.
2. Harden the markdown/log renderer pipeline: sanitize DOM nodes after Mermaid renders and avoid binding unsanitized strings with `[innerHTML]`.
3. Document that the dashboard is localhost-only by default and fail startup or warn loudly when `HOST` is not `127.0.0.1`.
4. Add security headers (CSP, Referrer-Policy) and optional throttling middleware for file/list APIs.
