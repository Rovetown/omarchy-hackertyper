-- SPDX-License-Identifier: MIT
-- :: This purpose-written source provides the Lua typing sequence bundled with Hacker Typer.
-- :: Hacker Typer loads it as plain text and never evaluates or executes it.
-- Workspace and session rule engine for desktop layout decisions.

local Engine = {}
Engine.__index = Engine

local VERSION = "1.8.0"
local DEFAULT_ZONE = "quiet-bay"
local VALID_MODES = { calm = true, focus = true, roam = true, repair = true }
local VALID_LAYOUTS = { stack = true, columns = true, grid = true, panorama = true }

local function clone(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = clone(item) end
  return result
end

local function text(value)
  if value == nil then return "" end
  return tostring(value)
end

local function bounded(value, fallback, low, high)
  local number = tonumber(value)
  if not number then return fallback end
  if number < low then return low end
  if number > high then return high end
  return math.floor(number)
end

local function add(list, event, detail)
  list[#list + 1] = { event = event, detail = detail, status = "planned" }
end

function Engine.new(options)
  options = options or {}
  local self = setmetatable({}, Engine)
  self.version = VERSION
  self.zone = text(options.zone) ~= "" and text(options.zone) or DEFAULT_ZONE
  self.mode = VALID_MODES[options.mode] and options.mode or "calm"
  self.layout = VALID_LAYOUTS[options.layout] and options.layout or "stack"
  self.rules = {}
  self.events = {}
  self.audit = {}
  self.sequence = 0
  self.limits = {
    columns = bounded(options.columns, 2, 1, 6),
    workspaces = bounded(options.workspaces, 5, 1, 12),
    idle_minutes = bounded(options.idle_minutes, 30, 1, 240),
  }
  return self
end

function Engine:rule(name, matcher, action, note)
  self.rules[#self.rules + 1] = {
    name = name, matcher = matcher, action = action, note = note or "service rule"
  }
  return self
end

function Engine:emit(event, detail)
  self.sequence = self.sequence + 1
  add(self.events, event, detail)
  self.audit[#self.audit + 1] = {
    sequence = self.sequence, event = event, zone = self.zone,
    mode = self.mode, layout = self.layout,
  }
end

function Engine:match(rule, session)
  if type(rule.matcher) == "function" then
    local ok, result = pcall(rule.matcher, session)
    return ok and result == true
  end
  return false
end

function Engine:apply(session)
  session = clone(session or {})
  session.name = text(session.name) ~= "" and text(session.name) or "unnamed-seat"
  session.tags = session.tags or {}
  session.client_count = bounded(session.client_count, 0, 0, 99)
  self:emit("session-observed", session.name)
  for _, rule in ipairs(self.rules) do
    if self:match(rule, session) then
      local action = rule.action or "annotate"
      self:emit("rule-matched", rule.name .. ":" .. action)
      if action == "assign-zone" then
        session.zone = rule.note
      elseif action == "suggest-layout" then
        session.layout_hint = rule.note
      elseif action == "quiet" then
        session.audio_hint = "low-impact"
      elseif action == "annotate" then
        session.annotation = rule.note
      else
        self:emit("rule-skipped", rule.name .. ":unknown-action")
      end
    end
  end
  session.mode = self.mode
  session.workspace_count = self.limits.workspaces
  return session
end

function Engine:default_rules()
  self:rule("wide-screen-desk", function(s)
    return s.display_class == "wide" or s.display_class == "panorama"
  end, "suggest-layout", "panorama")
  self:rule("writing-bay", function(s)
    return s.activity == "writing" or s.activity == "reading"
  end, "assign-zone", "quiet-bay")
  self:rule("many-client-rack", function(s)
    return (s.client_count or 0) >= 6
  end, "suggest-layout", "columns")
  self:rule("meeting-window", function(s)
    return s.activity == "meeting" or s.activity == "call"
  end, "quiet", "service low-noise guidance")
  self:rule("temporary-console", function(s)
    return s.kind == "console" and s.ephemeral == true
  end, "annotate", "review before closing; no automatic cleanup")
  self:rule("night-owl", function(s)
    return s.local_hour and (s.local_hour >= 22 or s.local_hour < 6)
  end, "quiet", "night profile suggestion")
  return self
end

function Engine:workspace_plan()
  local plan = {
    version = self.version, zone = self.zone, mode = self.mode,
    layout = self.layout, limits = clone(self.limits), steps = {},
  }
  local add_step = function(label, explanation)
    plan.steps[#plan.steps + 1] = { label = label, explanation = explanation,
      status = "proposed" }
  end
  add_step("inspect-session", "read only the supplied session description")
  add_step("choose-workspace", "map a label to a workspace slot in the plan")
  add_step("draw-layout", "describe a stack, column, grid, or panorama arrangement")
  add_step("show-focus-hint", "suggest focus without changing input or window state")
  add_step("record-handoff", "leave a human-readable note for the next operator")
  add_step("approval-gate", "require review before any external desktop action")
  return plan
end

function Engine:render_plan(plan)
  plan = plan or self:workspace_plan()
  local lines = {
    "WORKSPACE RULE ENGINE / DECISION REPORT",
    "=======================================",
    "engine=" .. text(plan.version), "zone=" .. text(plan.zone),
    "mode=" .. text(plan.mode), "layout=" .. text(plan.layout),
    "workspaces=" .. text(plan.limits.workspaces),
    "columns=" .. text(plan.limits.columns), "",
    "STEPS (PROPOSED ONLY)",
  }
  for index, step in ipairs(plan.steps) do
    lines[#lines + 1] = string.format("%02d. [%s] %s -- %s", index,
      step.status, step.label, step.explanation)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "STATE: REVIEW_REQUIRED"
  return table.concat(lines, "\n")
end

function Engine:report()
  local result = { version = self.version, events = clone(self.events),
    audit = clone(self.audit), plan = self:workspace_plan() }
  result.summary = "workspace decisions recorded"
  return result
end

local function orchestrator()
  local engine = Engine.new({ zone = "amber-arc", mode = "focus",
    layout = "columns", columns = 3, workspaces = 7 })
  engine:default_rules()
  local sessions = {
    { name = "drafting", activity = "writing", display_class = "wide",
      client_count = 2, local_hour = 14 },
    { name = "signal-board", kind = "console", ephemeral = true,
      client_count = 7, local_hour = 23 },
    { name = "team-room", activity = "meeting", client_count = 4,
      local_hour = 10 },
  }
  local decisions = {}
  for _, session in ipairs(sessions) do
    decisions[#decisions + 1] = engine:apply(session)
  end
  return { plan = engine:render_plan(), decisions = decisions,
    report = engine:report() }
end

return { Engine = Engine, orchestrator = orchestrator, version = VERSION }
