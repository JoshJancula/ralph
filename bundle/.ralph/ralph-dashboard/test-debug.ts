import { HttpClientTestingModule } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { HttpClient, HttpTestingController } from '@angular/common/http';

describe('ApiService', () => {
  let service: any;
  let httpMock: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      imports: [HttpClientTestingModule],
      providers: [],
    });

    service = TestBed.inject(HttpTestingController);
    httpMock = service;
  });

  it('should make GET request to /api/roots', () => {
    expect(httpMock).toBeDefined();
  });
});
