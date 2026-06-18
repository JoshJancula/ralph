import { Routes } from '@angular/router';

/**
 * Test routes for use with RouterTestingModule.
 * Provides valid route configuration while allowing NavService to read URL state.
 */
export const testRoutes: Routes = [
  {
    path: '',
    pathMatch: 'full',
    redirectTo: 'plans',
  },
  { path: '**' },
];