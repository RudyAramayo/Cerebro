import Foundation

/// Fragments from different map revisions/devices must never form one grid.
/// Only a complete, recent SDK snapshot is exposed to planning.
struct ROBRoomMapAssembler {
    private var first: ROBRoomMapFragment?
    private var source: UUID?
    private var pieces: [Int: Data] = [:]
    mutating func consume(_ f: ROBRoomMapFragment, device: UUID, now: Double) -> ROBRoomMissionMap? {
        guard f.valid, (-500...15_000).contains(now-f.capturedAtMilliseconds) else { return nil }
        if source != device || first?.epoch != f.epoch || first?.revision != f.revision {
            first=f; source=device; pieces=[:]
        }
        guard let h=first, h.width==f.width, h.height==f.height,
              h.resolutionX==f.resolutionX, h.resolutionY==f.resolutionY,
              h.originX==f.originX, h.originY==f.originY, h.capturedAtMilliseconds==f.capturedAtMilliseconds else {
            first=nil;pieces=[:];return nil
        }
        if let old=pieces[f.offset], old != f.cells { first=nil;pieces=[:];return nil }
        pieces[f.offset]=f.cells
        guard pieces.count == (f.width*f.height+ROBRoomMapFragment.chunkBytes-1)/ROBRoomMapFragment.chunkBytes else { return nil }
        var cells=Data()
        for offset in stride(from:0,to:f.width*f.height,by:ROBRoomMapFragment.chunkBytes) {
            guard let part=pieces[offset] else { return nil };cells.append(part)
        }
        return ROBRoomMissionMap(epoch:f.epoch,revision:f.revision,capturedAtMilliseconds:f.capturedAtMilliseconds,
            width:f.width,height:f.height,resolutionX:f.resolutionX,resolutionY:f.resolutionY,
            originX:f.originX,originY:f.originY,cells:cells)
    }
}

/// Metric SLAM data, never satellite-overlay coordinates. SDK cells are
/// signed: positive free, zero unknown, negative occupied. Unknown stays blocked.
struct ROBRoomMissionMap: Equatable {
    let epoch: UUID
    let revision: UInt64
    let capturedAtMilliseconds: Double
    let width: Int
    let height: Int
    let resolutionX: Double
    let resolutionY: Double
    let originX: Double
    let originY: Double
    let cells: Data
    var valid: Bool {
        (1...2048).contains(width) && (1...2048).contains(height) && width * height <= 1_000_000
            && cells.count == width * height && revision > 0 && capturedAtMilliseconds.isFinite
            && [resolutionX, resolutionY].allSatisfy { $0.isFinite && (0.01...0.25).contains($0) }
            && [originX, originY].allSatisfy { $0.isFinite && abs($0) < 1_000_000 }
    }
}

struct ROBRoomMissionPoint: Equatable, Codable {
    var x: Double
    var y: Double
    func distance(to other: Self) -> Double { hypot(x - other.x, y - other.y) }
}

/// Flood-fill route planning over an inflated accumulated SDK map. Returns a
/// reachable observation stop and a checked path, not a time-to-distance guess.
struct ROBRoomMissionPlanner {
    let map: ROBRoomMissionMap
    let clearanceMeters: Double
    let origin: ROBRoomMissionPoint
    let radius: Double
    private let free: [Bool]

    init?(map: ROBRoomMissionMap, clearanceMeters: Double, origin: ROBRoomMissionPoint, radius: Double) {
        guard map.valid, clearanceMeters.isFinite, (0.1...2).contains(clearanceMeters),
              radius.isFinite, (1...10).contains(radius), origin.x.isFinite, origin.y.isFinite else { return nil }
        self.map = map; self.clearanceMeters = clearanceMeters; self.origin = origin; self.radius = radius
        // Integral image makes conservative rectangular hull inflation O(N).
        // A square circumscribes the robot's rotation envelope at every yaw.
        let w = map.width, h = map.height, bytes = [UInt8](map.cells), stride = w + 1
        var integral = [Int](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var row = 0
            for x in 0..<w {
                if Int8(bitPattern: bytes[y*w+x]) <= 0 { row += 1 }
                integral[(y+1)*stride+x+1] = integral[y*stride+x+1] + row
            }
        }
        let dx = Int(ceil(clearanceMeters / map.resolutionX)), dy = Int(ceil(clearanceMeters / map.resolutionY))
        var free = [Bool](repeating: false, count: w*h)
        for y in 0..<h { for x in 0..<w {
            let l=x-dx, r=x+dx+1, b=y-dy, t=y+dy+1
            guard l >= 0, b >= 0, r <= w, t <= h else { continue }
            let blocked = integral[t*stride+r] - integral[b*stride+r] - integral[t*stride+l] + integral[b*stride+l]
            let p = ROBRoomMissionPoint(x: map.originX+(Double(x)+0.5)*map.resolutionX,
                                        y: map.originY+(Double(y)+0.5)*map.resolutionY)
            free[y*w+x] = blocked == 0 && p.distance(to: origin) <= radius
        } }
        self.free = free
    }
    func index(_ p: ROBRoomMissionPoint) -> Int? {
        guard p.x.isFinite, p.y.isFinite else { return nil }
        let x = Int(floor((p.x-map.originX)/map.resolutionX)), y = Int(floor((p.y-map.originY)/map.resolutionY))
        return x >= 0 && y >= 0 && x < map.width && y < map.height ? y*map.width+x : nil
    }
    func point(_ index: Int) -> ROBRoomMissionPoint {
        .init(x: map.originX+(Double(index%map.width)+0.5)*map.resolutionX,
              y: map.originY+(Double(index/map.width)+0.5)*map.resolutionY)
    }
    func isFree(_ p: ROBRoomMissionPoint) -> Bool { index(p).map { free[$0] } ?? false }
    func path(from start: ROBRoomMissionPoint, to goal: ROBRoomMissionPoint? = nil,
              excluding searched: [ROBRoomMissionPoint] = []) -> [ROBRoomMissionPoint]? {
        guard let first = index(start), free[first] else { return nil }
        let target = goal.flatMap(index)
        if goal != nil && (target == nil || !free[target!]) { return nil }
        var parent = [Int](repeating: -2, count: free.count), queue = [first], cursor = 0
        parent[first] = -1
        while cursor < queue.count {
            let current = queue[cursor]; cursor += 1
            let p = point(current)
            let wanted = target.map { $0 == current } ??
                (p.distance(to: start) >= 0.8 && searched.allSatisfy { p.distance(to: $0) >= 0.8 })
            if wanted {
                var route = [p], previous = parent[current]
                while previous >= 0 { route.append(point(previous)); previous = parent[previous] }
                return route.reversed()
            }
            let x=current%map.width, y=current/map.width
            for (nx,ny) in [(x+1,y),(x-1,y),(x,y+1),(x,y-1)] {
                guard nx >= 0, ny >= 0, nx < map.width, ny < map.height else { continue }
                let next=ny*map.width+nx
                if free[next] && parent[next] == -2 { parent[next]=current; queue.append(next) }
            }
        }
        return nil
    }
    /// Every cell along a shortened segment remains checked after map updates.
    func segmentIsFree(_ a: ROBRoomMissionPoint, _ b: ROBRoomMissionPoint) -> Bool {
        let count = max(1,Int(ceil(a.distance(to:b)/min(map.resolutionX,map.resolutionY)*2)))
        return (0...count).allSatisfy { i in
            let f=Double(i)/Double(count)
            return isFree(.init(x:a.x+(b.x-a.x)*f,y:a.y+(b.y-a.y)*f))
        }
    }
}
