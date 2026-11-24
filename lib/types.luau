--!strict
-- The block's state, shared by the controller (host.luau) and the pure view.

local github = require("./github")

export type RuleNotice = { ok: boolean, text: string }

export type State = {
	cx: any,
	-- The PR shown; nil on the standalone rule screen.
	ref: github.PrRef?,
	-- "pr" shows the pull request, "rule" the agent-rule setup.
	screen: "pr" | "rule",
	-- The rule screen was opened with no PR to go back to.
	standalone: boolean,
	phase: "loading" | "ready" | "error",
	pr: github.Pr?,
	threads: github.Threads?,
	failure: github.Failure?,
	refreshing: boolean,
	-- Wall-clock time of the last good load, for the footer.
	updated: string?,
	-- Bumped by every load so a late answer for an earlier one is dropped.
	generation: number,
	-- The `gh pr checks --watch` child while a check is pending, and the token that retires its callbacks.
	watcher: any?,
	watchToken: number,
	-- A watch that dies at once is not restarted until the user refreshes.
	noWatch: boolean,
	-- Debounce timer for the reload a watch tick asks for, and when the last load started (tern.now() ms).
	reloadTimer: any?,
	loadedAt: number,
	-- Setup screen: whether gh is usable (nil until probed) and the outcome of the last file change.
	gh: { ok: boolean, why: string? }?,
	notice: RuleNotice?,
}

return {}
