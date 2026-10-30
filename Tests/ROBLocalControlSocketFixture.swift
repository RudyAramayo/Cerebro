import Foundation

@main enum SocketFixture {
    static func main() throws {
        let directory=URL(fileURLWithPath:CommandLine.arguments[1])
        let socket=ROBLocalControlSocket()
        var admission=ROBLocalControlAdmission()
        var commands=0
        try socket.start(directory:directory) { data,reply in
            DispatchQueue.main.async {
                var value:[String:Any] = [:]
                do {
                    let request=try ROBLocalControlRequest(data:data)
                    value["id"]=request.id.uuidString
                    try admission.admit(request)
                    if request.mutates {commands+=1}
                    value.merge(["ok":true,"session":admission.session,"result":["commands":commands]]) {_,new in new}
                } catch {value["ok"]=false;value["error"]=error.localizedDescription}
                reply(try! JSONSerialization.data(withJSONObject:value))
            }
        }
        // Starting another instance must leave the original listener intact.
        do {try ROBLocalControlSocket().start(directory:directory){_,_ in};fatalError("Stole live socket")}
        catch {}
        RunLoop.main.run(until:Date().addingTimeInterval(30));socket.stop()
    }
}
