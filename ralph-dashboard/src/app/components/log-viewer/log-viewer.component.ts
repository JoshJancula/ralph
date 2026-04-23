import { Component, Input, OnInit, OnChanges, OnDestroy, SimpleChanges, ElementRef, ViewChild, ChangeDetectorRef, computed, inject, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { IonSpinner, IonBadge, IonSearchbar } from '@ionic/angular/standalone';
import { ApiService } from '../../services/api.service';
import { NavService } from '../../services/nav.service';
import { Subscription } from 'rxjs';
import { markdownToHtml } from '../../utils/markdown-to-html';

interface LogEntry {
  content: string;
  offset: number;
  nextOffset: number;
}

@Component({
  selector: 'ralph-log-viewer',
  standalone: true,
  imports: [CommonModule, FormsModule, IonSpinner, IonBadge, IonSearchbar],
  templateUrl: './log-viewer.component.html',
  styleUrls: ['./log-viewer.component.scss']
})
export class LogViewerComponent implements OnInit, OnChanges, OnDestroy {
  @Input() root: string = '';
  @Input() filePath: string = '';

  @ViewChild('logContent', { static: false }) logContentElement?: ElementRef<HTMLPreElement>;
  @ViewChild('prettyContent', { static: false }) prettyContentElement?: ElementRef<HTMLDivElement>;

  prettyMode = false;
  searchQuery: string = '';
  filteredLines: string[] = [];
  matchLineIndices: number[] = [];
  currentMatchIndex: number = -1;
  nextOffset: number = 0;
  isTailing: boolean = false;
  isLoading: boolean = false;
  error: string | null = null;
  private tailInterval: number | null = null;
  private subscription: Subscription = new Subscription();
  private readonly nav = inject(NavService);
  private readonly contentSignal = signal('');
  private readonly prettyHtmlSignal = computed(() => markdownToHtml(this.contentSignal()));
  waitingForOutput: boolean = false;

  constructor(private apiService: ApiService, private cdr: ChangeDetectorRef) {}

  get content(): string {
    return this.contentSignal();
  }

  set content(value: string) {
    this.contentSignal.set(value);
  }

  ngOnInit(): void {
    this.loadFile(0);
  }

  ngOnChanges(changes: SimpleChanges): void {
    if ((changes['root'] || changes['filePath']) && this.root && this.filePath) {
      this.stopTailing();
      this.content = '';
      this.searchQuery = '';
      this.nextOffset = 0;
      this.loadFile(0);
    }
  }

  ngOnDestroy(): void {
    this.stopTailing();
    this.subscription.unsubscribe();
  }

  loadFile(offset: number): void {
    if (!this.root || !this.filePath) {
      return;
    }
    this.isLoading = true;
    this.error = null;
    this.cdr.markForCheck();
    this.subscription.add(
      this.apiService.fetchFile(this.root, this.filePath, offset).subscribe({
        next: (response) => {
          this.content = response.content;
          this.nextOffset = response.nextOffset;
          this.applySearch();
          this.isLoading = false;
          this.cdr.markForCheck();
        },
        error: () => {
          this.error = 'Failed to load log file';
          this.isLoading = false;
          this.cdr.markForCheck();
        }
      })
    );
  }

  startTailing(): void {
    if (this.isTailing) return;
    if (this.tailInterval !== null) {
      clearInterval(this.tailInterval);
      this.tailInterval = null;
    }
    this.isTailing = true;
    this.waitingForOutput = true;
    // Scroll to bottom immediately when starting tail
    this.cdr.detectChanges();
    setTimeout(() => this.scrollToBottom(), 0);
    this.tailInterval = window.setInterval(() => {
      this.fetchNewContent();
    }, 2000);
  }

  trackByLine(index: number, _line: string): number {
    return index;
  }

  stopTailing(): void {
    if (this.tailInterval !== null) {
      clearInterval(this.tailInterval);
      this.tailInterval = null;
    }
    this.isTailing = false;
  }

  fetchNewContent(forceScroll = false): void {
    if (!this.root || !this.filePath) return;
    this.subscription.add(
      this.apiService.fetchFile(this.root, this.filePath, this.nextOffset).subscribe({
        next: (response) => {
          const hasContent = Boolean(response.content);
          if (hasContent) {
            this.content += response.content;
            this.applySearch();
            this.waitingForOutput = false;
          }
          this.nextOffset = response.nextOffset;
          if (forceScroll) {
            this.cdr.detectChanges();
            setTimeout(() => this.scrollToBottom(), 0);
          } else {
            this.autoScroll();
          }
          this.cdr.markForCheck();
        },
        error: () => {
          this.error = 'Failed to fetch new log content';
          this.cdr.markForCheck();
        }
      })
    );
  }

  handleSearchInput(query: string): void {
    this.searchQuery = query;
    this.applySearch();
    this.cdr.markForCheck();
  }

  togglePrettyMode(): void {
    this.prettyMode = !this.prettyMode;
    this.cdr.markForCheck();
  }

  applySearch(): void {
    if (!this.searchQuery.trim()) {
      this.filteredLines = this.content.split('\n');
      this.matchLineIndices = [];
      this.currentMatchIndex = -1;
    } else {
      const searchTerm = this.searchQuery.toLowerCase();
      const indices: number[] = [];
      this.filteredLines = this.content.split('\n').map((line, i) => {
        const lowerLine = line.toLowerCase();
        const index = lowerLine.indexOf(searchTerm);
        if (index === -1) return line;
        indices.push(i);
        const matchLength = this.searchQuery.length;
        const beforeMatch = line.slice(0, index);
        const match = line.slice(index, index + matchLength);
        const afterMatch = line.slice(index + matchLength);
        return `${beforeMatch}<mark>${match}</mark>${afterMatch}`;
      });
      this.matchLineIndices = indices;
      this.currentMatchIndex = indices.length > 0 ? 0 : -1;
      if (this.currentMatchIndex >= 0) {
        setTimeout(() => this.scrollToCurrentMatch(), 50);
      }
    }
    this.cdr.markForCheck();
  }

  get filteredPrettyHtml(): string {
    if (!this.searchQuery.trim()) {
      return this.prettyHtml;
    }
    // In pretty mode, we highlight matches in the HTML content
    const searchTerm = this.searchQuery;
    const lowerSearch = searchTerm.toLowerCase();
    let html = this.prettyHtml;
    
    // Find all text nodes in the HTML and wrap matches in mark tags
    // We use a regex to match the search term case-insensitively
    const regex = new RegExp(`(${this.escapeRegex(searchTerm)})`, 'gi');
    
    // Only highlight in text content, not in HTML tags
    // Split by HTML tags and only apply highlighting to text parts
    const parts = html.split(/(<[^>]+>)/g);
    return parts.map((part, index) => {
      // Even indices are text, odd indices are HTML tags
      if (index % 2 === 0) {
        return part.replace(regex, '<mark>$1</mark>');
      }
      return part;
    }).join('');
  }

  private escapeRegex(str: string): string {
    return str.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }

  get matchCount(): string {
    if (!this.searchQuery.trim() || this.matchLineIndices.length === 0) return '';
    return `${this.currentMatchIndex + 1} of ${this.matchLineIndices.length}`;
  }

  get prettyHtml(): string {
    return this.prettyHtmlSignal();
  }

  nextMatch(): void {
    if (this.matchLineIndices.length === 0) return;
    this.currentMatchIndex = (this.currentMatchIndex + 1) % this.matchLineIndices.length;
    this.scrollToCurrentMatch();
    this.cdr.markForCheck();
  }

  prevMatch(): void {
    if (this.matchLineIndices.length === 0) return;
    this.currentMatchIndex =
      (this.currentMatchIndex - 1 + this.matchLineIndices.length) % this.matchLineIndices.length;
    this.scrollToCurrentMatch();
    this.cdr.markForCheck();
  }

  private scrollToCurrentMatch(): void {
    const lineIndex = this.matchLineIndices[this.currentMatchIndex];
    if (lineIndex === undefined) return;
    const el = document.getElementById(`log-line-${lineIndex}`);
    el?.scrollIntoView({ block: 'center', behavior: 'smooth' });
  }

  autoScroll(): void {
    if (this.prettyMode) {
      if (!this.prettyContentElement?.nativeElement) return;
      const element = this.prettyContentElement.nativeElement;
      const threshold = 100;
      const distanceFromBottom = element.scrollHeight - element.scrollTop - element.clientHeight;
      if (distanceFromBottom <= threshold) {
        element.scrollTop = element.scrollHeight;
      }
    } else {
      if (!this.logContentElement?.nativeElement) return;
      const element = this.logContentElement.nativeElement;
      const threshold = 100;
      const distanceFromBottom = element.scrollHeight - element.scrollTop - element.clientHeight;
      if (distanceFromBottom <= threshold) {
        element.scrollTop = element.scrollHeight;
      }
    }
  }

  private scrollToBottom(): void {
    if (this.prettyMode) {
      if (!this.prettyContentElement?.nativeElement) return;
      const element = this.prettyContentElement.nativeElement;
      element.scrollTop = element.scrollHeight;
    } else {
      if (!this.logContentElement?.nativeElement) return;
      const element = this.logContentElement.nativeElement;
      element.scrollTop = element.scrollHeight;
    }
  }

  goToLatest(): void {
    if (!this.root || !this.filePath) return;
    this.stopTailing();
    this.scrollToBottom();
    this.fetchNewContent(true);
  }

  onScroll(): void {
    const threshold = 100;
    if (this.prettyMode) {
      if (!this.prettyContentElement?.nativeElement) return;
      const element = this.prettyContentElement.nativeElement;
      const distanceFromBottom = element.scrollHeight - element.scrollTop - element.clientHeight;
      if (this.isTailing && distanceFromBottom <= threshold) {
        element.scrollTop = element.scrollHeight;
      }
    } else {
      if (!this.logContentElement?.nativeElement) return;
      const element = this.logContentElement.nativeElement;
      const distanceFromBottom = element.scrollHeight - element.scrollTop - element.clientHeight;
      if (this.isTailing && distanceFromBottom <= threshold) {
        element.scrollTop = element.scrollHeight;
      }
    }
  }

  get planDirectory(): string | null {
    if (!this.filePath) return null;
    const parts = this.filePath.split('/').filter(Boolean);
    if (parts.length < 1) return null;
    // The plan directory is the first segment (e.g. "PLAN9" in "PLAN9/run-xxx/output.log")
    return parts[0];
  }

  viewPlanFile(): void {
    const dir = this.planDirectory;
    if (!dir) return;
    this.nav.navigate('plans', dir, `${dir}.md`);
  }
}
