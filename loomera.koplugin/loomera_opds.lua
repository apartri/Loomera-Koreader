--[[
Loomera — self-contained OPDS browser for KOReader.

Displays the Life Calendar OPDS catalog in the plugin's OWN Menu (no dependency
on KOReader's native OPDS plugin). Flow:

  Browse → status categories  (Currently reading / Want to read / Read / All)
         → tag filter screen   (★ All books + every tag, within that status)
         → book list           (paginate "Load more", download best format, open)
  Browse → 🔍 Search…          (title/author, via the server's /opds/search)

The server feeds are unauthenticated with a known, controlled shape (see the
Flask opds.py), so small pattern parsers are enough — no XML library or native
OPDS code. Everything is pcall-guarded and degrades to a clear InfoMessage; this
must never crash KOReader.

Entry point:  require("loomera_opds").browse(self)   (self = the Loomera plugin)
]]--

local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local ConfirmBox = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local DataStorage = require("datastorage")
local Screen = require("device").screen
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local OPDS = {}

local FMT_PREF = { EPUB = 1, AZW3 = 2, MOBI = 3, AZW = 4, FB2 = 5,
                   PDF = 6, CBZ = 7, CBR = 8, DJVU = 9, TXT = 10, RTF = 11 }

-- Top-level categories shown first. status='' is "All books". Each opens the
-- tag-filter screen for that status, so filtering is one tap away.
local NAV_CATS = {
    { text = "🔖  Want to read",      status = "want" },
    { text = "✓  Read",               status = "read" },
    { text = "📚  All books",          status = "" },
}

------------------------------------------------------------------------------
-- Parsing (targeted at our own controlled OPDS output)
------------------------------------------------------------------------------

local _ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }
local function unescape(s)
    if type(s) ~= "string" then return "" end
    s = s:gsub("&#(%d+);", function(n)
        local c = tonumber(n); return c and string.char(c % 256) or "" end)
    s = s:gsub("&(%a+);", function(name) return _ENTITIES[name] or ("&" .. name .. ";") end)
    return s
end

local function urlencode(s)
    return (tostring(s or ""):gsub("[^%w%-_%.~]", function(ch)
        return string.format("%%%02X", string.byte(ch)) end))
end

-- Acquisition feed → entries(list), next_href(string|nil).
local function parse_feed(xml)
    local entries, next_href = {}, nil
    if type(xml) ~= "string" then return entries, nil end
    next_href = xml:match('<link[^>]-rel="next"[^>]-href="([^"]*)"')
    if next_href then next_href = unescape(next_href) end
    for block in xml:gmatch("<entry>(.-)</entry>") do
        local e = { acq = {} }
        e.title = unescape(block:match("<title>(.-)</title>") or "")
        e.author = unescape(block:match("<author>.-<name>(.-)</name>") or "")
        for href, mime in block:gmatch(
            '<link[^>]-rel="http://opds%-spec%.org/acquisition"[^>]-href="([^"]*)"[^>]-type="([^"]*)"') do
            local fmt = href:match("/download/%d+/([^/]+)") or "FILE"
            e.acq[#e.acq + 1] = { href = unescape(href), fmt = fmt:upper(), mime = mime }
        end
        -- Cover thumbnail (when the server has one): prefer the thumbnail link,
        -- fall back to the full image. Used for the tap-to-preview cover.
        local cover = block:match('<link[^>]-rel="http://opds%-spec%.org/image/thumbnail"[^>]-href="([^"]*)"')
                   or block:match('<link[^>]-rel="http://opds%-spec%.org/image"[^>]-href="([^"]*)"')
        if cover then e.cover = unescape(cover) end
        if e.title ~= "" and #e.acq > 0 then
            entries[#entries + 1] = e
        end
    end
    return entries, next_href
end

-- Navigation feed → { {title, href}, … }  (the nav + tag screens).
local function parse_nav_feed(xml)
    local out = {}
    if type(xml) ~= "string" then return out end
    for block in xml:gmatch("<entry>(.-)</entry>") do
        local title = unescape(block:match("<title>(.-)</title>") or "")
        local href = block:match('<link[^>]-rel="subsection"[^>]-href="([^"]*)"')
        if title ~= "" and href then
            out[#out + 1] = { title = title, href = unescape(href) }
        end
    end
    return out
end

local function best_acq(acq)
    local best, best_rank = acq[1], 9999
    for _, a in ipairs(acq) do
        local r = FMT_PREF[a.fmt] or 500
        if r < best_rank then best, best_rank = a, r end
    end
    return best
end

------------------------------------------------------------------------------
-- Download
------------------------------------------------------------------------------

local function abs_url(base, href)
    if type(href) ~= "string" then return base end
    if href:match("^https?://") then return href end
    return base .. href
end

local function safe_name(title)
    local s = (title or "book"):gsub('[/\\:%*%?"<>|%c]', "_")
    s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then s = "book" end
    return s:sub(1, 120)
end

-- Save downloads straight into the user's library root (home_dir) so a book
-- lands in their main library — immediately visible and openable — rather than
-- buried in a separate Loomera/ subfolder. Falls back to the data dir if no
-- home_dir is configured.
local function download_dir()
    local home
    if G_reader_settings then home = G_reader_settings:readSetting("home_dir") end
    return home or DataStorage:getDataDir()
end

local function http_ok(code, body)
    local n = tonumber(code)
    return n and n >= 200 and n < 300 and type(body) == "string" and #body > 0
end

local function download_and_open(plugin, entry)
    local a = best_acq(entry.acq)
    if not a then return end
    plugin:notify(T(_("Loomera: downloading\n%1…"), entry.title), 2)
    local ok, code, body = plugin.httpGet(abs_url(plugin:baseUrl(), a.href), 60)
    if not ok or not http_ok(code, body) then
        plugin:notify(T(_("Loomera: download failed (%1)"), tostring(code)), 5)
        return
    end
    local path = download_dir() .. "/" .. safe_name(entry.title) .. "." .. a.fmt:lower()
    local f, err = io.open(path, "wb")
    if not f then
        plugin:notify(T(_("Loomera: cannot save file\n%1"), tostring(err)), 5)
        return
    end
    f:write(body); f:close()
    UIManager:show(ConfirmBox:new{
        text = T(_("Downloaded:\n%1\n\nOpen it now?"), entry.title),
        ok_text = _("Read"), cancel_text = _("Later"),
        ok_callback = function()
            local opened = pcall(function() require("apps/reader/readerui"):showReader(path) end)
            if not opened then plugin:notify(T(_("Saved to:\n%1"), path), 5) end
        end,
    })
end

-- Tapping a book shows its cover (when the server has one) with a Read button;
-- "Read" downloads + opens. EVERYTHING is guarded so a missing cover, missing
-- image modules (stripped build), or a render error falls straight through to a
-- normal download — the cover is a nicety, never a gate.
local function preview_book(plugin, entry)
    local function just_download() return download_and_open(plugin, entry) end
    if not entry.cover then return just_download() end
    local ok_iv, ImageViewer = pcall(require, "ui/widget/imageviewer")
    local ok_ri, RenderImage = pcall(require, "ui/renderimage")
    if not (ok_iv and ImageViewer and ok_ri and RenderImage) then return just_download() end
    local ok, code, body = plugin.httpGet(abs_url(plugin:baseUrl(), entry.cover), 15)
    if not ok or not http_ok(code, body) then return just_download() end
    local ok_bb, bb = pcall(function() return RenderImage:renderImageData(body, nil, nil) end)
    if not ok_bb or not bb then return just_download() end
    local iv
    local shown = pcall(function()
        iv = ImageViewer:new{
            image = bb,
            image_disposable = true,   -- ImageViewer frees the BlitBuffer on close
            with_title_bar = true,
            title_text = entry.title,
            caption = (entry.author ~= "" and entry.author) or nil,
            fullscreen = false,
            buttons_table = {
                {
                    { text = _("Read"),
                      callback = function() UIManager:close(iv); just_download() end },
                    { text = _("Close"),
                      callback = function() UIManager:close(iv) end },
                },
            },
        }
        UIManager:show(iv)
    end)
    if not shown then
        pcall(function() if bb and bb.free then bb:free() end end)
        return just_download()
    end
end

------------------------------------------------------------------------------
-- Screens
------------------------------------------------------------------------------

-- Book list (acquisition feed at `url`), paginated. `title` labels the menu.
function OPDS._open_acq(plugin, url, title)
    local ok, code, body = plugin.httpGet(url, 20)
    if not ok or not http_ok(code, body) then
        plugin:notify(T(_("Loomera: could not load books (%1)"), tostring(code)), 5)
        return
    end
    local entries, next_href = parse_feed(body)
    if #entries == 0 then
        plugin:notify(_("Loomera: no downloadable books here."), 4)
        return
    end
    local base = plugin:baseUrl()
    local state = { entries = entries, next_href = next_href }
    local menu

    local function build_items()
        local items = {}
        for _, e in ipairs(state.entries) do
            local fmts = {}
            for _, a in ipairs(e.acq) do fmts[#fmts + 1] = a.fmt end
            items[#items + 1] = {
                text = (e.author ~= "" and (e.title .. "  —  " .. e.author)) or e.title,
                mandatory = table.concat(fmts, "/"), _entry = e,
            }
        end
        if state.next_href then
            items[#items + 1] = { text = _("▼  Load more…"), _loadmore = true }
        end
        return items
    end

    local function load_more()
        if not state.next_href then return end
        local ok2, code2, body2 = plugin.httpGet(abs_url(base, state.next_href), 20)
        if ok2 and http_ok(code2, body2) then
            local more, nh = parse_feed(body2)
            for _, e in ipairs(more) do state.entries[#state.entries + 1] = e end
            state.next_href = nh
            menu:switchItemTable(menu.title, build_items(), #state.entries)
        else
            plugin:notify(T(_("Loomera: could not load more (%1)"), tostring(code2)), 4)
        end
    end

    menu = Menu:new{
        title = title or _("Loomera Library"),
        item_table = build_items(),
        is_borderless = true, is_popout = false,
        width = Screen:getWidth(), height = Screen:getHeight(),
        onMenuSelect = function(_m, item)
            if item._loadmore then load_more()
            elseif item._entry then preview_book(plugin, item._entry) end
        end,
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

-- Tag-filter screen for a status: ★ All books + every tag (within that status).
function OPDS._open_tags(plugin, status)
    local base = plugin:baseUrl()
    local url = base .. "/opds/tags" .. (status ~= "" and ("?status=" .. status) or "")
    local ok, code, body = plugin.httpGet(url, 20)
    local navs = (ok and http_ok(code, body)) and parse_nav_feed(body) or {}
    if #navs == 0 then
        -- No tags (or fetch failed): just open the book list for this status.
        local burl = base .. "/opds/books" .. (status ~= "" and ("?status=" .. status) or "")
        return OPDS._open_acq(plugin, burl)
    end
    local menu
    local items = {}
    for _, n in ipairs(navs) do
        items[#items + 1] = { text = n.title, _href = n.href }
    end
    menu = Menu:new{
        title = _("Filter by tag"),
        item_table = items,
        is_borderless = true, is_popout = false,
        width = Screen:getWidth(), height = Screen:getHeight(),
        onMenuSelect = function(_m, item)
            if item._href then OPDS._open_acq(plugin, abs_url(base, item._href)) end
        end,
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

-- Search prompt → /opds/search?q=…
function OPDS._search_prompt(plugin)
    local base = plugin:baseUrl()
    local dialog
    dialog = InputDialog:new{
        title = _("Search the library"),
        input = "",
        input_hint = _("title or author"),
        buttons = {{
            { text = _("Cancel"), id = "close",
              callback = function() UIManager:close(dialog) end },
            { text = _("Search"), is_enter_default = true,
              callback = function()
                  local q = dialog:getInputText()
                  UIManager:close(dialog)
                  q = (q or ""):gsub("^%s+", ""):gsub("%s+$", "")
                  if q ~= "" then
                      OPDS._open_acq(plugin, base .. "/opds/search?q=" .. urlencode(q),
                                     T(_("Search: %1"), q))
                  end
              end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Top-level nav: status categories + Search.
function OPDS._open_nav(plugin)
    local menu
    local items = {}
    for _, c in ipairs(NAV_CATS) do
        items[#items + 1] = { text = c.text, _status = c.status }
    end
    items[#items + 1] = { text = _("🔍  Search…"), _search = true }
    menu = Menu:new{
        title = _("Loomera Library"),
        item_table = items,
        is_borderless = true, is_popout = false,
        width = Screen:getWidth(), height = Screen:getHeight(),
        onMenuSelect = function(_m, item)
            if item._search then OPDS._search_prompt(plugin)
            elseif item._status ~= nil then OPDS._open_tags(plugin, item._status) end
        end,
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

-- Public entry point. Brings Wi-Fi up, then opens the nav. Never throws.
function OPDS.browse(plugin)
    if not plugin:isConfigured() then return plugin:promptConfigure() end
    local function run()
        local ok, err = pcall(function() OPDS._open_nav(plugin) end)
        if not ok then
            logger.warn("Loomera OPDS: open failed:", err)
            plugin:notify(_("Loomera: could not open the library browser."), 5)
        end
    end
    if not pcall(function() NetworkMgr:goOnlineToRun(run) end) then
        plugin:notify(_("Loomera: could not connect to Wi-Fi."), 5)
    end
end

return OPDS
