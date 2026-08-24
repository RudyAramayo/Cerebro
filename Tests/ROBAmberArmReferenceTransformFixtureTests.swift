import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
private enum ROBAmberArmReferenceTransformFixtureTests {
    static func main() {
        let vendorPark = [0.0, 0.2, -0.3, 0.4, -0.5, 0.6, -0.7]
        let modelPark = [-1.0, 0.5, 0.25, -0.75, 0.3, -0.2, 0.1]
        let directions = [1, -1, 1, -1, 1, -1, 1]
        guard let zero = ROBAmberArmReferenceTransform.vendorAtModelZero(
            vendorAtPark: vendorPark,
            modelAtPark: modelPark,
            directions: directions
        ) else {
            expect(false, "a valid commissioned park transform must produce an offset")
            return
        }
        let recoveredPark = ROBAmberArmReferenceTransform.modelPositions(
            fromVendor: vendorPark,
            vendorAtModelZero: zero,
            directions: directions
        )
        expect(recoveredPark.map {
            zip($0, modelPark).allSatisfy { abs($0 - $1) < 1e-12 }
        } == true, "the captured park pose must map back within floating-point precision")

        let targetModel = [0.1, -0.2, 0.3, -0.4, 0.5, -0.6, 0.7]
        guard let targetVendor = ROBAmberArmReferenceTransform.vendorPositions(
            fromModel: targetModel,
            vendorAtModelZero: zero,
            directions: directions
        ), let roundTrip = ROBAmberArmReferenceTransform.modelPositions(
            fromVendor: targetVendor,
            vendorAtModelZero: zero,
            directions: directions
        ) else {
            expect(false, "valid model/vendor transforms must succeed")
            return
        }
        expect(zip(roundTrip, targetModel).allSatisfy { abs($0 - $1) < 1e-12 },
               "model -> vendor -> model must round-trip with mixed direction signs")

        expect(ROBAmberArmReferenceTransform.vendorAtModelZero(
            vendorAtPark: [0], modelAtPark: [0, 1], directions: [1]
        ) == nil, "mismatched vector lengths must fail closed")
        expect(ROBAmberArmReferenceTransform.vendorPositions(
            fromModel: [0], vendorAtModelZero: [0], directions: [0]
        ) == nil, "a direction other than +1 or -1 must fail closed")
        expect(ROBAmberArmReferenceTransform.modelPositions(
            fromVendor: [.infinity], vendorAtModelZero: [0], directions: [1]
        ) == nil, "non-finite encoder data must fail closed")

        print("ROBAmberArmReferenceTransform fixture tests passed")
    }
}
