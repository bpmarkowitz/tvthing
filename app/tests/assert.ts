// Minimal assertions, so the tests need nothing beyond Deno itself.
export function equal(actual: unknown, expected: unknown, message = '') {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${message}\n  expected ${e}\n  actual   ${a}`);
}

export function ok(value: unknown, message = 'expected a truthy value') {
  if (!value) throw new Error(message);
}

export function throws(run: () => unknown, pattern: RegExp) {
  try {
    run();
  } catch (error) {
    if (!pattern.test((error as Error).message)) throw new Error(`threw "${(error as Error).message}", expected ${pattern}`);
    return;
  }
  throw new Error(`expected an error matching ${pattern}`);
}
