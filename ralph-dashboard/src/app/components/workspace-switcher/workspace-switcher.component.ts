import {
  Component,
  OnInit,
  OnDestroy,
  AfterViewInit,
  inject,
  signal,
  computed,
  HostListener,
  ElementRef,
  ViewChild,
  effect,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { IonIcon } from '@ionic/angular/standalone';
import { addIcons } from 'ionicons';
import { checkmark, chevronDown, pin, search } from 'ionicons/icons';
import { WorkspaceSelectorService, ProjectGroup, ProjectItem } from '../../services/workspace-selector.service';

interface DisplayProject extends ProjectItem {
  groupLabel: string;
  isDuplicate: boolean;
}

@Component({
  selector: 'app-workspace-switcher',
  standalone: true,
  imports: [CommonModule, FormsModule, IonIcon],
  templateUrl: './workspace-switcher.component.html',
  styleUrls: ['./workspace-switcher.component.scss'],
})
export class WorkspaceSwitcherComponent implements OnInit, AfterViewInit, OnDestroy {
  protected readonly selectorService = inject(WorkspaceSelectorService);
  private readonly hostElement = inject(ElementRef);

  @ViewChild('searchInput', { static: false }) searchInput!: ElementRef<HTMLInputElement>;
  @ViewChild('listContainer', { static: false }) listContainer!: ElementRef<HTMLElement>;
  @ViewChild('triggerButton', { static: false }) triggerButton!: ElementRef<HTMLButtonElement>;
  @ViewChild('dropdownPanel', { static: false }) dropdownPanel?: ElementRef<HTMLElement>;

  constructor() {
    addIcons({ checkmark, chevronDown, pin, search });
  }

  readonly isOpen = signal(false);
  readonly searchQuery = signal('');
  readonly selectedIndex = signal<number | null>(null);
  readonly hasDuplicateNames = computed(() => this.selectorService.getHasDuplicateNames());

  readonly displayName = computed(() => this.selectorService.displayName());
  readonly groupedProjects = computed(() => this.selectorService.groupedProjects());
  readonly shouldShow = computed(() => this.selectorService.shouldShowSwitcher());

  readonly filteredProjects = computed(() => {
    const query = this.searchQuery().toLowerCase().trim();
    const groups = this.groupedProjects();
    const hasDupes = this.hasDuplicateNames();

    if (!query) {
      return groups.map((group) => ({
        label: group.label,
        projects: group.projects.map((p) => ({
          ...p,
          groupLabel: group.label,
          isDuplicate: hasDupes && this.countDuplicates(p.label, groups) > 1,
        })),
      }));
    }

    return groups
      .map((group) => ({
        label: group.label,
        projects: group.projects
          .filter((p) => this.matchesQuery(p, query))
          .map((p) => ({
            ...p,
            groupLabel: group.label,
            isDuplicate: hasDupes && this.countDuplicates(p.label, groups) > 1,
          })),
      }))
      .filter((g) => g.projects.length > 0);
  });

  readonly flatProjects = computed(() => {
    return this.filteredProjects().flatMap((g) => g.projects);
  });

  private readonly onReposition = () => this.portalAndPositionDropdown();

  private setupOpenStateEffect = effect(() => {
    if (this.isOpen()) {
      this.selectedIndex.set(0);
      setTimeout(() => {
        this.portalAndPositionDropdown();
        this.searchInput?.nativeElement?.focus();
      }, 0);
    } else {
      this.selectedIndex.set(null);
      this.teardownPortaledDropdown();
    }
  });

  ngOnInit(): void {
    this.selectorService.loadWorkspaces();
  }

  ngAfterViewInit(): void {
    // Ionic's shadow toolbar-container uses overflow:hidden + contain:content,
    // which clips the menu and corrupts slotted control geometry on narrow viewports.
    const toolbar = this.hostElement.nativeElement.closest('ion-toolbar') as HTMLElement | null;
    const container = toolbar?.shadowRoot?.querySelector('.toolbar-container') as HTMLElement | null;
    if (container) {
      container.style.overflow = 'visible';
      container.style.contain = 'none';
    }
  }

  ngOnDestroy(): void {
    this.teardownPortaledDropdown();
  }

  @HostListener('document:click', ['$event'])
  onDocumentClick(event: MouseEvent): void {
    const target = event.target as HTMLElement;
    const inHost = this.hostElement.nativeElement.contains(target);
    const inDropdown = !!target.closest?.('.switcher-dropdown');
    if (!inHost && !inDropdown) {
      this.close();
    }
  }

  @HostListener('document:keydown', ['$event'])
  onDocumentKeyDown(event: KeyboardEvent): void {
    if (!this.isOpen()) {
      return;
    }
    if (event.key === 'Escape') {
      event.preventDefault();
      this.close({ restoreFocus: true });
    }
  }

  toggle(): void {
    if (this.isOpen()) {
      this.close({ restoreFocus: true });
    } else {
      this.isOpen.set(true);
    }
  }

  close(options: { restoreFocus?: boolean } = {}): void {
    const wasOpen = this.isOpen();
    this.isOpen.set(false);
    this.searchQuery.set('');
    if (wasOpen && options.restoreFocus) {
      setTimeout(() => {
        this.triggerButton?.nativeElement?.focus();
      }, 0);
    }
  }

  selectProject(project: DisplayProject): void {
    this.selectorService.selectWorkspace(project.projectRoot);
    this.close({ restoreFocus: true });
  }

  selectAllProjects(): void {
    this.selectorService.selectWorkspace(null);
    this.close({ restoreFocus: true });
  }

  /** Listbox index: 0 is All projects; project rows start at 1. */
  projectOptionIndex(groupIndex: number, itemIndex: number): number {
    const groups = this.filteredProjects();
    let index = 1;
    for (let g = 0; g < groupIndex; g++) {
      index += groups[g].projects.length;
    }
    return index + itemIndex;
  }

  togglePin(project: DisplayProject, event: Event): void {
    event.stopPropagation();
    this.selectorService.togglePinnedProject(project.projectRoot);
  }

  onSearchInput(value: string): void {
    this.searchQuery.set(value);
    this.selectedIndex.set(0);
  }

  onKeyDown(event: KeyboardEvent): void {
    const projects = this.flatProjects();
    const maxIndex = projects.length;
    const current = this.selectedIndex() ?? 0;

    switch (event.key) {
      case 'Escape':
        event.preventDefault();
        this.close({ restoreFocus: true });
        break;
      case 'ArrowDown':
        event.preventDefault();
        {
          const next = Math.min(current + 1, maxIndex);
          this.selectedIndex.set(next);
          this.scrollToSelected();
        }
        break;
      case 'ArrowUp':
        event.preventDefault();
        {
          const next = Math.max(current - 1, 0);
          this.selectedIndex.set(next);
          this.scrollToSelected();
        }
        break;
      case 'Enter':
        event.preventDefault();
        if (current === 0) {
          this.selectAllProjects();
        } else {
          const project = projects[current - 1];
          if (project) {
            this.selectProject(project);
          }
        }
        break;
      default:
        break;
    }
  }

  private scrollToSelected(): void {
    if (!this.listContainer) return;
    setTimeout(() => {
      const selected = this.listContainer?.nativeElement.querySelector('[data-selected="true"]');
      if (selected) {
        selected.scrollIntoView({ block: 'nearest' });
      }
    }, 0);
  }

  /**
   * ion-toolbar uses contain:content and clips overflow, which breaks position:fixed
   * for descendants and can report bogus getBoundingClientRect values for slotted
   * light-DOM nodes. Portal the panel to document.body and anchor it to the header.
   */
  private portalAndPositionDropdown(): void {
    const dropdown =
      this.dropdownPanel?.nativeElement ??
      (document.body.querySelector('.switcher-dropdown.is-portaled') as HTMLElement | null);
    if (!dropdown || !this.isOpen()) {
      return;
    }

    if (dropdown.parentElement !== document.body) {
      document.body.appendChild(dropdown);
    }
    dropdown.classList.add('is-portaled');

    const headerBottom =
      document.querySelector('ion-header')?.getBoundingClientRect().bottom ?? 56;
    const triggerRect = this.triggerButton?.nativeElement?.getBoundingClientRect();
    const narrow = window.matchMedia('(max-width: 991px)').matches;
    const triggerUsable =
      !!triggerRect &&
      triggerRect.height > 0 &&
      triggerRect.top >= 0 &&
      triggerRect.bottom <= window.innerHeight + 1;

    dropdown.style.position = 'fixed';
    dropdown.style.zIndex = '10000';
    dropdown.style.maxHeight = `min(70vh, ${Math.max(160, window.innerHeight - headerBottom - 16)}px)`;

    if (narrow || !triggerUsable) {
      dropdown.style.top = `${headerBottom + 6}px`;
      dropdown.style.left = '0.5rem';
      dropdown.style.right = '0.5rem';
      dropdown.style.width = 'auto';
    } else {
      dropdown.style.top = `${triggerRect!.bottom + 8}px`;
      dropdown.style.left = `${Math.max(8, triggerRect!.left)}px`;
      dropdown.style.width = `${Math.min(triggerRect!.width, window.innerWidth - 16)}px`;
      dropdown.style.right = 'auto';
    }

    window.addEventListener('resize', this.onReposition);
    window.addEventListener('orientationchange', this.onReposition);
  }

  private teardownPortaledDropdown(): void {
    window.removeEventListener('resize', this.onReposition);
    window.removeEventListener('orientationchange', this.onReposition);
    const dropdown =
      this.dropdownPanel?.nativeElement ??
      (document.body.querySelector('.switcher-dropdown.is-portaled') as HTMLElement | null);
    if (!dropdown) {
      return;
    }
    dropdown.classList.remove('is-portaled');
    dropdown.style.position = '';
    dropdown.style.top = '';
    dropdown.style.left = '';
    dropdown.style.right = '';
    dropdown.style.width = '';
    dropdown.style.maxHeight = '';
    dropdown.style.zIndex = '';
  }

  private matchesQuery(project: ProjectItem, query: string): boolean {
    return (
      project.label.toLowerCase().includes(query) ||
      project.projectRoot.toLowerCase().includes(query) ||
      project.parentPath.toLowerCase().includes(query)
    );
  }

  private countDuplicates(label: string, groups: ProjectGroup[]): number {
    let count = 0;
    for (const group of groups) {
      for (const p of group.projects) {
        if (p.label === label) {
          count++;
        }
      }
    }
    return count;
  }

  getProjectDisplayLabel(project: DisplayProject): string {
    const selected = this.selectorService.selectedWorkspacePath();
    if (project.projectRoot === selected) {
      return `${project.label} (current)`;
    }
    return project.label;
  }
}
