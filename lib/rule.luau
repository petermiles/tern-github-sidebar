--!strict
-- The agent rule: one instruction that makes coding agents print PR references as Markdown links (which a
-- terminal shows as clickable OSC 8 hyperlinks), and the marked block that adds it to an agent's instructions file.

local rule = {}

export type Target = { path: string, label: string, exists: boolean, present: boolean }

rule.TEXT = "Write every GitHub PR reference as a Markdown link: [repo#N](https://github.com/owner/repo/pull/N). "
	.. "When a PR's title is shown, link the title to the same URL."

local START = "<!-- tern-github-sidebar-rule:start -->"
local END = "<!-- tern-github-sidebar-rule:end -->"

-- Instruction files of the agents that read one, relative to the home directory.
local FILES = { "/.omp/agent/AGENTS.md", "/.claude/CLAUDE.md", "/.codex/AGENTS.md" }

local function block(): string
	return START .. "\n" .. rule.TEXT .. "\n" .. END .. "\n"
end

-- Byte range of the marked block, its end marker's line break included.
local function find(content: string): (number?, number?)
	local from = string.find(content, START, 1, true)
	if from == nil then
		return nil, nil
	end
	local _, markerEnd = string.find(content, END, from, true)
	if markerEnd == nil then
		return nil, nil
	end
	if string.sub(content, markerEnd + 1, markerEnd + 1) == "\n" then
		markerEnd += 1
	end
	return from, markerEnd
end

function rule.has(content: string): boolean
	return find(content) ~= nil
end

-- `content` with the block appended once; unchanged when it is already there.
function rule.addTo(content: string): string
	if rule.has(content) then
		return content
	end
	local separator = ""
	if content ~= "" then
		separator = if string.sub(content, -1) == "\n" then "\n" else "\n\n"
	end
	return content .. separator .. block()
end

-- `content` without the marked block and the blank line `addTo` put before it.
function rule.removeFrom(content: string): string
	local from, to = find(content)
	if from == nil or to == nil then
		return content
	end
	local before = string.sub(content, 1, from - 1)
	if string.sub(before, -2) == "\n\n" then
		before = string.sub(before, 1, -2)
	end
	return before .. string.sub(content, to + 1)
end

local function home(): string
	return tern.getenv("HOME") or ""
end

local function read(path: string): string?
	local ok, content = pcall(tern.fs.read, path)
	if ok and type(content) == "string" then
		return content
	end
	return nil
end

-- The instruction files that exist, with whether each already holds the block.
function rule.targets(): { Target }
	local targets: { Target } = {}
	for _, relative in FILES do
		local path = home() .. relative
		if tern.fs.exists(path) then
			local content = read(path)
			table.insert(targets, {
				path = path,
				label = "~" .. relative,
				exists = true,
				present = content ~= nil and rule.has(content),
			})
		end
	end
	return targets
end

local function update(path: string, change: (string) -> string): (boolean, string?)
	local content = read(path)
	if content == nil then
		return false, "Could not read " .. path
	end
	local updated = change(content)
	if updated == content then
		return true, nil
	end
	local ok, err = pcall(tern.fs.write, path, updated)
	if not ok then
		return false, tostring(err)
	end
	return true, nil
end

function rule.add(path: string): (boolean, string?)
	return update(path, rule.addTo)
end

function rule.remove(path: string): (boolean, string?)
	return update(path, rule.removeFrom)
end

return rule
