# Depost Arena

Browser-based low-poly 3D arcade arena for the existing Depost account and inventory.

## Included
- Three.js first-person arena client, desktop and touch controls.
- Team and free-for-all room modes.
- Supabase Auth token reuse from the existing `depost-auth2` session.
- Inventory-backed cosmetic loadout; equipped items are not consumed.
- Colyseus WebSocket server with server-owned room membership, player state and score calculation.
- Additive SQL migration at `online/arena.sql`.

## Setup
1. Run `online/arena.sql` in the existing Supabase project's SQL editor. Do not rerun the original installer on a live database.
2. Deploy `arena-server` on a Node.js 20+ host. Set `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `PORT`, and `ALLOWED_ORIGIN`. The key must be the public publishable/anon key, never a service-role key.
3. Set `GAME_SERVER_URL` in `arena/src/config.js` to the deployed secure WebSocket URL (`wss://...`).
4. Publish the repository's `arena/` folder with GitHub Pages; open `/arena/`.

## Notes
The browser requires a valid existing Depost session in localStorage. Arena currently reads the authenticated user's inventory rows and loadout table. RLS and the migration trigger enforce item ownership. The game server validates the Supabase session for every connection and only accepts a loadout item that the same user owns.

This is an initial deployable game foundation, not a claim that a public game server is already running. A production launch still needs hosting, TLS/WSS, environment variables, a live Supabase migration, and end-to-end testing with multiple accounts.
