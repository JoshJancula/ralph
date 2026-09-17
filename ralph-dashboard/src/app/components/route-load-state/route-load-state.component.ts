import { CommonModule } from '@angular/common';
import { ChangeDetectionStrategy, Component, input, output } from '@angular/core';
import { ErrorModalComponent } from '../error-modal/error-modal.component';

/**
 * Route-level loading skeleton + scoped error/retry.
 * Skeletons preserve layout height without inventing fake data rows.
 * When `errorDetail` is set, the shared error panel is embedded inline
 * (better than an overlay when a page has several independent loads).
 */
@Component({
  selector: 'ralph-route-load-state',
  standalone: true,
  imports: [CommonModule, ErrorModalComponent],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    @if (loading()) {
      <div
        class="route-skeleton"
        data-testid="route-loading-skeleton"
        aria-hidden="true"
        aria-busy="true"
      >
        @for (row of rows; track row) {
          <div class="route-skeleton-row" [style.--skel-cols]="columns()"></div>
        }
      </div>
      <div class="sr-only route-live-region" aria-live="polite" aria-atomic="true">Loading</div>
    } @else if (errorDetail() || error()) {
      <div class="route-error" role="alert" aria-live="assertive" data-testid="route-error">
        @if (errorDetail(); as detail) {
          <ralph-error-modal
            class="is-embedded"
            [error]="detail"
            [embedded]="true"
            [showHeader]="false"
          />
        } @else {
          <p class="route-error-message">{{ error() }}</p>
        }
        <button type="button" class="route-retry touch-target" data-testid="route-retry" (click)="retry.emit()">
          Retry
        </button>
      </div>
    }
  `,
  styles: `
    :host {
      display: block;
    }

    .route-skeleton {
      display: flex;
      flex-direction: column;
      gap: 0.65rem;
      padding: 0.5rem 0;
      min-height: 10rem;
    }

    .route-skeleton-row {
      display: grid;
      grid-template-columns: repeat(var(--skel-cols, 4), minmax(0, 1fr));
      gap: 0.75rem;
      height: 2.25rem;
    }

    .route-skeleton-row::before,
    .route-skeleton-row::after {
      content: '';
      display: block;
      height: 100%;
      border-radius: 4px;
      background: linear-gradient(
        90deg,
        var(--surface-muted, #101620) 0%,
        var(--surface-hover, rgba(255, 255, 255, 0.06)) 50%,
        var(--surface-muted, #101620) 100%
      );
      background-size: 200% 100%;
      animation: route-skel-pulse 1.4s ease infinite;
      grid-column: span 1;
    }

    .route-skeleton-row::before {
      grid-column: 1 / span 2;
    }

    .route-skeleton-row::after {
      grid-column: 3 / -1;
      opacity: 0.7;
    }

    @keyframes route-skel-pulse {
      0% {
        background-position: 100% 0;
      }
      100% {
        background-position: -100% 0;
      }
    }

    .route-error {
      display: flex;
      flex-direction: column;
      align-items: stretch;
      gap: 0.75rem;
      padding: 1rem;
      border: 1px solid var(--error, #f85149);
      border-radius: 6px;
      background: rgba(248, 81, 73, 0.08);
      color: var(--error, #f85149);
    }

    .route-error-message {
      margin: 0;
      font-size: 0.95rem;
    }

    .route-retry {
      align-self: flex-start;
      border: 1px solid var(--border, #30363d);
      border-radius: 4px;
      background: var(--surface-secondary, #0d1117);
      color: var(--text-primary, #e6edf3);
      padding: 0.4rem 0.85rem;
      cursor: pointer;
      font-size: 0.875rem;
      min-height: var(--touch-target-min, 44px);
    }

    .route-retry:hover {
      background: var(--surface-hover, rgba(255, 255, 255, 0.04));
    }

    .route-retry:focus-visible {
      outline: var(--focus-ring-width, 2px) solid var(--focus-ring-color, var(--accent));
      outline-offset: var(--focus-ring-offset, 2px);
    }
  `,
})
export class RouteLoadStateComponent {
  readonly loading = input(false);
  /** Short fallback message when `errorDetail` is not provided. */
  readonly error = input<string | null>(null);
  /** Raw failure payload for the embedded error panel. */
  readonly errorDetail = input<unknown>(null);
  readonly columns = input(4);
  readonly rowCount = input(6);
  readonly retry = output<void>();

  get rows(): number[] {
    const count = Math.max(1, Math.min(this.rowCount(), 12));
    return Array.from({ length: count }, (_, i) => i);
  }
}
