import '../../angular-test-env';
import { NavService } from './nav.service';

describe('NavService', () => {
  beforeEach(() => {
    window.location.hash = '';
  });

  afterEach(() => {
    window.location.hash = '';
  });

  it('initial state: all signals are empty/null with no hash set', () => {
    const service = new NavService();
    expect(service.activeRoot()).toBeNull();
    expect(service.activePath()).toBeNull();
    expect(service.activeFile()).toBeNull();
    expect(service.mode()).toBe('hub');
  });

  it('navigate updates all three signals and writes the correct hash', () => {
    const service = new NavService();
    service.navigate('logs', 'PLAN2', 'plan-runner.log');
    expect(service.activeRoot()).toBe('logs');
    expect(service.activePath()).toBe('PLAN2');
    expect(service.activeFile()).toBe('plan-runner.log');
    expect(window.location.hash).toBe('#root=logs&path=PLAN2&file=plan-runner.log');
  });

  it('parseHash restores activeRoot, activePath, activeFile from a pre-set location.hash', () => {
    window.location.hash = '#root=alpha&path=beta&file=gamma.txt';
    const service = new NavService();
    expect(service.activeRoot()).toBe('alpha');
    expect(service.activePath()).toBe('beta');
    expect(service.activeFile()).toBe('gamma.txt');
    expect(service.mode()).toBe('file');
  });

  it('navigate with no file sets mode to hub; with a file sets mode to file', () => {
    const service = new NavService();
    service.navigate('logs', 'PLAN2');
    expect(service.mode()).toBe('hub');
    expect(service.activeFile()).toBeNull();

    service.navigate('logs', 'PLAN2', 'plan-runner.log');
    expect(service.mode()).toBe('file');
    expect(service.activeFile()).toBe('plan-runner.log');
  });

  it('refresh re-runs parseHash', () => {
    const service = new NavService();
    const spy = vi.spyOn(service, 'parseHash');
    service.refresh();
    expect(spy).toHaveBeenCalledTimes(1);
  });

  it('navigate with only root updates hash without path or file segments', () => {
    const service = new NavService();
    service.navigate('plans');
    expect(service.activeRoot()).toBe('plans');
    expect(service.activePath()).toBeNull();
    expect(service.activeFile()).toBeNull();
    expect(window.location.hash).toBe('#root=plans');
  });

  it('parseHash with root only leaves path and file null', () => {
    window.location.hash = '#root=artifacts';
    const service = new NavService();
    expect(service.activeRoot()).toBe('artifacts');
    expect(service.activePath()).toBeNull();
    expect(service.activeFile()).toBeNull();
  });
});
