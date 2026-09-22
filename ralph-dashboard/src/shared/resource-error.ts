import { ResourceIdentity } from './resource-identity';

export type ResourceErrorCode = 'NOT_FOUND' | 'FORBIDDEN' | 'STALE_RESOURCE' | 'INVALID_REQUEST' | 'UNKNOWN';

export interface ResourceError {
  code: ResourceErrorCode;
  message: string;
  requestedIdentity?: ResourceIdentity;
  resolvedPath?: string;
  resolvedRoot?: string;
  title: string;
  explanation: string;
  recoverable: boolean;
  suggestedActions: ResourceErrorAction[];
}

export type ResourceErrorAction = 'REFRESH_INDEX' | 'RETURN_TO_PLANS' | 'SELECT_PROJECT' | 'RETRY';

export class ResourceErrorBuilder {
  static notFound(
    requestedPath: string,
    requestedIdentity?: ResourceIdentity,
    resolvedPath?: string
  ): ResourceError {
    return {
      code: 'NOT_FOUND',
      message: `File not found: ${requestedPath}`,
      requestedIdentity,
      resolvedPath,
      title: 'File Not Found',
      explanation: `The file "${requestedPath}" could not be found. It may have been moved, renamed, or deleted.`,
      recoverable: true,
      suggestedActions: ['REFRESH_INDEX', 'RETURN_TO_PLANS'],
    };
  }

  static forbidden(
    requestedPath: string,
    requestedIdentity?: ResourceIdentity
  ): ResourceError {
    return {
      code: 'FORBIDDEN',
      message: `Access denied: ${requestedPath}`,
      requestedIdentity,
      title: 'Access Denied',
      explanation: `You do not have permission to access "${requestedPath}". Check your project selection.`,
      recoverable: false,
      suggestedActions: ['SELECT_PROJECT'],
    };
  }

  static staleResource(
    requestedPath: string,
    requestedIdentity?: ResourceIdentity
  ): ResourceError {
    return {
      code: 'STALE_RESOURCE',
      message: `Resource index may be stale: ${requestedPath}`,
      requestedIdentity,
      title: 'Resource Index Stale',
      explanation: `The resource listing may be outdated. Try refreshing the index to see recent changes.`,
      recoverable: true,
      suggestedActions: ['REFRESH_INDEX'],
    };
  }

  static invalidRequest(message: string): ResourceError {
    return {
      code: 'INVALID_REQUEST',
      message,
      title: 'Invalid Request',
      explanation: message,
      recoverable: false,
      suggestedActions: ['RETURN_TO_PLANS'],
    };
  }

  static fromHttpError(status: number, requestedPath: string, requestedIdentity?: ResourceIdentity): ResourceError {
    switch (status) {
      case 404:
        return this.notFound(requestedPath, requestedIdentity);
      case 403:
      case 401:
        return this.forbidden(requestedPath, requestedIdentity);
      case 400:
        return this.invalidRequest(`Bad request while accessing "${requestedPath}"`);
      default:
        return {
          code: 'UNKNOWN',
          message: `Unexpected error: HTTP ${status}`,
          requestedIdentity,
          title: 'Unexpected Error',
          explanation: `An unexpected error occurred while loading the file. Please try again.`,
          recoverable: true,
          suggestedActions: ['RETRY', 'RETURN_TO_PLANS'],
        };
    }
  }
}
