import { Injectable, inject } from '@angular/core';
import { Observable, catchError, map, of, switchMap } from 'rxjs';
import { ApiService, ListingEntry } from './api.service';

export interface LogResolutionTarget {
  directory: string | null;
  file: string | null;
}

@Injectable({
  providedIn: 'root',
})
export class PlanLogResolutionService {
  private readonly apiService = inject(ApiService);

  resolvePlanDirectory(path: string | null | undefined): string | null {
    if (!path) {
      return null;
    }

    const parts = path.split('/').filter(Boolean);
    if (parts.length === 0) {
      return null;
    }

    const name = parts[0];
    if (parts.length === 1) {
      const dotIdx = name.lastIndexOf('.');
      return dotIdx > 0 ? name.substring(0, dotIdx) : name;
    }

    return name;
  }

  resolveLatestLogTarget(planDirectory: string | null | undefined): Observable<LogResolutionTarget> {
    if (!planDirectory) {
      return of({ directory: null, file: null });
    }

    return this.apiService.fetchListing('logs', planDirectory).pipe(
      switchMap((listing) => this.resolveFromListing(listing.entries, planDirectory)),
      catchError(() => of({ directory: planDirectory, file: null })),
    );
  }

  private resolveFromListing(entries: ListingEntry[], prefix: string): Observable<LogResolutionTarget> {
    const logFile = this.findMostRecentLog(entries, prefix);
    if (logFile) {
      return of({ directory: null, file: logFile });
    }

    // Look one level deeper in subdirectories (e.g. run-xxx/output.log)
    const subdirs = entries
      .filter((entry) => entry.type === 'dir')
      .sort((a, b) => b.mtime - a.mtime);

    if (subdirs.length === 0) {
      return of({ directory: prefix, file: null });
    }

    const subdirPath = `${prefix}/${subdirs[0].name}`;
    return this.apiService.fetchListing('logs', subdirPath).pipe(
      map((sub) => {
        const found = this.findMostRecentLog(sub.entries, subdirPath);
        return found ? { directory: null, file: found } : { directory: null, file: null };
      }),
      catchError(() => of({ directory: prefix, file: null })),
    );
  }

  private findMostRecentLog(entries: ListingEntry[], prefix: string): string | null {
    const logs = entries
      .filter((entry) => entry.type === 'file' && entry.name.endsWith('.log'))
      .sort((a, b) => b.mtime - a.mtime);

    return logs.length > 0 ? `${prefix}/${logs[0].name}` : null;
  }
}
