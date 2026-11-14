// Pure trajectory math. No robot API, sockets, CAN, mode changes or core calls.
// Build against Amber's installed Ruckig to test a hypothesized handoff input;
// this does not replay the historical incident or measure its internal state.
#include <ruckig/ruckig.hpp>
#include <algorithm>
#include <cmath>
#include <iomanip>
#include <iostream>
#include <stdexcept>

constexpr double degrees = 180.0 / 3.14159265358979323846;
struct Summary { double minimum, maximum, duration; };

Summary simulate(const char* label, double velocity, double acceleration) {
    ruckig::Ruckig<7> planner(0.005);
    ruckig::InputParameter<7> input;
    ruckig::Trajectory<7> trajectory;
    input.current_position = {0, 0, 0, 0, 0, 0.34 * degrees, 0};
    input.current_velocity = {0, 0, 0, 0, 0, velocity * degrees, 0};
    input.current_acceleration = {0, 0, 0, 0, 0, acceleration * degrees, 0};
    input.target_position = {0, 0, 0, 0, 0, 1.05 * degrees, 0};
    input.target_velocity = {0, 0, 0, 0, 0, 0, 0};
    input.target_acceleration = {0, 0, 0, 0, 0, 0, 0};
    // Exact numeric launch constraints; core disassembly shows radians are
    // converted to degrees before PositionTask and these limits copied directly.
    input.max_velocity = {5400, 5400, 5400, 5400, 4200, 4200, 4200};
    input.max_acceleration = {90000, 90000, 90000, 90000, 90000, 90000, 90000};
    input.max_jerk = {5000, 5000, 5000, 5000, 5000, 5000, 5000};
    input.minimum_duration = 2.0;
    if (planner.calculate(input, trajectory) < 0) throw std::runtime_error("Trajectory rejected");
    Summary result{0.34, 0.34, trajectory.get_duration()};
    std::array<double, 7> q, v, a;
    const int steps = static_cast<int>(std::ceil(result.duration / 0.005));
    for (int i = 0; i <= steps; ++i) {
        trajectory.at_time(std::min(i * 0.005, result.duration), q, v, a);
        result.minimum = std::min(result.minimum, q[5] / degrees);
        result.maximum = std::max(result.maximum, q[5] / degrees);
    }
    std::cout << "{\"case\":\"" << label << "\",\"start_rad\":0.34,\"target_rad\":1.05,"
              << "\"seed_velocity_rad_s\":" << velocity << ",\"seed_acceleration_rad_s2\":" << acceleration
              << ",\"minimum_rad\":" << result.minimum << ",\"maximum_rad\":" << result.maximum
              << ",\"duration_s\":" << result.duration << "}\n";
    return result;
}

void continuousRetarget() {
    // Proposed architecture in SI units, using illustrative commissioning
    // limits, NOT a new hardware driver or certified motor ratings.
    ruckig::Ruckig<7> planner(0.005);
    ruckig::InputParameter<7> input;
    ruckig::OutputParameter<7> output;
    input.current_position = {0, 0, 0, 0, 0, 0.34, 0};
    input.current_velocity.fill(0); input.current_acceleration.fill(0);
    input.target_position = input.current_position;
    input.target_velocity.fill(0); input.target_acceleration.fill(0);
    input.max_velocity.fill(0.3); input.max_acceleration.fill(0.6); input.max_jerk.fill(2.0);
    double maxVelocity=0, maxAcceleration=0, maxJerk=0, maxStep=0, previousAcceleration=0;
    int changesWhileMoving=0;
    for (int step=0; step<2400; ++step) {
        if (step < 1600 && step%10 == 0) {
            if (std::abs(input.current_velocity[5]) > 0.01) ++changesWhileMoving;
            input.target_position[5] = 0.7 + 0.3 * std::sin(step*0.005*1.2);
        } else if (step == 1600) input.target_position[5] = 0.7;
        if (planner.update(input, output) < 0) throw std::runtime_error("Continuous update rejected");
        maxStep = std::max(maxStep, std::abs(output.new_position[5]-input.current_position[5]));
        maxVelocity = std::max(maxVelocity, std::abs(output.new_velocity[5]));
        maxAcceleration = std::max(maxAcceleration, std::abs(output.new_acceleration[5]));
        maxJerk = std::max(maxJerk, std::abs(output.new_acceleration[5]-previousAcceleration)/0.005);
        previousAcceleration = output.new_acceleration[5];
        if (std::abs(output.new_position[5]) > 2.09) throw std::runtime_error("Prototype left position bound");
        // Keep the exact coherent output state. Never redifferentiate a
        // sampled position command on an unrelated timer at target changes.
        output.pass_to_input(input);
    }
    if (maxVelocity > 0.300001 || maxAcceleration > 0.600001 || maxJerk > 2.000001 ||
        maxStep > 0.001501 || changesWhileMoving < 100 || std::abs(input.current_position[5]-0.7)>1e-6)
        throw std::runtime_error("Continuous prototype violated its declared limits");
    std::cout << "{\"case\":\"persistent_latest_target_prototype\",\"target_updates_hz\":20,\"planner_hz\":200,"
              << "\"changes_while_moving\":" << changesWhileMoving << ",\"max_velocity_rad_s\":" << maxVelocity
              << ",\"max_acceleration_rad_s2\":" << maxAcceleration << ",\"max_jerk_rad_s3\":" << maxJerk
              << ",\"max_step_rad\":" << maxStep << ",\"final_rad\":" << input.current_position[5] << "}\n";
}

int main() {
    std::cout << std::setprecision(12);
    auto consistent = simulate("consistent_command_state", 0.2, 0);
    // A position update missed by one 5 ms sampler interval makes its next
    // derivative zero; differencing against the previous 0.2 rad/s gives -40.
    auto missed = simulate("hypothetical_missed_sample", 0, (0 - 0.2) / 0.005);
    auto settled = simulate("stationary_handoff", 0, 0);
    if (consistent.minimum < 0.34 - 1e-8 || settled.minimum < 0.34 - 1e-8 || missed.minimum >= 0)
        throw std::runtime_error("Expected comparison not reproduced");
    continuousRetarget();
}
