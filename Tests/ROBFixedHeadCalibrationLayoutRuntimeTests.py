#!/usr/bin/env python3
"""Instantiate the real calibration form layout without robot services."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    source = (ROOT / "Cerebro/ROBFixedHeadCalibrationWindowController.swift").read_text()
    start = source.index("    private func build() {")
    depth, quoted, escaped, end = 0, False, False, None
    for index in range(source.index("{", start), len(source)):
        char = source[index]
        if quoted:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quoted = False
        elif char == '"':
            quoted = True
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                end = index + 1
                break
    assert end is not None
    method = source[start:end]
    fixture = r'''
import AppKit
@MainActor @objcMembers final class Form: NSWindowController {
    let side = NSPopUpButton()
    let referenceError = NSTextField(string:"20")
    let image = NSImageView()
    let details = NSTextView()
    let captureButton = NSButton(title:"Capture",target:nil,action:nil)
    let importButton = NSButton(title:"Import",target:nil,action:nil)
    let stopButton = NSButton(title:"Stop",target:nil,action:nil)
    init(size:NSSize) {
        let window = NSWindow(contentRect:NSRect(origin:.zero,size:size),
            styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        super.init(window:window)
        build()
        window.contentView!.layoutSubtreeIfNeeded()
    }
    required init?(coder:NSCoder) { fatalError() }
    @objc func captureCurrentView() {}
    @objc func importLandmarks() {}
    @objc func stop() {}
    @objc func showEvidence() {}
/*PRODUCTION_BUILD*/
}
@main struct Test {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        for size in [NSSize(width:1000,height:760),NSSize(width:1200,height:900)] {
            let form = Form(size:size)
            precondition(form.image.superview != nil)
            precondition(form.image.frame.width >= 900)
            precondition(form.image.frame.height >= 270)
            precondition(form.details.enclosingScrollView != nil)
            precondition(form.details.frame.width >= 800)
            precondition(form.side.itemTitles == ["Right arm","Left arm"])
            precondition(form.captureButton.target === form)
            precondition(form.stopButton.target === form)
            form.window?.close()
        }
        print("Fixed-head calibration native layout passed at two window sizes; no robot services loaded")
    }
}
'''.replace("/*PRODUCTION_BUILD*/", method)
    with tempfile.TemporaryDirectory(prefix="rob-fixed-head-layout-", dir="/private/tmp") as directory:
        path = Path(directory)
        (path / "main.swift").write_text(fixture)
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                        "-framework", "AppKit", str(path / "main.swift"), "-o", str(path / "layout")], check=True)
        result = subprocess.run([str(path / "layout")], capture_output=True, text=True)
        if result.returncode:
            raise AssertionError((result.stdout + result.stderr)[-5000:])
        print(result.stdout.strip())


if __name__ == "__main__":
    main()
