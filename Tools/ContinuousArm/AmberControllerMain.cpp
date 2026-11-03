// Linux commissioning executable. Physical mode is receive-only. The sole
// transmit mode requires both an explicit fixture flag and kernel-verified
// vcan.
#include "ArmSession.hpp"
#include "SocketCanTransport.hpp"
#include <cerrno>
#include <cmath>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <json/json.hpp>
#include <limits>
#include <poll.h>
#include <set>
#include <stdexcept>
#include <sys/random.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

namespace w = rob::amber;
namespace a = rob::arm;
using Json = nlohmann::json;
namespace {
volatile std::sig_atomic_t stop_requested = 0;
void signalStop(int) { stop_requested = 1; }
const char *modeName(w::SessionMode m) {
  switch (m) {
  case w::SessionMode::Observing:
    return "observing";
  case w::SessionMode::Following:
    return "following";
  case w::SessionMode::Braking:
    return "braking";
  case w::SessionMode::Held:
    return "held";
  case w::SessionMode::Fault:
    return "fault";
  }
  return "unknown";
}
struct Options {
  bool fixture{};
  w::PhysicalArm arm{w::PhysicalArm::Right};
  std::string interface, directory;
  double duration{10};
};
void help() {
  std::cout << "rob-amber-controller --self-check\n"
               "rob-amber-controller --observe --arm right|left [--duration "
               "SECONDS]\n"
               "rob-amber-controller --virtual-fixture --interface VCAN "
               "--runtime-dir NEW_PRIVATE_DIR [--duration SECONDS]\n"
               "No physical transmit, mode change, calibration, activation, "
               "install or restart operation exists.\n";
}
Options options(int argc, char **argv) {
  Options o;
  bool selected = false;
  std::set<std::string> seen;
  for (int i = 1; i < argc; ++i) {
    std::string key = argv[i];
    if (!seen.insert(key).second)
      throw std::runtime_error("duplicate option");
    if (key == "--observe" || key == "--virtual-fixture") {
      if (selected)
        throw std::runtime_error("choose one mode");
      selected = true;
      o.fixture = key == "--virtual-fixture";
      continue;
    }
    if (i + 1 == argc)
      throw std::runtime_error("missing option value");
    const std::string value = argv[++i];
    if (key == "--arm") {
      if (value == "right")
        o.arm = w::PhysicalArm::Right;
      else if (value == "left")
        o.arm = w::PhysicalArm::Left;
      else
        throw std::runtime_error("invalid arm");
    } else if (key == "--interface")
      o.interface = value;
    else if (key == "--runtime-dir")
      o.directory = value;
    else if (key == "--duration") {
      std::size_t used = 0;
      o.duration = std::stod(value, &used);
      if (used != value.size())
        throw std::runtime_error("invalid duration");
    } else
      throw std::runtime_error("unknown option");
  }
  if (!selected || !std::isfinite(o.duration) || o.duration <= 0 ||
      o.duration > 60)
    throw std::runtime_error("mode and duration 0..60 required");
  if (o.fixture) {
    const char *gate = std::getenv("ROB_ISOLATED_VCAN_TEST");
    if (!gate || std::strcmp(gate, "1") != 0 || o.interface.empty() ||
        o.directory.empty() || o.directory.front() != '/')
      throw std::runtime_error(
          "virtual fixture requires explicit isolated-test environment, "
          "interface and absolute new directory");
  } else {
    if (!o.interface.empty() || !o.directory.empty())
      throw std::runtime_error("passive mode uses canonical arm route only");
    o.interface = std::string(w::route(o.arm)->can_interface);
  }
  return o;
}
std::string nonce() {
  std::array<unsigned char, 16> bytes{};
  if (getrandom(bytes.data(), bytes.size(), 0) !=
      static_cast<ssize_t>(bytes.size()))
    throw std::runtime_error("session entropy unavailable");
  const char *digits = "0123456789abcdef";
  std::string result;
  for (auto x : bytes) {
    result += digits[x >> 4];
    result += digits[x & 15];
  }
  return result;
}
struct LocalServer {
  int listener{-1}, client{-1};
  std::string directory, path;
  bool created{};
  explicit LocalServer(const std::string &dir)
      : directory(dir), path(dir + "/control.sock") {
    if (path.size() >= sizeof(sockaddr_un{}.sun_path))
      throw std::runtime_error("socket path too long");
    if (mkdir(directory.c_str(), 0700) != 0)
      throw std::runtime_error(
          "runtime directory must be new; never replace existing files");
    created = true;
    listener =
        socket(AF_UNIX, SOCK_SEQPACKET | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
    if (listener < 0 ||
        bind(listener, reinterpret_cast<sockaddr *>(&address),
             sizeof(address)) < 0 ||
        listen(listener, 2) < 0) {
      cleanup();
      throw std::runtime_error("private local socket creation failed");
    }
  }
  void drop() {
    if (client >= 0) {
      close(client);
      client = -1;
    }
  }
  void cleanup() {
    drop();
    if (listener >= 0) {
      close(listener);
      listener = -1;
    }
    if (created) {
      unlink(path.c_str());
      rmdir(directory.c_str());
      created = false;
    }
  }
  ~LocalServer() { cleanup(); }
  bool acceptPeer() {
    const int next =
        accept4(listener, nullptr, nullptr, SOCK_NONBLOCK | SOCK_CLOEXEC);
    if (next < 0) {
      if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
        throw std::runtime_error("accept failed");
      return false;
    }
    ucred credential{};
    socklen_t length = sizeof(credential);
    if (client >= 0 ||
        getsockopt(next, SOL_SOCKET, SO_PEERCRED, &credential, &length) < 0 ||
        length != sizeof(credential) || credential.uid != geteuid()) {
      close(next);
      return false;
    }
    client = next;
    return true;
  }
  bool send(const Json &body) {
    const std::string data = body.dump();
    return client >= 0 && ::send(client, data.data(), data.size(),
                                 MSG_DONTWAIT | MSG_NOSIGNAL) ==
                              static_cast<ssize_t>(data.size());
  }
};
Json snapshot(const w::ArmSession &session,
              const w::SocketCanTransport &transport) {
  const auto s = session.status();
  const auto t = transport.status();
  return {{"mode", modeName(s.mode)},
          {"reason", static_cast<int>(s.reason)},
          {"generation", s.generation},
          {"owner_reason", a::name(s.owner.reason)},
          {"boundary_fault", static_cast<int>(s.boundary.fault)},
          {"transport_fault", static_cast<int>(t.fault)},
          {"transport_errno", t.system_error},
          {"boundary_accepted_frames", s.boundary.accepted_frames},
          {"backend_accepted_frames", t.accepted},
          {"boundary_attempted_frames", s.boundary.attempted_frames},
          {"backend_attempted_frames", t.attempted},
          {"published_batches", s.boundary.published_batches},
          {"commanded_position", s.owner.commanded.position},
          {"commanded_velocity", s.owner.commanded.velocity},
          {"commanded_acceleration", s.owner.commanded.acceleration},
          {"shutdown_complete", s.shutdown_complete},
          {"physical_transmit_available", false}};
}
Json parsePacket(const char *begin, const char *end) {
  std::set<std::string> keys;
  bool duplicate = false;
  auto parsed = Json::parse(
      begin, end, [&](int depth, Json::parse_event_t event, Json &value) {
        if (depth == 1 && event == Json::parse_event_t::key &&
            !keys.insert(value.get<std::string>()).second)
          duplicate = true;
        return true;
      });
  if (duplicate)
    throw std::runtime_error("duplicate packet key");
  return parsed;
}
bool exactKeys(const Json &j, const std::set<std::string> &keys) {
  if (!j.is_object() || j.size() != keys.size())
    return false;
  for (auto it = j.begin(); it != j.end(); ++it)
    if (!keys.count(it.key()))
      return false;
  return true;
}
std::uint64_t uint(const Json &j, const char *key) {
  if (!j.at(key).is_number_unsigned())
    throw std::runtime_error("unsigned integer required");
  return j.at(key).get<std::uint64_t>();
}
bool dispatch(const Json &j, const std::string &token, std::uint64_t peer,
              w::ArmSession &session, double end) {
  if (!j.is_object() || !j.contains("nonce") || !j["nonce"].is_string() ||
      j["nonce"] != token || !j.contains("op") || !j["op"].is_string())
    throw std::runtime_error("session packet identity");
  const auto op = j["op"].get<std::string>();
  std::set<std::string> fields = {"op", "nonce", "generation", "created_ns"};
  if (op == "target") {
    fields.insert("sequence");
    fields.insert("position");
  }
  if (!exactKeys(j, fields))
    throw std::runtime_error("packet shape");
  const auto gen = uint(j, "generation"), created = uint(j, "created_ns");
  const auto now = w::SocketCanTransport::monotonicNanoseconds();
  if (created > static_cast<std::uint64_t>(now) ||
      static_cast<std::uint64_t>(now) - created > 200000000)
    return false; // age checked in integer nanoseconds before conversion
  const double captured = static_cast<double>(created) * 1e-9;
  if (op == "start") {
    if (gen != 0)
      return false;
    // This synthetic grant exists ONLY after the executable verified vcan.
    // No client field can authorize the physical receive-only mode.
    return session.start(peer, std::min(now * 1e-9 + 10, end - .5), true);
  }
  if (op == "target") {
    if (!j["position"].is_array() || j["position"].size() != 7)
      throw std::runtime_error("seven positions required");
    a::Vector q{};
    for (std::size_t i = 0; i < 7; ++i) {
      if (!j["position"][i].is_number())
        throw std::runtime_error("numeric position required");
      q[i] = j["position"][i].get<double>();
    }
    return session.submit(peer, gen, uint(j, "sequence"), captured, q) ==
           a::Reason::None;
  }
  if (op == "heartbeat")
    return session.heartbeat(peer, gen, captured);
  if (op == "stop")
    return session.stop(peer, gen);
  throw std::runtime_error("unknown operation");
}
int run(const Options &o) {
  w::SocketCanOptions config;
  config.arm = o.arm;
  config.interface = o.interface;
  config.require_virtual = o.fixture;
  config.allow_transmit = o.fixture;
  config.clock.maximum_age = 200000000;
  w::SocketCanTransport transport(config);
  if (!transport.open(1))
    throw std::runtime_error("CAN open/verification failed, errno=" +
                             std::to_string(transport.status().system_error));
  // These are SIMULATION values, never a physical motor rating/profile.
  a::Limits limits;
  limits.lower.fill(-2.09);
  limits.upper.fill(2.09);
  limits.velocity.fill(.3);
  limits.acceleration.fill(.6);
  limits.jerk.fill(2);
  w::ArmSession session(
      o.arm, {1, 1, 1, 1, 1, 1, 1}, limits, {.005, .05, .2, .2, .08},
      {.2, .1, .2, .0004, 5, 64, 1, 2, .004, .05, 1}, {.3, .15, 20, .15, 3}, 1,
      w::SocketCanTransport::monotonicSeconds,
      [](const a::Trajectory &path, double, bool) {
        const auto e = a::envelope(path);
        if (!e.valid)
          return false;
        for (std::size_t j = 0; j < 7; ++j)
          if (e.lower[j] < -.8 || e.upper[j] > .8)
            return false;
        return true;
      },
      [&](const w::Route &route, const w::Frame &frame, double deadline) {
        return transport.writePosition(route, frame, deadline);
      });
  if (!session.resetSource(1))
    throw std::runtime_error("source initialization failed");
  std::unique_ptr<LocalServer> server;
  if (o.fixture)
    server = std::make_unique<LocalServer>(o.directory);
  const double begin = w::SocketCanTransport::monotonicSeconds(),
               end = begin + o.duration;
  double next_tick = begin;
  std::uint64_t peer = 0, connection_generation = 0;
  std::string token;
  auto drop = [&] {
    if (server && server->client >= 0) {
      session.disconnect(peer, connection_generation);
      server->drop();
    }
    connection_generation = 0;
    token.clear();
  };
  std::cout << Json({{"event", "ready"},
                     {"mode",
                      o.fixture ? "virtual_fixture" : "passive_observation"},
                     {"interface", o.interface},
                     {"interface_kind", transport.status().interface_kind},
                     {"physical_transmit_available", false}})
                   .dump()
            << std::endl;
  while (true) {
    const auto feedback = transport.receive();
    if (transport.status().fault != w::SocketCanFault::None) {
      session.transportFault();
      break;
    }
    for (const auto &f : feedback)
      session.observe(f.epoch, f.frame,
                      static_cast<double>(f.received_at) * 1e-9);
    const double now = w::SocketCanTransport::monotonicSeconds();
    if (stop_requested || now >= end)
      session.shutdown();
    if (server && !session.status().shutting_down) {
      if (server->acceptPeer()) {
        if (peer == std::numeric_limits<std::uint64_t>::max())
          throw std::runtime_error("client identity exhausted");
        ++peer;
        token = nonce();
        connection_generation = 0;
        if (!server->send(
                {{"event", "hello"},
                 {"nonce", token},
                 {"peer", peer},
                 {"protocol", 1},
                 {"clock", "CLOCK_MONOTONIC nanoseconds on this host"},
                 {"virtual_fixture", true}}))
          drop();
      }
      for (int count = 0; server->client >= 0 && count < 16 && !stop_requested;
           ++count) {
        std::array<char, 2048> bytes{};
        const auto n = recv(server->client, bytes.data(), bytes.size(),
                            MSG_DONTWAIT | MSG_TRUNC);
        if (n < 0) {
          if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
            break;
          drop();
          break;
        }
        if (n == 0 || n >= static_cast<ssize_t>(bytes.size())) {
          drop();
          break;
        }
        bool accepted = false;
        try {
          accepted = dispatch(parsePacket(bytes.data(), bytes.data() + n),
                              token, peer, session, end);
        } catch (...) {
          drop();
          break;
        }
        if (accepted && session.status().client == peer)
          connection_generation = session.status().generation;
        auto response = snapshot(session, transport);
        response["accepted"] = accepted;
        if (!server->send(response)) {
          drop();
          break;
        }
        if (count == 15) {
          char pending;
          const auto more =
              recv(server->client, &pending, 1, MSG_PEEK | MSG_DONTWAIT);
          if (more >= 0 ||
              (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR))
            drop();
        }
      }
    }
    if (stop_requested)
      session.shutdown();
    if (now >= next_tick) {
      session.tick();
      next_tick = w::SocketCanTransport::monotonicSeconds() + .005;
    }
    const auto state = session.status();
    if (state.mode == w::SessionMode::Fault || state.shutdown_complete)
      break;
    // No catch-up burst after scheduler delays. Session timing checks fail
    // closed; this non-real-time fixture is not a scheduling guarantee.
    poll(nullptr, 0, 1);
  }
  const auto final = snapshot(session, transport);
  std::cout << Json({{"event", "final"},
                     {"status", final},
                     {"received_frames", transport.status().received},
                     {"virtual_fixture", o.fixture}})
                   .dump()
            << std::endl;
  return session.status().mode == w::SessionMode::Fault ? 3 : 0;
}
} // namespace
int main(int argc, char **argv) {
  try {
    if (argc == 1 || (argc == 2 && std::string(argv[1]) == "--help")) {
      help();
      return 0;
    }
    if (argc == 2 && std::string(argv[1]) == "--self-check") {
      std::cout << Json({{"protocol", 1},
                         {"hardware_io", false},
                         {"physical_transmit_available", false},
                         {"modes",
                          {"passive_observation", "isolated_virtual_fixture"}},
                         {"ruckig", "0.9.2"}})
                       .dump()
                << '\n';
      return 0;
    }
    const auto o = options(argc, argv);
    struct sigaction action{};
    action.sa_handler = signalStop;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGINT, &action, nullptr) < 0 ||
        sigaction(SIGTERM, &action, nullptr) < 0)
      throw std::runtime_error("signal handler setup");
    return run(o);
  } catch (const std::exception &e) {
    std::cerr << "rob-amber-controller: " << e.what() << '\n';
    return 2;
  }
}
