// SPDX-License-Identifier: MIT
// :: This purpose-written source provides the Go typing sequence bundled with Hacker Typer.
// :: Hacker Typer loads it as plain text and never evaluates or executes it.
// Reconciles desired node assignments with observed cluster state.
package reconciler

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"
)

type Phase string
const (
	PhaseWaiting Phase = "waiting"
	PhaseReady   Phase = "ready"
	PhaseDraining Phase = "draining"
	PhaseStalled Phase = "stalled"
)

type Node struct {
	Name string
	Zone string
	Capacity int
	Used int
	Labels map[string]string
}
func (n Node) Free() int { return n.Capacity - n.Used }

type Workload struct {
	Name string
	Replicas int
	Weight int
	Selector map[string]string
}

type Placement struct { Workload, Node string; Ordinal int }
type Snapshot struct {
	Revision uint64
	Nodes []Node
	Workloads []Workload
	Placements []Placement
	Phase Phase
	Message string
}

type Store interface {
	Read(context.Context) (Snapshot, error)
	Commit(context.Context, Snapshot) error
}

type MemoryStore struct { mu sync.Mutex; state Snapshot }
func NewMemoryStore() *MemoryStore { return &MemoryStore{state: Snapshot{Phase: PhaseWaiting}} }
func (s *MemoryStore) Read(context.Context) (Snapshot, error) {
	s.mu.Lock(); defer s.mu.Unlock()
	return cloneSnapshot(s.state), nil
}
func (s *MemoryStore) Commit(_ context.Context, next Snapshot) error {
	s.mu.Lock(); defer s.mu.Unlock()
	if next.Revision != s.state.Revision+1 { return fmt.Errorf("revision conflict") }
	s.state = cloneSnapshot(next); return nil
}

func cloneSnapshot(in Snapshot) Snapshot {
	out := in
	out.Nodes = append([]Node(nil), in.Nodes...)
	out.Workloads = append([]Workload(nil), in.Workloads...)
	out.Placements = append([]Placement(nil), in.Placements...)
	return out
}
func matches(labels, selector map[string]string) bool {
	for k, want := range selector { if labels[k] != want { return false } }
	return true
}
func sortNodes(nodes []Node) {
	sort.Slice(nodes, func(i, j int) bool {
		if nodes[i].Free() == nodes[j].Free() { return nodes[i].Name < nodes[j].Name }
		return nodes[i].Free() > nodes[j].Free()
	})
}

type Reconciler struct { store Store; clock func() time.Time; maxRetries int }
func New(store Store) *Reconciler { return &Reconciler{store: store, clock: time.Now, maxRetries: 4} }
func (r *Reconciler) Reconcile(ctx context.Context) error {
	for attempt := 0; attempt < r.maxRetries; attempt++ {
		current, err := r.store.Read(ctx); if err != nil { return err }
		next := plan(current, r.clock())
		next.Revision = current.Revision + 1
		if err = r.store.Commit(ctx, next); err == nil { return nil }
		if ctx.Err() != nil { return ctx.Err() }
	}
	return fmt.Errorf("reconcile retries exhausted")
}
func plan(in Snapshot, now time.Time) Snapshot {
	next := cloneSnapshot(in); next.Placements = nil
	nodes := append([]Node(nil), in.Nodes...); sortNodes(nodes)
	workloads := append([]Workload(nil), in.Workloads...)
	sort.Slice(workloads, func(i,j int) bool { return workloads[i].Name < workloads[j].Name })
	for _, workload := range workloads {
		for ordinal := 0; ordinal < workload.Replicas; ordinal++ {
			chosen := -1
			for i := range nodes {
				if nodes[i].Free() >= workload.Weight && matches(nodes[i].Labels, workload.Selector) {
					chosen = i; break
				}
			}
			if chosen < 0 { next.Phase = PhaseStalled; next.Message = "capacity or selector mismatch"; continue }
			nodes[chosen].Used += workload.Weight
			next.Placements = append(next.Placements, Placement{workload.Name, nodes[chosen].Name, ordinal})
		}
		sortNodes(nodes)
	}
	if len(next.Placements) == 0 && len(workloads) != 0 { next.Phase = PhaseWaiting } else { next.Phase = PhaseReady }
	next.Message = fmt.Sprintf("planned at %s", now.UTC().Format(time.RFC3339))
	return next
}
func Summary(s Snapshot) string {
	parts := make([]string, len(s.Placements)); for i,p := range s.Placements { parts[i] = p.Workload+"/"+p.Node }
	return fmt.Sprintf("rev=%d phase=%s placements=%s", s.Revision, s.Phase, strings.Join(parts, ","))
}
