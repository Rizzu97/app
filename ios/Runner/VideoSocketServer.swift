import Foundation

class VideoSocketServer {
    var onDataReceived: ((Data) -> Void)?
    private var isRunning = false
    private var socket: Int32 = -1
    private var thread: Thread?
    
    func start(port: UInt16) -> Bool {
        // Aumenta il log per il debugging
        NSLog("[DEBUG] 🔌 Starting UDP socket server on port \(port)")
        
        // Crea socket UDP
        socket = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        if socket == -1 {
            NSLog("[ERROR] Failed to create UDP socket")
            return false
        }
        
        // Imposta opzioni socket
        var reuse = 1
        if setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse))) == -1 {
            NSLog("[ERROR] Failed to set socket options")
            close(socket)
            return false
        }
        
        // Configura indirizzo
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        
        // Associa socket all'indirizzo
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        
        if bindResult == -1 {
            NSLog("[ERROR] 🔌 Failed to bind socket: \(String(cString: strerror(errno))) (error code: \(errno))")
            close(socket)
            return false
        }
        
        NSLog("[DEBUG] 🔌 Successfully bound to port \(port), waiting for data...")
        
        // Inizia a ricevere dati in un thread separato
        isRunning = true
        thread = Thread { [weak self] in
            self?.receiveLoop()
        }
        thread?.start()
        
        return true
    }
    
    private func receiveLoop() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        
        while isRunning {
            // Ricevi dati dal socket
            var addr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            
            let bytesRead = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { addrPtr in
                    recvfrom(socket, &buffer, buffer.count, 0, addrPtr, &addrLen)
                }
            }
            
            if bytesRead > 0 {
                let data = Data(bytes: buffer, count: bytesRead)
                DispatchQueue.main.async { [weak self] in
                    self?.onDataReceived?(data)
                }
            } else if bytesRead < 0 && isRunning {
                NSLog("[ERROR] Error receiving data: \(String(cString: strerror(errno)))")
                // Breve pausa prima di riprovare
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }
    
    func stop() {
        isRunning = false
        if socket != -1 {
            close(socket)
            socket = -1
        }
        thread = nil
    }
} 