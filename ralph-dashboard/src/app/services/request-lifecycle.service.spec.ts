import { describe, expect, it, vi } from 'vitest';
import { RequestLifecycleService } from './request-lifecycle.service';

describe('RequestLifecycleService', () => {
  it('starts keyed handles and reports currency', () => {
    const service = new RequestLifecycleService();
    const first = service.start('hub', { projectRoot: '/a', query: 'q' });
    expect(service.isCurrent(first)).toBe(true);

    const second = service.startWithKey('hub', 'custom-key');
    expect(service.isCurrent(first)).toBe(false);
    expect(service.isCurrent(second)).toBe(true);
  });

  it('cancels a slot and clears all on destroy', () => {
    const service = new RequestLifecycleService();
    const cancelSpy = vi.spyOn((service as any).lifecycle, 'cancel');
    const cancelAllSpy = vi.spyOn((service as any).lifecycle, 'cancelAll');

    service.cancel('hub');
    expect(cancelSpy).toHaveBeenCalledWith('hub');

    service.cancelAll();
    expect(cancelAllSpy).toHaveBeenCalled();

    service.ngOnDestroy();
    expect(cancelAllSpy).toHaveBeenCalledTimes(2);
  });
});
