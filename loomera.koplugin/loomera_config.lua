-- Loomera plugin configuration (TEMPLATE).
--
-- The Loomera setup wizard rewrites this file with your personal server URL
-- and sync token when it generates your personalized plugin zip. If both
-- values below are left empty, the plugin falls back to an on-device settings
-- file you can fill in from: Menu -> Loomera -> Settings / About.
--
--   server_url : base URL of your Loomera server, e.g. "https://loomera.example.com"
--                (no trailing slash; the plugin appends /nightly/... and /opds)
--   sync_token : your SYNC_TOKEN, sent as "Authorization: Bearer <token>"
return {
    server_url = "",
    sync_token = "",
}
