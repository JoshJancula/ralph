import { provideHttpClient } from '@angular/common/http';
import { ApplicationConfig } from '@angular/core';
import { provideIonicAngular } from '@ionic/angular/standalone';
import { provideRouter, RouteReuseStrategy } from '@angular/router';

import { routes } from './app.routes';
import { DashboardRouteReuseStrategy } from './dashboard-route-reuse.strategy';

export const appConfig: ApplicationConfig = {
  providers: [
    provideHttpClient(),
    provideRouter(routes),
    provideIonicAngular(),
    { provide: RouteReuseStrategy, useClass: DashboardRouteReuseStrategy },
  ],
};
