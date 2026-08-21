-- SPDX-License-Identifier: MIT
-- :: This purpose-written source provides the SQL typing sequence bundled with Hacker Typer.
-- :: Hacker Typer loads it as plain text and never evaluates or executes it.
-- Telemetry retention schema and service analysis queries.

CREATE SCHEMA IF NOT EXISTS telemetry_lab;

CREATE TABLE IF NOT EXISTS telemetry_lab.workspace (
    workspace_id UUID PRIMARY KEY,
    display_name TEXT NOT NULL,
    region_code TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    status TEXT NOT NULL CHECK (status IN ('active', 'suspended', 'archived'))
);

CREATE TABLE IF NOT EXISTS telemetry_lab.actor (
    actor_id UUID PRIMARY KEY,
    workspace_id UUID NOT NULL REFERENCES telemetry_lab.workspace(workspace_id),
    actor_kind TEXT NOT NULL CHECK (actor_kind IN ('member', 'service', 'device')),
    consent_state TEXT NOT NULL CHECK (consent_state IN ('granted', 'limited', 'withdrawn')),
    first_seen_at TIMESTAMPTZ NOT NULL,
    last_seen_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS telemetry_lab.session (
    session_id UUID PRIMARY KEY,
    workspace_id UUID NOT NULL REFERENCES telemetry_lab.workspace(workspace_id),
    actor_id UUID NOT NULL REFERENCES telemetry_lab.actor(actor_id),
    client_label TEXT NOT NULL,
    client_version TEXT NOT NULL,
    started_at TIMESTAMPTZ NOT NULL,
    ended_at TIMESTAMPTZ,
    session_status TEXT NOT NULL CHECK (session_status IN ('open', 'closed', 'expired')),
    sample_rate NUMERIC(5,4) NOT NULL DEFAULT 1.0000,
    properties_json JSONB NOT NULL DEFAULT '{}'::JSONB
);

CREATE TABLE IF NOT EXISTS telemetry_lab.event (
    event_id UUID PRIMARY KEY,
    session_id UUID NOT NULL REFERENCES telemetry_lab.session(session_id),
    workspace_id UUID NOT NULL REFERENCES telemetry_lab.workspace(workspace_id),
    event_name TEXT NOT NULL,
    event_version INTEGER NOT NULL DEFAULT 1,
    occurred_at TIMESTAMPTZ NOT NULL,
    received_at TIMESTAMPTZ NOT NULL,
    sequence_no BIGINT NOT NULL,
    source_area TEXT NOT NULL,
    value_number NUMERIC,
    value_text TEXT,
    attributes_json JSONB NOT NULL DEFAULT '{}'::JSONB,
    privacy_class TEXT NOT NULL DEFAULT 'standard',
    ingest_state TEXT NOT NULL CHECK (ingest_state IN ('accepted', 'held', 'rejected')),
    UNIQUE (session_id, sequence_no)
);

CREATE TABLE IF NOT EXISTS telemetry_lab.metric_sample (
    sample_id UUID PRIMARY KEY,
    session_id UUID NOT NULL REFERENCES telemetry_lab.session(session_id),
    workspace_id UUID NOT NULL REFERENCES telemetry_lab.workspace(workspace_id),
    metric_name TEXT NOT NULL,
    sampled_at TIMESTAMPTZ NOT NULL,
    metric_value NUMERIC NOT NULL,
    unit_name TEXT NOT NULL,
    aggregation_hint TEXT NOT NULL DEFAULT 'gauge',
    dimensions_json JSONB NOT NULL DEFAULT '{}'::JSONB
);

CREATE INDEX IF NOT EXISTS event_workspace_occurred_idx
    ON telemetry_lab.event (workspace_id, occurred_at, event_name);
CREATE INDEX IF NOT EXISTS event_session_sequence_idx
    ON telemetry_lab.event (session_id, sequence_no);
CREATE INDEX IF NOT EXISTS session_workspace_started_idx
    ON telemetry_lab.session (workspace_id, started_at DESC);
CREATE INDEX IF NOT EXISTS metric_workspace_name_time_idx
    ON telemetry_lab.metric_sample (workspace_id, metric_name, sampled_at DESC);

CREATE OR REPLACE VIEW telemetry_lab.daily_event_rollup AS
SELECT
    workspace_id,
    DATE_TRUNC('day', occurred_at) AS activity_day,
    event_name,
    COUNT(*) AS event_count,
    COUNT(DISTINCT session_id) AS session_count,
    COUNT(*) FILTER (WHERE ingest_state = 'held') AS held_count
FROM telemetry_lab.event
GROUP BY workspace_id, DATE_TRUNC('day', occurred_at), event_name;

CREATE OR REPLACE VIEW telemetry_lab.session_activity AS
SELECT
    s.workspace_id,
    s.session_id,
    s.client_label,
    s.client_version,
    s.started_at,
    s.ended_at,
    COUNT(e.event_id) AS event_count,
    MIN(e.occurred_at) AS first_event_at,
    MAX(e.occurred_at) AS last_event_at
FROM telemetry_lab.session AS s
LEFT JOIN telemetry_lab.event AS e ON e.session_id = s.session_id
GROUP BY s.workspace_id, s.session_id, s.client_label, s.client_version, s.started_at, s.ended_at;

-- Event volume by day with deterministic ordering.
SELECT
    activity_day,
    event_name,
    event_count,
    session_count,
    held_count
FROM telemetry_lab.daily_event_rollup
WHERE workspace_id = :workspace_id
  AND activity_day >= :from_timestamp
  AND activity_day < :to_timestamp
ORDER BY activity_day, event_name
FETCH FIRST 500 ROWS ONLY;

-- Sessions above an event-volume review threshold.
SELECT
    session_id,
    client_label,
    client_version,
    started_at,
    event_count,
    first_event_at,
    last_event_at
FROM telemetry_lab.session_activity
WHERE workspace_id = :workspace_id
  AND started_at >= :from_timestamp
  AND started_at < :to_timestamp
  AND event_count >= :minimum_events
ORDER BY started_at DESC
FETCH FIRST 250 ROWS ONLY;

-- Hourly ingest latency for accepted events.
SELECT
    DATE_TRUNC('hour', received_at) AS received_hour,
    COUNT(*) AS observations,
    AVG(EXTRACT(EPOCH FROM (received_at - occurred_at))) AS mean_delay_seconds,
    MAX(EXTRACT(EPOCH FROM (received_at - occurred_at))) AS max_delay_seconds
FROM telemetry_lab.event
WHERE workspace_id = :workspace_id
  AND occurred_at >= :from_timestamp
  AND occurred_at < :to_timestamp
  AND ingest_state = 'accepted'
GROUP BY DATE_TRUNC('hour', received_at)
ORDER BY received_hour;

-- Metric distribution by client label.
SELECT
    s.client_label,
    m.metric_name,
    COUNT(*) AS sample_count,
    AVG(m.metric_value) AS mean_value,
    MIN(m.metric_value) AS minimum_value,
    MAX(m.metric_value) AS maximum_value
FROM telemetry_lab.metric_sample AS m
JOIN telemetry_lab.session AS s ON s.session_id = m.session_id
WHERE m.workspace_id = :workspace_id
  AND m.metric_name = :metric_name
  AND m.sampled_at >= :from_timestamp
  AND m.sampled_at < :to_timestamp
GROUP BY s.client_label, m.metric_name
ORDER BY s.client_label;

-- Event names with a high held proportion.
SELECT
    event_name,
    COUNT(*) AS inspected_events,
    SUM(CASE WHEN ingest_state = 'held' THEN 1 ELSE 0 END) AS held_events,
    100.0 * SUM(CASE WHEN ingest_state = 'held' THEN 1 ELSE 0 END)
        / NULLIF(COUNT(*), 0) AS held_percent
FROM telemetry_lab.event
WHERE workspace_id = :workspace_id
  AND received_at >= :from_timestamp
  AND received_at < :to_timestamp
GROUP BY event_name
HAVING COUNT(*) >= :minimum_observations
ORDER BY held_percent DESC, event_name
FETCH FIRST 100 ROWS ONLY;

-- Open sessions approaching the configured timeout window.
SELECT session_id, actor_id, client_label, started_at
FROM telemetry_lab.session
WHERE workspace_id = :workspace_id
  AND session_status = 'open'
  AND started_at < :stale_before
ORDER BY started_at
FETCH FIRST 200 ROWS ONLY;
