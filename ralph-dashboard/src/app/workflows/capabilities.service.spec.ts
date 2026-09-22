import '../../angular-test-env';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { CapabilitiesService } from './capabilities.service';

describe('CapabilitiesService', () => {
  let service: CapabilitiesService;
  let httpMock: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      imports: [HttpClientTestingModule],
      providers: [CapabilitiesService],
    });
    service = TestBed.inject(CapabilitiesService);
    httpMock = TestBed.inject(HttpTestingController);
  });

  afterEach(() => {
    httpMock.verify();
  });

  it('defaults to all-false before load', () => {
    expect(service.capabilities()).toEqual({
      workflowWrites: false,
      workflowRuns: false,
      assistant: false,
      safetyWrites: false,
    });
    expect(service.loaded()).toBe(false);
  });

  it('load() fetches /api/capabilities and stores the result', () => {
    service.load();
    const req = httpMock.expectOne('/api/capabilities');
    expect(req.request.method).toBe('GET');
    req.flush({ workflowWrites: true, workflowRuns: true, assistant: true, safetyWrites: true });
    expect(service.capabilities()).toEqual({
      workflowWrites: true,
      workflowRuns: true,
      assistant: true,
      safetyWrites: true,
    });
    expect(service.loaded()).toBe(true);
  });

  it('load() is a no-op once already loaded or while a load is inflight', () => {
    service.load();
    service.load(); // second call while inflight must not issue a second request
    const req = httpMock.expectOne('/api/capabilities');
    req.flush({ workflowWrites: true, workflowRuns: false, assistant: false, safetyWrites: false });
    service.load(); // third call after loaded must not issue a request either
    httpMock.expectNone('/api/capabilities');
  });

  it('stays all-false on a failed load', () => {
    service.load();
    const req = httpMock.expectOne('/api/capabilities');
    req.flush('boom', { status: 500, statusText: 'Server Error' });
    expect(service.capabilities()).toEqual({
      workflowWrites: false,
      workflowRuns: false,
      assistant: false,
      safetyWrites: false,
    });
    expect(service.loaded()).toBe(true);
  });
});
