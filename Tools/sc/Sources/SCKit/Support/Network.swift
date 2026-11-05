import Darwin

/// Bits of networking sc needs here.
enum Network {
    /// A local port nothing is listening on, for a tunnel: the one the
    /// system gives a socket bound to port 0. Another tunnel or a leftover
    /// one may hold any fixed port.
    static func freePort() throws -> Int {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw SCError("Couldn't open a socket to find a free port: \(String(cString: strerror(errno))).") }
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, length) == 0 && getsockname(socket, $0, &length) == 0
            }
        }
        guard bound else { throw SCError("Couldn't find a free port for the tunnel: \(String(cString: strerror(errno))).") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
