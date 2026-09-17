import {
  AfterViewInit,
  Component,
  DestroyRef,
  ElementRef,
  HostListener,
  PLATFORM_ID,
  computed,
  effect,
  inject,
  signal,
  viewChild,
} from '@angular/core';
import { isPlatformBrowser } from '@angular/common';
import { DomSanitizer, type SafeHtml } from '@angular/platform-browser';
import { FormsModule } from '@angular/forms';
import { AssistantStore } from './assistant.store';
import { CapabilitiesService } from '../workflows/capabilities.service';
import { markdownToHtml } from '../utils/markdown-to-html';
import { sanitizeHtmlDocument } from '../utils/sanitize-html';
import type { AssistantChatMessage, AssistantCronPreview, AssistantProposalView, AssistantWorkflowPreview } from './assistant.types';

/**
 * Ported from trade-beacon's shared/assistant-dock.component.ts: FAB
 * launcher, slide-in config panel, message log, composer, provenance bar.
 * Restyled with dashboard CSS variables instead of `--tb-*` tokens.
 * Renders assistant messages through markdown-to-html + sanitize-html
 * (dropped trade-beacon's plain-text interpolation). Adds a quick-actions
 * bar: the only way a mutating tool runs is a click on one of these
 * confirm cards — never inferred from what the assistant said. See
 * port-design.md "Component decisions".
 */
@Component({
  selector: 'ralph-assistant-dock',
  standalone: true,
  imports: [FormsModule],
  template: `
    @if (capabilities.capabilities().assistant) {
      @if (!modalBlocksLauncher()) {
        <button
          type="button"
          class="fab"
          #launcher
          data-testid="assistant-launcher"
          [attr.aria-expanded]="store.open()"
          aria-haspopup="dialog"
          aria-label="Open assistant"
          (click)="toggleOpen()"
          [class.is-open]="store.open()"
        >
          Ask
        </button>
      }

      @if (store.open()) {
        <button type="button" class="scrim" aria-label="Close assistant" data-testid="assistant-scrim" (click)="closePanel()"></button>

        <section class="panel" role="dialog" aria-modal="true" aria-label="Assistant" data-testid="assistant-panel" (keydown.escape)="closePanel()">
          <header class="header">
            <h2 class="title">Assistant</h2>
            <div class="header-actions">
              <button
                type="button"
                class="icon-btn"
                [class.is-active]="configOpen()"
                title="Configure runtime and model"
                aria-label="Toggle configuration"
                [attr.aria-expanded]="configOpen()"
                data-testid="assistant-config-toggle"
                (click)="toggleConfig()"
              >
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" aria-hidden="true">
                  <path
                    d="M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6zm7.43-3a7.97 7.97 0 0 0-.1-1l1.96-1.53-1.5-2.6-2.36.95a8.1 8.1 0 0 0-1.73-1L15.3 3h-3l-.4 2.49a8.1 8.1 0 0 0-1.73 1l-2.36-.95-1.5 2.6L7.67 11a7.97 7.97 0 0 0 0 2l-1.96 1.53 1.5 2.6 2.36-.95a8.1 8.1 0 0 0 1.73 1L12.3 21h3l.4-2.49a8.1 8.1 0 0 0 1.73-1l2.36.95 1.5-2.6L19.33 13c.06-.33.1-.66.1-1z"
                    fill="currentColor"
                  />
                </svg>
              </button>
              <button type="button" class="icon-btn" title="Clear conversation" aria-label="Clear conversation" data-testid="assistant-clear" (click)="store.clear()">
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" aria-hidden="true">
                  <path
                    d="M6 7h12M9 7V5a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2M10 11v6M14 11v6M5 7l1 12a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2L19 7H5z"
                    stroke="currentColor"
                    stroke-width="1.75"
                    stroke-linecap="round"
                    stroke-linejoin="round"
                  />
                </svg>
              </button>
              <button type="button" class="icon-btn" title="Close assistant" aria-label="Close assistant" data-testid="assistant-close" (click)="closePanel()">
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" aria-hidden="true">
                  <path d="M18 6L6 18M6 6l12 12" stroke="currentColor" stroke-width="2" stroke-linecap="round" />
                </svg>
              </button>
            </div>
          </header>

          @if (configOpen()) {
            <div class="config" data-testid="assistant-config">
              <label class="config-row">
                <span>Runtime</span>
                <select class="select" [ngModel]="store.selectedRuntime() ?? ''" [ngModelOptions]="{ standalone: true }" (ngModelChange)="onRuntimeChange($event)">
                  <option value="" disabled>Choose a runtime…</option>
                  @for (rt of store.runtimes(); track rt.id) {
                    <option [value]="rt.id" [disabled]="!rt.installed">{{ rt.label }}{{ rt.installed ? '' : ' (not found)' }}</option>
                  }
                </select>
              </label>
              <label class="config-row">
                <span>Model</span>
                <select class="select" [disabled]="!store.selectedRuntime()" [ngModel]="modelChoice()" [ngModelOptions]="{ standalone: true }" (ngModelChange)="selectModel($event)">
                  <option value="">Runtime default model</option>
                  @for (model of store.models(); track model.id) {
                    <option [value]="model.id">{{ model.label }}</option>
                  }
                  <option value="__custom__">Custom model…</option>
                </select>
              </label>
              @if (showCustomModel()) {
                <label class="config-row">
                  <span>Custom model id</span>
                  <input class="select" type="text" placeholder="Enter a model id" [(ngModel)]="customModel" [ngModelOptions]="{ standalone: true }" (change)="applyCustomModel()" />
                </label>
              }
              <div class="config-footer">
                <p class="config-hint">Runtime and model apply to the next message.</p>
                <button type="button" class="config-done" data-testid="assistant-config-done" (click)="configOpen.set(false)">Done</button>
              </div>
            </div>
          }

          <div class="log" role="log" aria-live="polite" data-testid="assistant-messages" #logEl>
            @if (store.messages().length === 0) {
              <div class="intro">
                <p>Ask about workflows, runs, or plans in this install.</p>
                @if (store.tools().length > 0) {
                  <details class="tools-details">
                    <summary>What it can reach ({{ store.tools().length }} tools)</summary>
                    <ul class="tools-list">
                      @for (tool of store.tools(); track tool.name) {
                        <li>
                          <code>{{ tool.name }}</code>
                          @if (tool.mutating) {
                            <span class="badge badge-warn">changes things</span>
                          }
                          — {{ tool.description }}
                        </li>
                      }
                    </ul>
                  </details>
                }
              </div>
            }

            @for (message of store.messages(); track $index) {
              <div class="msg" [class.is-user]="message.role === 'user'">
                <span class="role">{{ message.role === 'user' ? 'You' : 'Assistant' }}</span>
                <div class="bubble" [class.bubble-user]="message.role === 'user'" [class.bubble-assistant]="message.role !== 'user'" [innerHTML]="renderedContent(message)"></div>
              </div>
            }

            @if (store.sending()) {
              <div class="msg">
                <span class="role">Assistant</span>
                <div class="bubble bubble-assistant bubble-typing" data-testid="assistant-pending" aria-label="Assistant is thinking">
                  <span class="typing-dot" aria-hidden="true"></span>
                  <span class="typing-dot" aria-hidden="true"></span>
                  <span class="typing-dot" aria-hidden="true"></span>
                </div>
              </div>
            }
          </div>

          @if (store.error(); as message) {
            <div class="error-notice" role="alert" data-testid="assistant-error">{{ message }}</div>
          }

          @if (store.lastAnsweredBy(); as answeredBy) {
            <p class="provenance" data-testid="assistant-provenance">
              <span class="provenance-dot" [class.is-degraded]="store.lastDegraded()"></span>
              {{ answeredBy }}
            </p>
          }

          @if (store.proposals().length > 0) {
            <div class="proposals" data-testid="assistant-proposals">
              @for (proposal of store.proposals(); track proposal.id) {
                <div class="proposal" [attr.data-testid]="'proposal-' + proposal.tool">
                  <p class="proposal-title">{{ proposal.title }}</p>

                  @if (cronPreview(proposal); as cron) {
                    @if (cron.valid) {
                      <p class="proposal-note">Next runs:</p>
                      <ul class="proposal-times">
                        @for (time of cron.upcoming; track time) {
                          <li>{{ time }}</li>
                        }
                      </ul>
                    } @else {
                      <p class="proposal-error" data-testid="proposal-invalid">{{ cron.error || 'That schedule is not valid.' }}</p>
                    }
                  }

                  @if (workflowPreview(proposal); as draft) {
                    @if (draft.valid) {
                      <p class="proposal-note">Validated against Ralph.</p>
                    } @else {
                      <p class="proposal-error" data-testid="proposal-invalid">{{ draft.diagnostics || 'That workflow did not validate.' }}</p>
                    }
                  }

                  <details class="proposal-details">
                    <summary>What this will do</summary>
                    <pre class="proposal-args">{{ argumentsJson(proposal) }}</pre>
                  </details>

                  <div class="confirm-actions">
                    <button type="button" class="chip" data-testid="proposal-dismiss" (click)="store.dismissProposal(proposal.id)">Dismiss</button>
                    <button
                      type="button"
                      class="chip chip-primary"
                      data-testid="proposal-confirm"
                      [disabled]="store.committing() !== null || !canCommit(proposal)"
                      (click)="commit(proposal)"
                    >
                      {{ store.committing() === proposal.id ? 'Applying…' : 'Confirm' }}
                    </button>
                  </div>
                </div>
              }
            </div>
          }

          @if (!hasConversation() || pendingAction()) {
            <div class="quick-actions" data-testid="assistant-quick-actions">
              @if (!pendingAction()) {
                <button type="button" class="chip" data-testid="quick-action-start" (click)="openAction('start_workflow')">Start workflow…</button>
                <button type="button" class="chip" data-testid="quick-action-cancel" (click)="openAction('cancel_run')">Cancel run…</button>
              } @else if (pendingAction() === 'start_workflow') {
                <div class="confirm-card hub-nested-panel" data-testid="confirm-card-start">
                  <label class="config-row">
                    <span>Workflow id</span>
                    <input class="control" type="text" [(ngModel)]="actionWorkflowId" name="actionWorkflowId" />
                  </label>
                  <label class="config-row">
                    <span>Task</span>
                    <input class="control" type="text" [(ngModel)]="actionTask" name="actionTask" />
                  </label>
                  <div class="confirm-actions">
                    <button type="button" class="chip" data-testid="confirm-cancel-action" (click)="pendingAction.set(null)">Cancel</button>
                    <button
                      type="button"
                      class="chip chip-primary"
                      data-testid="confirm-send-start"
                      [disabled]="!actionWorkflowId().trim() || !actionTask().trim()"
                      (click)="confirmStartWorkflow()"
                    >
                      Start
                    </button>
                  </div>
                </div>
              } @else {
                <div class="confirm-card hub-nested-panel" data-testid="confirm-card-cancel">
                  <label class="config-row">
                    <span>Run id</span>
                    <input class="control" type="text" [(ngModel)]="actionRunId" name="actionRunId" />
                  </label>
                  <div class="confirm-actions">
                    <button type="button" class="chip" data-testid="confirm-cancel-action" (click)="pendingAction.set(null)">Cancel</button>
                    <button type="button" class="chip chip-primary" data-testid="confirm-send-cancel" [disabled]="!actionRunId().trim()" (click)="confirmCancelRun()">
                      Cancel run
                    </button>
                  </div>
                </div>
              }
            </div>
          }

          <form class="composer" (ngSubmit)="send()">
            <label class="sr-only" for="assistant-draft">Message</label>
            <textarea
              id="assistant-draft"
              class="textarea"
              rows="3"
              placeholder="Ask about your workflows, runs, or plans…"
              data-testid="assistant-draft"
              [(ngModel)]="draft"
              [ngModelOptions]="{ standalone: true }"
              [disabled]="store.sending()"
              (keydown.enter)="onEnter($event)"
            ></textarea>
            <div class="composer-footer">
              <span class="composer-hint">{{ store.selectedRuntime() || 'Choose a runtime' }}{{ store.selectedModel() ? ' · ' + store.selectedModel() : '' }}</span>
              <button
                type="submit"
                class="send-btn"
                data-testid="assistant-send"
                [attr.aria-label]="store.sending() ? 'Sending' : 'Send message'"
                [disabled]="store.sending() || !store.selectedRuntime() || !draft.trim()"
              >
                @if (store.sending()) {
                  <span class="send-label">…</span>
                } @else {
                  <svg width="16" height="16" viewBox="0 0 24 24" fill="none" aria-hidden="true">
                    <path d="M4 12h14M13 6l6 6-6 6" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
                  </svg>
                }
              </button>
            </div>
          </form>
        </section>
      }
    }
  `,
  styles: `
    .fab {
      position: fixed;
      right: 24px;
      bottom: calc(20px + env(safe-area-inset-bottom, 0px));
      z-index: 12;
      min-width: 54px;
      min-height: 44px;
      padding: 0.6rem 1.25rem;
      border-radius: 999px;
      border: 1px solid var(--button-bg);
      background: var(--button-bg);
      color: var(--button-text);
      font: inherit;
      font-size: var(--font-size-sm);
      font-weight: 600;
      letter-spacing: 0.01em;
      cursor: pointer;
      box-shadow: 0 6px 20px rgba(0, 0, 0, 0.28);
      transition: transform 0.15s ease, box-shadow 0.15s ease;
    }
    .fab:hover {
      transform: translateY(-2px);
      box-shadow: 0 8px 24px rgba(0, 0, 0, 0.35);
    }
    .fab:focus-visible {
      outline: var(--focus-ring-width, 2px) solid var(--focus-ring-color, var(--accent));
      outline-offset: 3px;
    }
    .fab.is-open {
      opacity: 0.75;
      transform: none;
    }
    .scrim {
      position: fixed;
      inset: 0;
      z-index: 70;
      border: 0;
      padding: 0;
      cursor: default;
      background: rgb(0 0 0 / 40%);
    }
    .panel {
      position: fixed;
      right: 20px;
      bottom: 20px;
      z-index: 80;
      display: flex;
      flex-direction: column;
      width: min(420px, calc(100vw - 32px));
      height: min(640px, calc(100dvh - 40px));
      max-height: min(640px, calc(100vh - 40px));
      border: 1px solid var(--border);
      border-radius: 14px;
      background: var(--surface);
      box-shadow: 0 24px 64px rgb(0 0 0 / 35%);
      overflow: hidden;
    }
    .header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 0.75rem 0.9rem;
      border-bottom: 1px solid var(--border);
    }
    .title {
      margin: 0;
      font-size: 0.95rem;
      color: var(--text-primary);
    }
    .header-actions {
      display: flex;
      gap: 0.2rem;
    }
    .icon-btn,
    .chip {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      min-width: var(--touch-target-min, 44px);
      min-height: var(--touch-target-min, 44px);
      padding: 0.4rem;
      border-radius: 8px;
      border: 1px solid transparent;
      background: transparent;
      color: var(--text-muted);
      font-size: 0.75rem;
      cursor: pointer;
    }
    .chip {
      min-width: 0;
      padding: 0.45rem 0.7rem;
      border: 1px solid var(--border);
    }
    .icon-btn:focus-visible,
    .chip:focus-visible,
    .send-btn:focus-visible,
    .config-done:focus-visible {
      outline: var(--focus-ring-width, 2px) solid var(--focus-ring-color, var(--accent));
      outline-offset: 2px;
    }
    .icon-btn.is-active {
      color: var(--accent);
      background: color-mix(in srgb, var(--accent) 12%, transparent);
      border-color: color-mix(in srgb, var(--accent) 30%, transparent);
    }
    .icon-btn:hover,
    .chip:hover {
      color: var(--text-primary);
      background: var(--surface-hover);
    }
    .config {
      display: flex;
      flex-direction: column;
      gap: 0.5rem;
      padding: 0.7rem 0.9rem;
      border-bottom: 1px solid var(--border);
      background: color-mix(in srgb, var(--surface-hover) 55%, transparent);
    }
    .config-footer {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 0.75rem;
      margin-top: 0.15rem;
    }
    .config-hint {
      margin: 0;
      color: var(--text-muted);
      font-size: 0.72rem;
      line-height: 1.35;
    }
    .config-done {
      flex: 0 0 auto;
      min-height: 2rem;
      padding: 0.3rem 0.75rem;
      border-radius: 6px;
      border: 1px solid var(--border);
      background: var(--surface);
      color: var(--text-primary);
      font-size: 0.75rem;
      font-weight: 600;
      cursor: pointer;
    }
    .config-done:hover {
      border-color: var(--accent);
      color: var(--accent);
    }
    .config-row {
      display: flex;
      flex-direction: column;
      gap: 0.2rem;
      font-size: 0.75rem;
      color: var(--text-muted);
    }
    .select {
      padding: 0.35rem 0.5rem;
      border-radius: 6px;
      border: 1px solid var(--border);
      background: var(--surface);
      color: var(--text-primary);
      font: inherit;
    }
    .log {
      flex: 1;
      min-height: 0;
      overflow-y: auto;
      display: flex;
      flex-direction: column;
      gap: 0.6rem;
      padding: 0.8rem 0.9rem;
      min-height: 80px;
    }
    .intro {
      font-size: 0.8rem;
      color: var(--text-muted);
    }
    .tools-details summary {
      cursor: pointer;
      font-weight: 600;
    }
    .tools-list {
      margin: 0.3rem 0 0;
      padding-left: 1.1rem;
    }
    .tools-list code {
      background: color-mix(in srgb, var(--accent) 14%, transparent);
      padding: 0 0.3rem;
      border-radius: 4px;
    }
    .badge {
      display: inline-block;
      padding: 0.05rem 0.35rem;
      border-radius: 4px;
      font-size: 0.65rem;
      font-weight: 700;
      text-transform: uppercase;
    }
    .badge-warn {
      background: color-mix(in srgb, var(--danger) 18%, transparent);
      color: var(--danger);
    }
    .msg {
      display: flex;
      flex-direction: column;
      gap: 0.15rem;
      max-width: 88%;
    }
    .msg.is-user {
      align-self: flex-end;
      align-items: flex-end;
    }
    .role {
      font-size: 0.65rem;
      text-transform: uppercase;
      color: var(--text-muted);
      padding: 0 0.2rem;
    }
    .bubble {
      padding: 0.5rem 0.75rem;
      border-radius: 10px;
      font-size: 0.83rem;
      line-height: 1.5;
      white-space: pre-wrap;
      overflow-wrap: anywhere;
    }
    .bubble-user {
      background: color-mix(in srgb, var(--accent) 18%, transparent);
      border: 1px solid color-mix(in srgb, var(--accent) 30%, transparent);
      color: var(--text-primary);
    }
    .bubble-assistant {
      background: var(--background, var(--surface));
      border: 1px solid var(--border);
      color: var(--text-primary);
    }
    .bubble-typing {
      display: inline-flex;
      align-items: center;
      gap: 0.3rem;
      min-height: 1.5rem;
      white-space: nowrap;
    }
    .typing-dot {
      width: 0.35rem;
      height: 0.35rem;
      border-radius: 50%;
      background: var(--text-muted);
      animation: assistant-typing 1s ease-in-out infinite;
    }
    .typing-dot:nth-child(2) {
      animation-delay: 0.15s;
    }
    .typing-dot:nth-child(3) {
      animation-delay: 0.3s;
    }
    @keyframes assistant-typing {
      0%,
      80%,
      100% {
        opacity: 0.35;
        transform: translateY(0);
      }
      40% {
        opacity: 1;
        transform: translateY(-2px);
      }
    }
    .error-notice {
      margin: 0 0.9rem;
      padding: 0.5rem 0.7rem;
      border: 1px solid var(--danger);
      border-radius: 8px;
      background: color-mix(in srgb, var(--danger) 8%, transparent);
      color: var(--danger);
      font-size: 0.78rem;
    }
    .provenance {
      display: flex;
      align-items: center;
      gap: 0.4rem;
      margin: 0;
      padding: 0.4rem 0.9rem;
      font-size: 0.72rem;
      color: var(--text-muted);
      border-top: 1px solid var(--border);
    }
    .provenance-dot {
      width: 6px;
      height: 6px;
      border-radius: 50%;
      background: var(--accent);
    }
    .provenance-dot.is-degraded {
      background: var(--danger);
    }
    .quick-actions {
      display: flex;
      flex-wrap: wrap;
      gap: 0.4rem;
      padding: 0.5rem 0.9rem;
      border-top: 1px solid var(--border);
    }
    .confirm-card {
      display: flex;
      flex-direction: column;
      gap: 0.4rem;
      width: 100%;
    }
    .confirm-actions {
      display: flex;
      justify-content: flex-end;
      gap: 0.4rem;
    }
    .chip-primary {
      background: var(--button-bg);
      color: var(--button-text);
      border-color: transparent;
    }
    .chip:disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }
    .proposals {
      display: flex;
      flex-direction: column;
      gap: 0.5rem;
      padding: 0.6rem 0.7rem;
      border-top: 1px solid var(--border);
      max-height: 40%;
      overflow-y: auto;
    }
    .proposal {
      display: flex;
      flex-direction: column;
      gap: 0.4rem;
      padding: 0.6rem;
      border: 1px solid var(--border);
      border-radius: 8px;
      background: var(--surface);
    }
    .proposal-title {
      margin: 0;
      font-size: 0.8rem;
      font-weight: 600;
      color: var(--text-primary);
    }
    .proposal-note {
      margin: 0;
      font-size: 0.7rem;
      color: var(--text-muted);
    }
    .proposal-error {
      margin: 0;
      font-size: 0.7rem;
      color: var(--danger, #c0392b);
    }
    .proposal-times {
      margin: 0;
      padding-left: 1rem;
      font-size: 0.7rem;
      color: var(--text-muted);
    }
    .proposal-details {
      font-size: 0.7rem;
      color: var(--text-muted);
    }
    .proposal-args {
      margin: 0.3rem 0 0;
      padding: 0.4rem;
      border-radius: 6px;
      background: var(--surface-hover);
      color: var(--text-primary);
      font-size: 0.68rem;
      white-space: pre-wrap;
      word-break: break-word;
      max-height: 9rem;
      overflow-y: auto;
    }
    .composer {
      border-top: 1px solid var(--border);
      display: flex;
      flex-direction: column;
      flex: 0 0 auto;
    }
    .textarea {
      margin: 0.6rem 0.7rem 0.2rem;
      padding: 0.5rem 0.6rem;
      border-radius: 8px;
      border: 1px solid var(--border);
      background: var(--surface);
      color: var(--text-primary);
      font: inherit;
      resize: none;
    }
    .composer-footer {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 0.4rem 0.7rem 0.6rem;
    }
    .composer-hint {
      font-size: 0.7rem;
      color: var(--text-muted);
    }
    .send-btn {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      min-width: var(--touch-target-min, 44px);
      min-height: var(--touch-target-min, 44px);
      padding: 0.4rem;
      border-radius: 8px;
      border: none;
      background: var(--button-bg);
      color: var(--button-text);
      font: inherit;
      font-weight: 600;
      cursor: pointer;
    }
    .send-btn:disabled {
      opacity: 0.4;
      cursor: not-allowed;
    }
    .send-label {
      font-size: 0.9rem;
      letter-spacing: 0.08em;
    }
  `,
})
export class AssistantDockComponent implements AfterViewInit {
  readonly store = inject(AssistantStore);
  readonly capabilities = inject(CapabilitiesService);
  private readonly sanitizer = inject(DomSanitizer);
  private readonly platformId = inject(PLATFORM_ID);
  private readonly destroyRef = inject(DestroyRef);

  /** Hub modals render under ion-content; the FAB sits above that stacking context. */
  readonly modalBlocksLauncher = signal(false);

  readonly configOpen = signal(false);
  readonly pendingAction = signal<'start_workflow' | 'cancel_run' | null>(null);
  readonly customModelOpen = signal(false);
  readonly actionWorkflowId = signal('');
  readonly actionTask = signal('');
  readonly actionRunId = signal('');
  /** Hide starter quick actions once the user has sent a message. */
  readonly hasConversation = computed(() => this.store.messages().some((message) => message.role === 'user'));

  private readonly logEl = viewChild<ElementRef<HTMLDivElement>>('logEl');
  private readonly launcher = viewChild<ElementRef<HTMLButtonElement>>('launcher');

  draft = '';
  customModel = '';

  private modalObserver: MutationObserver | null = null;

  constructor() {
    this.capabilities.load();
    effect(() => {
      void this.store.messages();
      void this.store.sending();
      queueMicrotask(() => {
        const el = this.logEl()?.nativeElement;
        if (el) el.scrollTop = el.scrollHeight;
      });
    });
    effect(() => {
      const draft = this.store.prefilledDraft();
      if (draft) this.draft = this.store.consumePrefilledDraft();
    });
  }

  ngAfterViewInit(): void {
    if (!isPlatformBrowser(this.platformId)) {
      return;
    }
    this.refreshModalBlocksLauncher();
    this.modalObserver = new MutationObserver(() => this.refreshModalBlocksLauncher());
    this.modalObserver.observe(document.body, { childList: true, subtree: true });
    this.destroyRef.onDestroy(() => this.modalObserver?.disconnect());
  }

  private refreshModalBlocksLauncher(): void {
    if (!isPlatformBrowser(this.platformId)) {
      return;
    }
    const blocked =
      document.querySelector('.hub-modal-backdrop') !== null ||
      document.querySelector('ion-modal.show-modal') !== null;
    this.modalBlocksLauncher.set(blocked);
    if (blocked && this.store.open()) {
      this.store.close();
    }
  }

  toggleConfig(): void {
    this.configOpen.update((open) => !open);
    if (this.configOpen() && this.modelChoice() === '__custom__') {
      this.customModel = this.store.selectedModel();
    }
  }

  /**
   * Ignore empty emissions from the runtime <select>. Before options load, the
   * browser can briefly report "" for a restored value that is not yet present
   * as an <option>, which would otherwise wipe the remembered selection.
   */
  onRuntimeChange(value: string): void {
    if (!value) return;
    this.store.setRuntime(value);
  }

  toggleOpen(): void {
    if (this.store.open()) {
      this.closePanel();
    } else {
      this.store.toggle();
    }
  }

  closePanel(): void {
    this.store.close();
    setTimeout(() => {
      this.launcher()?.nativeElement?.focus();
    }, 0);
  }

  @HostListener('document:keydown.escape')
  onDocumentEscape(): void {
    if (!this.store.open()) {
      return;
    }
    this.closePanel();
  }

  renderedContent(message: AssistantChatMessage): SafeHtml {
    if (!isPlatformBrowser(this.platformId)) {
      return this.sanitizer.bypassSecurityTrustHtml(escapeText(message.content));
    }
    const html = markdownToHtml(message.content);
    const doc = new DOMParser().parseFromString(html, 'text/html');
    sanitizeHtmlDocument(doc.body);
    return this.sanitizer.bypassSecurityTrustHtml(doc.body.innerHTML);
  }

  openAction(action: 'start_workflow' | 'cancel_run'): void {
    this.pendingAction.set(action);
    this.actionWorkflowId.set('');
    this.actionTask.set('');
    this.actionRunId.set('');
  }

  modelChoice(): string {
    const selected = this.store.selectedModel();
    if (!selected || this.store.models().some((model) => model.id === selected)) return selected;
    return '__custom__';
  }

  showCustomModel(): boolean {
    return this.customModelOpen() || this.modelChoice() === '__custom__';
  }

  selectModel(value: string): void {
    if (value === '__custom__') {
      this.customModel = this.store.selectedModel();
      this.customModelOpen.set(true);
      return;
    }
    this.customModelOpen.set(false);
    this.customModel = '';
    this.store.setModel(value);
  }

  applyCustomModel(): void {
    this.customModelOpen.set(false);
    this.store.setModel(this.customModel);
  }

  async confirmStartWorkflow(): Promise<void> {
    const workflowId = this.actionWorkflowId().trim();
    const task = this.actionTask().trim();
    if (!workflowId || !task) return;
    this.pendingAction.set(null);
    await this.store.sendApprovedAction(`Start workflow ${workflowId}: ${task}`, {
      tool: 'start_workflow',
      arguments: { workflowId, task },
    });
  }

  async confirmCancelRun(): Promise<void> {
    const runId = this.actionRunId().trim();
    if (!runId) return;
    this.pendingAction.set(null);
    await this.store.sendApprovedAction(`Cancel run ${runId}`, { tool: 'cancel_run', arguments: { runId } });
  }

  /** The server computed these previews from the real cron engine and the real workflow codec, not from what the model claimed. */
  cronPreview(proposal: AssistantProposalView): AssistantCronPreview | null {
    if (proposal.tool !== 'create_schedule' && proposal.tool !== 'update_schedule') return null;
    const preview = proposal.preview as AssistantCronPreview | undefined;
    return preview && typeof preview.valid === 'boolean' ? preview : null;
  }

  workflowPreview(proposal: AssistantProposalView): AssistantWorkflowPreview | null {
    if (proposal.tool !== 'create_workflow') return null;
    const preview = proposal.preview as AssistantWorkflowPreview | undefined;
    return preview && typeof preview.valid === 'boolean' ? preview : null;
  }

  /** A proposal the server could not validate is never committable: the card refuses rather than posting a known-bad body. */
  canCommit(proposal: AssistantProposalView): boolean {
    return this.cronPreview(proposal)?.valid !== false && this.workflowPreview(proposal)?.valid !== false;
  }

  argumentsJson(proposal: AssistantProposalView): string {
    try {
      return JSON.stringify(proposal.arguments, null, 2);
    } catch {
      return '{}';
    }
  }

  async commit(proposal: AssistantProposalView): Promise<void> {
    await this.store.commitProposal(proposal);
  }

  onEnter(event: Event): void {
    const keyboardEvent = event as KeyboardEvent;
    if (keyboardEvent.shiftKey) return;
    keyboardEvent.preventDefault();
    void this.send();
  }

  async send(): Promise<void> {
    const toSend = this.draft;
    if (!toSend.trim()) {
      return;
    }
    this.draft = '';
    const ok = await this.store.send(toSend);
    if (!ok) {
      this.draft = toSend;
    }
  }
}

function escapeText(value: string): string {
  return value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}
