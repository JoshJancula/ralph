import { HttpClient } from '@angular/common/http';
import { Injectable, inject } from '@angular/core';
import { Observable } from 'rxjs';

export interface Root {
  key: string;
  label: string;
  exists: boolean;
}

export interface Listing {
  root: string;
  path: string;
  parent: string | null;
  entries: ListingEntry[];
}

export interface ListingEntry {
  name: string;
  path: string;
  type: 'file' | 'dir';
  size: number;
  mtime: number;
}

export interface FileChunk {
  content: string;
  size: number;
  offset: number;
  nextOffset: number;
}

export type TemplateName = 'plan' | 'orchestration';

export interface Template {
  name: TemplateName;
  content: string;
}

export interface WorkspaceInfo {
  root: string;
}

@Injectable({
  providedIn: 'root',
})
export class ApiService {
  private readonly http = inject(HttpClient);

  fetchWorkspace(): Observable<WorkspaceInfo> {
    return this.http.get<WorkspaceInfo>('/api/workspace');
  }

  fetchRoots(): Observable<Root[]> {
    return this.http.get<Root[]>('/api/roots');
  }

  fetchListing(root: string, path: string): Observable<Listing> {
    const params = { root, path };
    return this.http.get<Listing>('/api/list', { params });
  }

  fetchFile(root: string, filePath: string, offset = 0): Observable<FileChunk> {
    const params = { root, path: filePath, offset: offset.toString() };
    return this.http.get<FileChunk>('/api/file', { params });
  }

  fetchTemplate(name: TemplateName): Observable<Template> {
    const params = { name };
    return this.http.get<Template>('/api/template', { params });
  }
}
