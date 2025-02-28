import Foundation
import Network
import UIKit
import Darwin.POSIX.sys.select

class VideoPlayer {
    private let decoder: VideoDecoder
    private var socket: CFSocket?
    private var isPlaying = false
    private var bufferSize = 4096
    
    init(decoder: VideoDecoder) {
        self.decoder = decoder
    }
    
    func setBufferSize(size: Int) {
        if size > 0 {
            bufferSize = size
        }
    }
    
    func startPlayback(ip: String, port: Int, onFrame: @escaping (Data) -> Void) {
        if isPlaying {
            stopPlayback()
        }
        
        print("[DEBUG] Starting playback from \(ip):\(port)")
        
        // Imposta il callback per i frame decodificati
        decoder.onFrameDecoded = onFrame
        
        // Avvia il thread di ricezione
        isPlaying = true
        startReceiverThread(ip: ip, port: port)
    }
    
    func stopPlayback() {
        print("[DEBUG] Stopping playback")
        isPlaying = false
        
        // Chiudi il socket
        if let socket = socket {
            CFSocketInvalidate(socket)
            self.socket = nil
        }
    }
    
    func dispose() {
        stopPlayback()
    }
    
    func captureCurrentFrame() -> Data? {
        return decoder.getCurrentFrame()
    }
    
    private func startReceiverThread(ip: String, port: Int) {
        DispatchQueue.global(qos: .userInitiated).async {
            print("[DEBUG] Receiver thread started for \(ip):\(port)")
            
            // Crea il socket
            if !self.connectLikeKotlin(ip: ip, port: port) {
                print("[ERROR] Failed to connect to camera")
                self.isPlaying = false
                return
            }
            
            // Invia una richiesta HTTP per stimolare la telecamera
            self.sendHTTPRequest(ip: ip)
            
            // Buffer per ricevere i dati
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: self.bufferSize)
            defer { buffer.deallocate() }
            
            // Loop di ricezione dati
            while self.isPlaying {
                guard let socket = self.socket else { break }
                let fileDescriptor = CFSocketGetNative(socket)
                
                // Usa select per verificare se ci sono dati da leggere
                var readfds = fd_set()
                var timeout = timeval(tv_sec: 0, tv_usec: 100000) // 100ms timeout
                
                __darwin_fd_set(fileDescriptor, &readfds)
                
                let selectResult = select(fileDescriptor + 1, &readfds, nil, nil, &timeout)
                
                if selectResult <= 0 {
                    if selectResult < 0 {
                        print("[ERROR] Select error: \(errno)")
                        break
                    }
                    // Timeout, nessun dato disponibile
                    continue
                }
                
                // Leggi i dati dal socket
                let bytesRead = recv(fileDescriptor, buffer, self.bufferSize, 0)
                
                // Stampa informazioni di debug
                print("[DEBUG] Bytes read: \(bytesRead)")
                
                if bytesRead <= 0 {
                    if bytesRead < 0 {
                        let errorCode = errno
                        print("[ERROR] Error reading from socket: \(errorCode) - \(String(cString: strerror(errorCode)))")
                        
                        // Se è un errore temporaneo, continua
                        if errorCode == EAGAIN || errorCode == EWOULDBLOCK {
                            Thread.sleep(forTimeInterval: 0.1)
                            continue
                        }
                    } else {
                        print("[DEBUG] Connection closed by remote host")
                    }
                    break
                }
                
                // Stampa i primi byte per debug
                var hexPreview = ""
                let previewLength = min(bytesRead, 32)
                for i in 0..<previewLength {
                    hexPreview += String(format: "%02X ", buffer[i])
                }
                print("[DEBUG] Received \(bytesRead) bytes: \(hexPreview)...")
                
                // Crea un Data object e passa al decoder
                let data = Data(bytes: buffer, count: bytesRead)
                self.decoder.queueNalUnit(nalUnit: data)
            }
            
            print("[DEBUG] Receiver thread stopped")
            self.isPlaying = false
        }
    }
    
    private func connectTCP(ip: String, port: Int) -> Bool {
        // Prima chiudi il socket esistente
        if let socket = socket {
            CFSocketInvalidate(socket)
            self.socket = nil
        }
        
        print("[DEBUG] Trying to connect to \(ip):\(port)")
        
        // Prova prima con NWConnection (API moderna)
        if #available(iOS 12.0, *) {
            let hostEndpoint = NWEndpoint.Host(ip)
            let portEndpoint = NWEndpoint.Port(integerLiteral: NWEndpoint.Port.IntegerLiteralType(port))
            
            let connection = NWConnection(host: hostEndpoint, port: portEndpoint, using: .tcp)
            
            let semaphore = DispatchSemaphore(value: 0)
            var connectionSuccess = false
            
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("[DEBUG] NWConnection ready")
                    connectionSuccess = true
                    semaphore.signal()
                case .failed(let error):
                    print("[DEBUG] NWConnection failed: \(error)")
                    semaphore.signal()
                case .cancelled:
                    print("[DEBUG] NWConnection cancelled")
                    semaphore.signal()
                default:
                    break
                }
            }
            
            connection.start(queue: .global())
            
            // Attendi la connessione con timeout
            _ = semaphore.wait(timeout: .now() + 5.0)
            
            if connectionSuccess {
                print("[DEBUG] Successfully connected to \(ip):\(port) using NWConnection")
                // Ora dobbiamo creare un socket CFSocket dal NWConnection
                // Questo è complicato, quindi per ora usiamo il metodo tradizionale
            }
        }
        
        // Fallback al metodo tradizionale con socket
        // Crea il socket
        socket = CFSocketCreate(kCFAllocatorDefault, PF_INET, SOCK_STREAM, IPPROTO_TCP, 0, nil, nil)
        
        guard let socket = socket else {
            print("[ERROR] Failed to create socket")
            return false
        }
        
        // Imposta l'opzione SO_REUSEADDR
        var yes: Int32 = 1
        let fd = CFSocketGetNative(socket)
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        
        // Imposta timeout
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        
        // Imposta l'indirizzo
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        
        // Prova prima con inet_pton
        let conversionResult = inet_pton(AF_INET, ip, &addr.sin_addr)
        if conversionResult <= 0 {
            print("[ERROR] Failed to convert IP address: \(ip)")
            
            // Prova con gethostbyname come fallback
            guard let hostent = gethostbyname(ip) else {
                print("[ERROR] gethostbyname failed for \(ip)")
                CFSocketInvalidate(socket)
                self.socket = nil
                return false
            }
            
            memcpy(&addr.sin_addr, hostent.pointee.h_addr_list[0], Int(hostent.pointee.h_length))
        }
        
        let addrData = Data(bytes: &addr, count: MemoryLayout<sockaddr_in>.size)
        
        // Connetti al server
        let result = CFSocketConnectToAddress(socket, addrData as CFData, 5.0)
        
        if result != .success {
            print("[ERROR] Failed to connect to \(ip):\(port), error: \(result.rawValue)")
            CFSocketInvalidate(socket)
            self.socket = nil
            return false
        }
        
        print("[DEBUG] Successfully connected to \(ip):\(port)")
        return true
    }
    
    private func sendHTTPRequest(ip: String) {
        guard let socket = socket else { return }
        
        // Array di richieste da provare
        let requests = [
            // Richiesta standard
            "GET / HTTP/1.1\r\nHost: \(ip)\r\nConnection: keep-alive\r\n\r\n",
            
            // Richiesta per MJPEG
            "GET /video.mjpg HTTP/1.1\r\nHost: \(ip)\r\nConnection: keep-alive\r\n\r\n",
            
            // Richiesta per H.264
            "GET /video.h264 HTTP/1.1\r\nHost: \(ip)\r\nConnection: keep-alive\r\n\r\n",
            
            // Richiesta per JPEG
            "GET /image.jpg HTTP/1.1\r\nHost: \(ip)\r\nConnection: keep-alive\r\n\r\n"
        ]
        
        let fileDescriptor = CFSocketGetNative(socket)
        
        // Invia solo la prima richiesta
        if let data = requests[0].data(using: .ascii) {
            data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Void in
                if let baseAddress = bytes.baseAddress {
                    let sent = send(fileDescriptor, baseAddress, data.count, 0)
                    print("[DEBUG] Sent request: \(requests[0]), bytes: \(sent)")
                }
            }
        }
    }
    
    func tryAlternativeConnections(ip: String, onFrame: @escaping (Data) -> Void) {
        // Array di porte comuni per telecamere IP
        let commonPorts = [80, 8080, 554, 8554, 40005, 40004, 8000, 8081, 9000]
        
        DispatchQueue.global(qos: .background).async {
            // Prova diverse porte TCP
            for port in commonPorts {
                print("[DEBUG] Trying TCP connection to \(ip):\(port)")
                
                // Ferma la riproduzione corrente
                self.stopPlayback()
                
                // Prova a connetterti
                if self.connectLikeKotlin(ip: ip, port: port) {
                    print("[DEBUG] TCP connection successful")
                    
                    // Imposta il callback
                    self.decoder.onFrameDecoded = onFrame
                    
                    // Avvia il thread di ricezione
                    self.isPlaying = true
                    self.startReceiverThread(ip: ip, port: port)
                    
                    // Attendi un po' per vedere se riceviamo dati
                    Thread.sleep(forTimeInterval: 2.0)
                    
                    // Se abbiamo ricevuto un frame valido, interrompi il ciclo
                    if self.decoder.getCurrentFrame() != nil {
                        print("[DEBUG] Successfully received frame from \(ip):\(port)")
                        break
                    }
                }
            }
        }
    }
    
    private func connectUDP(ip: String, port: Int) -> Bool {
        // Prima chiudi il socket esistente
        if let socket = socket {
            CFSocketInvalidate(socket)
            self.socket = nil
        }
        
        // Crea il socket UDP
        socket = CFSocketCreate(kCFAllocatorDefault, PF_INET, SOCK_DGRAM, IPPROTO_UDP, 0, nil, nil)
        
        guard let socket = socket else {
            print("[ERROR] Failed to create UDP socket")
            return false
        }
        
        // Imposta l'opzione SO_REUSEADDR
        var yes: Int32 = 1
        let fd = CFSocketGetNative(socket)
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        
        // Imposta l'indirizzo locale
        var localAddr = sockaddr_in()
        localAddr.sin_family = sa_family_t(AF_INET)
        localAddr.sin_port = in_port_t(port).bigEndian
        localAddr.sin_addr.s_addr = INADDR_ANY
        
        let bindResult = bind(fd, sockaddr_cast(&localAddr), socklen_t(MemoryLayout<sockaddr_in>.size))
        if bindResult < 0 {
            print("[ERROR] Failed to bind UDP socket: \(errno)")
            CFSocketInvalidate(socket)
            self.socket = nil
            return false
        }
        
        // Imposta l'indirizzo remoto
        var remoteAddr = sockaddr_in()
        remoteAddr.sin_family = sa_family_t(AF_INET)
        remoteAddr.sin_port = in_port_t(port).bigEndian
        inet_pton(AF_INET, ip, &remoteAddr.sin_addr)
        
        // Invia un pacchetto di prova
        let testMessage = "HELLO"
        let testData = testMessage.data(using: .ascii)!
        
        let sendResult = testData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int in
            guard let baseAddress = bytes.baseAddress else { return -1 }
            return sendto(fd, baseAddress, testData.count, 0, sockaddr_cast(&remoteAddr), socklen_t(MemoryLayout<sockaddr_in>.size))
        }
        
        if sendResult < 0 {
            print("[ERROR] Failed to send UDP test packet: \(errno)")
            CFSocketInvalidate(socket)
            self.socket = nil
            return false
        }
        
        print("[DEBUG] Successfully sent UDP test packet to \(ip):\(port)")
        return true
    }
    
    private func startUDPReceiver(ip: String, port: Int) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            print("[DEBUG] UDP receiver thread started for \(ip):\(port)")
            
            guard let socket = self.socket else {
                print("[ERROR] No UDP socket available")
                return
            }
            
            let fd = CFSocketGetNative(socket)
            
            // Buffer per ricevere i dati
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: self.bufferSize)
            defer { buffer.deallocate() }
            
            // Buffer per accumulare i dati
            var accumulatedData = Data()
            let maxAccumulatedSize = 100_000 // 100KB
            
            // Struttura per l'indirizzo del mittente
            var senderAddr = sockaddr_in()
            var senderAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            
            // Loop di ricezione dati
            self.isPlaying = true
            while self.isPlaying {
                // Leggi i dati dal socket
                let bytesRead = recvfrom(fd, buffer, self.bufferSize, 0, self.sockaddr_cast(&senderAddr), &senderAddrLen)
                if bytesRead <= 0 {
                    if bytesRead < 0 {
                        print("[ERROR] Error reading from UDP socket: \(errno)")
                    }
                    break
                }
                
                // Crea un Data object dai byte ricevuti
                let data = Data(bytes: buffer, count: bytesRead)
                
                // Aggiungi i dati al buffer accumulato
                accumulatedData.append(data)
                
                // Limita la dimensione del buffer accumulato
                if accumulatedData.count > maxAccumulatedSize {
                    // Passa i dati accumulati al decoder
                    self.decoder.queueNalUnit(nalUnit: accumulatedData)
                    // Svuota il buffer
                    accumulatedData = Data()
                } else {
                    // Passa i dati singoli al decoder
                    self.decoder.queueNalUnit(nalUnit: data)
                }
            }
            
            print("[DEBUG] UDP receiver thread stopped")
            self.isPlaying = false
        }
    }
    
    // Helper per convertire tra sockaddr e sockaddr_in
    private func sockaddr_cast(_ p: UnsafeMutablePointer<sockaddr_in>) -> UnsafeMutablePointer<sockaddr> {
        return UnsafeMutableRawPointer(p).assumingMemoryBound(to: sockaddr.self)
    }
    
    // Questo metodo emula esattamente il comportamento di Kotlin
    private func connectLikeKotlin(ip: String, port: Int) -> Bool {
        print("[DEBUG] Connecting like Kotlin to \(ip):\(port)")
        
        // Prima chiudi il socket esistente
        if let socket = socket {
            CFSocketInvalidate(socket)
            self.socket = nil
        }
        
        // Crea un socket BSD standard
        let socketFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        if socketFD == -1 {
            print("[ERROR] Failed to create socket: \(errno)")
            return false
        }
        
        // Imposta l'opzione SO_REUSEADDR
        var yes: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        
        // Imposta l'indirizzo
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        inet_pton(AF_INET, ip, &addr.sin_addr)
        
        // Connetti
        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        
        if connectResult == -1 {
            print("[ERROR] Failed to connect: \(errno)")
            close(socketFD)
            return false
        }
        
        print("[DEBUG] Connected successfully")
        
        // Crea un CFSocket dal socket BSD
        var context = CFSocketContext()
        socket = CFSocketCreateWithNative(kCFAllocatorDefault, socketFD, 0, nil, &context)
        
        if socket == nil {
            print("[ERROR] Failed to create CFSocket from native socket")
            close(socketFD)
            return false
        }
        
        return true
    }
    
    private func isSocketValid() -> Bool {
        guard let socket = socket else { return false }
        
        let fileDescriptor = CFSocketGetNative(socket)
        var error = 0
        var len = socklen_t(MemoryLayout<Int>.size)
        
        let result = getsockopt(fileDescriptor, SOL_SOCKET, SO_ERROR, &error, &len)
        
        if result < 0 || error != 0 {
            print("[DEBUG] Socket is invalid: \(error)")
            return false
        }
        
        return true
    }
}

// Funzione helper per impostare un bit in fd_set
private func __darwin_fd_set(_ fd: Int32, _ set: inout fd_set) {
    // Implementazione manuale di FD_SET
    let intOffset = Int(fd / 32)
    let bitOffset = Int(fd % 32)
    let mask = Int32(1 << bitOffset)
    
    // Accedi direttamente alla memoria della struttura fd_set
    withUnsafeMutableBytes(of: &set) { ptr in
        let basePtr = ptr.baseAddress!.assumingMemoryBound(to: Int32.self)
        basePtr[intOffset] |= mask
    }
}
