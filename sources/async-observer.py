# SPDX-License-Identifier: MIT
# :: This purpose-written source provides the Python typing sequence bundled with Hacker Typer.
# :: Hacker Typer loads it as plain text and never evaluates or executes it.
"""Asynchronous observability collector for service health signals."""
from __future__ import annotations

import asyncio
import dataclasses
import enum
import math
import random
import time
from collections import deque
from collections.abc import AsyncIterator, Iterable
from typing import Any, Final, NamedTuple

AGENT_NAME: Final = "lumen-observer"
SCHEMA_VERSION: Final = "observer.schema.v3"
MAX_QUEUE: Final = 128


class Severity(enum.StrEnum):
    TRACE = "trace"
    INFO = "info"
    NOTICE = "notice"
    WARNING = "warning"
    ALERT = "alert"


@dataclasses.dataclass(frozen=True, slots=True)
class Sample:
    metric: str
    value: float
    unit: str
    recorded_at: float
    labels: tuple[tuple[str, str], ...] = ()


@dataclasses.dataclass(frozen=True, slots=True)
class Observation:
    sequence: int
    kind: str
    subject: str
    severity: Severity
    message: str
    samples: tuple[Sample, ...]
    trace_hint: str | None = None


class AgentState(NamedTuple):
    phase: str
    observations_seen: int
    warnings: int
    queue_depth: int
    heartbeat: int


class Clock:
    """A replaceable clock keeps the runtime deterministic during rollout."""

    def __init__(self, start: float | None = None) -> None:
        self._start = time.monotonic() if start is None else start

    def now(self) -> float:
        return self._start + time.monotonic() - self._start


class RingBuffer:
    def __init__(self, capacity: int = MAX_QUEUE) -> None:
        self._items: deque[Observation] = deque(maxlen=capacity)
        self.dropped = 0

    def append(self, item: Observation) -> None:
        if len(self._items) == self._items.maxlen:
            self.dropped += 1
        self._items.append(item)

    def snapshot(self) -> tuple[Observation, ...]:
        return tuple(self._items)


class SignalFactory:
    def __init__(self, clock: Clock, seed: int = 23) -> None:
        self.clock = clock
        self.random = random.Random(seed)
        self.sequence = 0

    def observation(self, kind: str, subject: str, message: str,
                   severity: Severity = Severity.INFO) -> Observation:
        self.sequence += 1
        now = self.clock.now()
        base = self.random.uniform(0.18, 0.92)
        samples = (
            Sample("aggregate.load", round(base, 4), "ratio", now,
                   (("agent", AGENT_NAME), ("subject", subject))),
            Sample("aggregate.lag", round(base * 41.0, 3), "milliseconds", now,
                   (("kind", kind),)),
        )
        return Observation(self.sequence, kind, subject, severity, message,
                           samples, trace_hint=f"orchestrator-{self.sequence:06d}")


class LocalModel:
    """In-memory state projection; the name 'local' is an intentional promise."""

    def __init__(self) -> None:
        self.phase = "warming"
        self.seen = 0
        self.warnings = 0
        self.heartbeats = 0
        self.recent_subjects: deque[str] = deque(maxlen=12)

    def fold(self, event: Observation) -> AgentState:
        self.seen += 1
        self.phase = "watching" if event.kind == "heartbeat" else self.phase
        if event.severity in (Severity.WARNING, Severity.ALERT):
            self.warnings += 1
        self.recent_subjects.append(event.subject)
        if event.kind == "heartbeat":
            self.heartbeats += 1
        return AgentState(self.phase, self.seen, self.warnings,
                          len(self.recent_subjects), self.heartbeats)


async def aggregate_stream(factory: SignalFactory, count: int = 16,
                           pause: float = 0.01) -> AsyncIterator[Observation]:
    """Produce imaginary telemetry without reading the host or network."""
    subjects = ("clockwork", "paper-lantern", "quiet-orbit", "blue-comet")
    for index in range(count):
        await asyncio.sleep(pause)
        subject = subjects[index % len(subjects)]
        if index % 7 == 6:
            yield factory.observation("threshold", subject,
                                      "threshold exceeded; review required",
                                      Severity.WARNING)
        elif index % 4 == 0:
            yield factory.observation("heartbeat", subject, "pulse acknowledged")
        else:
            yield factory.observation("gauge", subject, "sample received")


class Observer:
    def __init__(self, factory: SignalFactory, model: LocalModel,
                 buffer: RingBuffer) -> None:
        self.factory = factory
        self.model = model
        self.buffer = buffer
        self._wake = asyncio.Event()
        self._stopped = False
        self._last_state = AgentState("warming", 0, 0, 0, 0)

    async def ingest(self, stream: AsyncIterator[Observation]) -> None:
        async for event in stream:
            if self._stopped:
                break
            self.buffer.append(event)
            self._last_state = self.model.fold(event)
            self._wake.set()
            self._wake.clear()

    async def pulse(self, interval: float = 0.07) -> AsyncIterator[Observation]:
        while not self._stopped:
            await asyncio.sleep(interval)
            yield self.factory.observation("heartbeat", "observer",
                                           "in-memory observer is alive")

    async def stop(self) -> None:
        self._stopped = True
        self._wake.set()

    def state(self) -> AgentState:
        return self._last_state


class ReviewFormatter:
    @staticmethod
    def line(event: Observation) -> str:
        measurements = ", ".join(
            f"{sample.metric}={sample.value:.3f}{sample.unit}"
            for sample in event.samples
        )
        trace = event.trace_hint or "none"
        return (f"#{event.sequence:04d} [{event.severity.value.upper():7}] "
                f"{event.subject:<14} {event.message} | {measurements} | {trace}")

    @classmethod
    def report(cls, events: Iterable[Observation], state: AgentState) -> str:
        header = ["LUMEN OBSERVER / SERVICE REVIEW", "=" * 64,
                  f"phase={state.phase} seen={state.observations_seen} "
                  f"warnings={state.warnings}"]
        return "\n".join([*header, *(cls.line(event) for event in events)])


def anomaly_score(samples: Iterable[Sample]) -> float:
    values = [sample.value for sample in samples if math.isfinite(sample.value)]
    if not values:
        return 0.0
    average = sum(values) / len(values)
    return round(min(1.0, abs(average - 0.5) * 1.8), 4)


async def rollout(count: int = 18) -> str:
    clock = Clock()
    factory = SignalFactory(clock)
    model = LocalModel()
    buffer = RingBuffer()
    observer = Observer(factory, model, buffer)
    await observer.ingest(aggregate_stream(factory, count=count))
    return ReviewFormatter.report(buffer.snapshot(), observer.state())


async def main() -> None:
    print(await rollout())


if __name__ == "__main__":
    asyncio.run(main())
