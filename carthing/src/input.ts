/**
 * Car Thing controls, as they arrive in the webview:
 * - the four top buttons are the keys 1–4
 * - turning the knob produces wheel events (arrow keys work too, for desktop testing)
 * - pressing the knob is Enter; the front button is Escape
 * - the small top-right button is M (five quick presses also return to Bridgething's home)
 */
export interface InputHandlers {
  preset(slot: number): void;
  turn(step: number): void;
  press(): void;
  back(): void;
  /** Show what's on. */
  info(): void;
  /** The first press of each key, reported once, to help map hardware buttons. */
  discovered(key: string, mapped: boolean): void;
}

const WHEEL_THROTTLE_MS = 45;

export function bindInput(handlers: InputHandlers): void {
  const reported = new Set<string>();
  let lastWheelAt = 0;

  window.addEventListener('keydown', (event) => {
    if (event.repeat) return;
    const handled = handleKey(event.key, handlers);
    if (handled) event.preventDefault();
    if (!reported.has(event.key)) {
      reported.add(event.key);
      handlers.discovered(event.key, handled);
    }
  });

  window.addEventListener(
    'wheel',
    (event) => {
      event.preventDefault();
      const delta = Math.abs(event.deltaX) > Math.abs(event.deltaY) ? event.deltaX : event.deltaY;
      const now = Date.now();
      if (delta === 0 || now - lastWheelAt < WHEEL_THROTTLE_MS) return;
      lastWheelAt = now;
      handlers.turn(delta > 0 ? 1 : -1);
    },
    { passive: false },
  );
}

function handleKey(key: string, handlers: InputHandlers): boolean {
  switch (key) {
    case '1':
    case '2':
    case '3':
    case '4':
      handlers.preset(Number(key) - 1);
      return true;
    case 'ArrowRight':
    case 'ArrowDown':
      handlers.turn(1);
      return true;
    case 'ArrowLeft':
    case 'ArrowUp':
      handlers.turn(-1);
      return true;
    case 'Enter':
    case ' ':
      handlers.press();
      return true;
    case 'Escape':
    case 'Backspace':
      handlers.back();
      return true;
    case 'm':
    case 'M':
      handlers.info();
      return true;
    default:
      return false;
  }
}
