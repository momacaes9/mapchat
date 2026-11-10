/**
 * Tiny PostgREST client that always acts AS THE CALLER (their JWT), never with
 * the service role, so Row Level Security and visible_friends() decide what
 * the routing service can see.
 */
export interface Friend {
  user_id: string;
  display_name: string;
  lat: number;
  lng: number;
  accuracy_m: number | null;
  floor: number | null;
  place_id: string | null;
  place_slug: string | null;
  place_name: string | null;
  share_precision: "exact" | "building";
  recorded_at: string;
}

export interface MyLocation {
  lat: number;
  lng: number;
  floor: number | null;
  place_slug: string | null;
  recorded_at: string;
}

export class AuthError extends Error {}

export class SupabaseAsUser {
  constructor(
    private readonly url: string,
    private readonly anonKey: string,
    private readonly jwt: string,
  ) {}

  private async rpc<T>(fn: string): Promise<T> {
    const res = await fetch(`${this.url}/rest/v1/rpc/${fn}`, {
      method: "POST",
      headers: {
        apikey: this.anonKey,
        Authorization: `Bearer ${this.jwt}`,
        "Content-Type": "application/json",
      },
      body: "{}",
    });
    if (res.status === 401 || res.status === 403) throw new AuthError("invalid or expired token");
    if (!res.ok) throw new Error(`Supabase rpc ${fn} failed: HTTP ${res.status}`);
    return (await res.json()) as T;
  }

  visibleFriends(): Promise<Friend[]> {
    return this.rpc<Friend[]>("visible_friends");
  }

  async myLatestLocation(): Promise<MyLocation | null> {
    const rows = await this.rpc<MyLocation[]>("my_latest_location");
    return rows[0] ?? null;
  }
}
