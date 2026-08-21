// SPDX-License-Identifier: MIT
// :: This purpose-written source provides the Rust typing sequence bundled with Hacker Typer.
// :: Hacker Typer loads it as plain text and never evaluates or executes it.
// Bounded packet-processing state machine.
use std::collections::VecDeque;
use std::time::{Duration, Instant};

#[derive(Clone, Debug)]
pub struct Packet { pub id: u64, pub stream: u16, pub payload: Vec<u8>, pub received: Instant }
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum State { New, Inspecting, Accepted, Quarantined, Expired, Closed }
#[derive(Clone, Debug)]
pub struct Record { pub packet_id: u64, pub state: State, pub reason: String }

pub struct PacketMachine {
    queue: VecDeque<Packet>, records: Vec<Record>, state: State,
    next_id: u64, limit: usize, ttl: Duration, accepted: u64, rejected: u64,
}
impl PacketMachine {
    pub fn new(limit: usize, ttl: Duration) -> Self { Self {
        queue: VecDeque::new(), records: Vec::new(), state: State::New,
        next_id: 1, limit, ttl, accepted: 0, rejected: 0,
    }}
    pub fn enqueue(&mut self, stream: u16, bytes: &[u8]) -> Result<u64, &'static str> {
        if self.state == State::Closed { return Err("machine closed"); }
        if self.queue.len() >= self.limit { self.rejected += 1; return Err("bounded queue full"); }
        let id = self.next_id; self.next_id += 1;
        self.queue.push_back(Packet { id, stream, payload: bytes.to_vec(), received: Instant::now() });
        self.state = State::Inspecting; Ok(id)
    }
    pub fn step(&mut self) -> Option<Record> {
        let packet = self.queue.pop_front()?;
        let result = if packet.received.elapsed() > self.ttl {
            self.state = State::Expired; self.rejected += 1;
            Record { packet_id: packet.id, state: State::Expired, reason: "age budget exceeded".into() }
        } else if packet.payload.is_empty() {
            self.state = State::Quarantined; self.rejected += 1;
            Record { packet_id: packet.id, state: State::Quarantined, reason: "empty frame".into() }
        } else if packet.payload.len() > 4096 {
            self.state = State::Quarantined; self.rejected += 1;
            Record { packet_id: packet.id, state: State::Quarantined, reason: "frame budget exceeded".into() }
        } else if packet.payload[0] == 0xff {
            self.state = State::Quarantined; self.rejected += 1;
            Record { packet_id: packet.id, state: State::Quarantined, reason: "reserved marker".into() }
        } else {
            self.state = State::Accepted; self.accepted += 1;
            Record { packet_id: packet.id, state: State::Accepted, reason: format!("stream {} verified", packet.stream) }
        };
        self.records.push(result.clone());
        if self.queue.is_empty() && self.state != State::Closed { self.state = State::New; }
        Some(result)
    }
    pub fn close(&mut self) { self.queue.clear(); self.state = State::Closed; }
    pub fn state(&self) -> &State { &self.state }
    pub fn counters(&self) -> (u64, u64) { (self.accepted, self.rejected) }
    pub fn history(&self) -> &[Record] { &self.records }
}

pub struct FlowTable { slots: Vec<FlowSlot> }
struct FlowSlot { stream: u16, seen: u64, last: Instant }
impl FlowTable {
    pub fn with_capacity(capacity: usize) -> Self { Self { slots: Vec::with_capacity(capacity) } }
    pub fn observe(&mut self, stream: u16) -> u64 {
        if let Some(slot) = self.slots.iter_mut().find(|s| s.stream == stream) {
            slot.seen += 1; slot.last = Instant::now(); return slot.seen;
        }
        self.slots.push(FlowSlot { stream, seen: 1, last: Instant::now() }); 1
    }
    pub fn prune(&mut self, age: Duration) {
        self.slots.retain(|slot| slot.last.elapsed() <= age);
    }
}

pub fn process_cycle(machine: &mut PacketMachine, flows: &mut FlowTable) -> Vec<Record> {
    let mut output = Vec::new();
    for stream in 1..=3 { let _ = flows.observe(stream); let _ = machine.enqueue(stream, &[stream as u8, 2, 4, 8]); }
    while let Some(record) = machine.step() { output.push(record); }
    flows.prune(Duration::from_secs(30)); output
}
