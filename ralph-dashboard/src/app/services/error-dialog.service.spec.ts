import '../../angular-test-env';
import { TestBed } from '@angular/core/testing';
import { ModalController } from '@ionic/angular/standalone';
import { vi } from 'vitest';
import { ErrorDialogService } from './error-dialog.service';
import { ErrorModalComponent } from '../components/error-modal/error-modal.component';

describe('ErrorDialogService', () => {
  it('presents the error modal with the raw error payload', async () => {
    const present = vi.fn().mockResolvedValue(undefined);
    const onDidDismiss = vi.fn().mockResolvedValue({ role: 'cancel' });
    const create = vi.fn().mockResolvedValue({ present, onDidDismiss });

    await TestBed.configureTestingModule({
      providers: [
        ErrorDialogService,
        { provide: ModalController, useValue: { create } },
      ],
    }).compileComponents();

    const service = TestBed.inject(ErrorDialogService);
    const err = { message: 'failed', status: 500 };
    await service.displayError(err);

    expect(create).toHaveBeenCalledWith(
      expect.objectContaining({
        component: ErrorModalComponent,
        cssClass: 'ralph-error-modal',
        componentProps: expect.objectContaining({ error: err, showHeader: true }),
      }),
    );
    expect(present).toHaveBeenCalled();
  });
});
