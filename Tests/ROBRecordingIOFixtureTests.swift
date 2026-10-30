import Foundation

@main enum ROBRecordingIOFixtureTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rob-recording-io-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("events.jsonl")
        let writer = try ROBJSONLinesWriter(url: url)
        writer.append(["event": 1, "detail": "one\ntwo"])
        writer.append(["event": 2])
        writer.finish()
        precondition(writer.lastError == nil)
        let original = try Data(contentsOf: url)
        let lines = String(decoding: original, as: UTF8.self).split(separator: "\n")
        precondition(lines.count == 2)
        for line in lines { _ = try JSONSerialization.jsonObject(with: Data(line.utf8)) }

        // A real OS write failure used to raise NSFileHandleOperationException.
        // It must now be a latched Swift error, leaving the controller alive.
        let readOnlyHandle = try FileHandle(forReadingFrom: url)
        let failingWriter = ROBJSONLinesWriter(handle: readOnlyHandle)
        failingWriter.append(["event": 3])
        precondition(failingWriter.lastError != nil)
        let firstError = failingWriter.lastError! as NSError
        failingWriter.append(["event": 4])
        precondition((failingWriter.lastError! as NSError) == firstError)
        failingWriter.finish()
        let afterFailure = try Data(contentsOf: url)
        precondition(afterFailure == original)
        print("ROB recording I/O fixtures passed: JSONL roundtrip, real write failure, latched failure, safe close")
    }
}
