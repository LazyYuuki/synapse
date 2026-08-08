/** Shared lexical validators for the protocol-v1 browser boundary.
 * @see ../../../../../docs/plan/PLAN-API.md
 */

const encoder = new TextEncoder();
const elixirTrimCodePoints = new Set([
  0x0009, 0x000a, 0x000b, 0x000c, 0x000d, 0x0020, 0x0085, 0x00a0, 0x1680, 0x2000, 0x2001, 0x2002,
  0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200a, 0x2028, 0x2029, 0x202f, 0x205f,
  0x3000,
]);

export function isWellFormedUnicode(value: string): boolean {
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);

    if (code >= 0xd800 && code <= 0xdbff) {
      if (index + 1 >= value.length) return false;
      const next = value.charCodeAt(index + 1);
      if (next < 0xdc00 || next > 0xdfff) return false;
      index += 1;
    } else if (code >= 0xdc00 && code <= 0xdfff) {
      return false;
    }
  }

  return true;
}

export function utf8ByteLength(value: string): number {
  return isWellFormedUnicode(value) ? encoder.encode(value).byteLength : Number.POSITIVE_INFINITY;
}

export function isBoundedString(value: unknown, maximumBytes: number): value is string {
  return typeof value === 'string' && utf8ByteLength(value) <= maximumBytes;
}

export function isIdentifier(value: unknown, maximumBytes: number): value is string {
  if (!isBoundedString(value, maximumBytes) || !hasNonBlankContent(value)) return false;

  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code < 0x20 || code === 0x7f) return false;
  }

  return true;
}

export function hasNonBlankContent(value: string): boolean {
  for (const character of value) {
    const codePoint = character.codePointAt(0);
    if (codePoint !== undefined && !elixirTrimCodePoints.has(codePoint)) return true;
  }
  return false;
}

export function isRunId(value: unknown): value is string {
  return (
    typeof value === 'string' && value.length === 26 && /^run_[A-Za-z0-9_-]{21}[AQgw]$/.test(value)
  );
}

export function isPlainObject(value: unknown): value is Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

export function hasExactKeys(
  value: unknown,
  expected: readonly string[],
): value is Record<string, unknown> {
  if (!isPlainObject(value)) return false;
  const keys = Object.keys(value);
  return keys.length === expected.length && expected.every((key) => keys.includes(key));
}

export function isOneOf<T extends string>(value: unknown, choices: readonly T[]): value is T {
  return typeof value === 'string' && choices.some((choice) => choice === value);
}
