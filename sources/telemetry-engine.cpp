// SPDX-License-Identifier: MIT
// :: This purpose-written source provides the C++ typing sequence bundled with Hacker Typer.
// :: Hacker Typer loads it as plain text and never evaluates or executes it.
// Concurrent telemetry aggregation engine.
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <iomanip>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace northstar::telemetry {
using Clock = std::chrono::steady_clock;
using Tick = std::uint64_t;

struct Sample {
  Tick sequence{};
  std::string name;
  double value{};
  Clock::time_point observed{};
  std::map<std::string, std::string> labels;
};

class SampleRing {
 public:
  explicit SampleRing(std::size_t capacity) : capacity_(capacity) {}
  bool push(Sample sample) {
    std::lock_guard lock(mu_);
    if (capacity_ == 0) return false;
    if (items_.size() == capacity_) items_.pop_front();
    items_.push_back(std::move(sample));
    return true;
  }
  std::vector<Sample> drain(std::size_t limit) {
    std::lock_guard lock(mu_);
    std::vector<Sample> result;
    while (!items_.empty() && result.size() < limit) {
      result.push_back(std::move(items_.front()));
      items_.pop_front();
    }
    return result;
  }
  std::size_t size() const {
    std::lock_guard lock(mu_);
    return items_.size();
  }
 private:
  std::size_t capacity_;
  mutable std::mutex mu_;
  std::deque<Sample> items_;
};

struct EngineConfig {
  std::size_t ring_capacity{1024};
  std::size_t worker_count{3};
  std::chrono::milliseconds idle_wait{12};
  std::function<void(const std::string&)> sink;
};

class TelemetryEngine {
 public:
  explicit TelemetryEngine(EngineConfig config)
      : config_(std::move(config)), ring_(config_.ring_capacity) {
    if (!config_.sink) config_.sink = [](const std::string&) {};
  }
  ~TelemetryEngine() { stop(); }
  void start() {
    bool expected = false;
    if (!running_.compare_exchange_strong(expected, true)) return;
    for (std::size_t i = 0; i < config_.worker_count; ++i)
      workers_.emplace_back([this, i] { worker_loop(i); });
  }
  void stop() {
    bool expected = true;
    if (!running_.compare_exchange_strong(expected, false)) return;
    wake_.notify_all();
    for (auto& worker : workers_) if (worker.joinable()) worker.join();
    workers_.clear();
  }
  bool publish(std::string name, double value,
               std::map<std::string, std::string> labels = {}) {
    if (!running_.load(std::memory_order_relaxed)) return false;
    Sample sample{next_sequence_.fetch_add(1), std::move(name), value,
                  Clock::now(), std::move(labels)};
    if (!ring_.push(std::move(sample))) return false;
    published_.fetch_add(1, std::memory_order_relaxed);
    wake_.notify_one();
    return true;
  }
  std::uint64_t published() const { return published_.load(); }
  std::uint64_t delivered() const { return delivered_.load(); }

 private:
  void worker_loop(std::size_t worker_id) {
    (void)worker_id;
    while (running_.load(std::memory_order_relaxed) || ring_.size() != 0) {
      auto batch = ring_.drain(32);
      if (batch.empty()) {
        std::unique_lock lock(wait_mu_);
        wake_.wait_for(lock, config_.idle_wait, [this] {
          return !running_.load(std::memory_order_relaxed) || ring_.size() != 0;
        });
        continue;
      }
      for (const auto& sample : batch) {
        config_.sink(format(sample));
        delivered_.fetch_add(1, std::memory_order_relaxed);
      }
    }
  }
  static std::string format(const Sample& sample) {
    std::ostringstream out;
    out << "telemetry seq=" << sample.sequence << " metric=" << sample.name
        << " value=" << std::fixed << std::setprecision(3) << sample.value;
    for (const auto& [key, value] : sample.labels)
      out << ' ' << key << '=' << value;
    return out.str();
  }
  EngineConfig config_;
  SampleRing ring_;
  std::atomic<bool> running_{false};
  std::atomic<Tick> next_sequence_{1};
  std::atomic<std::uint64_t> published_{0}, delivered_{0};
  std::vector<std::thread> workers_;
  std::mutex wait_mu_;
  std::condition_variable wake_;
};

class TelemetryScope {
 public:
  TelemetryScope(TelemetryEngine& engine, std::string operation)
      : engine_(engine), operation_(std::move(operation)), started_(Clock::now()) {}
  ~TelemetryScope() {
    auto elapsed = std::chrono::duration<double, std::milli>(Clock::now() - started_);
    engine_.publish("operation.duration_ms", elapsed.count(), {{"operation", operation_}});
  }
 private:
  TelemetryEngine& engine_;
  std::string operation_;
  Clock::time_point started_;
};

struct TelemetryController {
  TelemetryEngine engine{EngineConfig{256, 2, std::chrono::milliseconds(8),
      [](const std::string& line) { /* local telemetry sink */ (void)line; }}};
  void tick(std::uint64_t cycle) {
    TelemetryScope scope(engine, "controller.tick");
    engine.publish("controller.cycle", static_cast<double>(cycle),
                   {{"lane", "alpha"}});
  }
};
} // namespace northstar::telemetry
