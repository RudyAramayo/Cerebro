import Foundation
import CoreGraphics
import ImageIO

@main struct ROBChessStudyFixtureTests {
    static var checks = 0
    static func check(_ result:Bool,_ name:String) {
        guard result else { fputs("FAIL: \(name)\n",stderr); exit(1) }
        checks += 1
    }
    static func rejects(_ name:String,_ body:() throws -> Void) {
        do { try body(); fputs("FAIL: \(name) was accepted\n",stderr); exit(1) } catch { checks += 1 }
    }
    static func perft(_ p:ROBChessPosition,_ depth:Int) -> Int {
        if depth == 0 { return 1 }
        return p.legalSuccessors().reduce(0) { $0+perft($1.position,depth-1) }
    }
    static func raster(_ position:ROBChessPosition) throws -> ROBChessRaster {
        let size = 640
        var pixels = [UInt8](repeating:40,count:size*size*4)
        for y in 0..<size { for x in 0..<size {
            let i = (y*size+x)*4; pixels[i+3] = 255
            if x >= 64 && x < 576 && y >= 64 && y < 576 {
                let file = (x-64)/64, row = (y-64)/64, square = (7-row)*8+file
                let background:UInt8 = (file+row)%2 == 0 ? 210 : 125
                let p = position.board[square], rx = (x-64)%64-32, ry = (y-64)%64-32
                var value = background
                if p != ".", rx*rx+ry*ry < 24*24 { value = ROBChessPosition.isWhite(p) ? 245 : 45 }
                pixels[i] = value; pixels[i+1] = value; pixels[i+2] = value
            }
        }}
        pixels[0]=255; pixels[1]=0; pixels[2]=0
        pixels[(size-1)*size*4]=0; pixels[(size-1)*size*4+1]=0; pixels[(size-1)*size*4+2]=255
        let provider = CGDataProvider(data:Data(pixels) as CFData)!
        let image = CGImage(width:size,height:size,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:size*4,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),
            provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        return try ROBChessRaster(image:image)
    }
    static func main() throws {
        let start = ROBChessPosition.start
        check(start.fen == ROBChessPosition.startingFEN,"FEN round trip")
        check(start.labels["e1"] == "white_king" && start.labels["d8"] == "black_queen","semantic squares")
        check(perft(start,1) == 20,"start perft 1")
        check(perft(start,2) == 400,"start perft 2")
        check(perft(start,3) == 8902,"start perft 3")
        let kiwi = try ROBChessPosition(fen:"r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1")
        check(perft(kiwi,1) == 48,"castling/pins reference position 1")
        check(perft(kiwi,2) == 2039,"castling/pins reference position 2")
        rejects("illegal pawn jump") { _ = try start.applying(uci:"e2e5") }
        rejects("kingless position") { _ = try ROBChessPosition(fen:"8/8/8/8/8/8/8/8 w - - 0 1") }
        rejects("false castling rights") { _ = try ROBChessPosition(fen:"7k/8/8/8/8/8/8/K7 w K - 0 1") }
        rejects("invalid en passant") { _ = try ROBChessPosition(fen:"7k/8/8/8/8/8/8/K7 w - d6 0 1") }
        let pinned = try ROBChessPosition(fen:"k3r3/8/8/3pP3/8/8/8/4K3 w - d6 0 1")
        rejects("en passant exposing king") { _ = try pinned.applying(uci:"e5d6") }
        let ep = try ROBChessPosition(fen:"7k/8/8/3pP3/8/8/8/4K3 w - d6 0 1")
        check(ep.affectedSquares(ep.legalMoves().first { $0.uci == "e5d6" }!).count == 3,"en passant three squares")
        let castle = try ROBChessPosition(fen:"r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
        check(castle.affectedSquares(castle.legalMoves().first { $0.uci == "e1g1" }!).count == 4,"castle four squares")
        let promotion = try ROBChessPosition(fen:"7k/P7/8/8/8/8/8/4K3 w - - 0 1")
        check(promotion.legalMoves().filter { $0.from == 48 && $0.to == 56 }.count == 4,"four promotion choices")
        let mate = try ROBChessPosition(fen:"7k/6Q1/5K2/8/8/8/8/8 b - - 0 1")
        check(mate.legalMoves().isEmpty && mate.isInCheck(white:false),"checkmate")
        let stale = try ROBChessPosition(fen:"7k/5Q2/6K1/8/8/8/8/8 b - - 0 1")
        check(stale.legalMoves().isEmpty && !stale.isInCheck(white:false),"stalemate")
        let advice = ROBChessCoach.suggestion(start)
        check(advice != nil && start.legalMoves().contains(advice!),"coach suggests legal move")
        let corners:[ROBChessPoint] = [.init(x:0.1,y:0.1),.init(x:0.9,y:0.1),.init(x:0.9,y:0.9),.init(x:0.1,y:0.9)]
        let map = try ROBChessBoardMap(corners:corners)
        check(abs(map.imagePoint(u:0.5,v:0.5).x-0.5)<1e-9,"board center")
        let inverse = map.boardPoint(image:map.imagePoint(u:0.15,v:0.85))!
        check(abs(inverse.x-0.15)<1e-9 && abs(inverse.y-0.85)<1e-9,"board projection round trip")
        check(map.polygon(square:0)[0].y > 0.7,"a1 is at bottom")
        let turned = try ROBChessBoardMap(corners:[corners[2],corners[3],corners[0],corners[1]])
        check(abs(turned.imagePoint(u:0,v:0).x-corners[2].x)<1e-9,"180-degree semantic orientation")
        rejects("crossed board") { _ = try ROBChessBoardMap(corners:[corners[0],corners[2],corners[1],corners[3]]) }
        rejects("degenerate board") { _ = try ROBChessBoardMap(corners:Array(repeating:corners[0],count:4)) }
        let decodedMap = try JSONDecoder().decode(ROBChessBoardMap.self,from:JSONEncoder().encode(map))
        check(decodedMap == map,"map round trip")
        let before = try raster(start), next = try start.applying(uci:"e2e4"), after = try raster(next)
        check(before.rgba[0] == 255 && before.rgba[2] == 0,"image top-left orientation")
        let firstBoard = try before.rectified(map:map), nextBoard = try after.rectified(map:map)
        let firstEvidence = firstBoard.evidence(), nextEvidence = nextBoard.evidence()
        let changes = nextEvidence.changes(from:firstEvidence)
        check(ROBChessStudyAnalysis.proposals(position:start,changes:changes).first?.move.uci == "e2e4","gray-board image proposes e2e4")
        check(ROBChessStudyAnalysis.proposals(position:start,changes:Array(repeating:0,count:64)).isEmpty,"unchanged board")
        check(ROBChessStudyAnalysis.proposals(position:start,changes:Array(repeating:0.4,count:64)).isEmpty,"camera movement rejected")
        check(ROBChessStudyAnalysis.proposals(position:start,changes:Array(repeating:.nan,count:64)).isEmpty,"invalid image scores")
        var memory = ROBChessAppearanceMemory()
        check(memory.examples.isEmpty,"no unreviewed learning")
        memory.learn(position:start,evidence:firstEvidence)
        let count = memory.examples.count; memory.learn(position:start,evidence:firstEvidence)
        check(memory.examples.count == count,"duplicate appearance deduplicated")
        check(memory.guess(square:16,descriptor:firstEvidence.descriptors[16]) != nil,"retrieve verified empty-square appearance")
        check(memory.guess(square:8,descriptor:firstEvidence.descriptors[8]) == nil,"identical piece sprites remain ambiguous")
        var depth = [UInt8](repeating:0,count:640*640*2)
        for y in 0..<640 { for x in 0..<640 {
            let d:UInt16 = x >= 320 && x < 384 && y >= 320 && y < 384 ? 920 : 1000, i = (y*640+x)*2
            depth[i] = UInt8(d&255); depth[i+1] = UInt8(d>>8)
        }}
        let depthFrame = ROBChessStudyDepth(width:640,height:640,millimetersLittleEndian:Data(depth),
            fx:500,fy:500,cx:320,cy:320,cameraSequence:1,cameraTimestampNanoseconds:1)
        let heights = depthFrame.heights(map:map,position:next)!
        check(abs(heights[28]!-80)<0.5,"aligned depth height above board")
        check(abs(heights[20]!)<0.5,"empty square zero height")
        var raisedDepth = [UInt8](repeating:0,count:640*640*2)
        for y in 0..<640 { for x in 0..<640 {
            let footX = 320+Double(x-320)*0.82, footY = 320+Double(y-320)*0.82
            let value:UInt16 = (90...115).contains(footX) && (532...559).contains(footY) ? 820 : 1000
            let i = (y*640+x)*2; raisedDepth[i] = UInt8(value&255); raisedDepth[i+1] = UInt8(value>>8)
        }}
        let raisedFrame = ROBChessStudyDepth(width:640,height:640,millimetersLittleEndian:Data(raisedDepth),
            fx:500,fy:500,cx:320,cy:320,cameraSequence:2,cameraTimestampNanoseconds:2)
        let raisedHeights = raisedFrame.heights(map:map,position:start)!
        check(abs(raisedHeights[0]!-180)<0.5,"3D footprint assigns projected tall piece to a1")
        check(raisedHeights[1] == nil,"missing occupied-square depth stays unknown")
        let destination = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
        try before.encoded("public.png" as CFString).write(to:destination.appendingPathComponent("starting.png"))
        try after.encoded("public.png" as CFString).write(to:destination.appendingPathComponent("e2e4.png"))
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("chess-session-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temp) }
        let session = try ROBChessStudySession(createAt:temp)
        let responseFile = temp.appendingPathComponent("response.json")
        let responseBytes = Data("{\"ok\":true}".utf8)
        try ROBLocalAgentBridge.publishPrivateResponse(responseBytes,to:responseFile)
        check(try Data(contentsOf:responseFile) == responseBytes,"complete response publication")
        check((try FileManager.default.attributesOfItem(atPath:responseFile.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600,"private response permissions")
        rejects("response cannot overwrite or replay") { try ROBLocalAgentBridge.publishPrivateResponse(Data(),to:responseFile) }
        check(try Data(contentsOf:responseFile) == responseBytes,"original reply preserved after replay")
        let first = ROBChessStudyFrame(raster:before,source:"test fixture")
        try session.append(frame:first,board:firstBoard,map:map,position:start,kind:"baseline",move:nil)
        let second = ROBChessStudyFrame(raster:after,source:"test fixture")
        try session.append(frame:second,board:nextBoard,map:map,position:next,kind:"move",move:"e2e4")
        let reopened = try ROBChessStudySession(open:temp)
        check(reopened.manifest.records.count == 2,"session reload")
        check(reopened.manifest.records.last?.labels["e4"] == "white_pawn","reviewed move labels")
        rejects("duplicate frame") { try session.append(frame:second,board:nextBoard,map:map,position:next,kind:"rebaseline",move:nil) }
        let folder = temp.appendingPathComponent(session.manifest.records[0].id.uuidString)
        try Data("tampered".utf8).write(to:folder.appendingPathComponent("source.jpg"))
        rejects("tampered saved image") { _ = try ROBChessStudySession(open:temp) }
        let now = Date().timeIntervalSince1970
        func envelope(_ command:String,_ args:[String:String] = [:],deadline:Double? = nil) throws -> Data {
            try JSONEncoder().encode(ROBLocalAgentRequest(version:1,id:UUID(),expiresAt:deadline ?? now+5,command:command,arguments:args))
        }
        check(try ROBLocalAgentRequest.decode(envelope("capture"),now:now).command == "capture","capture envelope")
        rejects("expired request") { _ = try ROBLocalAgentRequest.decode(envelope("stop",deadline:now-1),now:now) }
        rejects("long-lived motion") { _ = try ROBLocalAgentRequest.decode(envelope("stop",deadline:now+100),now:now) }
        rejects("arbitrary command") { _ = try ROBLocalAgentRequest.decode(envelope("run-shell",["code":"anything"]),now:now) }
        rejects("arbitrary path") { _ = try ROBLocalAgentRequest.decode(envelope("capture",["path":"/tmp/unrequested"]),now:now) }
        for delta in ["101","-101",String(Int.min),"nan"] {
            rejects("unbounded nudge "+delta) {
                _ = try ROBLocalAgentRequest.decode(envelope("camera-nudge",["axis":"upper","delta":delta,"pan":"5799","lower":"6011","upper":"6906"]),now:now)
            }
        }
        rejects("lower-neck adjustment") {
            _ = try ROBLocalAgentRequest.decode(envelope("camera-nudge",["axis":"lower","delta":"10","pan":"5799","lower":"6011","upper":"6906"]),now:now)
        }
        print("Passed \(checks) chess, image, depth, persistence and command-boundary checks.")
        print("Illustrative fixtures: \(destination.path)")
    }
}
