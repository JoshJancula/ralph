import { Buffer } from 'node:buffer';
import { existsSync, readFileSync } from 'node:fs';

import { findDashboardRoots, findWorkspaceProjectRoot, getAllowedRoots, resolveRalphInstallRoot } from '../../src/paths';
import {
  handleFileRequest,
  handleListRequest,
  handleMetricsSummaryRequest,
  handleTemplateRequest,
  handleWorkspacesRequest,
} from '../../src/server/dashboard-api';

type Headers = Record<string, string>;
type QueryValue = string | string[] | undefined;

type RequestLike = {
  method: string;
  url: string;
  originalUrl: string;
  path: string;
  query: Record<string, QueryValue>;
  headers: Headers;
};

type ResponseResult = {
  status: number;
  body: unknown;
  text: string;
  headers: Headers;
};

function parseQuery(searchParams: URLSearchParams): Record<string, QueryValue> {
  const query: Record<string, QueryValue> = {};
  for (const [key, value] of searchParams.entries()) {
    const existing = query[key];
    if (existing === undefined) {
      query[key] = value;
    } else if (Array.isArray(existing)) {
      existing.push(value);
    } else {
      query[key] = [existing, value];
    }
  }
  return query;
}

function normalizeHeaderName(name: string): string {
  return name.toLowerCase();
}

function bodyToText(body: unknown): string {
  if (body === undefined || body === null) {
    return '';
  }
  if (typeof body === 'string') {
    return body;
  }
  if (Buffer.isBuffer(body)) {
    return body.toString('utf8');
  }
  return JSON.stringify(body);
}

class InMemoryResponse {
  statusCode = 200;
  body: unknown = undefined;
  text = '';
  headersSent = false;
  headers: Headers = {};

  status(code: number): this {
    this.statusCode = code;
    return this;
  }

  setHeader(name: string, value: string): this {
    this.headers[normalizeHeaderName(name)] = value;
    return this;
  }

  set(name: string, value: string): this {
    return this.setHeader(name, value);
  }

  getHeader(name: string): string | undefined {
    return this.headers[normalizeHeaderName(name)];
  }

  get(name: string): string | undefined {
    return this.getHeader(name);
  }

  json(body: unknown): this {
    this.setHeader('content-type', 'application/json; charset=utf-8');
    this.body = body;
    this.text = JSON.stringify(body);
    this.end();
    return this;
  }

  send(body: unknown): this {
    this.body = body;
    this.text = bodyToText(body);
    this.end();
    return this;
  }

  sendFile(
    filePath: string,
    optionsOrCallback?: unknown,
    callback?: (error?: { code?: string; message?: string; name?: string }) => void,
  ): this {
    const cb = typeof optionsOrCallback === 'function' ? optionsOrCallback : callback;
    try {
      const content = readFileSync(filePath);
      this.body = content;
      this.text = bodyToText(content);
      this.end();
      cb?.();
    } catch (error) {
      const err = error as NodeJS.ErrnoException;
      cb?.({
        code: err.code,
        message: err.message,
        name: err.name,
      });
      if (!this.headersSent) {
        this.status(err.code === 'ENOENT' ? 404 : 500);
        this.send(err.code === 'ENOENT' ? 'Not found' : 'Internal server error');
      }
    }
    return this;
  }

  end(body?: unknown): this {
    if (body !== undefined) {
      this.body = body;
      this.text = bodyToText(body);
    }
    this.headersSent = true;
    return this;
  }

  write(chunk: unknown): this {
    this.text += bodyToText(chunk);
    return this;
  }

  toResult(): ResponseResult {
    return {
      status: this.statusCode,
      body: this.body,
      text: this.text,
      headers: { ...this.headers },
    };
  }
}

export function createInMemoryRequester(_app: unknown) {
  return {
    get(path: string): Promise<ResponseResult> {
      return invoke('GET', path);
    },
  };
}

async function invoke(method: string, path: string): Promise<ResponseResult> {
  const parsed = new URL(path, 'http://localhost');
  const req: RequestLike = {
    method,
    url: `${parsed.pathname}${parsed.search}`,
    originalUrl: `${parsed.pathname}${parsed.search}`,
    path: parsed.pathname,
    query: parseQuery(parsed.searchParams),
    headers: {},
  };
  const res = new InMemoryResponse();

  switch (parsed.pathname) {
    case '/api/list':
      await handleListRequest(req as any, res as any);
      break;
    case '/api/file':
      await handleFileRequest(req as any, res as any);
      break;
    case '/api/template':
      await handleTemplateRequest(req as any, res as any);
      break;
    case '/api/metrics/summary':
      await handleMetricsSummaryRequest(req as any, res as any);
      break;
    case '/api/workspaces':
      await handleWorkspacesRequest(req as any, res as any);
      break;
    case '/api/workspace':
      res.json({ root: findWorkspaceProjectRoot() });
      break;
    case '/api/ralph-framework-root':
      res.json({ projectRoot: resolveRalphInstallRoot() });
      break;
    case '/api/roots': {
      const roots = getAllowedRoots(findDashboardRoots());
      res.json(
        Object.entries(roots).map(([key, config]) => ({
          key,
          label: config.label,
          exists: existsSync(config.basePath),
        })),
      );
      break;
    }
    default:
      throw new Error(`Unsupported in-memory request path: ${parsed.pathname}`);
  }

  return res.toResult();
}
