--[[
Loomera — KOReader plugin.

Pushes reading STATS (statistics.sqlite3) and HIGHLIGHTS (per-book sidecar
metadata.epub.lua) to a self-hosted Loomera server over HTTPS, and opens the
server's OPDS catalog in KOReader's built-in browser. Designed to REPLACE
Syncthing: every network call is opt-in, pcall-guarded, and surfaces a clear
InfoMessage on failure so it can never crash KOReader.

Server contract (targets, do not change server-side behaviour):
  POST {server}/nightly/reading     multipart file=statistics.sqlite3 bytes
  POST {server}/nightly/highlights  multipart file=metadata.epub.lua bytes,
                                     book=<book base name>
  GET  {server}/opds                OPDS catalog (no auth)
Both POSTs are guarded by  Authorization: Bearer <sync_token>.
]]--

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
-- ltn12 (part of the luasocket stack) is required lazily inside
-- httpPostMultipart so that on a stripped build lacking the socket stack the
-- plugin still LOADS (menus + OPDS browse keep working; only network sync degrades).
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

-- Public plugin repo. "Check for updates" reads the version from this repo's
-- _meta.lua (raw) and compares it to this install's _meta.lua version. The raw
-- file is fetched as plain text and pattern-matched — never executed.
local REPO_URL = "https://github.com/apartri/Loomera-Koreader"
local UPDATE_META_URL =
    "https://raw.githubusercontent.com/apartri/Loomera-Koreader/main/loomera.koplugin/_meta.lua"

local Loomera = WidgetContainer:extend{
    name = "loomera",
    -- Minimum gap (seconds) between sync-on-sleep pushes, to debounce rapid
    -- suspend/close cycles from hammering the server.
    AUTOSYNC_DEBOUNCE = 60,
    -- Short timeout (seconds) for the reachability probe so the sleep-sync
    -- never blocks the UI when the server is down / out of range.
    PROBE_TIMEOUT = 4,
}

------------------------------------------------------------------------------
-- Config loading
------------------------------------------------------------------------------

-- On-device fallback settings file (used when loomera_config.lua is empty, i.e.
-- the plugin was installed without the wizard baking in a URL/token).
local function settings_path()
    return DataStorage:getSettingsDir() .. "/loomera.lua"
end

-- Defensive JSON decode. KOReader ships rapidjson; older builds ship dkjson as
-- "json". Try both; return nil on any failure so callers degrade gracefully.
local function decode_json(str)
    if type(str) ~= "string" or str == "" then return nil end
    local ok, mod = pcall(require, "rapidjson")
    if ok and mod and mod.decode then
        local ok2, res = pcall(mod.decode, str)
        if ok2 and type(res) == "table" then return res end
    end
    local ok3, mod3 = pcall(require, "json")
    if ok3 and mod3 and mod3.decode then
        local ok4, res4 = pcall(mod3.decode, str)
        if ok4 and type(res4) == "table" then return res4 end
    end
    return nil
end

function Loomera:init()
    -- 1) wizard-baked config (shipped template returns empty strings).
    local cfg = {}
    local ok, loaded = pcall(require, "loomera_config")
    if ok and type(loaded) == "table" then cfg = loaded end
    self.server_url = (cfg.server_url or ""):gsub("%s+", "")
    self.sync_token = (cfg.sync_token or ""):gsub("%s+", "")
    self.from_wizard = (self.server_url ~= "" and self.sync_token ~= "")

    -- 2) on-device fallback (any URL/token the user typed in the on-device
    --    Settings dialog when the wizard didn't bake them in).
    self.store = LuaSettings:open(settings_path())
    if not self.from_wizard then
        self.server_url = (self.store:readSetting("server_url") or self.server_url or ""):gsub("%s+", "")
        self.sync_token = (self.store:readSetting("sync_token") or self.sync_token or ""):gsub("%s+", "")
    end
    self._last_autosync = 0

    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end

    -- Seamless library: auto-register our OPDS feed into KOReader's native OPDS
    -- browser list the moment the plugin loads, so "Loomera Library" simply
    -- appears in Search -> OPDS catalog with no manual add. Guarded so a failure
    -- here can never block plugin init.
    pcall(function() self:registerCatalog() end)
end

function Loomera:isConfigured()
    return self.server_url ~= "" and self.sync_token ~= ""
end

-- Trim any trailing slashes so we can safely append "/nightly/..." etc.
function Loomera:baseUrl()
    return (self.server_url or ""):gsub("/+$", "")
end

------------------------------------------------------------------------------
-- HTTP: multipart/form-data POST helper
------------------------------------------------------------------------------

-- parts: list of { name=, filename=(optional), content_type=(optional), data= }
-- Returns ok(boolean), code(number|string), body(string).
-- Picks ssl.https for https:// URLs, socket.http otherwise. Built manually so
-- we control the boundary, Content-Length, and Authorization header exactly.
function Loomera.httpPostMultipart(url, parts, token)
    local is_https = url:lower():match("^https://") ~= nil
    -- Require lazily and guarded: a stripped build might lack ssl.https / ltn12.
    local httpmod, ltn12
    do
        local mod_name = is_https and "ssl.https" or "socket.http"
        local ok, mod = pcall(require, mod_name)
        if not ok or not mod then
            return false, "no-http", "HTTP module unavailable: " .. mod_name
        end
        httpmod = mod
        local ok2, l = pcall(require, "ltn12")
        if not ok2 or not l then
            return false, "no-ltn12", "ltn12 module unavailable"
        end
        ltn12 = l
    end

    local boundary = "----LoomeraBoundary" .. tostring(os.time()) .. tostring(math.random(100000, 999999))
    local CRLF = "\r\n"
    local chunks = {}
    for _, p in ipairs(parts) do
        local header = "--" .. boundary .. CRLF
            .. 'Content-Disposition: form-data; name="' .. p.name .. '"'
        if p.filename then
            header = header .. '; filename="' .. p.filename .. '"'
        end
        header = header .. CRLF
        if p.content_type then
            header = header .. "Content-Type: " .. p.content_type .. CRLF
        end
        header = header .. CRLF
        chunks[#chunks + 1] = header
        chunks[#chunks + 1] = p.data or ""
        chunks[#chunks + 1] = CRLF
    end
    chunks[#chunks + 1] = "--" .. boundary .. "--" .. CRLF
    local body = table.concat(chunks)

    local resp = {}
    local headers = {
        ["Content-Type"] = "multipart/form-data; boundary=" .. boundary,
        ["Content-Length"] = tostring(#body),
    }
    if token and token ~= "" then
        headers["Authorization"] = "Bearer " .. token
    end

    -- socket.http / ssl.https request returns: r (1 or nil), code, headers,
    -- status. We pcall it and bundle BOTH r and code into a table so neither is
    -- lost (pcall keeps all return values: ok, r, code, ...).
    local ok, r, code = pcall(httpmod.request, {
        url = url,
        method = "POST",
        headers = headers,
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(resp),
    })
    if not ok then
        -- The request threw (e.g. TLS handshake / DNS failure). `r` holds the
        -- error object in this case.
        return false, "exception", tostring(r)
    end
    if r == nil then
        -- request returned nil; `code` is the error string (e.g. "connection
        -- refused", "timeout", "host not found").
        return false, "request-failed", tostring(code)
    end
    -- Success path: `code` is the numeric HTTP status; resp holds the body.
    return true, code, table.concat(resp)
end

-- Lightweight GET used only by the reachability probe. Mirrors the lazy/guarded
-- module loading of httpPostMultipart. Returns ok(boolean), code(number|string),
-- body(string). `timeout` is in seconds and is applied to the socket layer so a
-- dead/unreachable server fails fast instead of blocking the UI.
function Loomera.httpGet(url, timeout)
    local is_https = url:lower():match("^https://") ~= nil
    local httpmod, ltn12
    do
        local mod_name = is_https and "ssl.https" or "socket.http"
        local ok, mod = pcall(require, mod_name)
        if not ok or not mod then
            return false, "no-http", "HTTP module unavailable: " .. mod_name
        end
        httpmod = mod
        local ok2, l = pcall(require, "ltn12")
        if not ok2 or not l then
            return false, "no-ltn12", "ltn12 module unavailable"
        end
        ltn12 = l
    end

    -- Apply a global socket timeout for the probe. socket.http / ssl.https both
    -- honour the TIMEOUT field on the module table; we set it best-effort and
    -- restore it afterwards so we don't perturb other callers.
    local prev_timeout = httpmod.TIMEOUT
    if timeout then httpmod.TIMEOUT = timeout end

    local resp = {}
    local ok, r, code = pcall(httpmod.request, {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(resp),
    })

    httpmod.TIMEOUT = prev_timeout

    if not ok then
        return false, "exception", tostring(r)
    end
    if r == nil then
        return false, "request-failed", tostring(code)
    end
    return true, code, table.concat(resp)
end

------------------------------------------------------------------------------
-- File reading
------------------------------------------------------------------------------

local function read_file_bytes(path)
    if not path then return nil, "no path" end
    local f, err = io.open(path, "rb")
    if not f then return nil, err or ("cannot open " .. path) end
    local data = f:read("*a")
    f:close()
    if not data then return nil, "empty read: " .. path end
    return data
end

local function basename(path)
    if not path then return nil end
    return path:gsub("[/\\]+$", ""):match("([^/\\]+)$") or path
end

-- Return a file's last-modification time (epoch seconds), or nil if unknown.
-- Uses lfs (LuaFileSystem, always present in KOReader) and guards everything so
-- a missing path / odd FS just yields nil (treated as "needs push" by callers).
local function file_mtime(path)
    if not path then return nil end
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok or not lfs then
        ok, lfs = pcall(require, "lfs")
    end
    if not ok or not lfs or not lfs.attributes then return nil end
    local ok2, attr = pcall(lfs.attributes, path, "modification")
    if ok2 and type(attr) == "number" then return attr end
    return nil
end

-- Strip the file extension from a basename, e.g. "Dune.epub" -> "Dune".
local function strip_ext(name)
    if not name then return nil end
    return (name:gsub("%.[%w]+$", ""))
end

------------------------------------------------------------------------------
-- Status helpers
------------------------------------------------------------------------------

function Loomera:notify(msg, timeout)
    UIManager:show(InfoMessage:new{ text = msg, timeout = timeout or 3 })
end

-- Turn an httpPostMultipart result into a user-facing message. On HTTP 2xx with
-- a JSON body, surface {status,count}/{written}; otherwise a clear error.
local function format_result(ok, code, body)
    if not ok then
        return false, T(_("Loomera: network error\n%1"), tostring(body or code))
    end
    local numeric = tonumber(code)
    if numeric and numeric >= 200 and numeric < 300 then
        local j = decode_json(body)
        if j then
            if j.count ~= nil then
                return true, T(_("Loomera: synced (%1 rows)"), tostring(j.count))
            elseif j.written ~= nil then
                return true, T(_("Loomera: highlights saved (%1)"), tostring(j.written))
            elseif j.status ~= nil then
                return true, T(_("Loomera: %1"), tostring(j.status))
            end
        end
        return true, _("Loomera: sync complete")
    end
    -- Non-2xx: try to show the server's message.
    local j = decode_json(body)
    local detail = j and (j.message or j.status) or tostring(code)
    return false, T(_("Loomera: server error (%1)\n%2"), tostring(code), tostring(detail))
end

------------------------------------------------------------------------------
-- Sync: reading stats
------------------------------------------------------------------------------

-- Locate the reading-statistics DB. Always written by the Statistics plugin to
-- the settings dir.
function Loomera:statsDbPath()
    return DataStorage:getSettingsDir() .. "/statistics.sqlite3"
end

-- Internal: perform the stats push (assumes we are already online). Returns
-- ok, message. The statistics DB is ALWAYS pushed in full; the server uses
-- INSERT OR REPLACE on (start_time, title), so re-pushing the whole DB is
-- idempotent — no duplicate rows are ever created.
function Loomera:_pushStats()
    local path = self:statsDbPath()
    local data, err = read_file_bytes(path)
    if not data then
        return false, T(_("Loomera: no statistics DB\n%1"), tostring(err))
    end
    local url = self:baseUrl() .. "/nightly/reading"
    local ok, code, body = self.httpPostMultipart(url, {
        { name = "file", filename = "statistics.sqlite3",
          content_type = "application/octet-stream", data = data },
    }, self.sync_token)
    local good, msg = format_result(ok, code, body)
    if not good then logger.warn("Loomera: stats sync failed:", msg) end
    return good, msg
end

------------------------------------------------------------------------------
-- Sync: highlights for the current book
------------------------------------------------------------------------------

-- Generalized: resolve the sidecar metadata.<ext>.lua path for ANY book file
-- path (not just the open document). Returns lua_path, book_base or nil, reason.
--
-- Strategy (version-robust; respects collocated-vs-centralized sidecar setting):
--   1) Ask DocSettings for the sidecar dir, then probe metadata.epub.lua and the
--      generic metadata.<ext>.lua naming inside it.
--   2) Fall back to a collocated "<file>.sdr/" next to the book.
function Loomera:sidecarForFile(file)
    if not file then return nil, _("No book file") end
    local book_base = strip_ext(basename(file)) or basename(file)
    local ext = file:match("%.([%w]+)$")

    -- Build the ordered list of candidate metadata filenames to probe in a dir.
    local function candidates_in(dir)
        local names = { "metadata.epub.lua" }
        if ext then names[#names + 1] = "metadata." .. ext:lower() .. ".lua" end
        for _, n in ipairs(names) do
            local candidate = dir .. "/" .. n
            local f = io.open(candidate, "rb")
            if f then f:close(); return candidate end
        end
        return nil
    end

    -- 1) Preferred: ask DocSettings for the sidecar directory.
    local ok, DocSettings = pcall(require, "docsettings")
    if ok and DocSettings and DocSettings.getSidecarDir then
        local okd, dir = pcall(function() return DocSettings:getSidecarDir(file) end)
        if okd and dir then
            local hit = candidates_in(dir)
            if hit then return hit, book_base end
        end
    end

    -- 2) Last resort: collocated "<file>.sdr/" next to the book.
    local sdr = file:gsub("(%.%w+)$", "") .. ".sdr"
    local hit = candidates_in(sdr)
    if hit then return hit, book_base end

    return nil, _("Sidecar metadata not found")
end

-- Resolve the CURRENTLY-OPEN document's sidecar. Thin wrapper over
-- sidecarForFile for the open-book case.
function Loomera:currentSidecar()
    local doc = self.ui and self.ui.document
    local file = doc and doc.file
    if not file then return nil, _("No book is open") end
    return self:sidecarForFile(file)
end

-- Push a single sidecar's bytes to /nightly/highlights. The server overwrites
-- <book>.sdr/metadata.epub.lua atomically, so re-pushing the same book is
-- idempotent — no duplicate highlights are created. Returns ok(boolean).
function Loomera:_pushOneSidecar(lua_path, book_base)
    local data = read_file_bytes(lua_path)
    if not data then return false end
    local url = self:baseUrl() .. "/nightly/highlights"
    local ok, code, body = self.httpPostMultipart(url, {
        { name = "file", filename = "metadata.epub.lua",
          content_type = "application/octet-stream", data = data },
        { name = "book", data = tostring(book_base) },
    }, self.sync_token)
    local good = format_result(ok, code, body)
    if not good then logger.warn("Loomera: highlight push failed for", tostring(book_base)) end
    return good
end

-- Enumerate every known book file via ReadHistory. Returns a list of file paths.
function Loomera:knownBookFiles()
    local files = {}
    local ok, ReadHistory = pcall(require, "readhistory")
    if not ok or not ReadHistory then return files end
    local hist = ReadHistory.hist
    if type(hist) ~= "table" then return files end
    for _, item in ipairs(hist) do
        local f = item and item.file
        if f and f ~= "" then files[#files + 1] = f end
    end
    return files
end

------------------------------------------------------------------------------
-- Full sync: reading progress + ALL highlights, idempotent.
------------------------------------------------------------------------------

-- fullSync(opts): opts = { silent=bool, force_all=bool }.
-- Assumes the caller has already established connectivity (manual path uses
-- goOnlineToRun; periodic path probes reachability first).
--
--   * ALWAYS pushes the statistics DB (one small file; idempotent via
--     INSERT OR REPLACE on (start_time,title)).
--   * Pushes per-book highlight sidecars enumerated from ReadHistory. When
--     force_all is false only sidecars whose mtime is newer than the stored
--     "last_sync" timestamp are pushed (incremental); when true EVERY book's
--     sidecar is pushed (full reconcile, the manual "Sync" button).
--   * On overall success stores last_sync = os.time().
--
-- Returns { reading_ok=bool, highlight_files=N, errors=N }.
function Loomera:fullSync(opts)
    opts = opts or {}
    local summary = { reading_ok = false, highlight_files = 0, errors = 0 }
    if not self:isConfigured() then
        summary.errors = summary.errors + 1
        return summary
    end

    local last_sync = tonumber(self.store:readSetting("last_sync")) or 0

    -- 1) Reading stats (always).
    local stats_ok = pcall(function()
        local good = self:_pushStats()
        summary.reading_ok = good and true or false
        if not good then summary.errors = summary.errors + 1 end
    end)
    if not stats_ok then summary.errors = summary.errors + 1 end

    -- 2) Highlights for each known book.
    for _, file in ipairs(self:knownBookFiles()) do
        pcall(function()
            local lua_path, book_base = self:sidecarForFile(file)
            if not lua_path then return end -- no sidecar for this book; skip.
            if not opts.force_all then
                -- Incremental: skip sidecars not modified since last_sync.
                local mt = file_mtime(lua_path)
                if mt and mt <= last_sync then return end
            end
            local good = self:_pushOneSidecar(lua_path, book_base)
            if good then
                summary.highlight_files = summary.highlight_files + 1
            else
                summary.errors = summary.errors + 1
            end
        end)
    end

    -- On overall success, advance the incremental watermark.
    if summary.errors == 0 then
        self.store:saveSetting("last_sync", os.time())
        pcall(function() self.store:flush() end)
    end

    if not opts.silent then
        logger.dbg("Loomera: fullSync", summary.reading_ok, summary.highlight_files, summary.errors)
    end
    return summary
end

-- Menu entry: "Sync". User-initiated full reconcile — OK to bring Wi-Fi up.
-- Shows exactly one InfoMessage summarizing the result. Never crashes.
function Loomera:manualSync()
    if not self:isConfigured() then return self:promptConfigure() end
    local function run()
        local ok, summary = pcall(function()
            return self:fullSync{ silent = false, force_all = true }
        end)
        if not ok or not summary then
            self:notify(_("Loomera: unexpected error during sync"), 5)
            return
        end
        local reading = summary.reading_ok and _("reading ✓") or _("reading ✗")
        if summary.errors == 0 then
            self:notify(T(_("Loomera: synced — %1, %2 highlight files"),
                reading, tostring(summary.highlight_files)))
        else
            self:notify(T(_("Loomera: synced with errors — %1, %2 highlight files, %3 error(s)"),
                reading, tostring(summary.highlight_files), tostring(summary.errors)), 6)
        end
    end
    if not pcall(function() NetworkMgr:goOnlineToRun(run) end) then
        -- goOnlineToRun can throw if Wi-Fi can't be brought up; degrade.
        self:notify(_("Loomera: could not connect to Wi-Fi"), 5)
    end
end

------------------------------------------------------------------------------
-- OPDS catalog browsing
------------------------------------------------------------------------------

-- Auto-register our OPDS feed into KOReader's NATIVE OPDS browser list so that
-- "Loomera Library" simply APPEARS in Search -> OPDS catalog with no manual add.
--
-- The native OPDS plugin (plugins/opds.koplugin) persists its catalog list in a
-- LuaSettings file at  DataStorage:getSettingsDir() .. "/opds.lua"  under the
-- key "servers" — an ARRAY of { title=, url=, username=, password= } tables.
-- OPDSBrowser re-reads "servers" each time the catalog is opened, so an appended
-- entry shows up with NO restart (just close/reopen the OPDS browser).
--
-- Idempotent & dup-safe by URL: we never insert a second entry for the same feed
-- URL. If a prior "Loomera Library"-titled entry exists with a stale URL (e.g.
-- the user changed the server in Settings), we update it in place to the current
-- feed. Fully pcall-guarded — any failure returns false and never crashes KO.
function Loomera:registerCatalog()
    if not self:isConfigured() then return false end
    local ok = pcall(function()
        local feed_url = self:baseUrl() .. "/opds"
        local opds = LuaSettings:open(DataStorage:getSettingsDir() .. "/opds.lua")
        local servers = opds:readSetting("servers", {})
        if type(servers) ~= "table" then servers = {} end

        -- 1) Already present by URL? Nothing to do — keep it dup-safe.
        for _, srv in ipairs(servers) do
            if type(srv) == "table" and srv.url == feed_url then
                return true
            end
        end

        -- 2) An existing "Loomera Library" entry with a stale URL? Update it in
        --    place rather than leaving a dead catalog around.
        for _, srv in ipairs(servers) do
            if type(srv) == "table" and srv.title == "Loomera Library" then
                srv.url = feed_url
                opds:saveSetting("servers", servers)
                opds:flush() -- saveSetting only buffers; flush() persists it.
                return true
            end
        end

        -- 3) Fresh install / first run: append our entry. /opds is unauthenticated
        --    so username/password stay nil.
        table.insert(servers, { title = "Loomera Library", url = feed_url })
        opds:saveSetting("servers", servers)
        opds:flush() -- MUST flush; saveSetting alone only buffers.
    end)
    return ok
end

-- "Browse my library" — opens the plugin's OWN OPDS browser (loomera_opds),
-- which fetches + displays the Life Calendar catalog itself rather than relying
-- on KOReader's native OPDS plugin. The native-catalog open is kept ONLY as a
-- last-resort fallback for any build where the bundled browser fails to load.
function Loomera:openOPDS()
    if self.server_url == "" then return self:promptConfigure() end
    local ok = pcall(function()
        require("loomera_opds").browse(self)
    end)
    if not ok then self:openOPDSNative() end
end

-- Fallback only: register our feed into KOReader's native OPDS browser list and
-- open it (the pre-bundled-browser behaviour). Every step is pcall-guarded.
function Loomera:openOPDSNative()
    if self.server_url == "" then return self:promptConfigure() end
    local url = self:baseUrl() .. "/opds"

    -- a) Make sure our entry exists in the native OPDS list (idempotent).
    pcall(function() self:registerCatalog() end)

    -- b) Preferred: ask the NATIVE OPDS plugin to open its catalog list via an
    --    event (plugins/opds.koplugin handles onShowOPDSCatalog). This lands the
    --    user on the catalog list where "Loomera Library" is now registered —
    --    the seamless path. (Event name needs on-device confirmation per build.)
    local opened = pcall(function()
        if self.ui and self.ui.handleEvent then
            local Event = require("ui/event")
            local handled = self.ui:handleEvent(Event:new("ShowOPDSCatalog"))
            -- handleEvent returns true only if a handler consumed the event.
            if handled then return true end
        end
        error("ShowOPDSCatalog event not handled")
    end)

    -- c) Fallback: try to open KOReader's built-in OPDS catalog browser directly,
    --    pointed at our feed. Current KOReader (2023+) exposes
    --    OPDSCatalog:showCatalog{ catalog = {...} }; older builds expose the
    --    OPDSBrowser widget. We try each in turn.
    if not opened then
        opened = pcall(function()
            local OPDSCatalog = require("apps/opdscatalog/opdscatalog")
            if OPDSCatalog and OPDSCatalog.showCatalog then
                OPDSCatalog:showCatalog{
                    title = "Loomera",
                    url = url,             -- some versions key on `url`
                    catalog = { title = "Loomera", url = url },
                }
                return true
            end
            error("showCatalog unavailable")
        end)
    end

    if not opened then
        opened = pcall(function()
            local OPDSBrowser = require("apps/opds/opdsbrowser")
            if OPDSBrowser then
                local browser = OPDSBrowser:new{ root_catalog_title = "Loomera" }
                if browser.showCatalog then
                    browser:showCatalog{ title = "Loomera", url = url }
                elseif browser.genItemTableFromURL then
                    browser:showCatalog(url, "Loomera")
                else
                    error("no OPDSBrowser entry point")
                end
                return true
            end
            error("OPDSBrowser unavailable")
        end)
    end

    -- d) Final fallback: the catalog IS registered, so guide the user to it via
    --    the top menu and show the feed URL.
    if not opened then
        self:notify(T(_("Loomera Library is registered.\nOpen it via: Search -> OPDS catalog -> Loomera Library\n\n%1"), url), 8)
    end
end

------------------------------------------------------------------------------
-- Settings dialog (on-device server URL + token)
------------------------------------------------------------------------------

function Loomera:promptConfigure()
    self:showSettingsDialog()
end

function Loomera:showSettingsDialog()
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Loomera server settings"),
        fields = {
            {
                description = _("Server URL (https://host)"),
                text = self.server_url or "",
                hint = "https://loomera.example.com",
            },
            {
                description = _("Sync token (Bearer)"),
                text = self.sync_token or "",
                hint = _("paste your SYNC_TOKEN"),
                text_type = "password",
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local f = dialog:getFields()
                        local url = (f[1] or ""):gsub("%s+", "")
                        local tok = (f[2] or ""):gsub("%s+", "")
                        self.server_url = url
                        self.sync_token = tok
                        -- Persist to the on-device fallback file so they survive
                        -- restarts even without the wizard config.
                        self.store:saveSetting("server_url", url)
                        self.store:saveSetting("sync_token", tok)
                        self.store:flush()
                        UIManager:close(dialog)
                        self:notify(_("Loomera: settings saved"))
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

------------------------------------------------------------------------------
-- Update check (against the public repo)
------------------------------------------------------------------------------

-- Pull a `version = "x.y.z"` field out of a _meta.lua source string. A plain
-- pattern match (NOT loadstring), so remote text is never executed. nil if absent.
local function parse_meta_version(src)
    if type(src) ~= "string" then return nil end
    return src:match('version%s*=%s*["\']([%w%.%-]+)["\']')
end

-- True if dotted-numeric version `a` is strictly newer than `b`
-- (e.g. "1.2.0" > "1.1.9"). Non-numeric parts count as 0, so a weird value
-- degrades to "not newer" rather than throwing.
local function version_gt(a, b)
    local function parts(v)
        local t = {}
        for n in tostring(v or ""):gmatch("%d+") do t[#t + 1] = tonumber(n) end
        return t
    end
    local pa, pb = parts(a), parts(b)
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0
        if x ~= y then return x > y end
    end
    return false
end

-- This install's version, read from the plugin's own _meta.lua (the single
-- source of truth — sibling require, same as loomera_config). "?" if unreadable.
function Loomera:localVersion()
    local ok, meta = pcall(require, "_meta")
    if ok and type(meta) == "table" and meta.version then
        return tostring(meta.version)
    end
    return "?"
end

-- Menu entry: "Check for updates". User-initiated, so OK to bring Wi-Fi up.
-- Compares this install's version to the public repo's _meta.lua and shows
-- exactly one InfoMessage (available / up-to-date / error). Never crashes.
function Loomera:checkForUpdates()
    local function run()
        local ok, code, body = Loomera.httpGet(UPDATE_META_URL, 10)
        if not ok or code ~= 200 then
            self:notify(T(_("Loomera: couldn't check for updates\n%1"), tostring(code)), 5)
            return
        end
        local remote = parse_meta_version(body)
        local localv = self:localVersion()
        if not remote then
            self:notify(_("Loomera: couldn't read the latest version"), 5)
            return
        end
        if version_gt(remote, localv) then
            self:notify(T(_("Loomera: update available — v%1 (you have v%2).\n" ..
                "Get it at %3 — or re-download from your server's Setup page\n" ..
                "(Books & e-reader) to keep your URL + token."),
                remote, localv, REPO_URL), 12)
        else
            self:notify(T(_("Loomera: up to date (v%1)."), localv), 4)
        end
    end
    if not pcall(function() NetworkMgr:goOnlineToRun(run) end) then
        self:notify(_("Loomera: could not connect to Wi-Fi"), 5)
    end
end

------------------------------------------------------------------------------
-- Main menu registration
------------------------------------------------------------------------------

function Loomera:addToMainMenu(menu_items)
    menu_items.loomera = {
        text = _("Loomera"),
        sub_item_table = {
            {
                text = _("Sync"),
                callback = function() self:manualSync() end,
            },
            {
                text = _("Browse my library"),
                callback = function() self:openOPDS() end,
            },
            {
                text = _("Check for updates"),
                keep_menu_open = true,
                callback = function() self:checkForUpdates() end,
            },
            {
                text = _("Settings / About"),
                keep_menu_open = true,
                callback = function()
                    local where = self.from_wizard and _("from wizard config")
                        or _("on-device settings")
                    local server = self.server_url ~= "" and self.server_url
                        or _("(not set)")
                    local lines = {
                        _("Loomera replaces Syncthing by pushing your reading"),
                        _("stats + highlights to your own server."),
                        "",
                        T(_("Version: %1"), self:localVersion()),
                        T(_("Server: %1"), server),
                        T(_("Config source: %1"), where),
                        T(_("Token: %1"), self.sync_token ~= "" and _("set") or _("(not set)")),
                        "",
                        _("Tap below to edit the server URL / token."),
                    }
                    UIManager:show(InfoMessage:new{
                        text = table.concat(lines, "\n"),
                        dismiss_callback = function() self:showSettingsDialog() end,
                    })
                end,
            },
        },
    }
end

------------------------------------------------------------------------------
-- Reachability probe (NEVER forces Wi-Fi)
------------------------------------------------------------------------------

-- Best-effort check that the server is reachable RIGHT NOW without bringing up
-- Wi-Fi. Two gates, both guarded:
--   1) The radio/network is already up (NetworkMgr — whichever predicate the
--      installed build exposes; if none exist we optimistically pass this gate
--      and let the probe GET be the real arbiter).
--   2) A quick GET to {server}/opds with a short timeout returns a response.
-- Returns true only if both gates pass. Safe to call from the UI thread: the
-- GET is bounded by PROBE_TIMEOUT seconds.
function Loomera:isServerReachable()
    if not self:isConfigured() then return false end

    -- Gate 1: only consider Wi-Fi/network predicates that actually exist on this
    -- build. If a predicate exists and says "off", bail (don't force Wi-Fi). If
    -- NONE exist, we can't tell — fall through to the probe.
    local any_pred, network_up = false, false
    local function check(name)
        if type(NetworkMgr[name]) == "function" then
            any_pred = true
            local ok, up = pcall(function() return NetworkMgr[name](NetworkMgr) end)
            if ok and up then network_up = true end
        end
    end
    check("isWifiOn")
    check("isConnected")
    check("isOnline")
    if any_pred and not network_up then return false end

    -- Gate 2: short-timeout probe to the OPDS endpoint (no auth needed).
    local url = self:baseUrl() .. "/opds"
    local ok, code = self.httpGet(url, self.PROBE_TIMEOUT)
    if not ok then return false end
    -- Any HTTP response (even 401/404) proves the host is up and answering.
    return tonumber(code) ~= nil
end

------------------------------------------------------------------------------
-- Sync on sleep / power-off (debounced, opportunistic — never forces Wi-Fi)
------------------------------------------------------------------------------

-- Best-effort push fired when a book closes or the device sleeps / powers off.
-- Debounced and fully guarded; only syncs if the server is ALREADY reachable,
-- so it never blocks close/suspend or brings up Wi-Fi. (Routine syncing is now
-- this + the manual "Sync" button — there is no background 5-minute task.)
function Loomera:_autoSync()
    if not self:isConfigured() then return end
    local now = os.time()
    if now - (self._last_autosync or 0) < self.AUTOSYNC_DEBOUNCE then return end
    self._last_autosync = now
    pcall(function()
        if self:isServerReachable() then
            self:fullSync{ silent = true, force_all = false }
        end
    end)
end

function Loomera:onCloseDocument()
    self:_autoSync()
end

function Loomera:onSuspend()
    -- Attempt a push before the device sleeps (opportunistic; never forces Wi-Fi).
    self:_autoSync()
end

function Loomera:onPowerOff()
    -- And when the device is turned off.
    self:_autoSync()
end

return Loomera
