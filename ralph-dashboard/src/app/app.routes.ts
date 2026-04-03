import { Routes } from '@angular/router';

export const routes: Routes = [
  {
    path: '',
    pathMatch: 'full',
    redirectTo: 'plans',
  },
  // Wildcard route matches any path. NavService parses the URL client-side to extract state.
  // The redirectTo ensures the router accepts the navigation, but actual content is driven by NavService signals.
  {
    path: '**',
    redirectTo: 'plans',
  },
];
