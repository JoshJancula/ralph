import { PLATFORM_ID, inject } from '@angular/core';
import { isPlatformBrowser } from '@angular/common';
import type { CanDeactivateFn } from '@angular/router';
import { ConfirmationDialogService } from '../services/confirmation-dialog.service';
import { WorkflowsFacade } from './workflows.facade';

/** Warns on navigation away from the edit page with unsaved changes. Kept standalone (not a component method) so it can be a lightweight static import in app.routes.ts. */
export const workflowEditCanDeactivate: CanDeactivateFn<unknown> = () => {
  const facade = inject(WorkflowsFacade);
  if (!facade.editDirty()) {
    return true;
  }
  const platformId = inject(PLATFORM_ID);
  if (!isPlatformBrowser(platformId)) {
    return true;
  }
  return inject(ConfirmationDialogService).confirm({
    header: 'Discard unsaved changes?',
    message: 'Your edits will be lost if you leave this page.',
    confirmText: 'Discard',
  });
};
