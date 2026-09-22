import { ActivatedRouteSnapshot, DetachedRouteHandle, RouteReuseStrategy } from '@angular/router';

/** Static hub routes whose component trees should stay warm when you navigate away and back. */
const REUSE_ROUTE_PATHS = new Set([
  'home',
  'runs',
  'plans',
  'insights',
  'usage',
  'docs',
  'tasks',
  'schedules',
  'workflows',
]);

function routeCacheKey(route: ActivatedRouteSnapshot): string {
  const path = route.routeConfig?.path ?? '';
  const root = route.paramMap.get('root');
  if (root) {
    return `${path}:${root}`;
  }
  return path;
}

export class DashboardRouteReuseStrategy implements RouteReuseStrategy {
  private readonly stored = new Map<string, DetachedRouteHandle>();

  shouldDetach(route: ActivatedRouteSnapshot): boolean {
    const path = route.routeConfig?.path ?? '';
    if (REUSE_ROUTE_PATHS.has(path)) {
      return true;
    }
    return path === 'tasks/:taskView';
  }

  store(route: ActivatedRouteSnapshot, handle: DetachedRouteHandle): void {
    this.stored.set(routeCacheKey(route), handle);
  }

  shouldAttach(route: ActivatedRouteSnapshot): boolean {
    return this.stored.has(routeCacheKey(route));
  }

  retrieve(route: ActivatedRouteSnapshot): DetachedRouteHandle | null {
    return this.stored.get(routeCacheKey(route)) ?? null;
  }

  shouldReuseRoute(future: ActivatedRouteSnapshot, curr: ActivatedRouteSnapshot): boolean {
    return future.routeConfig === curr.routeConfig;
  }
}
