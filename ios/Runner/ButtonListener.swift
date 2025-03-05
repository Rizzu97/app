import Foundation
import Network

class ButtonListener {
    private let ip: String
    private let port: Int
    private var isListening: Bool = false
    private var listenerThread: Thread?
    private var socket: Socket?
    private var serverSocket: NWListener?
    
    // Callback per notificare quando il pulsante viene premuto
    var onButtonPressed: (() -> Void)?
    var onButtonReleased: (() -> Void)?
    
    init(ip: String, port: Int = 40004) {
        self.ip = ip
        self.port = port
    }
    
    func startListening() {
        if isListening {
            NSLog("[DEBUG] Button listener already running")
            return
        }
        
        isListening = true
        
        listenerThread = Thread {
            NSLog("[DEBUG] Starting button listener on port \(self.port) in SERVER mode")
            self.listenForConnections()
        }
        
        listenerThread?.start()
    }
    
    private func listenForConnections() {
        let tcpOptions = NWProtocolTCP.Options()
        
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.allowLocalEndpointReuse = true
        
        do {
            serverSocket = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: UInt16(port)))
            
            serverSocket?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    NSLog("[DEBUG] Server socket ready and listening on port \(self.port)")
                case .failed(let error):
                    NSLog("[ERROR] Server socket failed: \(error.localizedDescription)")
                    self.stopListening()
                default:
                    break
                }
            }
            
            serverSocket?.newConnectionHandler = { connection in
                NSLog("[DEBUG] Received connection from \(connection.endpoint)")
                
                // Gestisci la connessione
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        NSLog("[DEBUG] Connection ready")
                        self.handleConnection(connection)
                    case .failed(let error):
                        NSLog("[ERROR] Connection failed: \(error.localizedDescription)")
                        connection.cancel()
                    case .cancelled:
                        NSLog("[DEBUG] Connection cancelled")
                    default:
                        break
                    }
                }
                
                connection.start(queue: .global())
            }
            
            serverSocket?.start(queue: .global())
            
            // Mantieni il thread in esecuzione finché isListening è true
            while isListening {
                Thread.sleep(forTimeInterval: 0.5)
            }
            
        } catch {
            NSLog("[ERROR] Failed to create server socket: \(error.localizedDescription)")
        }
    }
    
    private func handleConnection(_ connection: NWConnection) {
        func receiveNextMessage() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 10) { content, contentContext, isComplete, error in
                if let error = error {
                    NSLog("[ERROR] Error receiving data: \(error.localizedDescription)")
                    return
                }
                
                if let data = content, !data.isEmpty {
                    NSLog("[DEBUG] Received \(data.count) bytes")
                    
                    // Stampa i byte ricevuti per debug
                    let hexString = data.map { String(format: "%02X", $0) }.joined(separator: " ")
                    NSLog("[DEBUG] Received data: \(hexString)")
                    
                    // Analizza il pacchetto - l'ottavo byte (indice 7) indica lo stato del pulsante
                    if data.count >= 8 {
                        let buttonState = Int(data[7])
                        NSLog("[DEBUG] Received button state: \(buttonState)")
                        
                        if buttonState > 0 {
                            NSLog("[DEBUG] Button pressed!")
                            DispatchQueue.main.async {
                                self.onButtonPressed?()
                            }
                        } else {
                            NSLog("[DEBUG] Button released!")
                            DispatchQueue.main.async {
                                self.onButtonReleased?()
                            }
                        }
                    }
                }
                
                if isComplete {
                    NSLog("[DEBUG] Connection completed")
                    return
                }
                
                // Continua a ricevere dati
                if self.isListening {
                    receiveNextMessage()
                }
            }
        }
        
        receiveNextMessage()
    }
    
    func stopListening() {
        isListening = false
        
        serverSocket?.cancel()
        serverSocket = nil
        
        socket?.close()
        socket = nil
        
        listenerThread?.cancel()
        listenerThread = nil
        
        NSLog("[DEBUG] Button listener stopped")
    }
}

// Classe di supporto Socket per la compatibilità
class Socket {
    private var connection: NWConnection?
    
    init(host: String, port: Int) throws {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: UInt16(port)))
        connection = NWConnection(to: endpoint, using: .tcp)
        connection?.start(queue: .global())
    }
    
    func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength: Int) -> Int {
        var result = 0
        
        let semaphore = DispatchSemaphore(value: 0)
        
        connection?.receive(minimumIncompleteLength: 1, maximumLength: maxLength) { data, _, _, error in
            if let data = data, !data.isEmpty {
                data.copyBytes(to: buffer, count: min(data.count, maxLength))
                result = data.count
            } else if let error = error {
                NSLog("[ERROR] Socket read error: \(error.localizedDescription)")
                result = -1
            } else {
                result = 0
            }
            
            semaphore.signal()
        }
        
        _ = semaphore.wait(timeout: .now() + 2)
        return result
    }
    
    func write(_ data: Data) -> Int {
        var result = 0
        
        let semaphore = DispatchSemaphore(value: 0)
        
        connection?.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                NSLog("[ERROR] Socket write error: \(error.localizedDescription)")
                result = -1
            } else {
                result = data.count
            }
            
            semaphore.signal()
        })
        
        _ = semaphore.wait(timeout: .now() + 2)
        return result
    }
    
    func close() {
        connection?.cancel()
        connection = nil
    }
} 
