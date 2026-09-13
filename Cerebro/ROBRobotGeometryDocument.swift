import Foundation
import simd

extension ROBGeometryProfile {
    /// Illustrative layout, not a measurement of ROB. Vendor B1 geometry alone
    /// is authoritative here. Every body/mount/neck value needs commissioning.
    static func draft() -> Self {
        var result = Self(joints: [], links: [.init(name: "base_link", boxMeters: [0.52, 0.32, 0.24], boxOrigin: .init(xyzMeters: [0, 0, 0.15]))])
        func add(_ name: String, _ parent: String, _ child: String, _ xyz: [Double], _ size: [Double], kind: String = "fixed", axis: [Double] = [0, 0, 1], limits: [Double] = [0, 0], rpy: [Double] = [0, 0, 0], boxXYZ: [Double] = [0, 0, 0]) {
            result.joints.append(.init(name: name, parent: parent, child: child, kind: kind,
                                       origin: .init(xyzMeters: xyz, rpyRadians: rpy), axis: axis, lower: limits[0], upper: limits[1]))
            result.links.append(.init(name: child, boxMeters: size, boxOrigin: .init(xyzMeters: boxXYZ)))
        }
        for (side, sign) in [("left", 1.0), ("right", -1.0)] {
            add("\(side)_track_mount", "base_link", "\(side)_track_link", [0, sign * 0.23, 0.15], [0.62, 0.12, 0.30])
            add("\(side)_track_drive", "\(side)_track_link", "\(side)_sprocket_link", [-0.20, 0, 0], [0.12, 0.13, 0.12], kind: "continuous", axis: [0, 1, 0], limits: [-Double.pi, Double.pi])
            add("\(side)_flipper", "base_link", "\(side)_flipper_link", [0.17, sign * 0.23, 0.24], [0.34, 0.10, 0.10], kind: "revolute", axis: [0, 1, 0], limits: [-1.5, 1.5], boxXYZ: [0.15, 0, 0])
        }
        add("body_lean", "base_link", "lean_link", [-0.10, 0, 0.37], [0.12, 0.25, 0.25], kind: "revolute", axis: [0, 1, 0], limits: [-0.35, 0.35], boxXYZ: [0, 0, 0.13])
        add("torso_yaw", "lean_link", "torso_link", [0, 0, 0.26], [0.30, 0.32, 0.36], kind: "revolute", limits: [-1.2, 1.2], boxXYZ: [0, 0, 0.18])
        add("lower_neck", "torso_link", "lower_neck_link", [0, 0, 0.39], [0.05, 0.07, 0.20], kind: "revolute", axis: [0, 1, 0], limits: [-1.3, 1.3], boxXYZ: [0, 0, 0.10])
        add("neck_pan", "lower_neck_link", "neck_pan_link", [0, 0, 0.20], [0.07, 0.07, 0.035], kind: "revolute", limits: [-1.05, 1.05])
        add("upper_neck", "neck_pan_link", "upper_neck_link", [0, 0, 0.03], [0.05, 0.07, 0.07], kind: "revolute", axis: [0, 1, 0], limits: [-1.3, 1.3])
        add("insta360_mount", "upper_neck_link", "insta360_link", [0, 0, 0.11], [0.16, 0.18, 0.18])
        add("oak_mount", "upper_neck_link", "oak_link", [0.11, 0, 0.035], [0.025, 0.14, 0.035])
        // Optical convention: X image-right, Y image-down, Z camera-forward.
        add("oak_optical_mount", "oak_link", "oak_optical_frame", [0.015, 0, 0], [0.01, 0.01, 0.01], rpy: [-Double.pi / 2, 0, -Double.pi / 2])
        add("belly_oak_mount", "torso_link", "belly_oak_link", [0.17, 0, 0.08], [0.025, 0.14, 0.035])
        add("belly_oak_optical_mount", "belly_oak_link", "belly_oak_optical_frame", [0.015, 0, 0], [0.01, 0.01, 0.01], rpy: [-Double.pi / 2, 0, -Double.pi / 2])
        for (side, sign) in [("left", 1.0), ("right", -1.0)] {
            add("\(side)_b1_mount", "torso_link", "\(side)_base_link", [0, sign * 0.14, 0.35], [0.085, 0.085, 0.083], rpy: [-sign * 0.35, 0, 0], boxXYZ: [0, 0, 0.04])
            result.joints[result.joints.count - 1].evidence = .init(source: "photo_estimate", note: "Photos suggest outward cant. Translation, angle, yaw, and scale are illustrative only; fit physical plate landmarks.")
            result.links[result.links.count - 1].vendorLink = "base_link"
            for definition in ROBAmberB1Kinematics.joints {
                func array(_ v: SIMD3<Double>) -> [Double] { [v.x, v.y, v.z] }
                let name = "\(side)_\(definition.name)"
                result.joints.append(.init(name: name, parent: "\(side)_\(definition.parentLink)", child: "\(side)_\(definition.childLink)", kind: "revolute", origin: .init(xyzMeters: array(definition.originXYZ), rpyRadians: array(definition.originRPY)), axis: array(definition.axis), lower: definition.lowerLimit, upper: definition.upperLimit,
                                          evidence: .init(source: "vendor", note: "Single-arm amber_b1.urdf. Driver direction and boot reference are separate, unverified mappings.")))
                result.links.append(.init(name: "\(side)_\(definition.childLink)", boxMeters: [0.075, 0.075, 0.09], boxOrigin: .init(xyzMeters: [0, 0, 0.04]), vendorLink: definition.childLink))
                // A neutral all-zero preview is not claimed to be the hanging pose.
                result.previewPositions[name] = 0
            }
            add("\(side)_tool_mount", "\(side)_seven_Link", "\(side)_tool", [0, 0, 0.11], [0.075, 0.075, 0.12])
        }
        let annotations = ["lower_neck": "Maestro channel 1; PWM-to-angle unmeasured", "neck_pan": "Maestro channel 0; PWM-to-angle unmeasured", "upper_neck": "Maestro channel 2; PWM-to-angle unmeasured", "body_lean": "LACT drives this pitch pivot; measure pin centers and stroke-to-angle samples", "torso_yaw": "Rotating torso; channel, zero and range unverified", "left_flipper": "Verify whether both flippers share one actuator", "right_flipper": "Verify whether both flippers share one actuator"]
        for i in result.joints.indices { if let note = annotations[result.joints[i].name] { result.joints[i].hardwareAnnotation = note } }
        return result
    }

    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func load(_ url: URL) throws -> Self {
        let data = try Data(contentsOf: url)
        guard data.count <= 5_000_000 else { throw ROBGeometryError.invalid("Profile exceeds 5 MB.") }
        let profile = try JSONDecoder().decode(Self.self, from: data)
        try profile.validate()
        return profile
    }
}

final class ROBGeometryVendor {
    let source: URL
    let document: XMLDocument
    let links: [String: XMLElement]
    init(url: URL) throws {
        source = url
        let data = try Data(contentsOf: url)
        guard data.count < 2_000_000, let xml = String(data: data, encoding: .utf8), !xml.uppercased().contains("<!DOCTYPE"), !xml.uppercased().contains("<!ENTITY") else { throw ROBGeometryError.invalid("Use a plain single-arm B1 URDF without external entities.") }
        document = try XMLDocument(data: data, options: [.nodePreserveAll])
        guard let root = document.rootElement(), root.name == "robot" else { throw ROBGeometryError.invalid("Missing URDF robot element.") }
        let elements = root.elements(forName: "link")
        var indexed: [String: XMLElement] = [:]
        for link in elements {
            guard let name = link.attribute(forName: "name")?.stringValue, indexed[name] == nil else { throw ROBGeometryError.invalid("Duplicate or unnamed vendor link.") }
            indexed[name] = link
        }
        let expected = Set(["base_link"] + ROBAmberB1Kinematics.joints.map(\.childLink))
        guard Set(indexed.keys) == expected else { throw ROBGeometryError.invalid("Select amber_b1.urdf for one B1 arm. The dual model has different side and driver conventions.") }
        for link in indexed.values {
            for role in ["visual", "collision"] {
                let geometries = link.elements(forName: role)
                guard geometries.count == 1, let geometry = geometries.first else { throw ROBGeometryError.invalid("Use the original B1 single-mesh link geometry.") }
                for attribute in ["xyz", "rpy"] {
                    let values = geometry.elements(forName: "origin").first?.attribute(forName: attribute)?.stringValue?.split(whereSeparator: \.isWhitespace).compactMap { Double($0) } ?? [0, 0, 0]
                    guard values.count == 3, values.allSatisfy({ $0.isFinite && abs($0) < 1e-8 }) else { throw ROBGeometryError.invalid("Use original zero-origin B1 meshes; edit the mounting transforms in the profile.") }
                }
                guard let mesh = try geometry.nodes(forXPath: "geometry/mesh").first as? XMLElement else { throw ROBGeometryError.invalid("Expected B1 mesh geometry.") }
                if let text = mesh.attribute(forName: "scale")?.stringValue {
                    let values = text.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
                    guard values.count == 3, values.allSatisfy({ $0.isFinite && abs($0 - 1) < 1e-8 }) else { throw ROBGeometryError.invalid("B1 meshes must retain their original meter scale.") }
                }
            }
        }
        // Reject a same-named but incompatible chain instead of mixing its meshes
        // with the single-arm constants used by the preview.
        for definition in ROBAmberB1Kinematics.joints {
            guard let joint = root.elements(forName: "joint").first(where: { $0.attribute(forName: "name")?.stringValue == definition.name }),
                  joint.elements(forName: "parent").first?.attribute(forName: "link")?.stringValue == definition.parentLink,
                  joint.elements(forName: "child").first?.attribute(forName: "link")?.stringValue == definition.childLink else { throw ROBGeometryError.invalid("Vendor chain differs from B1 reference.") }
            for (element, attribute, expectedVector) in [("origin", "xyz", definition.originXYZ), ("origin", "rpy", definition.originRPY), ("axis", "xyz", definition.axis)] {
                let values = joint.elements(forName: element).first?.attribute(forName: attribute)?.stringValue?.split(whereSeparator: \.isWhitespace).compactMap { Double($0) } ?? []
                guard values.count == 3, (0..<3).allSatisfy({ values[$0].isFinite && abs(values[$0] - expectedVector[$0]) < 1e-5 }) else { throw ROBGeometryError.invalid("Vendor \(definition.name) geometry differs from B1 reference.") }
            }
            guard joint.attribute(forName: "type")?.stringValue == "revolute",
                  let limit = joint.elements(forName: "limit").first,
                  let lower = Double(limit.attribute(forName: "lower")?.stringValue ?? ""),
                  let upper = Double(limit.attribute(forName: "upper")?.stringValue ?? ""),
                  abs(lower - definition.lowerLimit) < 1e-5, abs(upper - definition.upperLimit) < 1e-5 else { throw ROBGeometryError.invalid("Vendor joint limits differ from the B1 reference.") }
        }
        links = indexed
    }

    func meshURL(_ filename: String) throws -> URL {
        guard !filename.hasPrefix("/"), !filename.contains(":"), !filename.split(separator: "/").contains("..") else { throw ROBGeometryError.invalid("Vendor mesh must be relative to the URDF folder.") }
        let folder = source.deletingLastPathComponent().resolvingSymlinksInPath()
        let url = folder.appendingPathComponent(filename).resolvingSymlinksInPath()
        guard url.path.hasPrefix(folder.path + "/"), FileManager.default.fileExists(atPath: url.path) else { throw ROBGeometryError.invalid("Missing vendor mesh: \(filename)") }
        return url
    }

    func visualMesh(for link: String) throws -> URL? {
        guard let mesh = try links[link]?.nodes(forXPath: "visual/geometry/mesh").first as? XMLElement,
              let filename = mesh.attribute(forName: "filename")?.stringValue else { return nil }
        return try meshURL(filename)
    }
}

enum ROBGeometryURDF {
    static func export(_ profile: ROBGeometryProfile, vendor: ROBGeometryVendor?, to directory: URL) throws {
        try profile.validate()
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw ROBGeometryError.invalid("Choose a new folder; existing calibration bundles are preserved.") }
        let staging = directory.deletingLastPathComponent().appendingPathComponent(".rob-geometry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        func element(_ name: String, _ attributes: [String: String] = [:]) -> XMLElement {
            let e = XMLElement(name: name)
            for key in attributes.keys.sorted() { e.addAttribute(XMLNode.attribute(withName: key, stringValue: attributes[key]!) as! XMLNode) }
            return e
        }
        func numbers(_ values: [Double]) -> String { values.map { String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), $0) }.joined(separator: " ") }
        func origin(_ value: ROBGeometryOrigin) -> XMLElement { element("origin", ["xyz": numbers(value.xyzMeters), "rpy": numbers(value.rpyRadians)]) }
        let root = element("robot", ["name": "rob_droid_calibration_draft"])
        root.addChild(XMLNode.comment(withStringValue: "SIMULATION ONLY. Geometry contains unmeasured estimates. No drive mapping, physical calibration, or collision clearance is certified. q preview and boot encoder offsets are NOT joint origins. See calibration.json and README.txt.") as! XMLNode)
        for link in profile.links {
            let node: XMLElement
            if let name = link.vendorLink, let original = vendor?.links[name], let vendor {
                node = original.copy() as! XMLElement
                node.attribute(forName: "name")?.stringValue = link.name
                for mesh in try node.nodes(forXPath: ".//mesh").compactMap({ $0 as? XMLElement }) {
                    guard let attribute = mesh.attribute(forName: "filename"), let filename = attribute.stringValue else { continue }
                    let source = try vendor.meshURL(filename)
                    let relative = "meshes/amber/" + filename
                    let destination = staging.appendingPathComponent(relative)
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.copyItem(at: source, to: destination) }
                    attribute.stringValue = relative
                }
                for material in try node.nodes(forXPath: "visual/material").compactMap({ $0 as? XMLElement }) {
                    material.attribute(forName: "name")?.stringValue = "\(link.name)_material"
                }
            } else {
                node = element("link", ["name": link.name])
                for role in ["visual", "collision"] {
                    let shape = element(role), geometry = element("geometry")
                    shape.addChild(origin(link.boxOrigin)); geometry.addChild(element("box", ["size": numbers(link.boxMeters)])); shape.addChild(geometry)
                    node.addChild(shape)
                }
            }
            root.addChild(node)
        }
        for joint in profile.joints {
            let node = element("joint", ["name": joint.name, "type": joint.kind])
            node.addChild(element("parent", ["link": joint.parent])); node.addChild(element("child", ["link": joint.child])); node.addChild(origin(joint.origin))
            if joint.kind != "fixed" {
                node.addChild(element("axis", ["xyz": numbers(joint.axis)]))
                // Zero dynamics limits deliberately prohibit use as an actuation
                // configuration. Commissioned limits belong in a separate review.
                var limits = ["effort": "0", "velocity": "0"]
                if joint.kind != "continuous" { limits["lower"] = numbers([joint.lower]); limits["upper"] = numbers([joint.upper]) }
                node.addChild(element("limit", limits))
            }
            root.addChild(node)
        }
        let document = XMLDocument(rootElement: root); document.characterEncoding = "UTF-8"; document.version = "1.0"
        try document.xmlData(options: [.nodePrettyPrint]).write(to: staging.appendingPathComponent("rob_droid.urdf"))
        try profile.encoded().write(to: staging.appendingPathComponent("calibration.json"))
        let notes = """
        ROB calibration draft — SIMULATION ONLY
        Units: meters and radians. Base axes: X forward, Y ROB-left, Z up.
        Origin R = Rz(yaw) Ry(pitch) Rx(roll); joint motion follows origin.
        Vendor meshes: \(vendor == nil ? "not included; schematic boxes" : "single-arm B1, shared by both prefixed chains").
        Body, neck, mounts, tools and collision envelopes still need measurements.
        URDF zero is independent of preview joint positions and gravity-hanging startup.
        Capture a fresh Amber vendor reference each boot; do not persist boot offsets as physical geometry.
        LACT drives body_lean through a closed linkage. Its two measured pin anchors
        are in calibration.json. URDF is a tree; actuator length is derived from those
        anchors, not an independent body translation or an invented linear mimic.
        Tread joints are drive coordinates; box shapes represent fixed track envelopes.
        Confirm shared flipper actuation, lean/yaw order, neck axis order and all limits.
        Optical frames use X right, Y down, Z forward. Insta360 body geometry is not
        a pinhole camera model; use per-view calibration for its stitched imagery.
        Zero velocity/effort values are intentional draft placeholders, not hardware limits.
        This file supplies kinematic/collision geometry, not a dynamics model or a
        collision-approved path. Validate meshes, cables, payloads, table, uncertainty,
        joint feedback, swept paths and stopping distance before any execution.
        """
        try notes.write(to: staging.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.moveItem(at: staging, to: directory)
    }
}
