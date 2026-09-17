import { Injectable, OnDestroy, inject, isDevMode } from '@angular/core';
import { NavigationEnd, NavigationStart, Router } from '@angular/router';
import { filter, Subscription } from 'rxjs';
import { markPerf, measurePerf, setPerfDiagnosticsEnabled } from '../utils/perf-diagnostics';
import { NavService } from './nav.service';

/**
 * Development-only navigation timing. Marks nav start/usable without
 * capturing workspace paths or file contents.
 */
@Injectable({ providedIn: 'root' })
export class NavPerfService implements OnDestroy {
  private readonly router = inject(Router);
  private readonly nav = inject(NavService);
  private readonly subs = new Subscription();
  private section = 'unknown';

  constructor() {
    const enabled = isDevMode();
    setPerfDiagnosticsEnabled(enabled);
    if (!enabled) {
      return;
    }

    this.subs.add(
      this.router.events.pipe(filter((e): e is NavigationStart => e instanceof NavigationStart)).subscribe(() => {
        this.section = this.nav.activeSection();
        markPerf('ralph-nav-start', { section: this.section });
      }),
    );

    this.subs.add(
      this.router.events.pipe(filter((e): e is NavigationEnd => e instanceof NavigationEnd)).subscribe(() => {
        this.section = this.nav.activeSection();
        markPerf('ralph-nav-usable', { section: this.section });
        measurePerf('ralph-nav-usable', 'ralph-nav-start', 'ralph-nav-usable', this.section);
      }),
    );
  }

  ngOnDestroy(): void {
    this.subs.unsubscribe();
  }
}
