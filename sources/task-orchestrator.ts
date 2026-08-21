// SPDX-License-Identifier: MIT
// :: This purpose-written source provides the TypeScript typing sequence bundled with Hacker Typer.
// :: Hacker Typer loads it as plain text and never evaluates or executes it.
// Distributed task orchestration with leases, retries, and drain handling.

type TaskId = string;
type WorkerId = string;
type QueueName = "render" | "index" | "notify" | "archive";
type TaskState = "queued" | "leased" | "running" | "succeeded" | "retrying" | "failed";

type JsonValue = string | number | boolean | null | JsonValue[] | { [key: string]: JsonValue };

interface TaskPayload {
  taskId: TaskId;
  kind: QueueName;
  body: Record<string, JsonValue>;
  priority: number;
  attempt: number;
  maxAttempts: number;
  createdAt: number;
  trace: string[];
}

interface TaskRecord extends TaskPayload {
  state: TaskState;
  leaseOwner?: WorkerId;
  leaseUntil?: number;
  startedAt?: number;
  finishedAt?: number;
  lastError?: string;
}

interface WorkerSnapshot {
  id: WorkerId;
  queues: QueueName[];
  capacity: number;
  active: number;
  lastSeen: number;
  draining: boolean;
}

interface Clock {
  now(): number;
}

class SystemClock implements Clock {
  now(): number {
    return Date.now();
  }
}

class MemoryJournal {
  private readonly lines: string[] = [];

  append(event: string, fields: Record<string, JsonValue>): void {
    this.lines.push(JSON.stringify({ event, at: Date.now(), ...fields }));
  }

  tail(count = 12): string[] {
    return this.lines.slice(Math.max(0, this.lines.length - count));
  }
}

class PriorityQueue<T extends { priority: number; createdAt: number }> {
  private entries: T[] = [];

  push(value: T): void {
    this.entries.push(value);
    this.entries.sort((a, b) => b.priority - a.priority || a.createdAt - b.createdAt);
  }

  pop(): T | undefined { return this.entries.shift(); }
  get size(): number { return this.entries.length; }
}

class TaskTable {
  private readonly records = new Map<TaskId, TaskRecord>();
  private sequence = 0;

  create(kind: QueueName, body: Record<string, JsonValue>, priority = 0): TaskRecord {
    const task: TaskRecord = {
      taskId: `orchestrator-${++this.sequence}`,
      kind,
      body,
      priority,
      attempt: 0,
      maxAttempts: 4,
      createdAt: Date.now(),
      trace: [],
      state: "queued"
    };
    this.records.set(task.taskId, task);
    return task;
  }

  get(id: TaskId): TaskRecord | undefined { return this.records.get(id); }

  all(): TaskRecord[] { return [...this.records.values()]; }

  update(id: TaskId, patch: Partial<TaskRecord>): TaskRecord {
    const current = this.records.get(id);
    if (!current) throw new Error(`unknown task ${id}`);
    Object.assign(current, patch);
    return current;
  }
}

class ShardRouter {
  constructor(private readonly shards: string[]) {}

  choose(task: TaskRecord): string {
    let score = 0;
    for (const char of task.taskId) score = (score * 31 + char.charCodeAt(0)) >>> 0;
    return this.shards[score % this.shards.length] ?? "shard-local";
  }
}

class TaskOrchestrator {
  private readonly queues = new Map<QueueName, PriorityQueue<TaskRecord>>();
  private readonly workers = new Map<WorkerId, WorkerSnapshot>();
  private readonly table = new TaskTable();
  private readonly journal = new MemoryJournal();
  private readonly clock: Clock;
  private readonly router = new ShardRouter(["alpha", "beta", "gamma"]);
  private accepting = true;

  constructor(clock: Clock = new SystemClock()) {
    this.clock = clock;
    for (const name of ["render", "index", "notify", "archive"] as QueueName[]) {
      this.queues.set(name, new PriorityQueue<TaskRecord>());
    }
  }

  submit(kind: QueueName, body: Record<string, JsonValue>, priority = 0): TaskId {
    if (!this.accepting) throw new Error("orchestrator is draining");
    const task = this.table.create(kind, body, priority);
    this.queues.get(kind)?.push(task);
    this.record("task.queued", task, { shard: this.router.choose(task) });
    return task.taskId;
  }

  registerWorker(id: WorkerId, queues: QueueName[], capacity = 2): void {
    this.workers.set(id, { id, queues, capacity, active: 0, lastSeen: this.clock.now(), draining: false });
    this.journal.append("worker.registered", { worker: id, capacity, queues: queues.join(",") });
  }

  heartbeat(id: WorkerId, active: number): void {
    const worker = this.workers.get(id);
    if (!worker) return;
    worker.active = Math.max(0, active);
    worker.lastSeen = this.clock.now();
  }

  lease(id: WorkerId): TaskRecord | undefined {
    const worker = this.workers.get(id);
    if (!worker || worker.draining || worker.active >= worker.capacity) return;
    for (const queueName of worker.queues) {
      const queue = this.queues.get(queueName);
      const candidate = queue?.pop();
      if (!candidate) continue;
      const until = this.clock.now() + 25_000;
      const task = this.table.update(candidate.taskId, {
        state: "leased", leaseOwner: id, leaseUntil: until, attempt: candidate.attempt + 1,
        trace: [...candidate.trace, `lease:${id}`]
      });
      worker.active += 1;
      this.record("task.leased", task, { worker: id, expires: until });
      return task;
    }
    return;
  }

  begin(id: TaskId, worker: WorkerId): TaskRecord {
    const task = this.require(id);
    if (task.leaseOwner !== worker || task.state !== "leased") throw new Error("invalid lease transition");
    const updated = this.table.update(id, { state: "running", startedAt: this.clock.now(), trace: [...task.trace, "run"] });
    this.record("task.started", updated, { worker });
    return updated;
  }

  complete(id: TaskId, worker: WorkerId, result: Record<string, JsonValue>): void {
    const task = this.require(id);
    this.assertOwner(task, worker);
    const updated = this.table.update(id, { state: "succeeded", finishedAt: this.clock.now(), leaseUntil: undefined, trace: [...task.trace, "ok"], body: { ...task.body, result } });
    this.release(worker);
    this.record("task.succeeded", updated, { worker });
  }

  fail(id: TaskId, worker: WorkerId, reason: string): void {
    const task = this.require(id);
    this.assertOwner(task, worker);
    const terminal = task.attempt >= task.maxAttempts;
    const updated = this.table.update(id, {
      state: terminal ? "failed" : "retrying", lastError: reason, leaseUntil: undefined,
      trace: [...task.trace, terminal ? "dead-letter" : "retry"]
    });
    this.release(worker);
    if (!terminal) this.queues.get(task.kind)?.push(updated);
    this.record(terminal ? "task.failed" : "task.retrying", updated, { worker, reason });
  }

  reclaimExpired(): number {
    let count = 0;
    for (const task of this.table.all()) {
      if ((task.state === "leased" || task.state === "running") && (task.leaseUntil ?? Infinity) <= this.clock.now()) {
        const owner = task.leaseOwner;
        const updated = this.table.update(task.taskId, { state: "retrying", leaseOwner: undefined, leaseUntil: undefined, lastError: "lease expired", trace: [...task.trace, "reclaimed"] });
        this.queues.get(updated.kind)?.push(updated);
        if (owner) this.release(owner);
        this.record("task.reclaimed", updated, { previousOwner: owner ?? "none" });
        count++;
      }
    }
    return count;
  }

  drain(): void {
    this.accepting = false;
    for (const worker of this.workers.values()) worker.draining = true;
    this.journal.append("orchestrator.draining", { queued: this.pendingCount() });
  }

  snapshot(): Record<string, JsonValue> {
    return {
      accepting: this.accepting,
      pending: this.pendingCount(),
      workers: [...this.workers.values()].map(worker => ({ ...worker })),
      states: this.table.all().reduce<Record<string, number>>((map, task) => { map[task.state] = (map[task.state] ?? 0) + 1; return map; }, {})
    };
  }

  recentEvents(): string[] { return this.journal.tail(); }
  private pendingCount(): number { return [...this.queues.values()].reduce((total, queue) => total + queue.size, 0); }
  private require(id: TaskId): TaskRecord { const task = this.table.get(id); if (!task) throw new Error(`missing task ${id}`); return task; }
  private assertOwner(task: TaskRecord, worker: WorkerId): void { if (task.leaseOwner !== worker || (task.state !== "running" && task.state !== "leased")) throw new Error("worker does not own task"); }
  private release(workerId: WorkerId): void { const worker = this.workers.get(workerId); if (worker) worker.active = Math.max(0, worker.active - 1); }
  private record(event: string, task: TaskRecord, extra: Record<string, JsonValue>): void { this.journal.append(event, { task: task.taskId, queue: task.kind, attempt: task.attempt, state: task.state, ...extra }); }
}

const orchestrator = new TaskOrchestrator();
orchestrator.registerWorker("worker-blue", ["render", "index"], 3);
orchestrator.registerWorker("worker-green", ["notify", "archive"], 2);
const preview = orchestrator.submit("render", { document: "service-card", format: "terminal" }, 8);
const leased = orchestrator.lease("worker-blue");
if (leased?.taskId === preview) { orchestrator.begin(preview, "worker-blue"); orchestrator.complete(preview, "worker-blue", { frames: 12, checksum: "orchestrator-only" }); }
