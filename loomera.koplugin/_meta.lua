local _ = require("gettext")
return {
    name = "loomera",
    fullname = _("Loomera"),
    -- Single source of truth for the plugin version. Bump on each release; the
    -- in-app "Check for updates" reads this and compares it against the same
    -- field in the public repo (github.com/apartri/Loomera-Koreader).
    version = "1.1.0",
    description = _("Sync reading stats + highlights to your Loomera server and browse its library — replaces Syncthing."),
}
