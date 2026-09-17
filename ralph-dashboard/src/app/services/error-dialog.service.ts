import { Injectable, inject } from '@angular/core';
import { ModalController } from '@ionic/angular/standalone';
import { ErrorModalComponent } from '../components/error-modal/error-modal.component';

/**
 * Presents rich error diagnostics through the shared Ralph error modal.
 * Pass the original thrown value / HttpErrorResponse when available.
 * Overlay mode is for one-shot action failures; page sections should embed
 * `<ralph-error-modal>` inline when several loads can fail independently.
 */
@Injectable({ providedIn: 'root' })
export class ErrorDialogService {
  private readonly modalController = inject(ModalController, { optional: true });
  private open = false;

  async displayError(error: unknown, fallbackMessage = 'Something went wrong'): Promise<void> {
    const payload = error ?? fallbackMessage;
    if (this.open) {
      return;
    }
    if (!this.modalController) {
      console.error('ErrorDialogService: ModalController unavailable', payload);
      return;
    }
    this.open = true;
    try {
      const modal = await this.modalController.create({
        component: ErrorModalComponent,
        cssClass: 'ralph-error-modal',
        componentProps: {
          error: payload,
          showHeader: true,
        },
        breakpoints: [0, 1],
        initialBreakpoint: 1,
      });
      await modal.present();
      await modal.onDidDismiss();
    } finally {
      this.open = false;
    }
  }
}
