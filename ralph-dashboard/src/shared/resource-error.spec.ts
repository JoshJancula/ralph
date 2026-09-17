import { ResourceErrorBuilder, ResourceIdentityBuilder } from './';

describe('ResourceErrorBuilder', () => {
  it('should create a NOT_FOUND error', () => {
    const error = ResourceErrorBuilder.notFound('test.md');
    expect(error.code).toBe('NOT_FOUND');
    expect(error.title).toBe('File Not Found');
    expect(error.recoverable).toBe(true);
    expect(error.suggestedActions).toContain('REFRESH_INDEX');
    expect(error.suggestedActions).toContain('RETURN_TO_PLANS');
  });

  it('should create a FORBIDDEN error', () => {
    const error = ResourceErrorBuilder.forbidden('test.md');
    expect(error.code).toBe('FORBIDDEN');
    expect(error.title).toBe('Access Denied');
    expect(error.recoverable).toBe(false);
    expect(error.suggestedActions).toContain('SELECT_PROJECT');
  });

  it('should create a STALE_RESOURCE error', () => {
    const error = ResourceErrorBuilder.staleResource('test.md');
    expect(error.code).toBe('STALE_RESOURCE');
    expect(error.title).toBe('Resource Index Stale');
    expect(error.recoverable).toBe(true);
    expect(error.suggestedActions).toContain('REFRESH_INDEX');
  });

  it('should create an INVALID_REQUEST error', () => {
    const error = ResourceErrorBuilder.invalidRequest('Missing parameter');
    expect(error.code).toBe('INVALID_REQUEST');
    expect(error.title).toBe('Invalid Request');
    expect(error.recoverable).toBe(false);
  });

  it('should include requested identity in error', () => {
    const identity = ResourceIdentityBuilder.forPlan('/project', 'test.md', 'Test');
    const error = ResourceErrorBuilder.notFound('test.md', identity);
    expect(error.requestedIdentity).toEqual(identity);
  });

  it('should map HTTP 404 to NOT_FOUND', () => {
    const error = ResourceErrorBuilder.fromHttpError(404, 'test.md');
    expect(error.code).toBe('NOT_FOUND');
    expect(error.recoverable).toBe(true);
  });

  it('should map HTTP 403 to FORBIDDEN', () => {
    const error = ResourceErrorBuilder.fromHttpError(403, 'test.md');
    expect(error.code).toBe('FORBIDDEN');
    expect(error.recoverable).toBe(false);
  });

  it('should map HTTP 401 to FORBIDDEN', () => {
    const error = ResourceErrorBuilder.fromHttpError(401, 'test.md');
    expect(error.code).toBe('FORBIDDEN');
  });

  it('should map HTTP 400 to INVALID_REQUEST', () => {
    const error = ResourceErrorBuilder.fromHttpError(400, 'test.md');
    expect(error.code).toBe('INVALID_REQUEST');
  });

  it('should map unknown HTTP error to UNKNOWN', () => {
    const error = ResourceErrorBuilder.fromHttpError(500, 'test.md');
    expect(error.code).toBe('UNKNOWN');
    expect(error.recoverable).toBe(true);
  });
});
