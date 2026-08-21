.pragma library

var sources = [
  {
    id: "kernel-like",
    name: "Kernel",
    language: "C",
    description: "Event routing and scheduler internals.",
    file: "sources/kernel-like.c",
    license: "MIT",
    provenance: "Project-authored MIT source."
  },
  {
    id: "telemetry-engine",
    name: "Telemetry Engine",
    language: "C++",
    description: "Concurrent telemetry aggregation engine.",
    file: "sources/telemetry-engine.cpp",
    license: "MIT",
    provenance: "Project-authored MIT source."
  },
  {
    id: "command-coordinator",
    name: "Command Coordinator",
    language: "C#",
    description: "Command lease and event coordination.",
    file: "sources/CommandCoordinator.cs",
    license: "MIT",
    provenance: "Project-authored MIT source."
  },
  {
    id: "event-pipeline",
    name: "Event Pipeline",
    language: "Java",
    description: "Ordered event stream pipeline.",
    file: "sources/EventPipeline.java",
    license: "MIT",
    provenance: "Project-authored MIT source."
  },
  {
    id: "task-orchestrator",
    name: "Task Orchestrator",
    language: "TypeScript",
    description: "Distributed task orchestration with lease management.",
    file: "sources/task-orchestrator.ts",
    license: "MIT",
    provenance: "Project-authored MIT source."
  },
  {
    id: "async-observer",
    name: "Async Observer",
    language: "Python",
    description: "Asynchronous observability collector.",
    file: "sources/async-observer.py",
    license: "MIT",
    provenance: "Project-authored MIT source."
  },
  {
    id: "cluster-reconciler",
    name: "Cluster Reconciler",
    language: "Go",
    description: "Cluster desired-state reconciler.",
    file: "sources/cluster-reconciler.go",
    license: "MIT",
    provenance: "Project-authored MIT source."
  },
  {
    id: "packet-engine",
    name: "Packet Engine",
    language: "Rust",
    description: "Bounded packet-processing state machine.",
    file: "sources/packet-engine.rs",
    license: "MIT",
    provenance: "Project-authored MIT source."
  },
  {
    id: "deploy-coordinator",
    name: "Deploy Coordinator",
    language: "Ruby",
    description: "Deployment waves and health-gate coordination.",
    file: "sources/deploy-coordinator.rb",
    license: "MIT",
    provenance: "Project-authored MIT source."
  },
  {
    id: "request-router",
    name: "Request Router",
    language: "PHP",
    description: "API request routing with quotas and cache hints.",
    file: "sources/request-router.php",
    license: "MIT",
    provenance: "Project-authored MIT source."
  },
  {
    id: "fleet-bootstrap",
    name: "Fleet Bootstrap",
    language: "Bash",
    description: "Fleet readiness inventory report.",
    file: "sources/fleet-bootstrap.sh",
    license: "MIT",
    provenance: "Project-authored MIT source."
  },
  {
    id: "telemetry-lab",
    name: "Telemetry Lab",
    language: "SQL",
    description: "Telemetry retention schema and analysis queries.",
    file: "sources/telemetry-lab.sql",
    license: "MIT",
    provenance: "Project-authored MIT source."
  },
  {
    id: "workspace-rules",
    name: "Workspace Rules",
    language: "Lua",
    description: "Workspace and session rule engine.",
    file: "sources/workspace-rules.lua",
    license: "MIT",
    provenance: "Project-authored MIT source."
  },
  {
    id: "hacker-typer-ui",
    name: "Hacker Typer UI",
    language: "QML",
    description: "Native terminal overlay implementation.",
    file: "HackerTyper.qml",
    license: "MIT",
    provenance: "Project source."
  }
]
