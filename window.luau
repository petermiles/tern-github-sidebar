--!strict
-- GitHub Sidebar, window half: claims clicks on GitHub pull request links and shows them in the sidebar slot
-- beside the pane the link was clicked in (one slot per tab, shared with the other *-sidebar plugins).
-- Hold Alt to bypass it and get Tern's own link handling.

local github = require("./lib/github")

local KIND = "github-sidebar.view"
local SLOT_KINDS = { "github-sidebar.view", "linear-sidebar.view" }
local SHARE = 0.38
local AUTH_TTL_S = 120
local AUTH_RETRY_S = 10

type Pane = any
type Cx = any

-- gh's state as last probed: when, whether it works and why not. A failure is retried soon so signing in recovers.
local auth: { at: number, ok: boolean, why: string? }? = nil
-- Tern browsers this plugin opened in place of the sidebar, by tab.
local browsers: { [number]: number } = {}

-- ─── Slot ───────────────────────────────────────────────────────────────────

-- PaneInfo.block is the plugin block kind as declared: "github-sidebar.view", "linear-sidebar.view".
local function blockKind(pane: Pane): string?
	if pane.kind ~= "plugin" or type(pane.block) ~= "string" then
		return nil
	end
	for _, kind in SLOT_KINDS do
		if pane.block == kind or string.sub(pane.block, -#kind - 1) == "." .. kind then
			return kind
		end
	end
	return nil
end

-- The other plugin's fallback: a browser on a Linear issue, which holds the slot when its data source is missing.
local function isLinearBrowser(pane: Pane): boolean
	return pane.kind == "browser"
		and type(pane.url) == "string"
		and string.match(string.lower(pane.url), "^https?://linear%.app/[^/?#]+/issue/") ~= nil
end

local function paneInfo(cx: Cx, id: number?): Pane?
	if id == nil then
		return nil
	end
	return cx.session:pane(id)
end

-- The sidebar of either plugin in `tab` (a sidebar block, else a Linear fallback browser), if one is open.
local function findSlot(cx: Cx, tab: number): (Pane?, string?)
	local browser: Pane? = nil
	for _, pane in cx.session:panes() do
		if pane.tab == tab and not pane.parked then
			local kind = blockKind(pane)
			if kind ~= nil then
				return pane, kind
			end
			if browser == nil and isLinearBrowser(pane) then
				browser = pane
			end
		end
	end
	if browser ~= nil then
		return browser, "linear-browser"
	end
	return nil, nil
end

local function closeBrowser(cx: Cx, tab: number)
	local id = browsers[tab]
	if id == nil then
		return
	end
	browsers[tab] = nil
	local info = paneInfo(cx, id)
	if info ~= nil and info.kind == "browser" then
		cx.layout:close(id)
	end
end

-- Shows `args` in the tab's sidebar: this plugin's block gets the new url, the other plugin's is replaced in
-- place, and with no sidebar one opens to the right of the clicked pane.
local function showBlock(cx: Cx, clicked: number, args: { string })
	local tab = cx.session:tab_of(clicked)
	if tab == nil then
		return
	end
	closeBrowser(cx, tab)
	local slot, kind = findSlot(cx, tab)
	if slot ~= nil and kind == KIND then
		local event = if args[1] == "rule" then { ev = "action", id = "main", act = "rule" } else { ev = "action", id = "main", act = "goto", value = args[1] }
		local ok = pcall(function()
			cx.session:event(slot.pane, event)
		end)
		if ok then
			return
		end
	end
	if slot ~= nil then
		-- Take the other plugin's slot: the new block opens over it, then the old one is closed.
		local previous = cx.session:focused()
		cx.layout:focus(slot.pane)
		local opened = cx:new_block(KIND, args, "over", { focus = false })
		if opened ~= nil then
			cx.layout:close(slot.pane)
			if previous ~= nil and previous ~= slot.pane then
				cx.layout:focus(previous)
			end
			return
		end
		if previous ~= nil then
			cx.layout:focus(previous)
		end
	end
	local opened = cx:new_block(KIND, args, "beside", { target = clicked, dir = "right", ratio = SHARE, focus = false })
	if opened == nil then
		cx:toast("error", "GitHub Sidebar is not ready", "Open the link with Alt held to use the browser.")
	end
end

-- The fallback: a Tern browser in the sidebar's place, with the reason in a toast.
local function showBrowser(cx: Cx, clicked: number, url: string, why: string)
	local tab = cx.session:tab_of(clicked)
	if tab == nil then
		return
	end
	cx:toast("info", why, "Showing the page in a browser instead.")
	local existing = browsers[tab]
	local info = paneInfo(cx, existing)
	if existing ~= nil and info ~= nil and info.kind == "browser" then
		cx.browser:call({ op = "goto", block = existing, url = url })
		return
	end
	browsers[tab] = nil
	local slot = findSlot(cx, tab)
	if slot ~= nil then
		cx.layout:close(slot.pane)
	end
	-- The shared profile is the one the user signs in to GitHub with; fall back to the default when it is refused.
	local function open(cx2: Cx, profile: string?)
		local op: { [string]: any } = { op = "open", owner = clicked, url = url, how = "beside" }
		op.profile = profile
		cx2.browser:call(op):next(function(result, err, cx3)
			local opened = if result ~= nil and result.ok ~= nil then result.ok.block else nil
			if type(opened) == "number" then
				browsers[tab] = opened
			elseif profile ~= nil and cx3 ~= nil then
				open(cx3, nil)
			else
				tern.log.warn("browser fallback failed", err, result and result.error)
			end
		end)
	end
	open(cx, "shared")
end

-- ─── Routing ────────────────────────────────────────────────────────────────

local function show(cx: Cx, clicked: number, url: string, ok: boolean, why: string?)
	local pane = if paneInfo(cx, clicked) ~= nil then clicked else cx.session:focused()
	if pane == nil then
		return
	end
	if ok then
		showBlock(cx, pane, { url })
	else
		showBrowser(cx, pane, url, why or "gh is not available")
	end
end

local function route(req: any, cx: Cx): any?
	if req.mods.alt then
		return nil
	end
	local ref = github.parse(req.url)
	if ref == nil or github.takeBypass(ref.url) then
		return nil
	end
	local known = auth
	local now = os.time()
	if known ~= nil and now - known.at < (if known.ok then AUTH_TTL_S else AUTH_RETRY_S) then
		show(cx, req.pane, ref.url, known.ok, known.why)
		return { handled = true }
	end
	github.checkAuth(function(ok, why, later)
		auth = { at = os.time(), ok = ok, why = why }
		if later ~= nil then
			show(later, req.pane, ref.url, ok, why)
		end
	end)
	return { handled = true }
end

tern.route.link(route)

tern.command({
	id = "rule",
	title = "GitHub Sidebar: agent rule",
	icon = "settings",
	run = function(cx: Cx)
		local focused = cx.session:focused()
		if focused ~= nil then
			showBlock(cx, focused, { "rule" })
		end
	end,
})
