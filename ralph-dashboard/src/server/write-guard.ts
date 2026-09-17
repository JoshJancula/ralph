/**
 * Guard required on every non-GET route this plan adds. Refuses a request
 * unless: (1) the dashboard server itself is bound to a loopback host, (2)
 * the request's Host header names a loopback host on the server's own port,
 * and (3) an Origin header, when present, also names that host — this
 * combination blocks both plain cross-site requests and DNS-rebinding
 * attacks that would otherwise present a loopback Host header from a
 * non-loopback bind.
 *
 * Also enforces `application/json` content type and a body size cap on
 * every guarded route, parsing the body itself (no `express.json()`) so a
 * rejection is a plain, testable 403 rather than an Express error-handler
 * hop.
 */
import type { NextFunction, Request, RequestHandler, Response } from 'express';

const LOOPBACK_HOSTS: ReadonlySet<string> = new Set(['127.0.0.1', '::1', 'localhost']);
const DEFAULT_PORT = 8123;
const MAX_BODY_BYTES = 256 * 1024;

export function isLoopbackHost(host: string): boolean {
  return LOOPBACK_HOSTS.has(host.trim().toLowerCase());
}

export function configuredHost(): string {
  return (process.env['HOST'] ?? '127.0.0.1').trim();
}

export function configuredPort(): string {
  return String(process.env['PORT'] ?? DEFAULT_PORT);
}

export function serverIsLoopbackBound(): boolean {
  return isLoopbackHost(configuredHost());
}

export interface DashboardCapabilities {
  readonly workflowWrites: boolean;
  readonly workflowRuns: boolean;
  readonly assistant: boolean;
  readonly safetyWrites: boolean;
}

/** All four flags collapse to the same loopback-bound check; kept as separate fields per the API contract for independent future gating. */
export function computeCapabilities(): DashboardCapabilities {
  const loopback = serverIsLoopbackBound();
  return {
    workflowWrites: loopback,
    workflowRuns: loopback,
    assistant: loopback,
    safetyWrites: loopback,
  };
}

interface ParsedHostHeader {
  readonly host: string;
  readonly port: string | null;
}

function parseHostHeader(value: string | undefined): ParsedHostHeader | null {
  if (!value) {
    return null;
  }
  const trimmed = value.trim();
  const ipv6 = /^\[([^\]]+)\](?::(\d+))?$/.exec(trimmed);
  if (ipv6) {
    return { host: ipv6[1] ?? '', port: ipv6[2] ?? null };
  }
  const idx = trimmed.lastIndexOf(':');
  if (idx === -1) {
    return { host: trimmed, port: null };
  }
  const maybePort = trimmed.slice(idx + 1);
  if (!/^\d+$/.test(maybePort)) {
    // Not actually a port (e.g. a bare IPv6 address without brackets) — treat whole value as host.
    return { host: trimmed, port: null };
  }
  return { host: trimmed.slice(0, idx), port: maybePort };
}

class BodyTooLargeError extends Error {}
class MalformedJsonError extends Error {}

function readJsonBody(req: Request, maxBytes: number): Promise<unknown> {
  return new Promise((resolvePromise, reject) => {
    let total = 0;
    let exceeded = false;
    let settled = false;
    const chunks: Buffer[] = [];
    const rejectOnce = (error: Error) => {
      if (!settled) {
        settled = true;
        reject(error);
      }
    };
    req.on('data', (chunk: Buffer) => {
      if (exceeded) {
        return;
      }
      total += chunk.length;
      if (total > maxBytes) {
        exceeded = true;
        rejectOnce(new BodyTooLargeError());
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (exceeded || settled) {
        return;
      }
      const raw = Buffer.concat(chunks).toString('utf8');
      if (raw.trim().length === 0) {
        resolvePromise({});
        return;
      }
      try {
        resolvePromise(JSON.parse(raw));
      } catch {
        rejectOnce(new MalformedJsonError());
      }
    });
    req.on('error', (error) => rejectOnce(error));
  });
}

function deny(res: Response, message: string): void {
  res.status(403).json({ error: message });
}

export const writeGuard: RequestHandler = (req: Request, res: Response, next: NextFunction): void => {
  if (!serverIsLoopbackBound()) {
    deny(res, 'Write operations are disabled: the dashboard server is not bound to a loopback host');
    return;
  }

  const hostHeader = parseHostHeader(req.headers['host']);
  if (!hostHeader || !isLoopbackHost(hostHeader.host)) {
    deny(res, 'Write operations require a loopback Host header');
    return;
  }
  const expectedPort = configuredPort();
  if (hostHeader.port !== null && hostHeader.port !== expectedPort) {
    deny(res, 'Write operations require the Host header port to match the server port');
    return;
  }

  const originHeader = req.headers['origin'];
  if (typeof originHeader === 'string' && originHeader.length > 0) {
    try {
      const origin = new URL(originHeader);
      const originPortOk = origin.port === '' || origin.port === expectedPort;
      if (!isLoopbackHost(origin.hostname) || !originPortOk) {
        deny(res, 'Write operations refuse a foreign Origin');
        return;
      }
    } catch {
      deny(res, 'Write operations refuse a malformed Origin header');
      return;
    }
  }

  if (!req.is('application/json')) {
    deny(res, 'Write operations require Content-Type: application/json');
    return;
  }

  readJsonBody(req, MAX_BODY_BYTES)
    .then((body) => {
      req.body = body;
      next();
    })
    .catch((error: unknown) => {
      if (error instanceof BodyTooLargeError) {
        deny(res, `Request body exceeds the ${MAX_BODY_BYTES}-byte limit`);
        return;
      }
      if (error instanceof MalformedJsonError) {
        deny(res, 'Request body is not valid JSON');
        return;
      }
      deny(res, 'Failed to read request body');
    });
};
