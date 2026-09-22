import { Injectable, inject, signal } from '@angular/core';
import { WorkflowsApi } from './workflows-api.service';
import type { DashboardCapabilities } from './workflow.types';

const DEFAULT_CAPABILITIES: DashboardCapabilities = {
  workflowWrites: false,
  workflowRuns: false,
  assistant: false,
  safetyWrites: false,
};

/**
 * Reads GET /api/capabilities so the client hides controls the server will
 * refuse (write-guard denies mutating routes when not loopback-bound).
 * Defaults closed until the first successful load.
 */
@Injectable({ providedIn: 'root' })
export class CapabilitiesService {
  private readonly api = inject(WorkflowsApi);

  readonly capabilities = signal<DashboardCapabilities>(DEFAULT_CAPABILITIES);
  readonly loaded = signal(false);

  private loadInflight = false;

  load(): void {
    if (this.loadInflight || this.loaded()) {
      return;
    }
    this.loadInflight = true;
    this.api.fetchCapabilities().subscribe({
      next: (capabilities) => {
        this.capabilities.set(capabilities);
        this.loaded.set(true);
        this.loadInflight = false;
      },
      error: () => {
        // Stay closed (all-false) on failure — refusing controls is the safe default.
        this.capabilities.set(DEFAULT_CAPABILITIES);
        this.loaded.set(true);
        this.loadInflight = false;
      },
    });
  }
}
