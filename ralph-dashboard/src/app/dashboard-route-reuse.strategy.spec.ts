import { ActivatedRouteSnapshot, DetachedRouteHandle } from '@angular/router';
import { describe, expect, it } from 'vitest';
import { DashboardRouteReuseStrategy } from './dashboard-route-reuse.strategy';

function snapshot(path: string, root?: string | null): ActivatedRouteSnapshot {
  return {
    routeConfig: path ? { path } : null,
    paramMap: {
      get: (key: string) => (key === 'root' ? (root ?? null) : null),
    },
  } as unknown as ActivatedRouteSnapshot;
}

describe('DashboardRouteReuseStrategy', () => {
  it('detaches static hub routes and tasks/:taskView', () => {
    const strategy = new DashboardRouteReuseStrategy();

    expect(strategy.shouldDetach(snapshot('home'))).toBe(true);
    expect(strategy.shouldDetach(snapshot('workflows'))).toBe(true);
    expect(strategy.shouldDetach(snapshot('tasks/:taskView'))).toBe(true);
    expect(strategy.shouldDetach(snapshot('plan-detail/:planPath'))).toBe(false);
    expect(strategy.shouldDetach(snapshot(''))).toBe(false);
  });

  it('stores and retrieves detached handles by path and root', () => {
    const strategy = new DashboardRouteReuseStrategy();
    const handle = {} as DetachedRouteHandle;
    const route = snapshot(':root', 'plans');

    expect(strategy.shouldAttach(route)).toBe(false);
    expect(strategy.retrieve(route)).toBeNull();

    strategy.store(route, handle);

    expect(strategy.shouldAttach(route)).toBe(true);
    expect(strategy.retrieve(route)).toBe(handle);
    expect(strategy.shouldAttach(snapshot(':root', 'docs'))).toBe(false);
  });

  it('reuses routes only when routeConfig identity matches', () => {
    const strategy = new DashboardRouteReuseStrategy();
    const shared = { path: 'home' };
    const future = { routeConfig: shared } as ActivatedRouteSnapshot;
    const curr = { routeConfig: shared } as ActivatedRouteSnapshot;
    const other = { routeConfig: { path: 'home' } } as ActivatedRouteSnapshot;

    expect(strategy.shouldReuseRoute(future, curr)).toBe(true);
    expect(strategy.shouldReuseRoute(future, other)).toBe(false);
  });
});
