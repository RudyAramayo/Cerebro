//
//  ROBAmberArmReferenceTransform.swift
//  Cerebro
//
//  Pure coordinate math for the Amber physical-reference gate.
//

import Foundation

enum ROBAmberArmReferenceTransform {
    static func vendorAtModelZero(
        vendorAtPark: [Double],
        modelAtPark: [Double],
        directions: [Int]
    ) -> [Double]? {
        guard valid(vendorAtPark, modelAtPark, directions) else { return nil }
        return zip(zip(vendorAtPark, modelAtPark), directions).map { pair, direction in
            pair.0 - Double(direction) * pair.1
        }
    }

    static func modelPositions(
        fromVendor vendor: [Double],
        vendorAtModelZero: [Double],
        directions: [Int]
    ) -> [Double]? {
        guard valid(vendor, vendorAtModelZero, directions) else { return nil }
        return zip(zip(vendor, vendorAtModelZero), directions).map { pair, direction in
            Double(direction) * (pair.0 - pair.1)
        }
    }

    static func vendorPositions(
        fromModel model: [Double],
        vendorAtModelZero: [Double],
        directions: [Int]
    ) -> [Double]? {
        guard valid(model, vendorAtModelZero, directions) else { return nil }
        return zip(zip(model, directions), vendorAtModelZero).map { pair, zero in
            zero + Double(pair.1) * pair.0
        }
    }

    private static func valid(_ lhs: [Double], _ rhs: [Double], _ directions: [Int]) -> Bool {
        !lhs.isEmpty
            && lhs.count == rhs.count
            && lhs.count == directions.count
            && lhs.allSatisfy(\.isFinite)
            && rhs.allSatisfy(\.isFinite)
            && directions.allSatisfy { $0 == -1 || $0 == 1 }
    }
}
