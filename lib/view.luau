--!strict
-- Pure view of the block state: the pull request, the load error and the agent-rule setup screen.
-- Actions: refresh, browser, copy, rule, back, copy-rule, add=<n>, remove=<n> (n indexes `rule.targets()`).

local github = require("./github")
local rule = require("./rule")
local types = require("./types")

local ui = tern.ui

type State = types.State
type Node = any

local view = {}

local MAX_CHECK_ROWS = 60

local MERGE_STATES: { [string]: { string } } = {
	CLEAN = { "Ready to merge", "success" },
	HAS_HOOKS = { "Ready to merge", "success" },
	UNSTABLE = { "Mergeable, some checks failing", "warning" },
	BEHIND = { "Behind the base branch", "warning" },
	BLOCKED = { "Blocked by required reviews or checks", "warning" },
	DIRTY = { "Merge conflicts", "error" },
	DRAFT = { "Draft", "muted" },
}

local REVIEWS: { [string]: { string } } = {
	APPROVED = { "Approved", "success" },
	CHANGES_REQUESTED = { "Changes requested", "error" },
	REVIEW_REQUIRED = { "Review required", "warning" },
}

-- ─── Pieces ─────────────────────────────────────────────────────────────────

local function toolbar(state: State): Node
	local buttons: { Node } = {}
	if state.screen == "rule" then
		if not state.standalone then
			table.insert(buttons, ui.button("Back", { key = "back", size = "sm", icon = "arrow-left", actions = { click = "back" } }))
		end
	else
		table.insert(buttons, ui.button("Refresh", {
			key = "refresh",
			size = "sm",
			icon = "refresh",
			busy = state.refreshing,
			actions = { click = "refresh" },
		}))
		table.insert(buttons, ui.button("Open in browser", {
			key = "browser",
			size = "sm",
			icon = "open",
			actions = { click = "browser" },
		}))
		table.insert(buttons, ui.button("Copy link", { key = "copy", size = "sm", icon = "copy", actions = { click = "copy" } }))
		table.insert(buttons, ui.button("", {
			key = "rule",
			size = "sm",
			icon = "settings",
			title = "Agent rule: have your coding agent print PR links this sidebar opens",
			aria = "Agent rule",
			variant = "quiet",
			actions = { click = "rule" },
		}))
	end
	return ui.row(buttons)
end

local function stateBadge(pr: github.Pr): Node
	if pr.state == "MERGED" then
		return ui.badge("Merged", "accent")
	elseif pr.state == "CLOSED" then
		return ui.badge("Closed", "error")
	elseif pr.isDraft then
		return ui.badge("Draft", "muted")
	end
	return ui.badge("Open", "success")
end

local function mergeLine(pr: github.Pr): { any }
	if pr.state == "MERGED" then
		return { ui.span("Merged", "accent") }
	elseif pr.state == "CLOSED" then
		return { ui.span("Closed without merging", "muted") }
	end
	local known = MERGE_STATES[pr.mergeState]
	if known ~= nil then
		return { ui.span(known[1], known[2]) }
	end
	if pr.mergeable == "CONFLICTING" then
		return { ui.span("Merge conflicts", "error") }
	end
	return { ui.span("Merge state unknown", "muted") }
end

local function reviewLine(pr: github.Pr, threads: github.Threads?): { any }
	local spans: { any } = {}
	local review = REVIEWS[pr.review]
	if review ~= nil then
		table.insert(spans, ui.span(review[1], review[2]))
	else
		table.insert(spans, ui.span("No review decision", "muted"))
	end
	if threads ~= nil then
		local count = tostring(threads.unresolved) .. (if threads.capped then "+" else "")
		table.insert(spans, ui.span("  ·  ", "muted"))
		table.insert(
			spans,
			ui.span(count .. " unresolved " .. (if threads.unresolved == 1 and not threads.capped then "thread" else "threads"), if threads.unresolved > 0 then "warning" else "muted")
		)
	else
		table.insert(spans, ui.span("  ·  threads unavailable", "muted"))
	end
	return spans
end

local function checksSection(pr: github.Pr): { Node }
	local checks = pr.checks
	if #checks == 0 then
		return { ui.rule("Checks"), ui.text({ ui.span("No checks reported", "muted") }) }
	end
	local passed, failed, pending = 0, 0, 0
	for _, check in checks do
		if check.tone == "error" then
			failed += 1
		elseif check.pending then
			pending += 1
		elseif check.tone == "success" then
			passed += 1
		end
	end
	local summary: { any } = {}
	local function part(count: number, word: string, tone: string)
		if count > 0 then
			if #summary > 0 then
				table.insert(summary, ui.span("  ·  ", "muted"))
			end
			table.insert(summary, ui.span(tostring(count) .. " " .. word, tone))
		end
	end
	part(failed, "failing", "error")
	part(pending, "pending", "warning")
	part(passed, "passed", "success")
	local rows: { { any } } = {}
	for index, check in checks do
		if index > MAX_CHECK_ROWS then
			break
		end
		local name: any = if check.url ~= nil then ui.link(check.name, check.url) else check.name
		table.insert(rows, { { name }, { text = check.label, dot = check.tone } })
	end
	local nodes: { Node } = {
		ui.rule("Checks"),
		ui.text(summary),
		ui.table({
			{ id = "name", head = "Check", grow = 1, truncate = "end" },
			{ id = "status", head = "Status" },
		}, rows),
	}
	if #checks > MAX_CHECK_ROWS then
		table.insert(nodes, ui.overflow(#checks - MAX_CHECK_ROWS))
	end
	return nodes
end

local function footer(state: State): Node?
	local parts: { any } = {}
	if state.updated ~= nil then
		table.insert(parts, ui.span("Updated " .. state.updated, "muted"))
	end
	local pr = state.pr
	if pr ~= nil then
		for _, check in pr.checks do
			if check.pending then
				table.insert(parts, ui.span("  ·  watching checks while they run", "muted"))
				break
			end
		end
	end
	if #parts == 0 then
		return nil
	end
	return ui.text(parts)
end

-- ─── Screens ────────────────────────────────────────────────────────────────

local function failureNodes(failure: github.Failure): { Node }
	local hint: string
	if failure.kind == "missing" or failure.kind == "auth" then
		hint = "Sign in to GitHub in the browser once and use Open in browser, or fix gh and press Refresh."
	elseif failure.kind == "notfound" then
		hint = "gh could not find this pull request: check the link and that your gh account can see the repository."
	else
		hint = "Press Refresh to try again."
	end
	return {
		ui.text({ ui.span(failure.message, "error") }),
		ui.text({ ui.span(hint, "muted") }),
	}
end

local function prScreen(state: State): { Node }
	local nodes: { Node } = { toolbar(state) }
	local ref = state.ref
	if ref == nil then
		return nodes
	end
	local pr = state.pr
	if pr == nil then
		if state.phase == "error" and state.failure ~= nil then
			table.insert(nodes, ui.text({ ui.span(ref.owner .. "/" .. ref.repo .. "#" .. tostring(ref.number), "muted") }))
			for _, node in failureNodes(state.failure) do
				table.insert(nodes, node)
			end
		else
			table.insert(nodes, ui.text({ ui.span("Loading " .. ref.owner .. "/" .. ref.repo .. "#" .. tostring(ref.number) .. "…", "muted") }))
		end
		return nodes
	end
	table.insert(nodes, ui.text({ ui.span(pr.title, "strong") }))
	table.insert(nodes, ui.row({
		stateBadge(pr),
		ui.text({ ui.span(ref.owner .. "/" .. ref.repo .. "#" .. tostring(pr.number), "muted") }),
	}))
	table.insert(nodes, ui.kv({
		{ "Author", { ui.span(pr.author) } },
		{ "Branch", { ui.span(pr.head, "mono"), ui.span("  →  ", "muted"), ui.span(pr.base, "mono") } },
		{ "Merge", mergeLine(pr) },
		{ "Review", reviewLine(pr, state.threads) },
	}))
	if state.failure ~= nil then
		for _, node in failureNodes(state.failure) do
			table.insert(nodes, node)
		end
	end
	for _, node in checksSection(pr) do
		table.insert(nodes, node)
	end
	table.insert(nodes, ui.rule("Description"))
	if pr.body ~= "" then
		table.insert(nodes, ui.md(pr.body, { run = false }))
	else
		table.insert(nodes, ui.text({ ui.span("No description provided.", "muted") }))
	end
	local foot = footer(state)
	if foot ~= nil then
		table.insert(nodes, foot)
	end
	return nodes
end

local function ghLine(state: State): Node
	local gh = state.gh
	if gh == nil then
		return ui.text({ ui.span("Checking gh…", "muted") })
	elseif gh.ok then
		return ui.text({ ui.span("gh is installed and signed in to github.com.", "success") })
	end
	return ui.text({ ui.span(gh.why or "gh is not available.", "warning") })
end

local function ruleScreen(state: State): { Node }
	local nodes: { Node } = {
		toolbar(state),
		ui.text({ ui.span("Agent rule", "strong") }),
		ui.text({
			ui.span(
				"Terminals show a Markdown link as a clickable link, and a click opens it in this sidebar. "
					.. "Add this rule to your coding agent's instructions so it links every pull request it mentions.",
				"muted"
			),
		}),
		ui.text({ ui.span(rule.TEXT, "mono") }),
		ui.row({
			ui.button("Copy rule", { key = "copy-rule", size = "sm", icon = "copy", actions = { click = "copy-rule" } }),
		}),
	}
	local targets = rule.targets()
	if #targets == 0 then
		table.insert(nodes, ui.text({ ui.span("No agent instruction files found (~/.omp/agent/AGENTS.md, ~/.claude/CLAUDE.md, ~/.codex/AGENTS.md).", "muted") }))
	else
		table.insert(nodes, ui.rule("Instruction files"))
		for index, target in targets do
			local label = if target.present then "Remove from " .. target.label else "Add to " .. target.label
			table.insert(nodes, ui.button(label, {
				key = "target" .. tostring(index),
				size = "sm",
				icon = if target.present then "trash" else "plus",
				actions = { click = (if target.present then "remove=" else "add=") .. tostring(index) },
			}))
		end
	end
	if state.notice ~= nil then
		table.insert(nodes, ui.text({ ui.span(state.notice.text, if state.notice.ok then "success" else "error") }))
	end
	table.insert(nodes, ui.rule("GitHub CLI"))
	table.insert(nodes, ghLine(state))
	table.insert(nodes, ui.text({
		ui.span("The sidebar reads pull requests through the gh CLI and stores no credentials. Without gh a click opens the page in a browser instead.", "muted"),
	}))
	return nodes
end

function view.render(state: State): any
	local nodes = if state.screen == "rule" then ruleScreen(state) else prScreen(state)
	return { main = ui.col(nodes) }
end

return view
