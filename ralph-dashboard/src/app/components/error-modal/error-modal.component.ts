import { CommonModule, DOCUMENT, DatePipe, isPlatformBrowser } from '@angular/common';
import {
  Component,
  EventEmitter,
  Inject,
  Input,
  OnChanges,
  OnInit,
  Output,
  PLATFORM_ID,
  SimpleChanges,
  inject,
} from '@angular/core';
import { IonButton, IonButtons, IonCol, IonGrid, IonHeader, IonNote, IonRow, IonText, IonTitle, IonToolbar, ModalController } from '@ionic/angular/standalone';

export interface ErrorModalDeviceInfo {
  platform: string;
  deviceType: string;
  deviceName?: string;
  browser?: string;
  osVersion?: string;
  displayInfo: string;
  localeInfo: string;
}

@Component({
  selector: 'ralph-error-modal',
  standalone: true,
  imports: [
    CommonModule,
    DatePipe,
    IonHeader,
    IonToolbar,
    IonTitle,
    IonButtons,
    IonButton,
    IonNote,
    IonText,
    IonGrid,
    IonRow,
    IonCol,
  ],
  templateUrl: './error-modal.component.html',
  styleUrls: ['./error-modal.component.scss'],
})
export class ErrorModalComponent implements OnInit, OnChanges {
  private readonly modalController = inject(ModalController, { optional: true });

  /**
   * Raw failure payload (HttpErrorResponse, ResourceError, string, etc.).
   * When embedded on a page, pass the section-specific error so several panels
   * can each show their own diagnostics without stacking overlays.
   */
  @Input() error: unknown;
  /** Overlay mode shows an Ionic header; embedded page sections usually omit it. */
  @Input() showHeader = true;
  /** When true, Close emits `dismissed` instead of dismissing a ModalController host. */
  @Input() embedded = false;

  @Output() readonly dismissed = new EventEmitter<void>();

  showExtraDetails = false;
  showRawJson = false;
  copyStatus = '';

  errorMessage = 'There was an error processing this request';
  errorContext: string | null = null;
  requestId: string | null = null;
  traceId: string | null = null;
  cfRay: string | null = null;
  statusCode: number | null = null;
  timestamp = new Date().toISOString();
  path: string | null = null;
  userAgent = 'Unknown';
  deviceInfo: ErrorModalDeviceInfo = {
    platform: 'Unknown',
    deviceType: 'Unknown',
    displayInfo: 'N/A',
    localeInfo: 'N/A',
  };

  constructor(
    @Inject(DOCUMENT) private readonly document: Document,
    @Inject(PLATFORM_ID) private readonly platformId: object,
  ) {}

  ngOnInit(): void {
    this.parseErrorData();
    this.initializeDeviceInfo();
  }

  ngOnChanges(changes: SimpleChanges): void {
    if (changes['error'] && !changes['error'].firstChange) {
      this.parseErrorData();
    }
  }

  cancel(): void {
    if (this.embedded) {
      this.dismissed.emit();
      return;
    }
    void this.modalController?.dismiss();
  }

  get errorsObject(): Record<string, unknown> {
    return {
      statusCode: this.statusCode,
      message: this.errorMessage,
      context: this.errorContext,
      requestId: this.requestId,
      path: this.path,
      traceId: this.traceId,
      cfRay: this.cfRay,
      timestamp: this.timestamp,
      raw: this.safeRawError(),
      deviceInfo: {
        userAgent: this.userAgent,
        platform: this.deviceInfo.platform,
        deviceType: this.deviceInfo.deviceType,
        deviceName: this.deviceInfo.deviceName,
        osVersion: this.deviceInfo.osVersion,
        browser: this.deviceInfo.browser,
        displayInfo: this.deviceInfo.displayInfo,
        localeInfo: this.deviceInfo.localeInfo,
      },
    };
  }

  async copyToClipboard(): Promise<void> {
    try {
      await navigator.clipboard.writeText(JSON.stringify(this.errorsObject, null, 2));
      this.copyStatus = 'Copied';
      setTimeout(() => {
        this.copyStatus = '';
      }, 1500);
    } catch {
      this.copyStatus = 'Copy failed';
    }
  }

  private parseErrorData(): void {
    if (typeof this.error === 'string') {
      this.errorMessage = this.error;
      this.errorContext = null;
      this.statusCode = 500;
      this.timestamp = new Date().toISOString();
      return;
    }

    if (typeof this.error !== 'object' || this.error === null) {
      this.errorMessage = 'There was an error processing this request';
      this.errorContext = null;
      this.statusCode = 500;
      this.timestamp = new Date().toISOString();
      return;
    }

    const err = this.error as Record<string, unknown>;
    const nestedError = this.asRecord(err['error']);
    const nestedBody = this.asRecord(err['body']);

    this.errorMessage =
      this.asString(nestedBody?.['message']) ||
      this.asString(nestedError?.['error']) ||
      this.asString(nestedBody?.['error']) ||
      this.asString(nestedError?.['message']) ||
      this.asString(err['message']) ||
      this.asString(err['title']) ||
      'There was an error processing this request';

    this.errorContext =
      this.asString(nestedBody?.['context']) ||
      this.asString(nestedError?.['context']) ||
      this.asString(err['context']) ||
      this.asString(err['explanation']) ||
      this.asString(nestedError?.['diagnostics']) ||
      this.asString(nestedBody?.['diagnostics']) ||
      null;

    this.traceId =
      this.asString(nestedError?.['traceId']) ||
      this.asString(nestedBody?.['traceId']) ||
      this.asString(err['traceId']) ||
      (isPlatformBrowser(this.platformId) ? window.localStorage?.getItem('trace_id') : null);

    this.requestId =
      this.asString(nestedError?.['requestId']) ||
      this.asString(nestedBody?.['requestId']) ||
      this.asString(err['requestId']) ||
      null;

    this.cfRay = this.extractCfRayHeader(err);

    const status =
      err['status'] ?? nestedError?.['status'] ?? nestedError?.['statusCode'] ?? nestedBody?.['status'];
    this.statusCode = typeof status === 'number' ? status : null;

    this.path =
      this.asString(err['url']) ||
      this.asString(err['path']) ||
      this.asString(nestedError?.['path']) ||
      this.asString(nestedBody?.['path']) ||
      null;

    this.timestamp =
      this.asString(err['timestamp']) ||
      this.asString(nestedError?.['timestamp']) ||
      this.asString(nestedBody?.['timestamp']) ||
      new Date().toISOString();
  }

  private extractCfRayHeader(err: Record<string, unknown>): string | null {
    const headers = err['headers'];
    if (headers && typeof headers === 'object' && headers !== null && 'get' in headers) {
      const getter = (headers as { get: (key: string) => string | null }).get;
      if (typeof getter === 'function') {
        const cfRay = getter.call(headers, 'cf-ray');
        if (cfRay) return cfRay;
      }
    }
    if (headers && typeof headers === 'object' && headers !== null) {
      const record = headers as Record<string, unknown>;
      const direct = this.asString(record['cf-ray']);
      if (direct) return direct;
      const key = Object.keys(record).find((k) => k.toLowerCase() === 'cf-ray');
      if (key) return this.asString(record[key]);
    }
    if (isPlatformBrowser(this.platformId)) {
      return window.localStorage?.getItem('cf-ray');
    }
    return null;
  }

  private initializeDeviceInfo(): void {
    if (!isPlatformBrowser(this.platformId)) {
      this.userAgent = 'SSR';
      this.deviceInfo = {
        platform: 'Server-Side Rendering',
        deviceType: 'N/A',
        displayInfo: 'N/A',
        localeInfo: 'N/A',
      };
      return;
    }

    const win = this.document.defaultView;
    const navigator = win?.navigator;
    this.userAgent = navigator?.userAgent || 'Unknown';

    const ua = this.userAgent.toLowerCase();
    const isMobile = /mobile|iphone|android/.test(ua) && !/ipad|tablet/.test(ua);
    const isTablet = /ipad|tablet/.test(ua) || (ua.includes('android') && !ua.includes('mobile'));
    const platform = isMobile || isTablet ? 'Mobile Web' : 'Desktop Web';
    const deviceType = isMobile ? 'Phone' : isTablet ? 'Tablet' : 'Desktop / Laptop';
    const browser = this.detectBrowser(this.userAgent);
    const osVersion = this.detectOs(this.userAgent);

    const displayParts: string[] = [];
    if (win?.screen) {
      displayParts.push(`Screen: ${win.screen.width}x${win.screen.height}`);
      displayParts.push(`Pixel Ratio: ${win.devicePixelRatio || 1}`);
    }
    if (win?.innerWidth && win?.innerHeight) {
      displayParts.push(`Viewport: ${win.innerWidth}x${win.innerHeight}`);
    }

    const localeParts: string[] = [];
    if (navigator?.language) {
      localeParts.push(`Language: ${navigator.language}`);
    }
    try {
      const timezone = Intl.DateTimeFormat().resolvedOptions().timeZone;
      if (timezone) localeParts.push(`Timezone: ${timezone}`);
    } catch {
      localeParts.push('Timezone: Unknown');
    }

    this.deviceInfo = {
      platform,
      deviceType,
      browser: browser || undefined,
      osVersion: osVersion || undefined,
      displayInfo: displayParts.length > 0 ? displayParts.join(', ') : 'N/A',
      localeInfo: localeParts.length > 0 ? localeParts.join(', ') : 'N/A',
    };
  }

  private detectBrowser(userAgent: string): string | null {
    const ua = userAgent.toLowerCase();
    if (ua.includes('edg/')) return 'Edge';
    if (ua.includes('firefox/')) return 'Firefox';
    if (ua.includes('chrome/') && !ua.includes('edg/')) return 'Chrome';
    if (ua.includes('safari/') && !ua.includes('chrome/')) return 'Safari';
    return null;
  }

  private detectOs(userAgent: string): string | null {
    const ua = userAgent.toLowerCase();
    if (ua.includes('mac os x')) {
      const match = ua.match(/mac os x (\d+[._]\d+)/);
      return match ? `macOS ${match[1].replace('_', '.')}` : 'macOS';
    }
    if (ua.includes('windows')) return 'Windows';
    if (ua.includes('android')) {
      const match = ua.match(/android (\d+\.?\d*)/);
      return match ? `Android ${match[1]}` : 'Android';
    }
    if (ua.includes('iphone') || ua.includes('ipad')) {
      const match = ua.match(/os (\d+)_(\d+)/);
      return match ? `iOS ${match[1]}.${match[2]}` : 'iOS';
    }
    if (ua.includes('linux')) return 'Linux';
    return null;
  }

  private asRecord(value: unknown): Record<string, unknown> | null {
    return typeof value === 'object' && value !== null ? (value as Record<string, unknown>) : null;
  }

  private asString(value: unknown): string | null {
    return typeof value === 'string' && value.trim() ? value : null;
  }

  private safeRawError(): unknown {
    try {
      return JSON.parse(JSON.stringify(this.error));
    } catch {
      return String(this.error);
    }
  }
}
