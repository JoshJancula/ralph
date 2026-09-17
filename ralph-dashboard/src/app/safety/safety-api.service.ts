import { HttpClient } from '@angular/common/http';
import { Injectable, inject } from '@angular/core';
import { Observable } from 'rxjs';
import type {
  SafetyCheckCommand,
  SafetyCheckResult,
  SafetyConfigResponse,
  SafetyStatus,
  UpdateSafetyConfigCommand,
  UpdateSafetyConfigResponse,
} from './safety.types';

/** Thin Observable HTTP layer over the safety-api.ts server routes. */
@Injectable({ providedIn: 'root' })
export class SafetyApi {
  private readonly http = inject(HttpClient);

  private paramsWithWorkspace(workspaceRoot?: string): Record<string, string> {
    return workspaceRoot ? { workspaceRoot } : {};
  }

  /** GET /api/safety/status */
  fetchStatus(workspaceRoot?: string): Observable<SafetyStatus> {
    return this.http.get<SafetyStatus>('/api/safety/status', {
      params: this.paramsWithWorkspace(workspaceRoot),
    });
  }

  /** GET /api/safety/config */
  fetchConfig(workspaceRoot?: string): Observable<SafetyConfigResponse> {
    return this.http.get<SafetyConfigResponse>('/api/safety/config', {
      params: this.paramsWithWorkspace(workspaceRoot),
    });
  }

  /** POST /api/safety/check — classifies command text only; never executes it. */
  checkCommand(command: SafetyCheckCommand, workspaceRoot?: string): Observable<SafetyCheckResult> {
    return this.http.post<SafetyCheckResult>('/api/safety/check', command, {
      params: this.paramsWithWorkspace(workspaceRoot),
    });
  }

  /** PUT /api/safety/config — rules-only update with sha256 concurrency. */
  updateConfig(command: UpdateSafetyConfigCommand, workspaceRoot?: string): Observable<UpdateSafetyConfigResponse> {
    return this.http.put<UpdateSafetyConfigResponse>('/api/safety/config', command, {
      params: this.paramsWithWorkspace(workspaceRoot),
    });
  }
}
