#pragma once

// Pure offline packet codec for the hash-audited Amber executable. No sockets,
// mode/calibration commands, actuator authority, startup or hardware watchdog.
// These bytes are compatibility evidence, NOT commissioned motor behavior.
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>

namespace rob::amber {
constexpr std::size_t joint_count = 7;
constexpr double radians_to_degrees = 57.2957795130823208768;
constexpr double position_counts_per_degree = 128.0;
using JointVector = std::array<double, joint_count>;
using Directions = std::array<int, joint_count>;

enum class PhysicalArm { Right, Left };
struct Route {
    PhysicalArm physical_arm;
    std::string_view can_interface;
    std::string_view vendor_directory;
    std::string_view vendor_lcm_prefix;
};
std::optional<Route> route(PhysicalArm);

// identifier includes any SocketCAN flag bits supplied by a future adapter.
// Only exact standard joint-reply IDs are accepted by the diagnostic decoder.
struct Frame {
    std::uint32_t identifier{};
    std::uint8_t length{};
    std::array<std::uint8_t, 8> data{};
};
struct PositionBounds { JointVector lower{}, upper{}; }; // native-reference radians
struct PositionBatch { Route destination; std::array<Frame, joint_count> frames; };

// Converts radians to degrees exactly once, then applies the explicit native
// direction (+1/-1) and 128 counts/degree. Truncates toward zero like the audited
// sender, with +65535 for negative counts (NOT two's complement). Only integer
// counts -32766..32767 roundtrip without ambiguity. In particular -32767 would
// encode 0x8000 and decode as POSITIVE32768. Reject it and all overflow,
// nonfinite and out-of-bounds inputs before producing a batch.
// Returns an entire seven-joint batch or no batch; never clips/wraps a target.
// Both the requested and quantized output positions must satisfy the bounds.
// Bounds/signs are caller-supplied, not a hardware-rating or calibration claim.
std::optional<PositionBatch> encodePositions(PhysicalArm, const JointVector& radians,
                                            const Directions&, const PositionBounds&);

struct JointDiagnostic {
    std::size_t joint_index{}; // zero based, 0..6; excludes gripper node 8
    double position_radians{};
    std::int32_t position_native_counts{}; // before direction conversion
    std::int32_t velocity_native_counts{}; // physical units NOT established
    std::int32_t current_native_counts{};  // physical units NOT established
    double current_vendor_scaled{};       // /256 observed; NOT labelled amperes
    std::uint8_t reply_tag{};              // byte 0; vendor ignores this byte
    std::uint8_t status{};                 // raw byte, not a stationary proof
};

// Decodes the exact observed signed convention, including raw0x8000 => +32768
// and raw0xffff => 0. Does not infer timestamps, authority, mode validity,
// physical speed/current units or stationary state from a diagnostic packet.
// direction must be +1 or -1, taken from the explicit joint calibration.
std::optional<JointDiagnostic> decodeJointDiagnostic(const Frame&, int direction);
} // namespace rob::amber
