#include "AmberWireCodec.hpp"
#include <cmath>

namespace rob::amber {
namespace {
std::int32_t legacySigned(std::uint8_t high, std::uint8_t low) {
    const auto raw = (std::uint32_t(high) << 8) | low;
    return raw > 32768 ? std::int32_t(raw)-65535 : std::int32_t(raw);
}
bool validDirection(int value) { return value == 1 || value == -1; }
} // namespace

std::optional<Route> route(PhysicalArm arm) {
    switch (arm) {
        case PhysicalArm::Right: return Route{arm, "can10", "L-10", "Left_"};
        case PhysicalArm::Left: return Route{arm, "can11", "R-11", "Right_"};
    }
    return std::nullopt;
}

std::optional<PositionBatch> encodePositions(PhysicalArm arm, const JointVector& q,
                                            const Directions& signs, const PositionBounds& bounds) {
    const auto destination = route(arm);
    if (!destination) return std::nullopt;
    PositionBatch batch{*destination, {}};
    for (std::size_t j=0; j<joint_count; ++j) {
        if (!std::isfinite(q[j]) || !validDirection(signs[j]) ||
            !std::isfinite(bounds.lower[j]) || !std::isfinite(bounds.upper[j]) ||
            bounds.lower[j] >= bounds.upper[j] || q[j] < bounds.lower[j] || q[j] > bounds.upper[j])
            return std::nullopt;
        const double degrees = q[j] * radians_to_degrees;
        const double scaled = (degrees * signs[j]) * position_counts_per_degree;
        // Check before integer conversion; casting NaN/infinity/overflow is UB.
        // Restrict to the unambiguous signed domain, not just the low 16 bits.
        if (!std::isfinite(scaled) || scaled < -32767.0 || scaled > 32767.0)
            return std::nullopt;
        const auto count = static_cast<std::int32_t>(scaled);
        const double quantized = (count / position_counts_per_degree) * signs[j] / radians_to_degrees;
        if (quantized < bounds.lower[j] || quantized > bounds.upper[j]) return std::nullopt;
        const auto word = static_cast<std::uint16_t>(count < 0 ? count+65535 : count);
        Frame& frame = batch.frames[j];
        frame.identifier = 0x11 + static_cast<std::uint32_t>(j);
        frame.length = 3;
        frame.data[0] = 0x40;
        frame.data[1] = static_cast<std::uint8_t>(word >> 8);
        frame.data[2] = static_cast<std::uint8_t>(word & 0xff);
    }
    return batch;
}

std::optional<JointDiagnostic> decodeJointDiagnostic(const Frame& frame, int direction) {
    if (frame.identifier < 0x91 || frame.identifier > 0x97 || frame.length != 8 ||
        !validDirection(direction)) return std::nullopt;
    JointDiagnostic result;
    result.joint_index = frame.identifier-0x91;
    result.position_native_counts = legacySigned(frame.data[1], frame.data[2]);
    result.velocity_native_counts = legacySigned(frame.data[3], frame.data[4]);
    result.current_native_counts = legacySigned(frame.data[5], frame.data[6]);
    result.position_radians = (result.position_native_counts / position_counts_per_degree) *
                              direction / radians_to_degrees;
    result.current_vendor_scaled = result.current_native_counts / 256.0;
    result.reply_tag = frame.data[0];
    result.status = frame.data[7];
    return result;
}
} // namespace rob::amber
