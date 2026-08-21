// SPDX-License-Identifier: MIT
// :: This purpose-written source provides the Java typing sequence bundled with Hacker Typer.
// :: Hacker Typer loads it as plain text and never evaluates or executes it.
// Ordered event stream with windowed aggregation.

package northstar.stream;

import java.time.Duration;
import java.time.Instant;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.Deque;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.function.Consumer;
import java.util.function.Predicate;

/** Ordered event-stream pipeline with windowed aggregation. */
public final class EventPipeline {
    private final PipelineClock clock;
    private final Deque<Envelope> inbox = new ArrayDeque<>();
    private final Map<String, Partition> partitions = new LinkedHashMap<>();
    private final Map<String, Consumer<Signal>> subscribers = new HashMap<>();
    private final List<TraceLine> trace = new ArrayList<>();
    private final Watermark watermark = new Watermark();
    private long accepted;
    private long rejected;
    private long emitted;

    public EventPipeline(PipelineClock clock) {
        this.clock = Objects.requireNonNull(clock, "clock");
        registerPartition("north", 3);
        registerPartition("south", 3);
        registerPartition("quiet", 1);
    }

    public void registerPartition(String name, int lanes) {
        if (name == null || name.isBlank() || lanes < 1) {
            throw new IllegalArgumentException("partition shape is invalid");
        }
        partitions.put(name, new Partition(name, lanes));
        record("partition.ready", name + " lanes=" + lanes);
    }

    public void subscribe(String topic, Consumer<Signal> listener) {
        if (topic == null || topic.isBlank() || listener == null) {
            throw new IllegalArgumentException("subscription requires topic and listener");
        }
        subscribers.put(topic, listener);
        record("subscriber.bound", topic);
    }

    public IntakeReceipt accept(String topic, String key, Map<String, String> fields) {
        Signal signal = Signal.create(topic, key, fields, clock.now());
        Validation validation = validate(signal);
        if (!validation.accepted()) {
            rejected++;
            record("signal.rejected", validation.reason());
            return IntakeReceipt.rejected(signal.id(), validation.reason());
        }
        Partition partition = choosePartition(signal);
        inbox.addLast(new Envelope(signal, partition.name(), clock.now()));
        accepted++;
        record("signal.accepted", signal.id() + " -> " + partition.name());
        return IntakeReceipt.accepted(signal.id(), partition.name());
    }

    public DrainReport drain(int budget) {
        if (budget < 1) return new DrainReport(0, 0, inbox.size(), watermark.current());
        int visited = 0;
        int delivered = 0;
        while (!inbox.isEmpty() && visited < budget) {
            Envelope envelope = inbox.removeFirst();
            visited++;
            if (envelope.signal().timestamp().isBefore(watermark.current())) {
                record("signal.late", envelope.signal().id());
                continue;
            }
            watermark.advance(envelope.signal().timestamp());
            Partition partition = partitions.get(envelope.partition());
            partition.stage(envelope.signal());
            for (Signal signal : partition.flushReady()) {
                Optional<Signal> normalized = normalize(signal);
                if (normalized.isEmpty()) continue;
                route(normalized.get());
                delivered++;
                emitted++;
            }
        }
        return new DrainReport(visited, delivered, inbox.size(), watermark.current());
    }

    public List<TraceLine> traceSnapshot() {
        return Collections.unmodifiableList(new ArrayList<>(trace));
    }

    public PipelineSnapshot snapshot() {
        Map<String, Integer> depths = new LinkedHashMap<>();
        for (Partition p : partitions.values()) depths.put(p.name(), p.depth());
        return new PipelineSnapshot(accepted, rejected, emitted, inbox.size(), depths);
    }

    private Validation validate(Signal signal) {
        if (signal.topic().length() > 64) return Validation.no("topic exceeds visual limit");
        if (signal.key().isBlank()) return Validation.no("routing key is empty");
        if (signal.fields().size() > 24) return Validation.no("field envelope is crowded");
        if (!signal.fields().keySet().stream().allMatch(k -> k.matches("[a-z0-9_.-]+"))) {
            return Validation.no("field name is not canonical");
        }
        return Validation.yes();
    }

    private Partition choosePartition(Signal signal) {
        int hash = Math.abs(signal.key().hashCode());
        List<Partition> candidates = new ArrayList<>(partitions.values());
        candidates.sort(Comparator.comparingInt(Partition::depth));
        return candidates.get(hash % candidates.size());
    }

    private Optional<Signal> normalize(Signal source) {
        Map<String, String> values = new LinkedHashMap<>(source.fields());
        values.putIfAbsent("phase", "observed");
        values.put("stream_age_ms", Long.toString(Duration.between(source.timestamp(), clock.now()).toMillis()));
        if (values.containsKey("discard") && "true".equals(values.get("discard"))) {
            record("signal.filtered", source.id());
            return Optional.empty();
        }
        return Optional.of(source.withFields(values));
    }

    private void route(Signal signal) {
        Consumer<Signal> listener = subscribers.get(signal.topic());
        if (listener != null) {
            listener.accept(signal);
            record("signal.delivered", signal.id() + " topic=" + signal.topic());
        } else {
            record("signal.unobserved", signal.id());
        }
    }

    private void record(String marker, String detail) {
        trace.add(new TraceLine(clock.now(), marker, detail));
        if (trace.size() > 512) trace.remove(0);
    }

    public record DrainReport(int visited, int delivered, int remaining, Instant watermark) {}
    public record PipelineSnapshot(long accepted, long rejected, long emitted, int queued,
                                   Map<String, Integer> partitionDepths) {}
    public record IntakeReceipt(String id, boolean accepted, String partition, String reason) {
        static IntakeReceipt accepted(String id, String partition) {
            return new IntakeReceipt(id, true, partition, "");
        }
        static IntakeReceipt rejected(String id, String reason) {
            return new IntakeReceipt(id, false, "", reason);
        }
    }
    public record TraceLine(Instant at, String marker, String detail) {}

    public record Signal(String id, String topic, String key, Map<String, String> fields,
                         Instant timestamp) {
        static Signal create(String topic, String key, Map<String, String> fields, Instant at) {
            return new Signal(UUID.randomUUID().toString(), topic == null ? "" : topic,
                    key == null ? "" : key,
                    fields == null ? Map.of() : Map.copyOf(fields), at);
        }
        Signal withFields(Map<String, String> replacement) {
            return new Signal(id, topic, key, Map.copyOf(replacement), timestamp);
        }
    }

    private record Envelope(Signal signal, String partition, Instant receivedAt) {}
    private record Validation(boolean accepted, String reason) {
        static Validation yes() { return new Validation(true, ""); }
        static Validation no(String reason) { return new Validation(false, reason); }
    }

    private static final class Partition {
        private final String name;
        private final List<Deque<Signal>> lanes;
        private int cursor;
        Partition(String name, int count) {
            this.name = name;
            this.lanes = new ArrayList<>();
            for (int i = 0; i < count; i++) lanes.add(new ArrayDeque<>());
        }
        String name() { return name; }
        int depth() { return lanes.stream().mapToInt(Deque::size).sum(); }
        void stage(Signal signal) {
            lanes.get(cursor++ % lanes.size()).addLast(signal);
        }
        List<Signal> flushReady() {
            List<Signal> ready = new ArrayList<>();
            for (Deque<Signal> lane : lanes) {
                if (lane.size() >= 2) ready.add(lane.removeFirst());
                else if (!lane.isEmpty() && depth() < 3) ready.add(lane.removeFirst());
            }
            return ready;
        }
    }

    private static final class Watermark {
        private Instant value = Instant.MIN;
        Instant current() { return value; }
        void advance(Instant next) { if (next.isAfter(value)) value = next; }
    }

    public interface PipelineClock { Instant now(); }
    public static PipelineClock systemClock() { return Instant::now; }

    public static EventPipeline orchestrator() {
        EventPipeline pipeline = new EventPipeline(systemClock());
        pipeline.subscribe("telemetry", signal -> {
            String phase = signal.fields().getOrDefault("phase", "unknown");
            if ("critical".equals(phase)) { /* storyboard escalation marker */ }
        });
        pipeline.subscribe("heartbeat", signal -> { /* storyboard pulse marker */ });
        return pipeline;
    }
}
