--!strict
-- GitHub access through the `gh` CLI, shared by both halves: URL parsing, finding and probing `gh`, and one PR
-- load (`gh pr view` plus a GraphQL query for review threads). Nothing here stores credentials: `gh` owns them.

local github = {}

export type PrRef = { owner: string, repo: string, number: number, url: string }

export type Check = {
	name: string,
	label: string,
	tone: string,
	url: string?,
	pending: boolean,
	rank: number,
	order: number,
}

export type Pr = {
	title: string,
	number: number,
	state: string,
	isDraft: boolean,
	author: string,
	head: string,
	base: string,
	mergeable: string,
	mergeState: string,
	review: string,
	checks: { Check },
	body: string,
	url: string,
}

export type Threads = { unresolved: number, total: number, capped: boolean }

export type Failure = { kind: "missing" | "auth" | "notfound" | "error", message: string }

local PR_FIELDS = "title,number,state,isDraft,author,headRefName,baseRefName,mergeable,mergeStateStatus,"
	.. "reviewDecision,statusCheckRollup,body,url"
local THREADS_QUERY = "query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n)"
	.. "{reviewThreads(first:100){totalCount nodes{isResolved}}}}}"
local THREAD_PAGE = 100
local FALLBACK_DIRS = { "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/home/linuxbrew/.linuxbrew/bin" }
local CLI_TIMEOUT_MS = 30000
local AUTH_TIMEOUT_MS = 15000
local BYPASS_KEY = "bypass"
local BYPASS_TTL_S = 10

-- Quiet, non-interactive gh: no prompts, colour, spinner or update notices in the output we parse.
local CLI_ENV = {
	GH_PROMPT_DISABLED = "1",
	GH_NO_UPDATE_NOTIFIER = "1",
	GH_SPINNER_DISABLED = "1",
	GH_PAGER = "cat",
	NO_COLOR = "1",
}

local cachedGh: string? = nil

-- ─── URLs ───────────────────────────────────────────────────────────────────

-- https://github.com/<owner>/<repo>/pull/<N>, optionally followed by /files, /checks, ?query or #fragment.
function github.parse(url: string): PrRef?
	local scheme, host, path = string.match(url, "^(%a+)://([^/?#]+)(.*)$")
	if scheme == nil or host == nil or path == nil then
		return nil
	end
	scheme = string.lower(scheme)
	host = string.lower(host)
	if (scheme ~= "https" and scheme ~= "http") or (host ~= "github.com" and host ~= "www.github.com") then
		return nil
	end
	local owner, repo, number, tail = string.match(path, "^/([%w_.-]+)/([%w_.-]+)/pull/(%d+)(.*)$")
	if owner == nil or repo == nil or number == nil or tail == nil then
		return nil
	end
	if tail ~= "" and not string.find(tail, "^[/?#]") then
		return nil
	end
	return {
		owner = owner,
		repo = repo,
		number = tonumber(number) :: number,
		url = "https://github.com/" .. owner .. "/" .. repo .. "/pull/" .. number,
	}
end

-- ─── Open in the built-in browser ───────────────────────────────────────────
-- The sidebar's own "Open in browser" calls `cx:open(url)`, which goes through `tern.route.link` and would land
-- back here. The block (host half) marks the URL; the router (window half) lets it through once, shortly after.

function github.markBypass(url: string)
	tern.kv.set(BYPASS_KEY, { url = url, at = os.time() })
end

function github.takeBypass(url: string): boolean
	local mark = tern.kv.get(BYPASS_KEY)
	if type(mark) ~= "table" or mark.url ~= url then
		return false
	end
	tern.kv.set(BYPASS_KEY, nil)
	return type(mark.at) == "number" and os.time() - mark.at <= BYPASS_TTL_S
end

-- ─── gh ─────────────────────────────────────────────────────────────────────

-- The gh binary: PATH first, then the usual install prefixes (a GUI-launched app has a short PATH).
function github.ghPath(): string?
	local cached = cachedGh
	if cached ~= nil and tern.fs.exists(cached) then
		return cached
	end
	local dirs: { string } = {}
	for dir in string.gmatch(tern.getenv("PATH") or "", "[^:]+") do
		table.insert(dirs, dir)
	end
	for _, dir in FALLBACK_DIRS do
		table.insert(dirs, dir)
	end
	local home = tern.getenv("HOME")
	if home ~= nil then
		table.insert(dirs, home .. "/.local/bin")
	end
	for _, dir in dirs do
		local candidate = dir .. "/gh"
		if tern.fs.exists(candidate) then
			cachedGh = candidate
			return candidate
		end
	end
	return nil
end

local function firstLine(text: string): string
	for line in string.gmatch(text, "[^\r\n]+") do
		local trimmed = string.match(line, "^%s*(.-)%s*$")
		if trimmed ~= nil and trimmed ~= "" then
			return trimmed
		end
	end
	return ""
end

local function run(args: { string }, timeoutMs: number, cb: (any, any?) -> ())
	local argv: { string } = { github.ghPath() :: string }
	for _, arg in args do
		table.insert(argv, arg)
	end
	tern.process.run(argv, { cwd = tern.getenv("HOME") or "/", env = CLI_ENV, timeout_ms = timeoutMs }, cb)
end

-- Whether gh is installed and signed in to github.com. `cb(ok, why, cx)`.
function github.checkAuth(cb: (boolean, string?, any?) -> ())
	if github.ghPath() == nil then
		cb(false, "gh is not installed (https://cli.github.com)", nil)
		return
	end
	run({ "auth", "status", "--hostname", "github.com" }, AUTH_TIMEOUT_MS, function(result, cx)
		if result.status == 0 then
			cb(true, nil, cx)
		elseif result.timed_out then
			cb(false, "gh did not answer in time", cx)
		else
			cb(false, "gh is not signed in: run `gh auth login`", cx)
		end
	end)
end

local function classify(stderr: string): Failure
	local message = firstLine(stderr)
	local lower = string.lower(stderr)
	if
		string.find(lower, "gh auth login", 1, true)
		or string.find(lower, "http 401", 1, true)
		or string.find(lower, "bad credentials", 1, true)
		or string.find(lower, "authentication", 1, true)
	then
		return { kind = "auth", message = if message ~= "" then message else "gh is not signed in" }
	end
	if
		string.find(lower, "could not resolve", 1, true)
		or string.find(lower, "http 404", 1, true)
		or string.find(lower, "not found", 1, true)
	then
		return { kind = "notfound", message = if message ~= "" then message else "Pull request not found" }
	end
	return { kind = "error", message = if message ~= "" then message else "gh failed" }
end

-- ─── Normalising gh's JSON ──────────────────────────────────────────────────

local RUN_STATES: { [string]: string } = {
	QUEUED = "queued",
	IN_PROGRESS = "in progress",
	WAITING = "waiting",
	PENDING = "pending",
	REQUESTED = "requested",
}

local CONCLUSIONS: { [string]: { string } } = {
	SUCCESS = { "passed", "success" },
	FAILURE = { "failed", "error" },
	TIMED_OUT = { "timed out", "error" },
	STARTUP_FAILURE = { "failed to start", "error" },
	CANCELLED = { "cancelled", "muted" },
	SKIPPED = { "skipped", "muted" },
	NEUTRAL = { "neutral", "muted" },
	STALE = { "stale", "muted" },
	ACTION_REQUIRED = { "action required", "warning" },
}

local CONTEXT_STATES: { [string]: { string } } = {
	SUCCESS = { "passed", "success" },
	FAILURE = { "failed", "error" },
	ERROR = { "failed", "error" },
	PENDING = { "pending", "warning" },
	EXPECTED = { "expected", "warning" },
}

local function str(value: any, default: string): string
	if type(value) == "string" then
		return value
	end
	return default
end

local function normalizeCheck(raw: any, order: number): Check?
	if type(raw) ~= "table" then
		return nil
	end
	local label, tone, pending
	local name
	local url: string?
	if raw.__typename == "StatusContext" then
		local mapped = CONTEXT_STATES[str(raw.state, "")] or { string.lower(str(raw.state, "unknown")), "muted" }
		label, tone = mapped[1], mapped[2]
		pending = raw.state == "PENDING" or raw.state == "EXPECTED"
		name = str(raw.context, "status")
		url = if type(raw.targetUrl) == "string" and raw.targetUrl ~= "" then raw.targetUrl else nil
	else
		local status = str(raw.status, "")
		if status ~= "" and status ~= "COMPLETED" then
			label = RUN_STATES[status] or string.lower(status)
			tone = "warning"
			pending = true
		else
			local mapped = CONCLUSIONS[str(raw.conclusion, "")]
				or { string.lower(str(raw.conclusion, "unknown")), "muted" }
			label, tone = mapped[1], mapped[2]
			pending = false
		end
		name = str(raw.name, "check")
		local workflow = str(raw.workflowName, "")
		if workflow ~= "" and workflow ~= name then
			name = workflow .. " / " .. name
		end
		url = if type(raw.detailsUrl) == "string" and raw.detailsUrl ~= "" then raw.detailsUrl else nil
	end
	local rank = if tone == "error" then 0 elseif pending then 1 else 2
	return { name = name, label = label, tone = tone, url = url, pending = pending, rank = rank, order = order }
end

local function normalizeChecks(raw: any): { Check }
	local checks: { Check } = {}
	if type(raw) ~= "table" then
		return checks
	end
	for index, item in raw do
		local check = normalizeCheck(item, index)
		if check ~= nil then
			table.insert(checks, check)
		end
	end
	-- Failures first, then what is still running, then the rest, each group in GitHub's order.
	table.sort(checks, function(a, b)
		if a.rank ~= b.rank then
			return a.rank < b.rank
		end
		return a.order < b.order
	end)
	return checks
end

local function normalizePr(raw: any): Pr?
	if type(raw) ~= "table" or type(raw.title) ~= "string" then
		return nil
	end
	local author = if type(raw.author) == "table" then str(raw.author.login, "unknown") else "unknown"
	return {
		title = raw.title,
		number = if type(raw.number) == "number" then raw.number else 0,
		state = str(raw.state, "OPEN"),
		isDraft = raw.isDraft == true,
		author = author,
		head = str(raw.headRefName, "?"),
		base = str(raw.baseRefName, "?"),
		mergeable = str(raw.mergeable, "UNKNOWN"),
		mergeState = str(raw.mergeStateStatus, "UNKNOWN"),
		review = str(raw.reviewDecision, ""),
		checks = normalizeChecks(raw.statusCheckRollup),
		body = str(raw.body, ""),
		url = str(raw.url, ""),
	}
end

local function normalizeThreads(raw: any): Threads?
	local ok, threads = pcall(function()
		return raw.data.repository.pullRequest.reviewThreads
	end)
	if not ok or type(threads) ~= "table" or type(threads.nodes) ~= "table" then
		return nil
	end
	local unresolved = 0
	for _, node in threads.nodes do
		if type(node) == "table" and node.isResolved == false then
			unresolved += 1
		end
	end
	local total = if type(threads.totalCount) == "number" then threads.totalCount else #threads.nodes
	return { unresolved = unresolved, total = total, capped = total > THREAD_PAGE }
end

local function decode(text: string): any
	local ok, value = pcall(tern.json.decode, text)
	if ok then
		return value
	end
	return nil
end

-- Runs gh's own check watcher for a PR. `onTick()` fires for each line it prints, `onExit()` once it ended. The
-- caller re-reads the PR on a tick and kills the returned child when the view goes away. Nil without gh.
function github.watchChecks(ref: PrRef, onTick: () -> (), onExit: () -> ()): any?
	local path = github.ghPath()
	if path == nil then
		return nil
	end
	return tern.process.spawn({
		path,
		"pr",
		"checks",
		tostring(ref.number),
		"-R",
		ref.owner .. "/" .. ref.repo,
		"--watch",
		"--interval",
		"10",
	}, {
		cwd = tern.getenv("HOME") or "/",
		env = CLI_ENV,
		stdout = function()
			onTick()
		end,
		stderr = function() end,
		exit = function()
			onExit()
		end,
	})
end

-- Loads a PR and its review threads. `cb(pr, threads, failure, cx)`: `threads` is nil when only that query failed.
function github.loadPr(ref: PrRef, cb: (Pr?, Threads?, Failure?, any?) -> ())
	if github.ghPath() == nil then
		cb(nil, nil, { kind = "missing", message = "gh is not installed (https://cli.github.com)" }, nil)
		return
	end
	local repoArg = ref.owner .. "/" .. ref.repo
	local prResult: any = nil
	local threadResult: any = nil
	local lastCx: any = nil
	local pending = 2
	local function settle(cx: any?)
		lastCx = cx
		pending -= 1
		if pending > 0 then
			return
		end
		if prResult.status ~= 0 then
			cb(nil, nil, if prResult.timed_out then { kind = "error", message = "gh timed out" } else classify(prResult.stderr), lastCx)
			return
		end
		local pr = normalizePr(decode(prResult.stdout))
		if pr == nil then
			cb(nil, nil, { kind = "error", message = "Unexpected output from gh pr view" }, lastCx)
			return
		end
		local threads = if threadResult.status == 0 then normalizeThreads(decode(threadResult.stdout)) else nil
		cb(pr, threads, nil, lastCx)
	end
	run({ "pr", "view", tostring(ref.number), "-R", repoArg, "--json", PR_FIELDS }, CLI_TIMEOUT_MS, function(result, cx)
		prResult = result
		settle(cx)
	end)
	run({
		"api",
		"graphql",
		"-f",
		"query=" .. THREADS_QUERY,
		"-f",
		"o=" .. ref.owner,
		"-f",
		"r=" .. ref.repo,
		"-F",
		"n=" .. tostring(ref.number),
	}, CLI_TIMEOUT_MS, function(result, cx)
		threadResult = result
		settle(cx)
	end)
end

return github
