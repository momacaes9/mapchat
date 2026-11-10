/**
 * The owner-only guard. This module is the ONLY path by which the agent sends
 * a message. It is constructed with the owner's phone number and a raw
 * transport function, and it refuses to send anywhere else.
 */

/** Normalizes a phone number to E.164 (+ and digits), or null if invalid. */
export function normalizePhone(raw: string | undefined | null): string | null {
  if (!raw) return null;
  const s = raw.trim();
  // iMessage handles may look like "tel:+1 (919) 555-1234" or carry a scheme.
  const digits = s.replace(/^tel:/i, "").replace(/[\s().-]/g, "");
  if (/^\+[1-9]\d{6,14}$/.test(digits)) return digits;
  if (/^1\d{10}$/.test(digits)) return `+${digits}`; // US without +
  if (/^\d{10}$/.test(digits)) return `+1${digits}`; // US 10-digit
  return null;
}

export type RawSend = (phoneE164: string, text: string) => Promise<void>;

export class OwnerOnlySender {
  private sentTimestamps: number[] = [];

  constructor(
    private readonly ownerPhone: string,
    private readonly rawSend: RawSend,
    /** Hard cap on outgoing messages per hour (protects against loops/spam). */
    private readonly maxPerHour = 30,
    private readonly now: () => number = () => Date.now(),
  ) {
    if (!normalizePhone(ownerPhone) || normalizePhone(ownerPhone) !== ownerPhone) {
      throw new Error("OwnerOnlySender needs the owner's phone in E.164 format");
    }
  }

  isOwner(sender: string | undefined | null): boolean {
    return normalizePhone(sender) === this.ownerPhone;
  }

  /** Sends to the owner. There is deliberately no "send to X" method. */
  async sendToOwner(text: string): Promise<boolean> {
    const t = this.now();
    this.sentTimestamps = this.sentTimestamps.filter((x) => t - x < 3_600_000);
    if (this.sentTimestamps.length >= this.maxPerHour) return false;
    this.sentTimestamps.push(t);
    // Defense in depth: the recipient is always the constructor's number.
    await this.rawSend(this.ownerPhone, text.slice(0, 1500));
    return true;
  }
}
