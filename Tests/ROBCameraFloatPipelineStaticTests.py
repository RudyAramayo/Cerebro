#!/usr/bin/env python3
"""Regression checks for camera pixel formats and cancellable MLX vision work."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CAMERA = (ROOT / "Cerebro" / "CameraViewController.swift").read_text(
    encoding="utf-8"
)
MLX_RUNTIME = (ROOT / "Cerebro" / "ROBMLXRuntime.swift").read_text(
    encoding="utf-8"
)
INSTA360_PERCEPTION = (
    ROOT / "Cerebro" / "ROBInsta360PerceptionService.swift"
).read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    # SceneKit's point-cloud shader expects float4 for the color semantic. Feeding
    # it uchar4 causes macOS to emit "unsupported conversion uchar4 -> float4"
    # once per rendered frame, regardless of the ML analysis preferences.
    require(
        "var colors: [SIMD4<Float>] = []" in CAMERA,
        "Depth point-cloud colors must remain float4 values",
    )
    require(
        "usesFloatComponents: true, componentsPerVector: 4" in CAMERA
        and "bytesPerComponent: MemoryLayout<Float>.size" in CAMERA
        and "dataStride: MemoryLayout<SIMD4<Float>>.stride" in CAMERA,
        "SceneKit's color geometry source must advertise float components",
    )
    require(
        "var colors: [SIMD4<UInt8>]" not in CAMERA
        and "usesFloatComponents: false, componentsPerVector: 4" not in CAMERA,
        "The unsupported uchar4 SceneKit color path was reintroduced",
    )

    # VLM inputs are explicitly rendered into RGBA float storage before MLX sees
    # them, instead of asking the GPU graph to infer a uchar4-to-float4 cast.
    require(
        "private func floatBackedVisionImage(" in MLX_RUNTIME
        and ".useSoftwareRenderer: true" in MLX_RUNTIME
        and "format: .RGBAf" in MLX_RUNTIME,
        "MLX camera inputs must retain explicit CPU-backed RGBAf staging",
    )

    # Own the task returned by MLXLMCommon so disabling a stream stops in-progress
    # generation, not only future frame submission.
    require(
        "MLXLMCommon.generateTask(" in MLX_RUNTIME
        and "container.generate(" not in MLX_RUNTIME,
        "MLX generation must expose its worker task for cancellation",
    )
    require(
        "generation.task.cancel()" in MLX_RUNTIME
        and "await generation.task.value" in MLX_RUNTIME
        and "withTaskCancellationHandler" in MLX_RUNTIME,
        "Cancelled vision work must cancel and join the real MLX worker",
    )
    require(
        "public func cancelVision(source: String)" in MLX_RUNTIME
        and "cancelAllVisionTasks()" in MLX_RUNTIME,
        "Camera analysis switches must cancel active per-source generation",
    )
    require(
        "source: ROBMLXVisionSource.insta360Preview" in INSTA360_PERCEPTION,
        "The Insta360 producer and cancellation path must share one source ID",
    )

    print("Camera float-pipeline regression checks passed")


if __name__ == "__main__":
    main()
