import { Injectable, inject } from '@angular/core';
import { AlertController } from '@ionic/angular/standalone';

export interface ConfirmationDialogOptions {
  header: string;
  message: string;
  confirmText: string;
}

/** Presents confirmations through Ionic's ion-alert overlay. */
@Injectable({ providedIn: 'root' })
export class ConfirmationDialogService {
  private readonly alertController = inject(AlertController);

  async confirm({ header, message, confirmText }: ConfirmationDialogOptions): Promise<boolean> {
    const alert = await this.alertController.create({
      header,
      message,
      buttons: [
        { text: 'Cancel', role: 'cancel' },
        { text: confirmText, role: 'destructive' },
      ],
    });
    await alert.present();
    const { role } = await alert.onDidDismiss();
    return role === 'destructive';
  }
}
