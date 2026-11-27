# Depost Arena

Browser-based low-poly 3D arcade arena for the existing Depost account and inventory.

## Included
- Three.js first-person arena client with desktop and touch controls.
- Team and free-for-all room modes.
- Supabase Auth token reuse from the existing `depost-auth2` session.
- Inventory-backed cosmetic loadout; equipped items are not consumed.
- Colyseus WebSocket server with server-owned room membership, player state and score calculation.
- Per-user match results protected by Row Level Security.
- Additive SQL migration at `online/arena.sql`.

## Setup
1. Run `online/arena.sql` in the existing Supabase project's SQL editor. Do not rerun the original installer on a live database.
2. Import `arena-server/render.yaml` as a Blueprint in Render.
3. In Render, set `SUPABASE_ANON_KEY` to the existing Supabase publishable/anon key. Do not use a service-role key. The Supabase URL and allowed GitHub Pages origin are already in the blueprint.
4. Wait for the Render service health endpoint `/health` to return `{"ok":true}`.
5. Confirm the Render hostname matches `GAME_SERVER_URL` in `arena/src/config.js`, then change `SERVER_READY=false` to `SERVER_READY=true`.
6. Publish the repository with GitHub Pages and open `/arena/`.

## Notes
The browser requires a valid existing Depost session in localStorage. The client reads the authenticated user's inventory rows and loadout table. RLS and the migration trigger enforce item ownership. The game server validates the Supabase session for every connection and only accepts a loadout item that the same user owns.

The code and deployment blueprint are prepared, but the public game server is not running until the Render Blueprint is deployed and the Supabase migration is applied. Test with multiple accounts before announcing public matchmaking.
