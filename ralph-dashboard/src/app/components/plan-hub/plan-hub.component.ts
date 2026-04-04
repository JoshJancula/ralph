import { Component, OnInit, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { ActivatedRoute, Router } from '@angular/router';
import { ApiService, ListingEntry } from '../../services/api.service';
import { NavService } from '../../services/nav.service';

interface PlanItem {
  name: string;
  path: string;
  mtime: number;
  hasLogs: boolean;
}

@Component({
  selector: 'ralph-plan-hub',
  standalone: true,
  imports: [CommonModule],
  template: `
    <div class="plan-hub">
      <div class="header">
        <h2>Plans</h2>
      </div>
      @if (error) {
        <div class="error">{{ error }}</div>
      } @else if (loading) {
        <div class="loading">Loading plans...</div>
      } @else if (items.length === 0) {
        <div class="empty-state">No plan directories found</div>
      } @else {
        <div class="plan-list">
          @for (item of items; track item.name) {
            <div class="plan-card">
              <div class="plan-header">
                <span class="plan-name">{{ item.name }}</span>
                <span class="plan-date">{{ item.mtime | date: 'yyyy-MM-dd HH:mm' }}</span>
              </div>
              <div class="plan-actions">
                <button class="btn-primary" (click)="openPlan(item)">Open Plan</button>
                @if (item.hasLogs) {
                  <button class="btn-secondary" (click)="viewLogs(item)">View Logs</button>
                }
              </div>
            </div>
          }
        </div>
      }
    </div>
  `,
  styles: `
    .plan-hub {
      padding: 2rem;
      height: 100%;
      overflow-y: auto;
    }
    .header {
      margin-bottom: 2rem;
    }
    .header h2 {
      margin: 0;
      font-size: 1.75rem;
      font-weight: 600;
    }
    .error {
      color: var(--danger);
      padding: 1rem;
      background: rgba(255, 0, 0, 0.1);
      border-radius: 4px;
    }
    .loading {
      color: var(--text-muted);
      padding: 1rem;
    }
      .empty-state {
        color: var(--text-muted);
        padding: 3rem 2rem;
        text-align: center;
        background: var(--surface);
        border-radius: 8px;
        border: 1px solid var(--border);
      }
    .plan-list {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
      gap: 1rem;
    }
    .plan-card {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 1rem;
    }
    .plan-header {
      margin-bottom: 1rem;
    }
    .plan-name {
      font-size: 1.1rem;
      font-weight: 500;
      font-family: var(--monospace-font);
      display: block;
      margin-bottom: 0.25rem;
    }
    .plan-date {
      color: var(--text-muted);
      font-size: 0.8rem;
    }
    .plan-actions {
      display: flex;
      gap: 0.5rem;
    }
    button {
      padding: 0.5rem 1rem;
      border: none;
      border-radius: 4px;
      cursor: pointer;
      font-size: 0.85rem;
      transition: background 0.2s ease;
    }
    .btn-primary {
      background: var(--accent);
      color: #fff;
    }
    .btn-primary:hover {
      background: var(--accent-hover);
    }
    .btn-secondary {
      background: var(--surface-hover);
      color: var(--text-primary);
      border: 1px solid var(--border);
    }
    .btn-secondary:hover {
      background: var(--border);
    }
  `,
})
export class PlanHubComponent implements OnInit {
  items: PlanItem[] = [];
  loading = false;
  error = '';

  private apiService = inject(ApiService);
  private navService = inject(NavService);
  private route = inject(ActivatedRoute);
  private router = inject(Router);

  ngOnInit(): void {
    this.fetchPlans();
    
    // Subscribe to route params to handle direct navigation
    this.route.params.subscribe(() => {
      this.navService.refresh();
    });
  }

  fetchPlans(): void {
    this.loading = true;
    this.error = '';
    
    // Fetch plan log directories
    this.apiService.fetchListing('logs', '').subscribe({
      next: (response) => {
        // Filter for directories (these are the plan folders)
        this.items = response.entries
          .filter((entry) => entry.type === 'dir')
          .map((entry) => ({
            name: entry.name,
            path: entry.path,
            mtime: entry.mtime,
            hasLogs: true, // Since we're now using logs dir for plans, all have logs
          }))
          .sort((a, b) => b.mtime - a.mtime);
        this.loading = false;
      },
      error: (err) => {
        this.error = err.error?.error || 'Failed to load plans';
        this.loading = false;
      },
    });
  }

  openPlan(item: PlanItem): void {
    const directory = item.path.replace(/\/$/, '');
    const planFile = `${directory}.md`;
    this.navService.navigate('plans', '', planFile);
  }

  viewLogs(item: PlanItem): void {
    const dir = item.path.replace(/\/$/, '');

    this.apiService.fetchListing('logs', dir).subscribe({
      next: (listing) => {
        const logFile = this.findMostRecentLog(listing.entries, dir);
        if (logFile) {
          this.navService.navigate('logs', null, logFile);
          return;
        }

        const subdirs = listing.entries
          .filter((e) => e.type === 'dir')
          .sort((a, b) => b.mtime - a.mtime);

        if (subdirs.length === 0) {
          this.navService.navigate('logs', dir, null);
          return;
        }

        const subdirPath = `${dir}/${subdirs[0].name}`;
        this.apiService.fetchListing('logs', subdirPath).subscribe({
          next: (sub) => {
            const found = this.findMostRecentLog(sub.entries, subdirPath);
            this.navService.navigate('logs', null, found ?? null);
          },
          error: () => this.navService.navigate('logs', dir, null),
        });
      },
      error: () => this.navService.navigate('logs', dir, null),
    });
  }

  private findMostRecentLog(entries: ListingEntry[], prefix: string): string | null {
    const logs = entries
      .filter((e) => e.type === 'file' && e.name.endsWith('.log'))
      .sort((a, b) => b.mtime - a.mtime);
    return logs.length > 0 ? `${prefix}/${logs[0].name}` : null;
  }
}
