import { Routes } from '@angular/router';
import { PlanHubComponent } from './components/plan-hub/plan-hub.component';

export const routes: Routes = [
  {
    path: '',
    pathMatch: 'full',
    redirectTo: 'plans',
  },
  {
    path: 'plans',
    component: PlanHubComponent,
  },
  // Dynamic routes with optional path and file segments
  // Order matters: most specific routes first
  {
    path: ':root/path/:path/file/:file',
    component: PlanHubComponent,
  },
  {
    path: ':root/file/:file',
    component: PlanHubComponent,
  },
  {
    path: ':root/path/:path',
    component: PlanHubComponent,
  },
  {
    path: ':root',
    component: PlanHubComponent,
  },
  // Wildcard route - redirect to plans
  {
    path: '**',
    redirectTo: 'plans',
  },
];
