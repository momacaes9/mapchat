/**
 * In-memory token bucket, keyed by caller (user id or IP). Good enough for a
 * single routing instance; a shared store (e.g. Postgres or Redis) is needed
 * if the service ever runs on more than one machine.
 */
export class RateLimiter {
  private buckets = new Map<string, { tokens: number; updated: number }>();

  constructor(
    /** Maximum burst. */
    private readonly capacity: number,
    /** Tokens added per second. */
    private readonly refillPerSec: number,
    private readonly now: () => number = () => Date.now(),
  ) {}

  /** Returns true if the call is allowed (and consumes a token). */
  take(key: string): boolean {
    const t = this.now();
    const b = this.buckets.get(key) ?? { tokens: this.capacity, updated: t };
    b.tokens = Math.min(this.capacity, b.tokens + ((t - b.updated) / 1000) * this.refillPerSec);
    b.updated = t;
    const ok = b.tokens >= 1;
    if (ok) b.tokens -= 1;
    this.buckets.set(key, b);
    if (this.buckets.size > 10_000) this.sweep(t);
    return ok;
  }

  /** Seconds until the next token for `key`. */
  retryAfter(key: string): number {
    const b = this.buckets.get(key);
    if (!b || b.tokens >= 1) return 0;
    return Math.ceil((1 - b.tokens) / this.refillPerSec);
  }

  private sweep(t: number) {
    for (const [k, b] of this.buckets) {
      if (t - b.updated > (this.capacity / this.refillPerSec) * 1000) this.buckets.delete(k);
    }
  }
}
