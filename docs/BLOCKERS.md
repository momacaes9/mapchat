# Blockers

No step stayed blocked this session. These problems came up and were worked
around:

| Problem | Workaround | Follow-up |
|---|---|---|
| Docker Desktop was not installed (no app, no `docker` binary). | Installed the free, open-source Colima engine plus the Docker CLI via Homebrew (`colima start --cpu 4 --memory 8 --disk 60`). | Decide whether to keep Colima (QUESTIONS.md #1). After a reboot, run `colima start` before `supabase start`. |
| `docker compose` (the plugin form) is not available with the Homebrew Docker CLI. | Used the standalone `docker-compose` binary. | None. |
| The public Overpass API returned "502, at capacity". | The seed script retries with exponential backoff across two mirrors, and it succeeded. | None. |
| Supabase analytics (Logflare/Vector) is known to need Docker Desktop's socket. | Disabled `[analytics]` in `supabase/config.toml` for local development. | Only matters if you want the local logs UI. |
