import { CommonModule } from '@angular/common';
import { Component, Input, inject, signal } from '@angular/core';
import { ApiService, FileChunk } from '../../services/api.service';
import { NavService } from '../../services/nav.service';
import { markdownToHtml } from '../../utils/markdown-to-html';

@Component({
  selector: 'app-file-viewer',
  standalone: true,
  imports: [CommonModule],
  templateUrl: './file-viewer.component.html',
  styleUrls: ['./file-viewer.component.scss'],
})
export class FileViewerComponent {
  private readonly api = inject(ApiService);
  private readonly nav = inject(NavService);

  rootSignal = signal<string>('');
  filePathSignal = signal<string>('');
  content = signal<string>('');
  loading = signal<boolean>(false);
  error = signal<string | null>(null);
  isRendered = signal<boolean>(true);

  @Input() set root(value: string) {
    this.rootSignal.set(value);
    this.loadFile(value, this.filePathSignal());
  }

  @Input() set filePath(value: string) {
    this.filePathSignal.set(value);
    this.loadFile(this.rootSignal(), value);
  }

  loadFile(root: string, filePath: string): void {
    if (!root || !filePath) return;

    this.loading.set(true);
    this.error.set(null);

    this.api.fetchFile(root, filePath).subscribe({
      next: (chunk) => {
        this.content.set(chunk.content);
        this.loading.set(false);
      },
      error: () => {
        this.error.set('Failed to load file');
        this.loading.set(false);
      },
    });
  }

  toggleView(): void {
    this.isRendered.update((val) => !val);
  }

  isMarkdown(): boolean {
    const path = this.filePathSignal();
    return path.endsWith('.md') || path.endsWith('.mdc');
  }

  isJson(): boolean {
    const path = this.filePathSignal();
    return path.endsWith('.json') || path.endsWith('.orch.json');
  }

  formatHtml(): string {
    return markdownToHtml(this.content());
  }

  formatJson(): string {
    try {
      return JSON.stringify(JSON.parse(this.content()), null, 2);
    } catch {
      return this.content();
    }
  }

  isPlainText(): boolean {
    return !this.isMarkdown() && !this.isJson();
  }

  get planDirectory(): string | null {
    const path = this.filePathSignal();
    if (!path) return null;
    const parts = path.split('/').filter(Boolean);
    return parts.length > 0 ? parts[0] : null;
  }

  get showViewLogs(): boolean {
    const root = this.rootSignal();
    return (root === 'plans' || root === 'logs') && this.isMarkdown();
  }

  viewLogs(): void {
    const dir = this.planDirectory;
    if (!dir) return;
    this.nav.navigate('logs', dir + '/', null as any);
  }

  get runSnippet(): string | null {
    const root = this.rootSignal();
    const path = this.filePathSignal();
    const fileName = path.split('/').filter(Boolean).pop() ?? '';
    if (!fileName) return null;
    if ((root === 'plans' || root === 'logs') && path.endsWith('.md')) {
      return `bash $PWD/.ralph/run-plan.sh --plan ${fileName}`;
    }
    if (root === 'orchestration-plans' && path.endsWith('.orch.json')) {
      return `bash $PWD/.ralph/run-orchestration.sh --plan ${fileName}`;
    }
    return null;
  }
}
