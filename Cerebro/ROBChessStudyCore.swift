// Guided board observation. Foundation-only; no robot or network dependencies.
import Foundation

enum ROBChessStudyError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

struct ROBChessMove: Equatable, Codable {
    let from: Int
    let to: Int
    let promotion: String?
    var uci: String { ROBChessPosition.squareName(from) + ROBChessPosition.squareName(to) + (promotion ?? "") }
}

struct ROBChessPosition: Equatable {
    // a1 = 0; h8 = 63. Uppercase pieces are white.
    private(set) var board: [Character]
    private(set) var whiteToMove: Bool
    private(set) var castling: String
    private(set) var enPassant: Int?
    private(set) var halfmove: Int
    private(set) var fullmove: Int
    static let startingFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    static var start: Self { try! Self(fen: startingFEN) }

    init(fen: String) throws {
        let fields = fen.split(separator: " ")
        guard fields.count == 6, ["w", "b"].contains(fields[1]),
              let hm = Int(fields[4]), hm >= 0, hm <= 100_000,
              let fm = Int(fields[5]), fm > 0, fm <= 100_000 else {
            throw ROBChessStudyError.invalid("Enter a complete, valid six-field FEN position.")
        }
        let ranks = fields[0].split(separator: "/", omittingEmptySubsequences: false)
        guard ranks.count == 8 else { throw ROBChessStudyError.invalid("FEN needs eight ranks.") }
        var cells = [Character](repeating: ".", count: 64)
        for (row, rank) in ranks.enumerated() {
            var file = 0
            for symbol in rank {
                if let count = symbol.wholeNumberValue, (1...8).contains(count), symbol.isASCII {
                    file += count
                } else {
                    guard "pnbrqkPNBRQK".contains(symbol), file < 8 else {
                        throw ROBChessStudyError.invalid("Invalid FEN piece or rank width.")
                    }
                    cells[(7 - row) * 8 + file] = symbol
                    file += 1
                }
                guard file <= 8 else { throw ROBChessStudyError.invalid("FEN rank exceeds eight squares.") }
            }
            guard file == 8 else { throw ROBChessStudyError.invalid("FEN rank is incomplete.") }
        }
        guard cells.filter({ $0 == "K" }).count == 1, cells.filter({ $0 == "k" }).count == 1,
              !(0..<8).contains(where: { "pP".contains(cells[$0]) || "pP".contains(cells[56 + $0]) }) else {
            throw ROBChessStudyError.invalid("Position needs one king per side and no pawns on a back rank.")
        }
        let rights = fields[2] == "-" ? "" : String(fields[2])
        guard rights.allSatisfy({ "KQkq".contains($0) }), Set(rights).count == rights.count else {
            throw ROBChessStudyError.invalid("Invalid castling rights.")
        }
        for (right, king, rook, kingSquare, rookSquare): (Character, Character, Character, Int, Int) in [
            ("K","K","R",4,7), ("Q","K","R",4,0), ("k","k","r",60,63), ("q","k","r",60,56)
        ] where rights.contains(right) {
            guard cells[kingSquare] == king, cells[rookSquare] == rook else {
                throw ROBChessStudyError.invalid("Castling rights disagree with king or rook placement.")
            }
        }
        let ep = fields[3] == "-" ? nil : Self.square(String(fields[3]))
        if fields[3] != "-" {
            let white = fields[1] == "w"
            guard let ep, ep / 8 == (white ? 5 : 2), cells[ep] == ".",
                  cells[ep + (white ? -8 : 8)] == (white ? "p" : "P"),
                  cells[ep + (white ? 8 : -8)] == ".", hm == 0 else {
                throw ROBChessStudyError.invalid("En-passant target disagrees with the last pawn move.")
            }
        }
        board = cells; whiteToMove = fields[1] == "w"; castling = rights
        enPassant = ep; halfmove = hm; fullmove = fm
        guard !isInCheck(white: !whiteToMove) else {
            throw ROBChessStudyError.invalid("The side that just moved cannot leave its king in check.")
        }
    }

    static func square(_ name: String) -> Int? {
        let b = Array(name.utf8)
        guard b.count == 2, (97...104).contains(b[0]), (49...56).contains(b[1]) else { return nil }
        return Int(b[1] - 49) * 8 + Int(b[0] - 97)
    }
    static func squareName(_ square: Int) -> String {
        guard (0..<64).contains(square) else { return "?" }
        return String(UnicodeScalar(97 + square % 8)!) + String(square / 8 + 1)
    }
    static func isWhite(_ piece: Character) -> Bool { piece != "." && piece.isUppercase }
    static func label(_ piece: Character) -> String {
        let names: [Character: String] = ["p":"pawn","n":"knight","b":"bishop","r":"rook","q":"queen","k":"king"]
        guard let name = names[Character(piece.lowercased())] else { return "empty" }
        return (isWhite(piece) ? "white_" : "black_") + name
    }
    var fen: String {
        let ranks = (0..<8).reversed().map { rank -> String in
            var text = "", empty = 0
            for file in 0..<8 {
                let p = board[rank * 8 + file]
                if p == "." { empty += 1 } else {
                    if empty > 0 { text += String(empty); empty = 0 }
                    text.append(p)
                }
            }
            if empty > 0 { text += String(empty) }
            return text
        }
        return ranks.joined(separator: "/") + " \(whiteToMove ? "w" : "b") \(castling.isEmpty ? "-" : castling) \(enPassant.map(Self.squareName) ?? "-") \(halfmove) \(fullmove)"
    }
    var labels: [String: String] {
        Dictionary(uniqueKeysWithValues: (0..<64).map { (Self.squareName($0), Self.label(board[$0])) })
    }

    func isInCheck(white: Bool) -> Bool {
        guard let king = board.firstIndex(of: white ? "K" : "k") else { return true }
        return attacked(king, byWhite: !white)
    }
    private func attacked(_ square: Int, byWhite white: Bool) -> Bool {
        for from in 0..<64 where board[from] != "." && Self.isWhite(board[from]) == white {
            let dx = square % 8 - from % 8, dy = square / 8 - from / 8
            switch board[from].lowercased() {
            case "p": if abs(dx) == 1 && dy == (white ? 1 : -1) { return true }
            case "n": if abs(dx) * abs(dy) == 2 { return true }
            case "k": if max(abs(dx), abs(dy)) == 1 { return true }
            case "b", "r", "q":
                let kind = board[from].lowercased()
                let diagonal = abs(dx) == abs(dy) && dx != 0
                let straight = (dx == 0) != (dy == 0)
                if ((kind != "r" && diagonal) || (kind != "b" && straight)) && pathClear(from, square) { return true }
            default: break
            }
        }
        return false
    }
    private func pathClear(_ from: Int, _ to: Int) -> Bool {
        let dx = (to % 8 - from % 8).signum(), dy = (to / 8 - from / 8).signum()
        var f = from % 8 + dx, r = from / 8 + dy
        while f != to % 8 || r != to / 8 {
            if !(0..<8).contains(f) || !(0..<8).contains(r) || board[r * 8 + f] != "." { return false }
            f += dx; r += dy
        }
        return true
    }
    func legalMoves() -> [ROBChessMove] {
        var moves: [ROBChessMove] = []
        for from in 0..<64 where board[from] != "." && Self.isWhite(board[from]) == whiteToMove {
            let kind = board[from].lowercased()
            for to in 0..<64 where to != from {
                let target = board[to]
                if target != "." && (Self.isWhite(target) == whiteToMove || target.lowercased() == "k") { continue }
                let dx = to % 8 - from % 8, dy = to / 8 - from / 8
                var valid = false
                switch kind {
                case "p":
                    let step = whiteToMove ? 1 : -1
                    valid = dx == 0 && target == "." && (
                        dy == step || (dy == step * 2 && from / 8 == (whiteToMove ? 1 : 6)
                            && board[from + step * 8] == "."))
                    if abs(dx) == 1 && dy == step {
                        valid = target != "." || (to == enPassant && board[to - step * 8] == (whiteToMove ? "p" : "P"))
                    }
                case "n": valid = abs(dx) * abs(dy) == 2
                case "b": valid = abs(dx) == abs(dy) && pathClear(from, to)
                case "r": valid = ((dx == 0) != (dy == 0)) && pathClear(from, to)
                case "q": valid = (abs(dx) == abs(dy) || ((dx == 0) != (dy == 0))) && pathClear(from, to)
                case "k":
                    valid = max(abs(dx), abs(dy)) == 1
                    if dy == 0 && abs(dx) == 2 && from == (whiteToMove ? 4 : 60) {
                        let right: Character = whiteToMove ? (dx > 0 ? "K" : "Q") : (dx > 0 ? "k" : "q")
                        let rook = from + (dx > 0 ? 3 : -4)
                        valid = castling.contains(right) && board[rook] == (whiteToMove ? "R" : "r")
                            && pathClear(from, rook) && !attacked(from, byWhite: !whiteToMove)
                            && !attacked(from + dx.signum(), byWhite: !whiteToMove)
                    }
                default: break
                }
                guard valid else { continue }
                let promotions: [String?] = kind == "p" && [0,7].contains(to / 8) ? ["q","r","b","n"] : [nil]
                for promotion in promotions {
                    let move = ROBChessMove(from: from, to: to, promotion: promotion)
                    if !applyingUnchecked(move).isInCheck(white: whiteToMove) { moves.append(move) }
                }
            }
        }
        return moves
    }
    func applying(uci: String) throws -> Self {
        guard let move = legalMoves().first(where: { $0.uci == uci.lowercased() }) else {
            throw ROBChessStudyError.invalid("That move is not legal in the confirmed position. Use e2e4, or e7e8q for promotion.")
        }
        return applyingUnchecked(move)
    }
    func legalSuccessors() -> [(move:ROBChessMove,position:Self)] {
        legalMoves().map { ($0,applyingUnchecked($0)) }
    }
    func affectedSquares(_ move: ROBChessMove) -> Set<Int> {
        let next = applyingUnchecked(move)
        return Set((0..<64).filter { board[$0] != next.board[$0] })
    }
    private func applyingUnchecked(_ move: ROBChessMove) -> Self {
        var next = self
        let piece = board[move.from], capture = board[move.to] != "."
        next.board[move.from] = "."
        next.board[move.to] = move.promotion.map { Character(whiteToMove ? $0.uppercased() : $0) } ?? piece
        if piece.lowercased() == "p" && move.to == enPassant && move.from % 8 != move.to % 8 {
            next.board[move.to + (whiteToMove ? -8 : 8)] = "."
        }
        if piece.lowercased() == "k" {
            next.castling.removeAll { whiteToMove ? "KQ".contains($0) : "kq".contains($0) }
            if abs(move.to - move.from) == 2 {
                let rookFrom = move.from + (move.to > move.from ? 3 : -4)
                let rookTo = (move.from + move.to) / 2
                next.board[rookTo] = next.board[rookFrom]; next.board[rookFrom] = "."
            }
        }
        for (square, right): (Int, Character) in [(0,"Q"),(7,"K"),(56,"q"),(63,"k")]
            where move.from == square || move.to == square { next.castling.removeAll { $0 == right } }
        next.enPassant = piece.lowercased() == "p" && abs(move.to - move.from) == 16 ? (move.from + move.to) / 2 : nil
        next.halfmove = piece.lowercased() == "p" || capture ? 0 : halfmove + 1
        next.fullmove = fullmove + (whiteToMove ? 0 : 1)
        next.whiteToMove.toggle()
        return next
    }
}

struct ROBChessPoint: Codable, Equatable {
    let x: Double
    let y: Double
}

struct ROBChessBoardMap: Codable, Equatable {
    // Outer corners in semantic order a8, h8, h1, a1. Image origin is TOP left.
    let corners: [ROBChessPoint]
    let revision: UUID
    private let h: [Double]
    init(corners: [ROBChessPoint], revision: UUID = UUID()) throws {
        guard corners.count == 4, corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite &&
            (0...1).contains($0.x) && (0...1).contains($0.y) }) else {
            throw ROBChessStudyError.invalid("Mark four board corners inside the image.")
        }
        let turns = (0..<4).map { i -> Double in
            let a = corners[i], b = corners[(i+1)%4], c = corners[(i+2)%4]
            return (b.x-a.x)*(c.y-b.y) - (b.y-a.y)*(c.x-b.x)
        }
        let area = abs((0..<4).reduce(0.0) { sum,i in
            sum + corners[i].x*corners[(i+1)%4].y - corners[(i+1)%4].x*corners[i].y
        }) / 2
        guard area > 0.025, turns.allSatisfy({ $0 > 0.0001 }) || turns.allSatisfy({ $0 < -0.0001 }) else {
            throw ROBChessStudyError.invalid("Corners must form a clear convex board, in a8 → h8 → h1 → a1 order.")
        }
        let unit = [(0.0,0.0),(1.0,0.0),(1.0,1.0),(0.0,1.0)]
        var matrix: [[Double]] = []
        for i in 0..<4 {
            let (u,v) = unit[i], p = corners[i]
            matrix.append([u,v,1,0,0,0,-u*p.x,-v*p.x,p.x])
            matrix.append([0,0,0,u,v,1,-u*p.y,-v*p.y,p.y])
        }
        for k in 0..<8 {
            guard let pivot = (k..<8).max(by: { abs(matrix[$0][k]) < abs(matrix[$1][k]) }),
                  abs(matrix[pivot][k]) > 1e-10 else { throw ROBChessStudyError.invalid("Board geometry is singular.") }
            matrix.swapAt(k,pivot)
            let scale = matrix[k][k]
            for j in k...8 { matrix[k][j] /= scale }
            for i in 0..<8 where i != k {
                let factor = matrix[i][k]
                for j in k...8 { matrix[i][j] -= factor*matrix[k][j] }
            }
        }
        let solved = matrix.map { $0[8] } + [1]
        let denominators = unit.map { solved[6]*$0.0 + solved[7]*$0.1 + 1 }
        guard denominators.allSatisfy({ $0 > 1e-6 }) else {
            throw ROBChessStudyError.invalid("Board perspective is too oblique.")
        }
        self.corners = corners; h = solved; self.revision = revision
    }
    private enum CodingKeys: String, CodingKey { case corners, revision }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(corners: container.decode([ROBChessPoint].self, forKey: .corners),
                      revision: container.decode(UUID.self, forKey: .revision))
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(corners, forKey: .corners)
        try container.encode(revision, forKey: .revision)
    }
    func imagePoint(u: Double, v: Double) -> ROBChessPoint {
        let d = h[6]*u + h[7]*v + 1
        return ROBChessPoint(x: (h[0]*u+h[1]*v+h[2])/d, y: (h[3]*u+h[4]*v+h[5])/d)
    }
    func boardPoint(image p:ROBChessPoint) -> ROBChessPoint? {
        let a = h[0]-p.x*h[6], b = h[1]-p.x*h[7], c = p.x-h[2]
        let d = h[3]-p.y*h[6], e = h[4]-p.y*h[7], f = p.y-h[5]
        let determinant = a*e-b*d
        guard determinant.isFinite, abs(determinant) > 1e-10 else { return nil }
        let point = ROBChessPoint(x:(c*e-b*f)/determinant,y:(a*f-c*d)/determinant)
        return point.x.isFinite && point.y.isFinite ? point : nil
    }
    func polygon(square: Int) -> [ROBChessPoint] {
        let f = Double(square % 8)/8, r = Double(7-square/8)/8
        return [(f,r),(f+0.125,r),(f+0.125,r+0.125),(f,r+0.125)].map { imagePoint(u:$0.0,v:$0.1) }
    }
}

struct ROBChessEvidence {
    // 64 descriptors indexed a1...h8. Observations are never labels on their own.
    let descriptors: [[Float]]
    var heightsMillimeters: [Double?]? = nil
    static func distance(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        return zip(a,b).reduce(0.0) { $0 + Double(abs($1.0-$1.1)) } / Double(a.count)
    }
    func changes(from baseline: Self) -> [Double] {
        guard descriptors.count == 64, baseline.descriptors.count == 64 else { return [] }
        return zip(descriptors,baseline.descriptors).map(Self.distance)
    }
}

struct ROBChessProposal {
    let move: ROBChessMove
    let score: Double // image agreement score, NOT calibrated recognition probability
    let affected: Set<Int>
}

enum ROBChessStudyAnalysis {
    static func proposals(position: ROBChessPosition, changes: [Double]) -> [ROBChessProposal] {
        guard changes.count == 64, changes.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return [] }
        let changed = Set(changes.indices.filter { changes[$0] >= 0.045 })
        guard (2...6).contains(changed.count) else { return [] }
        return position.legalMoves().compactMap { move in
            let expected = position.affectedSquares(move)
            // Both endpoints must change. Castling and en passant need all their squares.
            guard expected.isSubset(of: changed) else { return nil }
            let coverage = Double(expected.intersection(changed).count) / Double(expected.union(changed).count)
            let unrelated = changes.indices.filter { !expected.contains($0) }.reduce(0.0) { $0 + changes[$1] }
            let score = max(0, coverage - unrelated / 4)
            return ROBChessProposal(move: move, score: score, affected: expected)
        }.sorted { $0.score == $1.score ? $0.move.uci < $1.move.uci : $0.score > $1.score }
    }
}

struct ROBChessTeachingExample {
    let label: String
    let lightSquare: Bool
    let descriptor: [Float]
    let heightMillimeters: Double?
}

struct ROBChessAppearanceMemory {
    private(set) var examples: [ROBChessTeachingExample] = []
    mutating func learn(position: ROBChessPosition, evidence: ROBChessEvidence) {
        guard evidence.descriptors.count == 64 else { return }
        for square in 0..<64 {
            let label = ROBChessPosition.label(position.board[square])
            let light = (square/8+square%8)%2 == 1
            let descriptor = evidence.descriptors[square]
            let existing = examples.filter { $0.label == label && $0.lightSquare == light }
            // Only add distinct appearances, capped per class/background to bound runtime.
            if existing.count < 24 && !existing.contains(where: { ROBChessEvidence.distance($0.descriptor,descriptor) < 0.008 }) {
                examples.append(.init(label: label, lightSquare: light, descriptor: descriptor,
                                      heightMillimeters:evidence.heightsMillimeters?[square]))
            }
        }
    }
    func guess(square: Int, descriptor: [Float], height:Double? = nil) -> (label: String, distance: Double)? {
        let light = (square/8+square%8)%2 == 1
        let ranked = examples.filter { $0.lightSquare == light }.map {
            example -> (label:String,distance:Double) in
            let heightPenalty = height.flatMap { h in example.heightMillimeters.map { abs($0-h)/200 } } ?? 0
            return (label:example.label,distance:ROBChessEvidence.distance(example.descriptor,descriptor)+heightPenalty)
        }.sorted { $0.distance < $1.distance }
        guard let best = ranked.first, best.distance < 0.10 else { return nil }
        let alternative = ranked.first { $0.label != best.label }
        guard alternative == nil || alternative!.distance - best.distance > 0.015 else { return nil }
        return best
    }
}

enum ROBChessCoach {
    // Deliberately modest two-ply rules/material coach. Not a trained chess engine.
    static func suggestion(_ position: ROBChessPosition) -> ROBChessMove? {
        let white = position.whiteToMove
        var best: (ROBChessMove,Int)?
        for (move,next) in position.legalSuccessors().sorted(by:{$0.move.uci < $1.move.uci}) {
            let replies = next.legalSuccessors()
            var worst = replies.isEmpty ? (next.isInCheck(white:next.whiteToMove) ? 100_000 : 0) : Int.max
            for (_,after) in replies {
                worst = min(worst,evaluate(after,forWhite:white))
            }
            if best == nil || worst > best!.1 { best = (move,worst) }
        }
        return best?.0
    }
    private static func evaluate(_ position: ROBChessPosition, forWhite white: Bool) -> Int {
        let values: [Character:Int] = ["p":100,"n":320,"b":330,"r":500,"q":900,"k":0]
        return position.board.enumerated().reduce(0) { score, pair in
            let (square,piece) = pair
            guard piece != "." else { return score }
            let color = ROBChessPosition.isWhite(piece)
            var value = values[Character(piece.lowercased())] ?? 0
            if piece.lowercased() == "p" { value += (color ? square/8 : 7-square/8)*6 }
            if "nb".contains(piece.lowercased()) {
                value += (3-min(abs(square%8-3),abs(square%8-4)))*5
            }
            return score + (color == white ? value : -value)
        }
    }
}
