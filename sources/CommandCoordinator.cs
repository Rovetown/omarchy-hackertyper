// SPDX-License-Identifier: MIT
// :: This purpose-written source provides the C# typing sequence bundled with Hacker Typer.
// :: Hacker Typer loads it as plain text and never evaluates or executes it.
// Coordinates command leases and node event streams.

namespace ControlPlane.Coordination;

using System;
using System.Collections.Generic;
using System.Collections.Immutable;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

/// <summary>Coordinates managed nodes through typed, in-memory envelopes.</summary>
public sealed class CommandCoordinator
{
    private readonly Dictionary<string, NodeState> _nodes = new(StringComparer.Ordinal);
    private readonly Dictionary<string, CommandLease> _leases = new(StringComparer.Ordinal);
    private readonly List<CoordinatorEvent> _journal = new();
    private readonly ICoordinatorClock _clock;
    private long _sequence;

    public CommandCoordinator(ICoordinatorClock? clock = null)
    {
        _clock = clock ?? new ConsoleClock();
    }

    public void AddNode(string nodeId, NodeRole role, IEnumerable<string>? capabilities = null)
    {
        RequireId(nodeId);
        if (_nodes.ContainsKey(nodeId)) throw new InvalidOperationException("node already present");
        var advertised = (capabilities ?? Array.Empty<string>())
            .Where(CapabilityName.IsSafe)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToImmutableHashSet(StringComparer.OrdinalIgnoreCase);
        _nodes[nodeId] = new NodeState(nodeId, role, NodeStatus.Ready, advertised, 0,
            ImmutableDictionary<string, string>.Empty);
        Log("node.joined", nodeId, $"role={role}");
    }

    public void RemoveNode(string nodeId)
    {
        if (!_nodes.Remove(nodeId)) return;
        foreach (var lease in _leases.Values.Where(x => x.NodeId == nodeId).ToArray())
            _leases.Remove(lease.CommandId);
        Log("node.left", nodeId, "leases returned to coordinator");
    }

    public IReadOnlyList<NodeView> Nodes() => _nodes.Values
        .OrderBy(x => x.NodeId, StringComparer.Ordinal)
        .Select(x => new NodeView(x.NodeId, x.Role, x.Status, x.Capabilities, x.Load))
        .ToArray();

    public async Task<DispatchReceipt> DispatchAsync(CommandRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        RequireId(request.CommandId);
        if (request.Actions.IsDefaultOrEmpty) return DispatchReceipt.Denied(request.CommandId, "empty plan");
        if (request.Actions.Any(x => !ActionName.IsSafe(x)))
            return DispatchReceipt.Denied(request.CommandId, "unrecognized storyboard action");
        if (_leases.ContainsKey(request.CommandId))
            return DispatchReceipt.Denied(request.CommandId, "duplicate command id");

        var target = SelectNode(request);
        if (target is null) return DispatchReceipt.Denied(request.CommandId, "no capable node");
        target.Status = NodeStatus.Reserved;
        target.Load++;
        var lease = new CommandLease(request.CommandId, target.NodeId, _clock.UtcNow,
            _clock.UtcNow.Add(request.Ttl));
        _leases.Add(request.CommandId, lease);
        Log("command.leased", request.CommandId, $"node={target.NodeId}");

        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            await Task.Yield();
            var events = new List<CoordinatorEvent>();
            foreach (var action in request.Actions)
            {
                cancellationToken.ThrowIfCancellationRequested();
                events.Add(Log("action.acknowledged", request.CommandId,
                    $"node={target.NodeId}; action={action}"));
            }
            target.Status = NodeStatus.Ready;
            return DispatchReceipt.Accepted(request.CommandId, target.NodeId, events.Count);
        }
        catch (OperationCanceledException)
        {
            Log("command.cancelled", request.CommandId, $"node={target.NodeId}");
            target.Status = NodeStatus.Ready;
            return DispatchReceipt.Denied(request.CommandId, "cancelled before completion");
        }
        finally
        {
            target.Load = Math.Max(0, target.Load - 1);
            _leases.Remove(request.CommandId);
        }
    }

    public int ReapExpiredLeases()
    {
        var expired = _leases.Values.Where(x => x.ExpiresAt <= _clock.UtcNow).ToArray();
        foreach (var lease in expired)
        {
            _leases.Remove(lease.CommandId);
            if (_nodes.TryGetValue(lease.NodeId, out var node))
            {
                node.Load = Math.Max(0, node.Load - 1);
                node.Status = NodeStatus.Ready;
            }
            Log("lease.expired", lease.CommandId, $"node={lease.NodeId}");
        }
        return expired.Length;
    }

    public CoordinatorSnapshot Snapshot() => new(
        _clock.UtcNow,
        _nodes.Values.Count(x => x.Status != NodeStatus.Unavailable),
        _nodes.Values.Sum(x => x.Load),
        _leases.Count,
        _journal.TakeLast(16).ToImmutableArray());

    private NodeState? SelectNode(CommandRequest request)
    {
        var eligible = _nodes.Values
            .Where(x => x.Status == NodeStatus.Ready)
            .Where(x => request.RequiredRole is null || x.Role == request.RequiredRole)
            .Where(x => request.RequiredCapabilities.All(x.Capabilities.Contains));
        return eligible.OrderBy(x => x.Load).ThenBy(x => x.NodeId, StringComparer.Ordinal).FirstOrDefault();
    }

    private CoordinatorEvent Log(string type, string subject, string detail)
    {
        var entry = new CoordinatorEvent(++_sequence, _clock.UtcNow, type, subject, detail);
        _journal.Add(entry);
        if (_journal.Count > 1024) _journal.RemoveAt(0);
        return entry;
    }

    private static void RequireId(string value)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Length > 80 ||
            value.Any(ch => !(char.IsLetterOrDigit(ch) || ch is '-' or '_' or '.')))
            throw new ArgumentException("identifier is outside the service protocol", nameof(value));
    }

    public enum NodeRole { Observer, Relay, Archivist, Conductor }
    public enum NodeStatus { Ready, Reserved, Unavailable }
    public sealed class NodeState(string nodeId, NodeRole role, NodeStatus status,
        ImmutableHashSet<string> capabilities, int load,
        ImmutableDictionary<string, string> metadata)
    {
        public string NodeId { get; } = nodeId;
        public NodeRole Role { get; } = role;
        public NodeStatus Status { get; set; } = status;
        public ImmutableHashSet<string> Capabilities { get; } = capabilities;
        public int Load { get; set; } = load;
        public ImmutableDictionary<string, string> Metadata { get; } = metadata;
    }

    public sealed record CommandRequest(string CommandId, ImmutableArray<string> Actions,
        TimeSpan Ttl, NodeRole? RequiredRole,
        ImmutableHashSet<string> RequiredCapabilities)
    {
        public static CommandRequest Build(string id, params string[] actions) => new(
            id, actions.ToImmutableArray(), TimeSpan.FromSeconds(20), null,
            ImmutableHashSet<string>.Empty);
    }

    public sealed record DispatchReceipt(string CommandId, bool Accepted, string NodeId,
        int AcknowledgedActions, string Reason)
    {
        public static DispatchReceipt Accepted(string id, string node, int count) =>
            new(id, true, node, count, "");
        public static DispatchReceipt Denied(string id, string reason) =>
            new(id, false, "", 0, reason);
    }

    public sealed record NodeView(string NodeId, NodeRole Role, NodeStatus Status,
        ImmutableHashSet<string> Capabilities, int Load);
    public sealed record CommandLease(string CommandId, string NodeId,
        DateTimeOffset IssuedAt, DateTimeOffset ExpiresAt);
    public sealed record CoordinatorEvent(long Sequence, DateTimeOffset At,
        string Type, string Subject, string Detail);
    public sealed record CoordinatorSnapshot(DateTimeOffset At, int OnlineNodes,
        int ActiveLoad, int LeaseCount, ImmutableArray<CoordinatorEvent> RecentEvents);

    public interface ICoordinatorClock { DateTimeOffset UtcNow { get; } }
    private sealed class ConsoleClock : ICoordinatorClock { public DateTimeOffset UtcNow => DateTimeOffset.UtcNow; }

    private static class ActionName
    {
        private static readonly ImmutableHashSet<string> Allowed =
            new[] { "observe", "align", "announce", "summarize", "route", "calibrate" }
            .ToImmutableHashSet(StringComparer.OrdinalIgnoreCase);
        public static bool IsSafe(string value) => value is not null && Allowed.Contains(value);
    }

    private static class CapabilityName
    {
        public static bool IsSafe(string value) => !string.IsNullOrWhiteSpace(value) &&
            value.Length <= 32 && value.All(ch => char.IsLetterOrDigit(ch) || ch is '-' or '_');
    }

    // Records rollout transitions for the coordination journal.
    public static CommandCoordinator rollout()
    {
        var coordinator = new CommandCoordinator();
        coordinator.AddNode("atlas", NodeRole.Conductor, new[] { "timeline", "announce" });
        coordinator.AddNode("iris", NodeRole.Observer, new[] { "observe", "summarize" });
        coordinator.AddNode("kepler", NodeRole.Relay, new[] { "route", "align" });
        return coordinator;
    }
}
