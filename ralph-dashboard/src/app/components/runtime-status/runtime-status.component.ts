import { CommonModule } from '@angular/common';
import { HttpClient } from '@angular/common/http';
import { Component, OnInit, inject, signal } from '@angular/core';
import type { AmbientProviderReport, AmbientUsageResponse } from '../../services/api.service';

type RuntimeConnectionState = 'connected' | 'not_connected' | 'not_installed';

interface RuntimeExternalLink {
  label: string;
  url: string;
}

interface RuntimeConnectionStatus {
  runtimeId: string;
  label: string;
  state: RuntimeConnectionState;
  detail: string | null;
  accountHint: string | null;
  planHint: string | null;
  providers: readonly string[];
  links: readonly RuntimeExternalLink[];
}

@Component({
  selector: 'ralph-runtime-status',
  standalone: true,
  imports: [CommonModule],
  template: `
    <div class="runtime-status hub-page" data-testid="runtime-status-page">
      <header class="page-header">
        <div>
          <h1 class="page-title">Runtimes</h1>
          <p class="page-lede">
            Connection status for each agent CLI on this machine, with plan details and usage links when available.
          </p>
        </div>
      </header>

      @if (loading()) {
        <p class="runtime-status-message">Checking runtime connections…</p>
      } @else if (error()) {
        <div class="runtime-error-panel" role="alert">
          <p class="runtime-status-message is-error">{{ error() }}</p>
          <button type="button" class="btn btn-ghost" (click)="load()">Retry</button>
        </div>
      } @else {
        <section class="runtime-status-list" aria-label="Runtime connection status">
          @for (runtime of runtimes(); track runtime.runtimeId) {
            <article
              class="runtime-card surface-card"
              [class.has-usage]="ambientProvider(runtime.runtimeId) !== null"
              [attr.data-runtime]="runtime.runtimeId"
            >
              <div class="card-main">
                <div class="badges-row">
                  <span
                    class="status-pill"
                    [class.pill-connected]="runtime.state === 'connected'"
                    [class.pill-muted]="runtime.state !== 'connected'"
                  >
                    <span class="status-dot" aria-hidden="true"></span>
                    {{ stateLabel(runtime.state) }}
                  </span>
                </div>

                <h2 class="runtime-name">{{ runtime.label }}</h2>

                <p class="runtime-detail">
                  @if (runtime.state === 'connected') {
                    Using your existing sign-in on this machine
                    @if (runtime.accountHint) { — {{ runtime.accountHint }} }
                  } @else {
                    {{ runtime.detail ?? 'No active sign-in found' }}
                  }
                </p>

                @if (runtime.planHint || runtime.providers.length) {
                  <div class="meta-specs">
                    @if (runtime.planHint) {
                      <span class="spec-item" data-testid="runtime-plan">
                        <span class="spec-label">Plan</span>
                        <strong>{{ runtime.planHint }}</strong>
                      </span>
                    }
                    @if (runtime.providers.length) {
                      <span class="spec-item" data-testid="runtime-providers">
                        <span class="spec-label">{{ runtime.providers.length === 1 ? 'Provider' : 'Providers' }}</span>
                        <strong>{{ runtime.providers.join(', ') }}</strong>
                      </span>
                    }
                  </div>
                }

                @if (runtime.links.length) {
                  <div class="runtime-links" data-testid="runtime-links">
                    @for (link of runtime.links; track link.url) {
                      <a class="runtime-link" [href]="link.url" target="_blank" rel="noopener noreferrer">{{ link.label }}</a>
                    }
                  </div>
                }
              </div>

              @if (ambientFeatureEnabled() && ambientProvider(runtime.runtimeId); as provider) {
                <div class="runtime-ambient" data-testid="runtime-ambient">
                  <div class="runtime-ambient-meta">
                    <span>Updated {{ formatAmbientUpdated(provider.updated_at) }}</span>
                    @if (provider.quota_fetched_at) {
                      <span>Quota snapshot {{ formatAmbientUpdated(provider.quota_fetched_at) }}</span>
                    }
                  </div>
                  @if (provider.rate_limits.length > 0) {
                    <div class="runtime-quota-list">
                      @for (window of provider.rate_limits; track window.id) {
                        <div class="runtime-quota">
                          <div class="runtime-quota-head">
                            <strong>{{ window.label }}</strong>
                            <span>{{ formatResetsIn(window.resets_in_seconds) }}</span>
                          </div>
                          <div class="runtime-quota-track">
                            <span
                              class="runtime-quota-fill"
                              [attr.data-level]="quotaLevel(window.used_percent)"
                              [style.width.%]="remainingQuotaPercent(window.used_percent)"
                            ></span>
                          </div>
                          <p>{{ formatQuotaPercent(window.used_percent) }} used · {{ formatQuotaPercent(remainingQuotaPercent(window.used_percent)) }} remaining</p>
                        </div>
                      }
                    </div>
                  }
                  @if (provider.tokens.total_tokens > 0) {
                    <div class="runtime-token-summary">
                      <span>Transcript tokens <strong>{{ formatCompact(provider.tokens.total_tokens) }}</strong></span>
                      <span>Sessions <strong>{{ formatNumber(provider.tokens.session_count) }}</strong></span>
                    </div>
                  }
                </div>
              } @else if (ambientLoading() && (runtime.runtimeId === 'claude' || runtime.runtimeId === 'codex' || runtime.runtimeId === 'antigravity')) {
                <p class="runtime-ambient-loading">Loading usage…</p>
              }
            </article>
          }
        </section>
      }
    </div>
  `,
  styles: `
    :host { display: block; min-height: 100%; }

    .runtime-status-list {
      display: grid;
      gap: var(--space-3, 0.85rem);
    }

    .runtime-card {
      display: grid;
      grid-template-columns: minmax(16rem, 0.95fr) minmax(0, 1.15fr);
      align-items: start;
      column-gap: var(--space-5, 1.5rem);
      row-gap: var(--space-3, 0.85rem);
      padding: 1.15rem 1.35rem;
    }

    .runtime-card:not(.has-usage) {
      grid-template-columns: 1fr;
    }

    .runtime-card:hover {
      border-color: var(--ion-color-step-300, #6e7681);
      box-shadow: 0 10px 28px rgba(0, 0, 0, 0.14);
    }

    .card-main {
      display: flex;
      flex-direction: column;
      gap: 0.55rem;
      min-width: 0;
    }

    .badges-row {
      display: flex;
      flex-wrap: wrap;
      gap: 0.45rem;
    }

    .status-pill {
      display: inline-flex;
      align-items: center;
      gap: 0.4rem;
      padding: 0.18rem 0.6rem;
      border-radius: 999px;
      border: 1px solid transparent;
      font-size: var(--font-size-xs, 0.75rem);
      font-weight: 600;
      letter-spacing: 0.02em;
    }

    .status-dot {
      width: 0.45rem;
      height: 0.45rem;
      border-radius: 50%;
      background: currentColor;
    }

    .pill-connected {
      color: var(--success, #3fb950);
      background: color-mix(in srgb, var(--success, #238636) 15%, transparent);
      border-color: color-mix(in srgb, var(--success, #238636) 30%, transparent);
    }

    .pill-muted {
      color: var(--text-muted);
      background: var(--surface-muted, var(--surface-hover));
      border-color: var(--border);
    }

    .runtime-name {
      margin: 0;
      color: var(--text-primary);
      font-size: 1.1rem;
      font-weight: 650;
      letter-spacing: -0.015em;
      line-height: 1.25;
    }

    .runtime-detail {
      margin: 0;
      color: var(--text-muted);
      font-size: var(--font-size-sm, 0.9rem);
      line-height: 1.45;
    }

    .meta-specs {
      display: flex;
      flex-wrap: wrap;
      gap: 0.55rem 1.15rem;
    }

    .spec-item {
      display: inline-flex;
      flex-wrap: wrap;
      align-items: baseline;
      gap: 0.35rem;
      color: var(--text-muted);
      font-size: var(--font-size-sm, 0.88rem);
    }

    .spec-label {
      font-size: var(--font-size-xs, 0.72rem);
      font-weight: 700;
      letter-spacing: 0.06em;
      text-transform: uppercase;
      color: var(--text-muted);
    }

    .spec-item strong {
      color: var(--text-primary);
      font-weight: 600;
    }

    .runtime-links {
      display: flex;
      flex-wrap: wrap;
      gap: 0.5rem 0.75rem;
      padding-top: 0.15rem;
    }

    .runtime-link {
      display: inline-flex;
      align-items: center;
      min-height: 1.85rem;
      padding: 0.2rem 0.7rem;
      border: 1px solid var(--control-border, var(--border));
      border-radius: var(--radius-md, 8px);
      background: var(--control-bg, var(--surface-secondary));
      color: var(--accent);
      font-size: var(--font-size-sm, 0.84rem);
      font-weight: 600;
      text-decoration: none;
      transition: border-color 0.15s ease, background-color 0.15s ease, color 0.15s ease;
    }

    .runtime-link:hover {
      border-color: color-mix(in srgb, var(--accent) 45%, var(--border));
      background: color-mix(in srgb, var(--accent) 10%, transparent);
      color: var(--text-primary);
    }

    .runtime-ambient {
      display: grid;
      min-width: 0;
      gap: 0.65rem;
      padding-left: var(--space-4, 1.15rem);
      border-left: 1px solid var(--border);
    }

    .runtime-ambient-meta {
      display: flex;
      flex-wrap: wrap;
      gap: 0.35rem 1rem;
      color: var(--text-muted);
      font-size: var(--font-size-xs, 0.75rem);
    }

    .runtime-quota-list {
      display: grid;
      gap: 0.65rem;
    }

    .runtime-quota-head {
      display: flex;
      justify-content: space-between;
      gap: 0.75rem;
      color: var(--text-primary);
      font-size: var(--font-size-sm, 0.88rem);
    }

    .runtime-quota-head span {
      color: var(--text-muted);
      font-weight: 400;
    }

    .runtime-quota-track {
      height: 0.5rem;
      margin-top: 0.35rem;
      overflow: hidden;
      border-radius: 999px;
      background: var(--surface-hover);
    }

    .runtime-quota-fill {
      display: block;
      height: 100%;
      border-radius: inherit;
      background: var(--accent);
    }

    .runtime-quota-fill[data-level='medium'] { background: #ca8a04; }
    .runtime-quota-fill[data-level='high'] { background: #eab308; }

    .runtime-quota p {
      margin: 0.25rem 0 0;
      color: var(--text-muted);
      font-size: var(--font-size-xs, 0.75rem);
    }

    .runtime-token-summary {
      display: flex;
      flex-wrap: wrap;
      justify-content: space-between;
      gap: 0.5rem 1rem;
      padding-top: 0.45rem;
      border-top: 1px solid var(--border);
      color: var(--text-muted);
      font-size: var(--font-size-sm, 0.82rem);
    }

    .runtime-token-summary strong {
      color: var(--text-primary);
      font-weight: 600;
    }

    .runtime-ambient-loading {
      margin: 0;
      color: var(--text-muted);
      font-size: var(--font-size-sm, 0.9rem);
    }

    .runtime-status-message {
      margin: 0;
      color: var(--text-muted);
    }

    .runtime-status-message.is-error {
      color: var(--error, #f85149);
    }

    .runtime-error-panel {
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      gap: 0.75rem;
    }

    @media (max-width: 720px) {
      .runtime-card,
      .runtime-card:not(.has-usage) {
        grid-template-columns: 1fr;
      }

      .runtime-ambient {
        padding-left: 0;
        padding-top: var(--space-3, 0.85rem);
        border-left: 0;
        border-top: 1px solid var(--border);
      }
    }
  `,
})
export class RuntimeStatusComponent implements OnInit {
  private readonly http = inject(HttpClient);
  readonly runtimes = signal<readonly RuntimeConnectionStatus[]>([]);
  readonly loading = signal(true);
  readonly error = signal<string | null>(null);
  readonly ambientLoading = signal(true);
  readonly ambientFeatureEnabled = signal(false);
  readonly ambientUsage = signal<AmbientUsageResponse | null>(null);

  ngOnInit(): void {
    this.load();
  }

  load(): void {
    this.loading.set(true);
    this.error.set(null);
    this.ambientLoading.set(true);
    this.http.get<readonly RuntimeConnectionStatus[]>('/api/runtime-status').subscribe({
      next: (runtimes) => {
        this.runtimes.set(runtimes);
        this.loading.set(false);
      },
      error: () => {
        this.error.set('Runtime status could not be loaded.');
        this.loading.set(false);
      },
    });
    this.http.get<AmbientUsageResponse>('/api/metrics/ambient-usage').subscribe({
      next: (usage) => {
        this.ambientFeatureEnabled.set(usage.enabled);
        this.ambientUsage.set(usage.enabled ? usage : null);
        this.ambientLoading.set(false);
      },
      error: () => {
        this.ambientLoading.set(false);
      },
    });
  }

  ambientProvider(runtimeId: string): AmbientProviderReport | null {
    const id =
      runtimeId === 'claude'
        ? 'claude_code'
        : runtimeId === 'codex'
          ? 'codex'
          : runtimeId === 'antigravity'
            ? 'antigravity'
            : null;
    if (!id) {
      return null;
    }
    const provider = this.ambientUsage()?.providers.find((entry) => entry.id === id) ?? null;
    if (!provider) {
      return null;
    }
    if (provider.rate_limits.length === 0 && !(provider.tokens.total_tokens > 0)) {
      return null;
    }
    return provider;
  }

  remainingQuotaPercent(usedPercent: number): number {
    return Number.isFinite(usedPercent) ? Math.max(0, Math.min(100, 100 - usedPercent)) : 0;
  }

  formatQuotaPercent(value: number): string {
    return Number.isFinite(value) ? `${Math.round(value)}%` : '--';
  }

  quotaLevel(percent: number): 'low' | 'medium' | 'high' {
    if (!Number.isFinite(percent) || percent < 50) return 'low';
    if (percent < 75) return 'medium';
    return 'high';
  }

  formatResetsIn(seconds: number | null | undefined): string {
    if (seconds == null || !Number.isFinite(seconds) || seconds <= 0) return '';
    const total = Math.round(seconds);
    const days = Math.floor(total / 86400);
    const hours = Math.floor((total % 86400) / 3600);
    const minutes = Math.floor((total % 3600) / 60);
    if (days > 0) return `in ${days}d ${hours}h`;
    if (hours > 0) return `in ${hours}h ${minutes}m`;
    return `in ${minutes}m`;
  }

  formatAmbientUpdated(iso: string): string {
    const timestamp = Date.parse(iso);
    if (Number.isNaN(timestamp)) return '--';
    const delta = Math.max(0, Math.round((Date.now() - timestamp) / 1000));
    if (delta < 90) return 'just now';
    if (delta < 3600) return `${Math.round(delta / 60)}m ago`;
    if (delta < 86400) return `${Math.round(delta / 3600)}h ago`;
    return new Date(timestamp).toLocaleString();
  }

  formatCompact(value: number): string {
    if (!Number.isFinite(value)) return '--';
    if (Math.abs(value) >= 1_000_000_000) return `${(value / 1_000_000_000).toFixed(1)}B`;
    if (Math.abs(value) >= 1_000_000) return `${(value / 1_000_000).toFixed(1)}M`;
    if (Math.abs(value) >= 1_000) return `${(value / 1_000).toFixed(1)}K`;
    return `${Math.round(value)}`;
  }

  formatNumber(value: number): string {
    return Number.isFinite(value) ? value.toLocaleString() : '--';
  }

  stateLabel(state: RuntimeConnectionState): string {
    switch (state) {
      case 'connected':
        return 'Connected';
      case 'not_installed':
        return 'Not installed';
      default:
        return 'Not connected';
    }
  }
}
