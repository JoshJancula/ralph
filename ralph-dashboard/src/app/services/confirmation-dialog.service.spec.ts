import '../../angular-test-env';
import { TestBed } from '@angular/core/testing';
import { AlertController } from '@ionic/angular/standalone';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ConfirmationDialogService } from './confirmation-dialog.service';

describe('ConfirmationDialogService', () => {
  const alert = {
    present: vi.fn(async () => undefined),
    onDidDismiss: vi.fn(async () => ({ role: 'destructive' })),
  };
  const alertController = { create: vi.fn(async () => alert) };

  beforeEach(() => {
    vi.clearAllMocks();
    TestBed.configureTestingModule({ providers: [{ provide: AlertController, useValue: alertController }] });
  });

  it('uses an ion-alert with cancel and destructive actions', async () => {
    const result = await TestBed.inject(ConfirmationDialogService).confirm({
      header: 'Delete override?',
      message: 'This cannot be undone.',
      confirmText: 'Delete',
    });

    expect(result).toBe(true);
    expect(alertController.create).toHaveBeenCalledWith({
      header: 'Delete override?',
      message: 'This cannot be undone.',
      buttons: [
        { text: 'Cancel', role: 'cancel' },
        { text: 'Delete', role: 'destructive' },
      ],
    });
    expect(alert.present).toHaveBeenCalledOnce();
  });
});
