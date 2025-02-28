import Foundation

class ButtonListener {
    private let ip: String
    private let port: Int
    private var serverSocket: CFSocket?
    private var isListening = false
    private var listenerThread: Thread?
    
    // Callback per notificare quando il pulsante viene premuto
    var onButtonPressed: (() -> Void)?
    var onButtonReleased: (() -> Void)?
    
    init(ip: String, port: Int = 40004) {
        self.ip = ip
        self.port = port
    }
    
    func startListening() {
        if isListening {
            print("[DEBUG] Button listener already running")
            return
        }
        
        isListening = true
        
        listenerThread = Thread {
            print("[DEBUG] Starting button listener on port \(self.port) in SERVER mode")
            self.listenForConnections()
        }
        
        listenerThread?.start()
    }
    
    private func listenForConnections() {
        // Crea un socket server
        var context = CFSocketContext()
        context.version = 0
        context.info = Unmanaged.passRetained(self).toOpaque()
        
        // Callback per le connessioni in entrata
        let callback: CFSocketCallBack = { socket, callbackType, address, data, info in
            guard let info = info else { return }
            let listener = Unmanaged<ButtonListener>.fromOpaque(info).takeUnretainedValue()
            
            if callbackType == .acceptCallBack {
                print("[DEBUG] Received connection")
                if let socketData = data, 
                   let nativeSocket = socketData.assumingMemoryBound(to: CFSocketNativeHandle.self).pointee as CFSocketNativeHandle? {
                    listener.handleConnection(socket: nativeSocket)
                }
            }
        }
        
        // Crea il socket server
        serverSocket = CFSocketCreate(kCFAllocatorDefault,
                                     PF_INET,
                                     SOCK_STREAM,
                                     IPPROTO_TCP,
                                     CFSocketCallBackType.acceptCallBack.rawValue,
                                     callback,
                                     &context)
        
        guard let serverSocket = serverSocket else {
            print("[ERROR] Failed to create server socket")
            isListening = false
            return
        }
        
        // Imposta le opzioni del socket
        var reuse = 1
        let fileDescriptor = CFSocketGetNative(serverSocket)
        setsockopt(fileDescriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int>.size))
        
        // Crea l'indirizzo del socket
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        
        let addrData = Data(bytes: &addr, count: MemoryLayout<sockaddr_in>.size)
        
        // Associa il socket all'indirizzo
        if CFSocketSetAddress(serverSocket, addrData as CFData) != .success {
            print("[ERROR] Failed to bind socket to address")
            CFSocketInvalidate(serverSocket)
            isListening = false
            return
        }
        
        print("[DEBUG] Server socket created and bound to port \(port)")
        
        // Crea un run loop source per il socket
        let runLoopSource = CFSocketCreateRunLoopSource(kCFAllocatorDefault, serverSocket, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        
        // Mantieni il thread in esecuzione
        while isListening {
            CFRunLoopRunInMode(.defaultMode, 1, false)
        }
        
        // Pulisci quando termina
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CFSocketInvalidate(serverSocket)
        print("[DEBUG] Button listener stopped")
    }
    
    private func handleConnection(socket: CFSocketNativeHandle) {
        print("[DEBUG] Handling connection from client")
        
        // Crea un file handle per il socket
        let fileHandle = FileHandle(fileDescriptor: socket, closeOnDealloc: true)
        
        // Thread per leggere i dati dal socket
        DispatchQueue.global(qos: .background).async {
            while self.isListening {
                autoreleasepool {
                    // Leggi i dati dal socket
                    let data = fileHandle.readData(ofLength: 10)
                    if data.count == 0 {
                        print("[DEBUG] End of stream reached")
                        return
                    }
                    
                    print("[DEBUG] Received \(data.count) bytes")
                    
                    // Stampa i byte ricevuti per debug
                    let hexString = data.map { String(format: "%02X", $0) }.joined(separator: " ")
                    print("[DEBUG] Received data: \(hexString)")
                    
                    // Analizza il pacchetto - l'ottavo byte (indice 7) indica lo stato del pulsante
                    if data.count >= 8 {
                        let buttonState = Int(data[7])
                        print("[DEBUG] Received button state: \(buttonState)")
                        
                        if buttonState > 0 {
                            print("[DEBUG] Button pressed!")
                            DispatchQueue.main.async {
                                self.onButtonPressed?()
                            }
                        } else {
                            print("[DEBUG] Button released!")
                            DispatchQueue.main.async {
                                self.onButtonReleased?()
                            }
                        }
                    }
                }
            }
            
            // Chiudi il file handle quando termina
            #if os(iOS) && compiler(>=5.1)
                if #available(iOS 13.0, *) {
                    try? fileHandle.close()
                } else {
                    fileHandle.closeFile()
                }
            #else
                fileHandle.closeFile()
            #endif
        }
    }
    
    func stopListening() {
        print("[DEBUG] Stopping button listener")
        isListening = false
        
        // Il thread terminerà automaticamente quando isListening diventa false
        listenerThread = nil
    }
    
    deinit {
        stopListening()
    }
} 