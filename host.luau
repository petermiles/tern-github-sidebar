--!strict
-- The `github-sidebar.view` block: one pull request, loaded through gh, with the agent-rule setup behind a
-- settings button. Launch args: `{url}` for a PR, or `{"rule"}` for the setup screen alone.
-- The window half (window.luau) claims PR link clicks and sends this block a new url with a `goto` action.

local github = require("./lib/github")
local rule = require("./lib/rule")
local types = require("./lib/types")
local view = require("./lib/view")

type State = types.State
type BlockDef<S> = any

-- While a check is pending, `gh pr checks --watch` runs and each burst of its output triggers a reload, at most once
-- per MIN_RELOAD_MS. A watch that ends after at least MIN_WATCH_MS is followed by a final reload (and a new watch if
-- checks are still pending); one that dies sooner is not restarted until the user refreshes.
local MIN_RELOAD_MS = 4000
local MIN_WATCH_MS = 5000

-- Blocks with a running watch, so a plugin reload can stop them all.
local watching: { [State]: boolean } = {}

local function paneExists(pane: number): boolean
	for _, info in tern.pane.list() do
		if info.pane == pane then
			return true
		end
	end
	return false
end

local function pendingCount(state: State): number
	local count = 0
	local pr = state.pr
	if pr ~= nil then
		for _, check in pr.checks do
			if check.pending then
				count += 1
			end
		end
	end
	return count
end

local function stopWatch(state: State)
	state.watchToken += 1
	local child = state.watcher
	if child ~= nil then
		state.watcher = nil
		pcall(function()
			child:kill()
		end)
	end
	local timer = state.reloadTimer
	if timer ~= nil then
		timer:cancel()
		state.reloadTimer = nil
	end
	watching[state] = nil
end

-- The block's status (tab, inbox, Agents widget): CI progress while checks run, then the outcome.
local function updateStatus(state: State)
	local pr = state.pr
	if pr == nil or #pr.checks == 0 then
		state.cx:status(nil)
		return
	end
	local total = #pr.checks
	local pending = pendingCount(state)
	if pending > 0 then
		local done = total - pending
		state.cx:status("working", {
			msg = "CI: " .. tostring(done) .. "/" .. tostring(total) .. " checks done",
			progress = math.floor(done * 100 / total),
		})
		return
	end
	for _, check in pr.checks do
		if check.tone == "error" then
			state.cx:status("error", { msg = "CI failed: " .. check.name })
			return
		end
	end
	state.cx:status("done", { msg = "CI passed" })
end

local load

local function startWatch(state: State)
	local ref = state.ref
	if ref == nil or state.watcher ~= nil or state.noWatch or pendingCount(state) == 0 then
		return
	end
	state.watchToken += 1
	local token = state.watchToken
	local startedAt = tern.now()
	local function current(): boolean
		return state.watchToken == token
	end
	local child = github.watchChecks(ref, function()
		if not current() then
			return
		end
		if not paneExists(state.cx.pane) then
			stopWatch(state)
			return
		end
		if state.reloadTimer ~= nil then
			return
		end
		local wait = math.max(0, MIN_RELOAD_MS - (tern.now() - state.loadedAt))
		state.reloadTimer = tern.timer(wait, function()
			state.reloadTimer = nil
			if current() then
				load(state)
			end
		end)
	end, function()
		if not current() then
			return
		end
		state.watcher = nil
		watching[state] = nil
		state.noWatch = tern.now() - startedAt < MIN_WATCH_MS
		if paneExists(state.cx.pane) then
			load(state)
		end
	end)
	if child ~= nil then
		state.watcher = child
		watching[state] = true
	end
end

function load(state: State)
	local ref = state.ref
	if ref == nil then
		return
	end
	state.generation += 1
	state.loadedAt = tern.now()
	local generation = state.generation
	state.refreshing = true
	if state.pr == nil then
		state.phase = "loading"
		state.failure = nil
	end
	github.loadPr(ref, function(pr, threads, failure)
		if generation ~= state.generation then
			return
		end
		state.refreshing = false
		if pr ~= nil then
			state.pr = pr
			state.threads = threads
			state.failure = nil
			state.phase = "ready"
			state.updated = os.date("%H:%M:%S")
			updateStatus(state)
			if pendingCount(state) > 0 then
				startWatch(state)
			else
				stopWatch(state)
			end
		else
			state.failure = failure
			if state.pr == nil then
				state.phase = "error"
			end
		end
		state.cx:render()
	end)
end

local function probeGh(state: State)
	github.checkAuth(function(ok, why)
		state.gh = { ok = ok, why = why }
		state.cx:render()
	end)
end

local function showRule(state: State)
	state.screen = "rule"
	state.notice = nil
	state.gh = nil
	probeGh(state)
end

-- Points the block at another PR (or the same one again: that just refreshes it).
local function navigate(state: State, url: string)
	local ref = github.parse(url)
	if ref == nil then
		return
	end
	state.screen = "pr"
	state.standalone = false
	local same = state.ref ~= nil and state.ref.url == ref.url
	state.ref = ref
	state.noWatch = false
	if not same then
		stopWatch(state)
		state.pr = nil
		state.threads = nil
		state.failure = nil
		state.updated = nil
		updateStatus(state)
	end
	load(state)
end

local function changeRuleFile(state: State, value: any, add: boolean)
	local index = tonumber(value)
	local target = if index ~= nil then rule.targets()[index] else nil
	if target == nil then
		state.notice = { ok = false, text = "That file is gone." }
		return
	end
	local ok, err
	if add then
		ok, err = rule.add(target.path)
	else
		ok, err = rule.remove(target.path)
	end
	if ok then
		state.notice = { ok = true, text = (if add then "Added to " else "Removed from ") .. target.label }
	else
		state.notice = { ok = false, text = err or "Could not change the file" }
	end
end

local function onAction(state: State, ev: any)
	local act = ev.act
	local ref = state.ref
	if act == "goto" then
		if type(ev.value) == "string" then
			navigate(state, ev.value)
		end
	elseif act == "rule" then
		showRule(state)
	elseif act == "back" then
		state.screen = "pr"
	elseif act == "refresh" then
		state.noWatch = false
		load(state)
	elseif act == "browser" then
		if ref ~= nil then
			github.markBypass(ref.url)
			state.cx:open(ref.url)
		end
	elseif act == "copy" then
		if ref ~= nil then
			state.cx:copy(ref.url)
			state.cx:toast("success", "Link copied", ref.url)
		end
	elseif act == "copy-rule" then
		state.cx:copy(rule.TEXT)
		state.notice = { ok = true, text = "Rule copied." }
	elseif act == "add" then
		changeRuleFile(state, ev.value, true)
	elseif act == "remove" then
		changeRuleFile(state, ev.value, false)
	end
	state.cx:render()
end

local def: BlockDef<State> = {
	font = "sans",
	init = function(cx, args, saved)
		local state: State = {
			cx = cx,
			ref = nil,
			screen = "pr",
			standalone = false,
			phase = "loading",
			pr = nil,
			threads = nil,
			failure = nil,
			refreshing = false,
			updated = nil,
			generation = 0,
			watcher = nil,
			watchToken = 0,
			noWatch = false,
			reloadTimer = nil,
			loadedAt = 0,
			gh = nil,
			notice = nil,
		}
		local launch = args[1]
		if launch == "rule" then
			state.standalone = true
			showRule(state)
			return state
		end
		local url = launch
		if url == nil and type(saved) == "table" then
			url = saved.url
		end
		state.ref = if type(url) == "string" then github.parse(url) else nil
		if state.ref == nil then
			state.phase = "error"
			state.failure = { kind = "error", message = "Not a GitHub pull request link: " .. tostring(url) }
		else
			load(state)
		end
		return state
	end,
	view = function(state)
		return view.render(state)
	end,
	title = function(state)
		local ref = state.ref
		if state.screen == "rule" or ref == nil then
			return "GitHub PR links"
		end
		return ref.repo .. "#" .. tostring(ref.number)
	end,
	event = function(state, ev)
		if ev.ev == "action" then
			onAction(state, ev)
		end
	end,
	save = function(state)
		local ref = state.ref
		return { url = if ref ~= nil then ref.url else nil }
	end,
}

tern.block.define("view", def)

-- A reload or shutdown of the plugin must not leave gh processes behind.
tern.on("unload", function()
	for state in watching do
		stopWatch(state)
	end
end)
