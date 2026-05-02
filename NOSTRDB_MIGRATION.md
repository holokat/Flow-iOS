# NostrDB Migration Retired

The NostrDB migration was retired on 2026-05-02.

Flow now follows the Wisp-style architecture in `docs/superpowers/plans/2026-05-02-wisp-speed-parity-without-nostrdb.md`: a hot `EventRepository` cache, selective SQLite-backed event persistence, bounded relay health, outbox-first routing, and batched UI/metadata work.
