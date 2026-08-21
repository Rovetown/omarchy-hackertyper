# SPDX-License-Identifier: MIT
# :: This purpose-written source provides the Ruby typing sequence bundled with Hacker Typer.
# :: Hacker Typer loads it as plain text and never evaluates or executes it.
# Coordinates deployment waves, health gates, and rollout approvals.

module PaperFleet
  VERSION = "2.4.0"
  DEFAULT_WINDOW = 12 * 60

  class Stage
    attr_reader :name, :description, :checks, :owner

    def initialize(name, description, owner: "platform", &block)
      @name = name
      @description = description
      @owner = owner
      @checks = []
      instance_eval(&block) if block
    end

    def check(label, severity: :notice, &rule)
      @checks << { label: label, severity: severity, rule: rule }
    end

    def inspect
      { name: @name, description: @description, owner: @owner,
        checks: @checks.map { |item| item.slice(:label, :severity) } }
    end
  end

  class Plan
    attr_reader :application, :release, :stages, :annotations

    def initialize(application:, release:, annotations: {})
      @application = application
      @release = release
      @stages = []
      @annotations = annotations
    end

    def stage(name, description, owner: "platform", &block)
      @stages << Stage.new(name, description, owner: owner, &block)
      self
    end

    def summary
      { application: @application, release: @release,
        annotations: @annotations, stages: @stages.map(&:inspect) }
    end
  end

  class Context
    attr_reader :signals, :history

    def initialize(signals = {})
      @signals = signals.freeze
      @history = []
    end

    def observe(label, value)
      @history << { label: label, value: value, recorded_at: "rollout" }
      value
    end

    def signal(name, fallback = nil)
      @signals.fetch(name, fallback)
    end
  end

  class Decision
    attr_reader :status, :reason, :evidence

    def initialize(status, reason, evidence: [])
      @status = status
      @reason = reason
      @evidence = evidence
    end

    def approved?
      @status == :approved
    end

    def to_h
      { status: @status, reason: @reason, evidence: @evidence }
    end
  end

  class Coordinator
    def initialize(plan, context: Context.new)
      @plan = plan
      @context = context
      @events = []
      @decisions = []
    end

    def record_action(stage, verb, details = {})
      # This is an event record, not a shell command or an API request.
      @events << { stage: stage.name, action: verb, details: details,
                   effect: :managed, target: @plan.application }
    end

    def evaluate(stage)
      checks = stage.checks.map do |check|
        result = check[:rule] ? check[:rule].call(@context) : true
        { label: check[:label], severity: check[:severity], passed: !!result }
      end
      failed = checks.reject { |check| check[:passed] }
      decision = if failed.empty?
                   Decision.new(:approved, "all service gates passed", evidence: checks)
                 else
                   Decision.new(:held, "a recorded gate requires review", evidence: checks)
                 end
      @decisions << { stage: stage.name, decision: decision.to_h }
      decision
    end

    def coordinate
      @plan.stages.each do |stage|
        record_action(stage, :announce, description: stage.description, owner: stage.owner)
        decision = evaluate(stage)
        record_action(stage, decision.approved? ? :continue_rollout : :hold_rollout,
                     decision: decision.status, reason: decision.reason)
        break unless decision.approved?
      end
      report
    end

    def report
      { plan: @plan.summary, recorded_events: @events, decisions: @decisions,
        release_note: "Rollout record prepared for release approval." }
    end
  end

  def self.release_plan
    Plan.new(
      application: "aurora-catalog",
      release: "2025.04",
      annotations: { risk: "low", ticket: "orchestrator-000", owner: "night-shift" }
    ).stage("draft", "describe the release and assemble a review packet", owner: "release") do
      check("release label is present", severity: :warning) { |ctx| !ctx.signal(:release).to_s.empty? }
      check("change notes are available") { |ctx| ctx.signal(:notes, true) }
    end.stage("canary", "observe the canary cohort", owner: "reliability") do
      check("aggregate health signal is calm") { |ctx| ctx.signal(:health, :calm) == :calm }
      check("review window is open", severity: :warning) { |ctx| ctx.signal(:window, true) }
    end.stage("handoff", "prepare the operations handoff", owner: "operations") do
      check("human acknowledgement is recorded") { |ctx| ctx.signal(:acknowledged, true) }
    end
  end

  def self.rollout
    plan = release_plan
    context = Context.new(release: plan.release, notes: true, health: :calm,
                          window: true, acknowledged: true)
    Coordinator.new(plan, context: context).coordinate
  end
end

if $PROGRAM_NAME == __FILE__
  result = PaperFleet.rollout
  puts "PAPERFLEET rollout / #{result[:plan][:application]}"
  result[:recorded_events].each_with_index do |event, index|
    puts format("%02d %-10s %-16s %s", index + 1, event[:stage],
                event[:action], event[:effect])
  end
  puts result[:release_note]
end
