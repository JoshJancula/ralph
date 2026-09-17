import '../../../angular-test-env';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { HttpErrorResponse } from '@angular/common/http';
import { ModalController } from '@ionic/angular/standalone';
import { vi } from 'vitest';
import { ErrorModalComponent } from './error-modal.component';

describe('ErrorModalComponent', () => {
  let fixture: ComponentFixture<ErrorModalComponent>;
  let component: ErrorModalComponent;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [ErrorModalComponent],
      providers: [{ provide: ModalController, useValue: { dismiss: vi.fn() } }],
    }).compileComponents();
    fixture = TestBed.createComponent(ErrorModalComponent);
    component = fixture.componentInstance;
  });

  it('parses a string error', () => {
    component.error = 'Boom';
    component.ngOnInit();
    expect(component.errorMessage).toBe('Boom');
    expect(component.statusCode).toBe(500);
  });

  it('parses an HttpErrorResponse-shaped object', () => {
    component.error = new HttpErrorResponse({
      status: 422,
      statusText: 'Unprocessable',
      url: '/api/workflows',
      error: { error: 'Invalid workflow', diagnostics: 'stage id missing' },
    });
    component.ngOnInit();
    expect(component.errorMessage).toContain('Invalid workflow');
    expect(component.errorContext).toContain('stage id missing');
    expect(component.statusCode).toBe(422);
    expect(component.path).toBe('/api/workflows');
  });

  it('exposes a copyable errorsObject', () => {
    component.error = 'Copy me';
    component.ngOnInit();
    expect(component.errorsObject.message).toBe('Copy me');
    expect(component.errorsObject.deviceInfo).toBeTruthy();
  });
});
