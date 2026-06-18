import './angular-test-env';
import { IonSpinner } from '@ionic/angular/standalone';

describe('Ionic Proxies Import Test', () => {
  it('should import IonSpinner from proxies', () => {
    expect(IonSpinner).toBeDefined();
  });
});
