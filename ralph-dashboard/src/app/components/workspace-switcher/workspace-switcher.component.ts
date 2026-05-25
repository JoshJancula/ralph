import { Component, OnInit, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { WorkspaceSelectorService } from '../../services/workspace-selector.service';

@Component({
  selector: 'app-workspace-switcher',
  standalone: true,
  imports: [CommonModule],
  template: `
    @if (shouldShow()) {
      <div class="workspace-switcher">
        <label for="workspace-select">Workspace:</label>
        <select
          id="workspace-select"
          [value]="selectedPath() || 'all'"
          (change)="onWorkspaceChange($event)"
        >
          <option value="all">All workspaces</option>
          @for (ws of displayWorkspaces(); track ws.path) {
            <option [value]="ws.path" [disabled]="!ws.exists">
              {{ ws.display }}{{ !ws.exists ? ' (deleted)' : '' }}
            </option>
          }
        </select>
      </div>
    }
  `,
  styles: `
    .workspace-switcher {
      display: flex;
      align-items: center;
      gap: 0.5rem;
      padding: 0 0.5rem;
    }

    label {
      font-size: 0.9rem;
      color: var(--text-muted);
      white-space: nowrap;
    }

    select {
      padding: 0.35rem 0.5rem;
      border: 1px solid var(--border);
      border-radius: 4px;
      background: var(--surface);
      color: var(--text);
      font-size: 0.9rem;
      cursor: pointer;
    }

    select:hover {
      border-color: var(--primary);
    }

    select:focus {
      outline: none;
      border-color: var(--primary);
      box-shadow: 0 0 0 2px var(--primary-alpha);
    }

    option:disabled {
      color: var(--text-muted);
    }
  `,
})
export class WorkspaceSwitcherComponent implements OnInit {
  private readonly selectorService = inject(WorkspaceSelectorService);

  readonly shouldShow = () => this.selectorService.shouldShowSwitcher();
  readonly selectedPath = () => this.selectorService.selectedWorkspacePath();
  readonly displayWorkspaces = () => this.selectorService.displayWorkspaces();

  ngOnInit(): void {
    this.selectorService.loadWorkspaces();
  }

  onWorkspaceChange(event: Event): void {
    const value = (event.target as HTMLSelectElement).value;
    this.selectorService.selectWorkspace(value === 'all' ? null : value);
  }
}
