import Foundation

enum ROBArmObservationCodecFixtures {
    static func run() {
        let plain = ROBArmObservationCodec.template
        for wrapped in [plain, " \n" + plain + "\n ", "```json\n" + plain + "\n```", "```\n" + plain + "\n```"] {
            let observation = try! ROBArmObservationCodec.decode(wrapped)
            precondition(!observation.permitsMotion && !observation.permitsCalibration && observation.graspArm == nil)
            precondition(observation.gripperInspectionBlockReason?.contains("confidence 0%") == true)
            precondition(observation.gripperInspectionBlockReason?.contains("complete route") == false)
        }
        let cases: [(String, String)] = [
            ("", "empty"),
            ("No arms are visible.", "invalid_json"),
            (String(plain.dropLast()), "invalid_json"),
            (plain + plain, "invalid_json"),
            ("Unsafe. " + plain, "invalid_json"),
            (plain + " Obstruction seen.", "invalid_json"),
            ("```json\n" + plain, "invalid_wrapper"),
            ("[" + plain + "]", "invalid_json"),
            (plain.replacingOccurrences(of: "\"pathClear\":false,", with: ""), "schema"),
            (plain.replacingOccurrences(of: "\"pathClear\":false", with: "\"pathClear\":\"true\""), "value_type"),
            (plain.replacingOccurrences(of: "\"pathClear\":false", with: "\"pathClear\":1"), "value_type"),
            (plain.replacingOccurrences(of: "\"pathClear\":false", with: "\"pathClear\":null"), "value_type"),
            (plain.replacingOccurrences(of: "\"confidence\":0.0", with: "\"confidence\":true"), "value_type"),
            (plain.replacingOccurrences(of: "\"confidence\":0.0", with: "\"confidence\":1.1"), "confidence_range"),
            (plain.replacingOccurrences(of: "\"confidence\":0.0", with: "\"confidence\":-0.1"), "confidence_range"),
            (plain.replacingOccurrences(of: "{", with: "{\"pathClear\":true,"), "duplicate_field"),
            (plain.replacingOccurrences(of: "{", with: "{\"path\\u0043lear\":true,"), "duplicate_field"),
            (plain.replacingOccurrences(of: "{", with: "{\"move\":true,"), "schema"),
            (String(repeating: "x", count: 4_001), "oversized")
        ]
        for (input, code) in cases {
            do {
                _ = try ROBArmObservationCodec.decode(input)
                preconditionFailure("Accepted invalid observation: \(code)")
            } catch let failure as ROBArmObservationCodec.Failure {
                precondition(failure.code == code, "Expected \(code); got \(failure.code)")
            } catch { preconditionFailure("Unexpected decoder error: \(error)") }
        }
        let sample = ROBArmObservationCodec.diagnosticSample("\n\r\u{1B}" + String(repeating: "x", count: 2_000))
        precondition(sample.count == 1_000 && !sample.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains))
        let frontOnly = ROBArmRoutineObservation(pathVisible: false, pathClear: false, hanging: false, armsInFront: true,
            leftJawEmpty: true, rightJawEmpty: true, leftObjectBetweenJaws: false, rightObjectBetweenJaws: false,
            leftJawOpen: true, rightJawOpen: true, leftJawClosedOnObject: false, rightJawClosedOnObject: false,
            handsClear: true, confidence: 0.99)
        precondition(!frontOnly.permitsMotion && frontOnly.permitsCalibration && frontOnly.graspArm == nil,
                     "Stationary jaw inspection incorrectly required the hanging route or authorized arm travel")
        precondition(frontOnly.gripperInspectionBlockReason == nil)
        let visible = try! JSONSerialization.data(withJSONObject: [
            "pathVisible": false, "pathClear": false, "hanging": false, "armsInFront": true,
            "leftJawEmpty": true, "rightJawEmpty": true, "leftObjectBetweenJaws": false,
            "rightObjectBetweenJaws": false, "leftJawOpen": true, "rightJawOpen": true,
            "leftJawClosedOnObject": false, "rightJawClosedOnObject": false, "handsClear": true,
            "confidence": 0.99])
        for (key, value) in [("confidence", 0.89 as Any), ("armsInFront", false), ("handsClear", false), ("leftJawEmpty", false), ("rightJawEmpty", false)] {
            var facts = try! JSONSerialization.jsonObject(with: visible) as! [String: Any]
            facts[key] = value
            let blocked = try! ROBArmObservationCodec.decode(String(data: try! JSONSerialization.data(withJSONObject: facts), encoding: .utf8)!)
            precondition(!blocked.permitsCalibration, "Missing \(key) evidence permitted jaw calibration")
            if ["confidence", "armsInFront", "handsClear"].contains(key) {
                precondition(blocked.gripperInspectionBlockReason != nil)
            }
        }
        let jawPrompt = ROBArmObservationCodec.inspectionPrompt(target: "", grippers: true, formatRetry: false)
        let routePrompt = ROBArmObservationCodec.inspectionPrompt(target: "", grippers: false, formatRetry: false)
        precondition(!jawPrompt.contains("pathVisible requires") && routePrompt.contains("pathVisible requires"),
                     "Stationary jaw prompt inherited complete-route requirements")
        precondition(jawPrompt.contains("A cropped or obscured jaw is NOT visible"))
        print("Arm response codec: wrappers, required facts, strict types, duplicates, conflicting prose and bounded diagnostics passed")
    }
}
