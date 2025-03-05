import Foundation
import UIKit

class VideoPlayer {
    private weak var decoder: AVCCDecoder?
    private var isPlaying: Bool = false
    private var socket: TCPSocket?
    private var networkThread: Thread?
    private var decoderThread: Thread?
    private var currentFrame: Data?
    private var bufferSize: Int = 4096
    private var ip: String = ""
    private var port: Int = 40005 // Porta standard
    
    // Coda thread-safe per passare i dati tra i thread
    private let dataQueue = DispatchQueue(label: "com.example.a.dataQueue")
    private var nalUnits = [Data]()
    private let maxQueueSize = 100
    
    // Flag per il tipo di protocollo (come in Android)
    private var cameraProtocolType = 0 // 0 = standard, 1 = HTTP, 2 = RTSP, 3 = ONVIF
    
    // Memorizza l'ultimo IP connesso
    static var lastConnectedIp: String?
    
    // Socket server UDP (mantenuto per compatibilità)
    private var videoSocketServer: VideoSocketServer?
    
    init(decoder: AVCCDecoder) {
        self.decoder = decoder
    }
    
    func setBufferSize(_ size: Int) {
        if size > 0 {
            bufferSize = size
            NSLog("[DEBUG] Buffer size set to \(bufferSize) bytes")
        }
    }
    
    func startPlayback(ip: String, port: Int, onFrame: @escaping (Data) -> Void) {
        if isPlaying {
            NSLog("[DEBUG] Playback already in progress")
            return
        }
        
        isPlaying = true
        self.ip = ip
        self.port = port
        VideoPlayer.lastConnectedIp = ip
        
        // Configura il callback per i frame decodificati
        decoder?.onFrameDecoded = onFrame
        
        // Avvia il thread di rete per la connessione TCP
        networkThread = Thread {
            self.connectAndReceive()
        }
        networkThread?.start()
        
        // Avvia il thread del decoder
        decoderThread = Thread {
            self.decodeLoop()
        }
        decoderThread?.start()
        
        NSLog("[DEBUG] Playback started for IP: \(ip) on port: \(port)")
    }
    
    private func connectAndReceive() {
        do {
            // Selezione porta in base al protocollo (come in Android)
            let actualPort: Int
            switch cameraProtocolType {
            case 1: actualPort = 80    // HTTP
            case 2: actualPort = 554   // RTSP
            case 3: actualPort = 80    // ONVIF
            default: actualPort = port  // Standard
            }
            
            NSLog("[DEBUG] Connecting to \(ip):\(actualPort) using protocol type \(cameraProtocolType)")
            
            // Connessione TCP
            socket = try TCPSocket(host: ip, port: actualPort)
            
            // Invia comando di inizializzazione
            if let initCommand = createInitCommand() {
                let _ = socket?.write(initCommand)
                NSLog("[DEBUG] Initialization command sent")
                
                // Breve attesa dopo l'invio del comando
                Thread.sleep(forTimeInterval: 1.0)
            }
            
            // Buffer per ricevere i dati
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            let nalBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1000000)
            var nalBufferPosition = 0
            
            // Loop di lettura
            while isPlaying {
                guard let socket = socket else { break }
                
                let bytesRead = socket.read(&buffer, maxLength: buffer.count)
                if bytesRead <= 0 {
                    if bytesRead < 0 {
                        NSLog("[ERROR] Socket error: \(errno)")
                    }
                    break
                }
                
                // Elabora i dati ricevuti cercando unità NAL
                processVideoData(Data(bytes: buffer, count: bytesRead), nalBuffer: nalBuffer, nalBufferPosition: &nalBufferPosition)
            }
            
            nalBuffer.deallocate()
            
        } catch {
            NSLog("[ERROR] Network error: \(error.localizedDescription)")
        }
        
        isPlaying = false
        NSLog("[DEBUG] Network thread stopped")
    }
    
    private func processVideoData(_ data: Data, nalBuffer: UnsafeMutablePointer<UInt8>, nalBufferPosition: inout Int) {
        var pos = 0
        var currentNalPos = nalBufferPosition
        
        // Cerca le unità NAL nel buffer (stessa logica di Android)
        while pos < data.count {
            // Cerca il codice di inizio NAL (0x00 0x00 0x00 0x01)
            if pos >= 3 && 
               data[pos-3] == 0 && 
               data[pos-2] == 0 && 
               data[pos-1] == 0 && 
               data[pos] == 1 {
                
                // Abbiamo trovato l'inizio di un nuovo NAL
                if currentNalPos > 4 {  // Se abbiamo già un NAL in corso (escludendo il codice di inizio)
                    // Invia il NAL precedente al decoder
                    let nalUnit = Data(bytes: nalBuffer, count: currentNalPos)
                    
                    dataQueue.sync {
                        nalUnits.append(nalUnit)
                        if nalUnits.count > maxQueueSize {
                            nalUnits.removeFirst()
                        }
                    }
                }
                
                // Inizia un nuovo NAL
                currentNalPos = 0
                
                // Aggiungi il codice di inizio NAL al buffer
                nalBuffer[currentNalPos] = 0
                currentNalPos += 1
                nalBuffer[currentNalPos] = 0
                currentNalPos += 1
                nalBuffer[currentNalPos] = 0
                currentNalPos += 1
                nalBuffer[currentNalPos] = 1
                currentNalPos += 1
                pos += 1
                continue
            }
            
            // Aggiungi il byte corrente al buffer NAL
            if currentNalPos < 1000000 {
                nalBuffer[currentNalPos] = data[pos]
                currentNalPos += 1
            } else {
                NSLog("[WARN] NAL buffer overflow, discarding data")
            }
            pos += 1
        }
        
        nalBufferPosition = currentNalPos
    }
    
    private func decodeLoop() {
        while isPlaying {
            var nalUnit: Data?
            
            // Preleva un NAL dalla coda
            dataQueue.sync {
                if !nalUnits.isEmpty {
                    nalUnit = nalUnits.removeFirst()
                }
            }
            
            if let nal = nalUnit {
                decoder?.queueNalUnit(nal)
            } else {
                // Attendi un po' se non ci sono dati
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        
        NSLog("[DEBUG] Decoder thread stopped")
    }
    
    private func createInitCommand() -> Data? {
        switch cameraProtocolType {
        case 0:  // Standard (come in Android)
            let calendar = Calendar.current
            let now = Date()
            let year = UInt8(calendar.component(.year, from: now) - 2000)
            let month = UInt8(calendar.component(.month, from: now))
            let day = UInt8(calendar.component(.day, from: now))
            let hour = UInt8(calendar.component(.hour, from: now))
            let minute = UInt8(calendar.component(.minute, from: now))
            let second = UInt8(calendar.component(.second, from: now))
            
            return Data([
                0x5f, 0x6f,  // Magic number
                0x00, 0x00,  // Reserved
                year, month, day, hour, minute, second,
                11,  // Fixed value
                0    // Reserved
            ])
            
        case 1:  // HTTP
            // Implementazione HTTP simile ad Android
            let httpRequest = "GET /videostream.cgi?user=admin&pwd=admin HTTP/1.1\r\n" +
                             "Host: \(ip)\r\n" +
                             "Connection: keep-alive\r\n\r\n"
            return httpRequest.data(using: .utf8)
            
        default:
            return nil
        }
    }
    
    func stopPlayback() {
        isPlaying = false
        
        // Chiudi il socket
        socket?.closeSocket()
        socket = nil
        
        // Arresta il server UDP se attivo
        videoSocketServer?.stop()
        videoSocketServer = nil
        
        // Attendi che i thread terminino
        networkThread?.cancel()
        decoderThread?.cancel()
        
        networkThread = nil
        decoderThread = nil
        
        // Svuota la coda
        dataQueue.sync {
            nalUnits.removeAll()
        }
    }
    
    func captureCurrentFrame() -> Data? {
        return decoder?.getCurrentFrame()
    }
    
    func takePicture(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global().async {
            guard let decoder = self.decoder else {
                completion(false)
                return
            }
            
            if let lastFrame = decoder.getCurrentFrame() {
                do {
                    let timestamp = Int(Date().timeIntervalSince1970)
                    let imagePath = NSTemporaryDirectory().appending("frame_\(timestamp).jpg")
                    try ImageSaver.saveImage(data: lastFrame, path: imagePath)
                    
                    ImageSaver.saveImageToPhotosAlbum(data: lastFrame) { success, error in
                        if !success {
                            NSLog("[ERROR] Failed to save image to Photos: \(error?.localizedDescription ?? "unknown error")")
                        }
                    }
                    
                    NSLog("[DEBUG] Picture taken and saved successfully")
                    completion(true)
                } catch {
                    NSLog("[ERROR] Failed to save picture: \(error.localizedDescription)")
                    completion(false)
                }
            } else {
                NSLog("[WARN] No valid frame available to capture")
                completion(false)
            }
        }
    }
    
    private func requestKeyframe() {
        // Formato come in Android
        let commandData: [UInt8] = [
            0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 
            0x00, 0x00, 0x00, 0x01, 0x01, 0x00
        ]
        
        let _ = socket?.write(Data(commandData))
        NSLog("[INFO] Keyframe request sent")
    }
    
    func connect(toHost host: String, port: UInt16 = 40005) {
        // Per compatibilità con codice esistente - ora usa startPlayback
        self.ip = host
        self.port = Int(port)
        VideoPlayer.lastConnectedIp = host
    }
    
    func dispose() {
        stopPlayback()
        decoder?.onFrameDecoded = nil
    }
    
    func tryAlternativeProtocol() {
        cameraProtocolType = (cameraProtocolType + 1) % 4
        NSLog("[DEBUG] Switching to camera protocol type: \(cameraProtocolType)")
    }
} 