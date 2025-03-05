import Foundation
import Darwin

// Rinomina la classe per evitare la ridefinizione
class TCPSocket {
    private var socketFd: Int32 = -1
    
    init(host: String, port: Int) throws {
        // Crea socket
        socketFd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        if socketFd == -1 {
            throw NSError(domain: "Socket", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
        }
        
        // Imposta timeout
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(socketFd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(socketFd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        
        // Prepara indirizzo
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr(host)
        
        // Connetti
        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        
        if connectResult == -1 {
            let errorCode = errno
            // Usa il nome qualificato per evitare ambiguità
            Darwin.close(socketFd)
            throw NSError(domain: "Socket", code: Int(errorCode), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errorCode))])
        }
        
        NSLog("[SOCKET] Connected to \(host):\(port)")
    }
    
    func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength: Int) -> Int {
        return Darwin.recv(socketFd, buffer, maxLength, 0)
    }
    
    func write(_ data: Data) -> Int {
        return data.withUnsafeBytes { bufferPtr in
            return Darwin.send(socketFd, bufferPtr.baseAddress, data.count, 0)
        }
    }
    
    func closeSocket() {
        if socketFd != -1 {
            // Usa il nome qualificato per evitare ambiguità
            Darwin.close(socketFd)
            socketFd = -1
        }
    }
    
    deinit {
        closeSocket()
    }
} 