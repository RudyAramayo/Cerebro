#!/usr/bin/env python3
"""Create a scientific diagnostic plot from measured, offline QR analyses.

No robot or camera APIs. Input files stay private; the public summary contains
aggregate metrics, source hashes and limitations, never camera images or points.
Use --summary to reproduce the plot without access to the private input files.
"""

import argparse
import hashlib
import json
import math
from pathlib import Path
import statistics

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np


BLUE = "#2665A8"
ORANGE = "#C66529"
GRAY = "#596574"


def read(path):
    return json.loads(Path(path).read_text())


def provenance(role, path):
    path = Path(path)
    return {"role": role, "filename": path.name,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def finite_tree(value):
    if isinstance(value, float) and not math.isfinite(value):
        raise ValueError("Non-finite metric cannot be plotted or published")
    if isinstance(value, dict):
        for item in value.values():
            finite_tree(item)
    elif isinstance(value, list):
        for item in value:
            finite_tree(item)


def aggregate(args):
    pixel = read(args.pixel_analysis)
    camera = read(args.camera_ab)
    labels = dict(item.split("=", 1) for item in args.capture_label)
    summary = {"schemaVersion": 1, "status": "diagnostic_unverified",
               "registrationVerified": False, "calibrationApplied": False,
               "sources": [provenance("pixel_geometry_comparison", args.pixel_analysis),
                           provenance("camera_pipeline_comparison", args.camera_ab)],
               "focusCapture": args.focus_capture, "captures": {}, "jointFits": [],
               "cameraModes": {}, "plotSoftware": {"matplotlib": matplotlib.__version__,
                                                     "numpy": np.__version__}}
    for key, capture in pixel.items():
        summary["captures"][key] = {
            "label": labels.get(key, key), "acceptedFrames": capture["accepted"],
            "rejectedFrames": capture["rejected"],
            "sourceCaptureSHA256": capture["rawCaptureSHA256"],
            "refinedCaptureSHA256": capture["refinedCaptureSHA256"],
            "repeatability": capture["repeatability"],
            "recordedFrameK": capture["calibration"]["templateECC"]["metadataK"]["K"],
            "imageOnlyKAndDepthComparisons": capture["calibration"]["templateECC"],
            "intrinsicSensitivity": capture["templateKBootstrap20WithPoint1PixelPerturbation"]}
    for label, path in args.joint_fit:
        fit = read(path)
        summary["sources"].append(provenance("shared_neck_fit: "+label, path))
        summary["jointFits"].append({
            "label": label,
            "trainingReprojectionRMSEPixels": fit["trainingReprojectionRMSEPixels"],
            "heldOutReprojectionRMSEPixels": fit["heldOutReprojectionRMSEPixels"],
            "gains": fit.get("scales"), "gauge": fit.get("gauge"),
            "analysisInput": fit.get("analysisInput"),
            "registrationVerified": fit.get("registrationVerified", False)})
    for mode, data in camera["modes"].items():
        records = data["records"]
        rgb = [item["pnpCenterZMeters"] for item in records]
        depth = [item["planeCenterDepthMeters"] for item in records]
        difference = [a-b for a, b in zip(rgb, depth)]
        summary["cameraModes"][mode] = {
            "frames": len(records), "RGBPnPMeanZMeters": statistics.mean(rgb),
            "RGBPnPFrameStdZMeters": statistics.pstdev(rgb),
            "alignedDepthPlaneMeanZMeters": statistics.mean(depth),
            "alignedDepthPlaneFrameStdZMeters": statistics.pstdev(depth),
            "RGBMinusDepthMeanMeters": statistics.mean(difference),
            "RGBMinusDepthRMSEMeters": math.sqrt(statistics.mean(x*x for x in difference))}
    summary["cameraModePlotOrder"] = args.camera_mode or [
        name for name in ["imagealign-native", "imagealign-undistorted", "stereo-native", "stereo-undistorted"]
        if name in summary["cameraModes"]]
    if args.raw_upper_report or args.refined_upper_report:
        if not args.raw_upper_report or not args.refined_upper_report:
            raise ValueError("Supply both raw and refined upper-neck reports")
        summary["upperNeck"] = {}
        for label, path in [("rawVision", args.raw_upper_report), ("templateECC", args.refined_upper_report)]:
            report = read(path)
            summary["sources"].append(provenance("upper_neck_report: "+label, path))
            summary["upperNeck"][label] = {
                "holdCount": report["holdCount"], "sampleCount": report["sampleCount"],
                "panDegrees": report["panDegrees"], "lowerTarget": report["lowerTarget"],
                "angleScaleCandidates": report["angleScaleCandidates"],
                "holds": [{key: hold[key] for key in ["stepIndex", "upperTarget", "sampleCount", "qrInferredCameraPitchChangeDegrees"]}
                          for hold in report["holds"]], "warnings": report["warnings"]}
    summary["limitations"] = [
        "No parameter, URDF, camera-to-arm registration or servo calibration is applied by this analysis.",
        "Raw observations are accepted neck command estimates, not measured shaft angles.",
        "A per-image PnP fit estimates a separate pose for each image. A shared neck fit must explain all command poses. These residuals are different quantities.",
        "Within-hold scatter and repeated commanded-pose differences measure repeatability, not absolute accuracy. Some held-out frames repeat previously observed postures.",
        "Intrinsic perturbation spans are a sensitivity experiment, not confidence intervals or a replacement camera calibration.",
        "Frame-to-frame distance standard deviations do not bound systematic distance error.",
        "The alternative 4K-crop intrinsic hypothesis is a sensitivity comparison; a smaller model residual does not make its framing correct.",
        "Upper servo zero and camera mounting rotation are exactly coupled without an independent mechanical reference. Lower zero also couples to an unknown world/base target pose.",
        "All source images, raw depth and corner coordinates remain private; only aggregate metrics and input hashes are published."]
    finite_tree(summary)
    return summary


def bars(ax, labels, first, second, first_name, second_name, ylabel):
    x = np.arange(len(labels))
    width = .35
    a = ax.bar(x-width/2, first, width, color=ORANGE, label=first_name)
    b = ax.bar(x+width/2, second, width, color=BLUE, label=second_name)
    ax.set_xticks(x, labels)
    ax.set_ylabel(ylabel)
    ax.legend(frameon=False, fontsize=8)
    ax.bar_label(a, fmt="%.3f", padding=3, fontsize=8)
    ax.bar_label(b, fmt="%.3f", padding=3, fontsize=8)
    maximum = max([*first, *second])
    ax.set_ylim(0, maximum*1.27)


def draw(summary, output):
    if summary.get("status") != "diagnostic_unverified" or summary.get("registrationVerified"):
        raise ValueError("This plot only represents unverified diagnostic analyses")
    finite_tree(summary)
    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 9,
                         "axes.titlesize": 11, "axes.labelsize": 9,
                         "axes.spines.top": False, "axes.spines.right": False,
                         "legend.fontsize": 8, "figure.facecolor": "white"})
    fig, axes = plt.subplots(2, 3, figsize=(16.5, 11))
    fig.subplots_adjust(left=.065, right=.98, top=.87, bottom=.20, wspace=.31, hspace=.54)
    fig.suptitle("ROB neck and camera commissioning: diagnostic, unverified", fontsize=18, y=.97)
    fig.text(.065, .925, "Known 120 mm QR target | aggregate measurements only | no calibration applied",
             fontsize=11, color=GRAY)
    for ax in axes.flat:
        ax.set_axisbelow(True)
        ax.grid(axis="y", color="#DFE4EA", linewidth=.7)

    captures = list(summary["captures"].values())
    labels = [item["label"]+f"\nn = {item['acceptedFrames']} frames" for item in captures]
    raw = [item["repeatability"]["rawVision"]["withinHoldCornerRMSEPixels"] for item in captures]
    refined = [item["repeatability"]["templateECC"]["withinHoldCornerRMSEPixels"] for item in captures]
    ax = axes[0, 0]
    bars(ax, labels, raw, refined, "Vision corners", "Exact-pattern corners", "Within-hold corner RMS (pixels)")
    ax.set_title("A. Repeated frames at a settled hold", loc="left", pad=14)

    repeats = [item for item in captures if item["repeatability"]["rawVision"]["repeatPostureVsFirstHoldCornerRMSEPixels"] is not None]
    ax = axes[0, 1]
    bars(ax, [item["label"] for item in repeats],
         [item["repeatability"]["rawVision"]["repeatPostureVsFirstHoldCornerRMSEPixels"] for item in repeats],
         [item["repeatability"]["templateECC"]["repeatPostureVsFirstHoldCornerRMSEPixels"] for item in repeats],
         "Vision corners", "Exact-pattern corners", "Return-to-commanded-pose corner RMS (pixels)")
    ax.set_title("B. Revisiting the same commanded pose", loc="left", pad=14)
    ax.text(0, -.20, "Compared with the first hold at that pose;\nthis includes revisit effects, not just detector noise.",
            transform=ax.transAxes, color=GRAY, fontsize=8, va="top")

    ax = axes[0, 2]
    fits = summary["jointFits"]
    bars(ax, [item["label"].replace(" / ", "\n") for item in fits],
         [item["trainingReprojectionRMSEPixels"] for item in fits],
         [item["heldOutReprojectionRMSEPixels"] for item in fits],
         "Training", "Held out", "Shared neck-model corner RMS (pixels)")
    ax.set_title("C. One shared neck model across poses", loc="left", pad=14)
    ax.tick_params(axis="x", labelsize=8)
    ax.text(0, -.23, "Intrinsics are conditional hypotheses. The 4K-crop K\nuses different framing; lower error does not validate it.",
            transform=ax.transAxes, color=GRAY, fontsize=8, va="top")

    ax = axes[1, 0]
    modes = summary["cameraModes"]
    order = summary["cameraModePlotOrder"]
    x = np.arange(len(order))
    for offset, color, mean_key, std_key, label in [
            (-.12, BLUE, "RGBPnPMeanZMeters", "RGBPnPFrameStdZMeters", "RGB QR pose (PnP)"),
            (.12, ORANGE, "alignedDepthPlaneMeanZMeters", "alignedDepthPlaneFrameStdZMeters", "Aligned depth plane")]:
        ax.errorbar(x+offset, [1000*modes[name][mean_key] for name in order],
                    yerr=[1000*modes[name][std_key] for name in order], fmt="o", color=color,
                    capsize=4, markersize=5, label=label)
    names = {"imagealign-native": "ImageAlign\nundistort off", "imagealign-undistorted": "ImageAlign\nundistort on",
             "stereo-native": "Stereo align\nundistort off", "stereo-undistorted": "Stereo align\nundistort on"}
    ax.set_xticks(x, [names.get(name, name.replace("-", "\n")) for name in order])
    ax.set_ylabel("Optical-axis distance Z (mm)")
    ax.set_title("D. Same pose: RGB and depth disagree", loc="left", pad=14)
    ax.legend(frameon=False, fontsize=8)
    ax.text(0, -.24, "Points: frame means; whiskers: +/-1 frame SD.\nSmall frame scatter does not bound systematic error.",
            transform=ax.transAxes, color=GRAY, fontsize=8, va="top")

    focus = summary["captures"][summary["focusCapture"]]
    ax = axes[1, 1]
    sensitivity = focus["intrinsicSensitivity"]
    center, lower, upper = [np.array(sensitivity[key]) for key in ["median", "p05", "p95"]]
    x = np.arange(len(center))
    ax.errorbar(x-.07, center, yerr=[center-lower, upper-center], fmt="o", color=ORANGE,
                capsize=5, label="Perturbation median / 5-95% span")
    ax.scatter(x+.07, focus["recordedFrameK"], marker="x", color=BLUE, s=45, label="Recorded frame K")
    ax.set_xticks(x, ["fx", "fy", "cx", "cy"])
    ax.set_ylabel("Intrinsic parameter value (pixels)")
    ax.set_title("E. Image-only intrinsics are sensitive", loc="left", pad=14)
    ax.legend(frameon=False, fontsize=8)
    ax.text(0, -.20, "20 runs: one frame per posture plus 0.1 px corner noise.\nThese are sensitivity spans, not confidence intervals.",
            transform=ax.transAxes, color=GRAY, fontsize=8, va="top")

    ax = axes[1, 2]
    comparisons = focus["imageOnlyKAndDepthComparisons"]
    points = []
    for key, label, color in [("metadataK", "Recorded frame K", BLUE), ("freePrincipal", "Image-only fitted K", ORANGE)]:
        item = comparisons[key]
        x = item.get("heldOutPnPReprojectionRMSPixels", item.get("heldOutRMSPixels"))
        y = 1000*item["PnPMinusOriginalCenterDepthRMSEMeters"]
        points.append((x, y))
        ax.scatter([x], [y], s=60, color=color)
        offset = (10, 10) if key == "metadataK" else (10, -32)
        ax.annotate(f"{label}\n{x:.3f} px / {y:.1f} mm", (x, y), xytext=offset,
                    textcoords="offset points", fontsize=8, color=color)
    xs, ys = zip(*points)
    margin = max(max(xs)-min(xs), .02)
    ax.set_xlim(max(0, min(xs)-.4*margin), max(xs)+1.3*margin)
    ax.set_ylim(0, max(ys)*1.3)
    ax.set_xlabel("Held-out per-image PnP corner RMS (pixels)")
    ax.set_ylabel("RGB PnP Z vs depth Z RMS difference (mm)")
    ax.set_title("F. Better image fit can worsen depth agreement", loc="left", pad=14)
    ax.text(0, -.23, focus["label"]+": separate pose fitted per image.\nThis image-only error is different from panel C.",
            transform=ax.transAxes, color=GRAY, fontsize=8, va="top")

    fig.text(.065, .045,
             "Interpretation: repeatability is not absolute accuracy. Accepted commands are not measured shaft angles. "
             "Intrinsic, mounting and servo-zero ambiguities remain.\n"
             "Source hashes, selected metrics, training/held-out scope and limitations are recorded in the accompanying analysis-summary.json. "
             "No source images or depth maps appear here.",
             fontsize=9, color=GRAY, linespacing=1.6)
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(output, dpi=200, facecolor="white")
    plt.close(fig)


def draw_upper(summary, output):
    """Separate upper-neck change/return experiment; no mechanical-zero claim."""
    data = summary["upperNeck"]
    fig, (ax, residual_axis) = plt.subplots(1, 2, figsize=(13.5, 7.2))
    fig.subplots_adjust(left=.075, right=.97, top=.80, bottom=.28, wspace=.30)
    fig.suptitle("Upper-neck forward / reverse check: diagnostic, unverified", fontsize=17, y=.96)
    refined = data["templateECC"]
    qr = refined["angleScaleCandidates"]["qrPitch"]
    reference = qr["referenceUpperTarget"]
    nominal = qr["nominalDegreesPerTargetUnitPrior"]
    targets = np.array([hold["upperTarget"] for hold in refined["holds"]])
    grid = np.linspace(min(targets), max(targets), 150)
    ax.plot(grid, nominal*(grid-reference), "--", color=GRAY,
            label=f"Nominal prior: {nominal:.4f} deg/unit")
    for label, color, name in [("rawVision", ORANGE, "Vision corners"), ("templateECC", BLUE, "Exact-pattern corners")]:
        report = data[label]
        fit = report["angleScaleCandidates"]["qrPitch"]
        holds = report["holds"]
        x = np.array([hold["upperTarget"] for hold in holds])
        y = np.array([hold["qrInferredCameraPitchChangeDegrees"] for hold in holds])
        training = fit["trainingHoldIndices"]
        held_out = fit["heldOutReturnHoldIndices"]
        prediction = fit["diagnosticAngleAtReferenceDegrees"]+fit["degreesPerTargetUnit"]*(grid-fit["referenceUpperTarget"])
        ax.plot(grid, prediction, color=color, linewidth=1.5,
                label=f"{name}: {fit['degreesPerTargetUnit']:.5f} deg/unit")
        ax.scatter(x[training], y[training], s=35, color=color, marker="o", zorder=3)
        ax.scatter(x[held_out], y[held_out], s=55, edgecolor=color, facecolor="white", marker="D", zorder=4)
    ax.axhline(0, color="#BCC3CC", linewidth=.7)
    ax.axvline(reference, color="#BCC3CC", linewidth=.7)
    ax.set_xlabel("Accepted upper-servo target (Maestro units)")
    ax.set_ylabel("QR-inferred camera pitch change (degrees)")
    ax.set_title("A. First-visit lines and held-out return observations", loc="left", pad=12)
    ax.legend(frameon=False, fontsize=8, loc="upper left")
    ax.grid(color="#DFE4EA", linewidth=.7)
    ax.set_axisbelow(True)
    ax.text(0, -.22, "Filled circles: first visits used to fit each line.\nOpen diamonds: return visits excluded from fitting.",
            transform=ax.transAxes, color=GRAY, fontsize=9, va="top")

    returns = qr["heldOutReturnHoldIndices"]
    labels = [f"Hold {refined['holds'][i]['stepIndex']}\n{refined['holds'][i]['upperTarget']} units" for i in returns]
    x = np.arange(len(labels))
    for offset, label, color, name in [(-.18, "rawVision", ORANGE, "Vision"), (.18, "templateECC", BLUE, "Exact pattern")]:
        fit = data[label]["angleScaleCandidates"]["qrPitch"]
        residual_axis.bar(x+offset, fit["heldOutReturnResidualsDegrees"], .34, color=color,
                          label=f"{name}: return RMS {fit['heldOutReturnRMSEDegrees']:.3f} deg")
    residual_axis.axhline(0, color=GRAY, linewidth=.8)
    residual_axis.set_xticks(x, labels)
    residual_axis.set_ylabel("QR pitch minus first-visit fitted line (degrees)")
    residual_axis.set_title("B. Held-out return errors remain", loc="left", pad=12)
    residual_axis.legend(frameon=False, fontsize=8, loc="lower right")
    residual_axis.grid(axis="y", color="#DFE4EA", linewidth=.7)
    residual_axis.set_axisbelow(True)
    fig.text(.075, .86,
             f"{refined['holdCount']} settled holds / {refined['sampleCount']} frames | lower target fixed at {refined['lowerTarget']} | "
             f"pan fixed at {refined['panDegrees']:.2f} degrees | pitch positive nose-up", color=GRAY, fontsize=10)
    fig.text(.075, .055,
             "Angles depend on the recorded camera intrinsics and an optical-X upper-neck-axis assumption. The nominal prior is unmeasured.\n"
             "QR and depth-derived angles share intrinsics and are not independent ground truth. Camera mounting and servo-zero offsets remain coupled.\n"
             "No gain, zero offset, URDF or robot registration was applied. Error bars are omitted because no independently measured angle uncertainty is available.",
             color=GRAY, fontsize=9, linespacing=1.5)
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(output, dpi=200, facecolor="white")
    plt.close(fig)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--summary", type=Path, help="Read an existing public aggregate summary for exact replotting")
    parser.add_argument("--pixel-analysis", type=Path)
    parser.add_argument("--camera-ab", type=Path)
    parser.add_argument("--joint-fit", nargs=2, action="append", default=[], metavar=("LABEL", "JSON"))
    parser.add_argument("--capture-label", action="append", default=[], metavar="KEY=LABEL")
    parser.add_argument("--focus-capture", default="B064")
    parser.add_argument("--camera-mode", action="append", default=[], help="Pipeline mode selected for the main plot; all aggregate modes are retained")
    parser.add_argument("--raw-upper-report", type=Path)
    parser.add_argument("--refined-upper-report", type=Path)
    parser.add_argument("--upper-output", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--summary-output", type=Path)
    args = parser.parse_args()
    if args.summary:
        data = read(args.summary)
    else:
        if not args.pixel_analysis or not args.camera_ab or not args.joint_fit or not args.summary_output:
            parser.error("Provide --summary, or all private analyses plus --summary-output")
        data = aggregate(args)
        args.summary_output.parent.mkdir(parents=True, exist_ok=True)
        args.summary_output.write_text(json.dumps(data, indent=2, allow_nan=False)+"\n")
    draw(data, args.output)
    if args.upper_output:
        draw_upper(data, args.upper_output)
        print(args.upper_output.resolve())
    print(args.output.resolve())
    if args.summary_output:
        print(args.summary_output.resolve())
