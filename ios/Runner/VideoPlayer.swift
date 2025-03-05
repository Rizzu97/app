import Foundation
import UIKit

class VideoPlayer {
    private weak var decoder: VideoDecoder?
    private var isPlaying: Bool = false
    private var socketFd: Int32 = -1
    private var networkThread: Thread?
    private var decoderThread: Thread?
    private var currentFrame: Data?
    private var bufferSize: Int = 4096
    private var ip: String = ""
    
    // Coda thread-safe per passare i dati tra i thread
    private let dataQueue = DispatchQueue(label: "com.example.a.dataQueue")
    private var nalUnits = [Data]()
    private let maxQueueSize = 100
    
    // Aggiungi queste costanti all'inizio della classe
    private let NAL_TYPE_SPS = 7
    private let NAL_TYPE_PPS = 8
    private let NAL_TYPE_IDR = 5  // Frame chiave (I-frame)
    private let NAL_TYPE_NON_IDR = 1  // Frame normale (P-frame)
    private var haveSPS = false
    private var havePPS = false
    
    init(decoder: VideoDecoder) {
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
            NSLog("[DEBUG] Playback already in progress, ignoring request")
            return
        }
        
        isPlaying = true
        self.ip = ip
        
        // Imposta il callback
        decoder?.onFrameDecoded = { jpegData in
            self.currentFrame = jpegData
            onFrame(jpegData)
        }
        
        // Avvia thread decodifica
        decoderThread = Thread {
            NSLog("[DEBUG] Decoder thread started")
            while self.isPlaying {
                var nalUnit: Data?
                self.dataQueue.sync {
                    if !self.nalUnits.isEmpty {
                        nalUnit = self.nalUnits.removeFirst()
                    }
                }
                
                if let nalData = nalUnit {
                    self.decoder?.queueNalUnit(nalData)
                } else {
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
            NSLog("[DEBUG] Decoder thread stopped")
        }
        
        decoderThread?.start()
        
        // Thread per la connessione e lettura dati
        networkThread = Thread {
            // 1. Crea il socket esattamente come nel server.js
            self.socketFd = socket(AF_INET, SOCK_STREAM, 0)
            if self.socketFd == -1 {
                NSLog("[ERROR] Failed to create socket: \(String(cString: strerror(errno)))")
                self.isPlaying = false
                return
            }
            
            // 2. Configura indirizzo
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(port).bigEndian
            addr.sin_addr.s_addr = inet_addr(ip)
            
            // 3. Connessione
            let connectResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(self.socketFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            
            if connectResult == -1 {
                NSLog("[ERROR] Connect failed: \(String(cString: strerror(errno)))")
                self.isPlaying = false
                close(self.socketFd)
                return
            }
            
            NSLog("[DEBUG] Connected to \(ip):\(port)")
            
            // 4. Invia comando di inizializzazione (esattamente come nel JS)
            let command = self.createStartCommand()
            var bytesSent = 0
            command.withUnsafeBytes { buffer in
                bytesSent = send(self.socketFd, buffer.baseAddress, command.count, 0)
            }
            
            if bytesSent <= 0 {
                NSLog("[ERROR] Failed to send init command: \(String(cString: strerror(errno)))")
                self.isPlaying = false
                close(self.socketFd)
                return
            }
            
            NSLog("[DEBUG] Sent init command, \(bytesSent) bytes")
            
            // 5. Leggi risposta e stream video
            var buffer = [UInt8](repeating: 0, count: self.bufferSize)
            var nalBuffer = [UInt8](repeating: 0, count: 1000000)
            var nalPos = 0
            var foundNalStart = false
            
            while self.isPlaying {
                let bytesRead = recv(self.socketFd, &buffer, self.bufferSize, 0)
                if bytesRead <= 0 {
                    if bytesRead < 0 {
                        NSLog("[ERROR] Read error: \(String(cString: strerror(errno)))")
                    } else {
                        NSLog("[DEBUG] Connection closed by peer")
                    }
                    break
                }
                
                NSLog("[DEBUG] Read \(bytesRead) bytes")
                
                // 6. Cerca i NAL units (esattamente come nel nostro readStandardVideoStream)
                for i in 0..<bytesRead {
                    // Cerca il marcatore NAL a 4 byte: 0x00 0x00 0x00 0x01
                    if i >= 3 && buffer[i-3] == 0 && buffer[i-2] == 0 && buffer[i-1] == 0 && buffer[i] == 1 {
                        if foundNalStart && nalPos > 4 {
                            let nalData = Data(bytes: nalBuffer, count: nalPos)
                            self.enqueueNalUnit(nalData)
                        }
                        
                        nalPos = 0
                        foundNalStart = true
                        
                        // Aggiungi codice di inizio NAL
                        nalBuffer[nalPos] = 0
                        nalPos += 1
                        nalBuffer[nalPos] = 0
                        nalPos += 1
                        nalBuffer[nalPos] = 0
                        nalPos += 1
                        nalBuffer[nalPos] = 1
                        nalPos += 1
                    }
                    // Cerca anche il marcatore NAL a 3 byte: 0x00 0x00 0x01
                    else if i >= 2 && buffer[i-2] == 0 && buffer[i-1] == 0 && buffer[i] == 1 {
                        if foundNalStart && nalPos > 3 {
                            let nalData = Data(bytes: nalBuffer, count: nalPos)
                            self.enqueueNalUnit(nalData)
                        }
                        
                        nalPos = 0
                        foundNalStart = true
                        
                        // Aggiungi codice di inizio NAL
                        nalBuffer[nalPos] = 0
                        nalPos += 1
                        nalBuffer[nalPos] = 0
                        nalPos += 1
                        nalBuffer[nalPos] = 1
                        nalPos += 1
                    }
                    
                    if foundNalStart && nalPos < nalBuffer.count {
                        nalBuffer[nalPos] = buffer[i]
                        nalPos += 1
                    }
                }
                
                // Alla fine del ciclo, considera l'ultimo NAL se non completato
                if foundNalStart && nalPos > 4 {
                    let nalData = Data(bytes: nalBuffer, count: nalPos)
                    self.enqueueNalUnit(nalData)
                }
            }
            
            close(self.socketFd)
            self.socketFd = -1
            self.isPlaying = false
        }
        
        networkThread?.start()
    }
    
    private func createStartCommand() -> Data {
        let calendar = Calendar.current
        let now = Date()
        
        var command = Data(count: 12)
        command[0] = 0x5f
        command[1] = 0x6f
        command[2] = 0
        command[3] = 0
        command[4] = UInt8(calendar.component(.year, from: now) - 2000)
        command[5] = UInt8(calendar.component(.month, from: now))
        command[6] = UInt8(calendar.component(.day, from: now))
        command[7] = UInt8(calendar.component(.hour, from: now))
        command[8] = UInt8(calendar.component(.minute, from: now))
        command[9] = UInt8(calendar.component(.second, from: now))
        command[10] = 11
        command[11] = 0
        
        return command
    }
    
    private func enqueueNalUnit(_ nalUnit: Data) {
        // Verifica che il NAL unit sia valido
        guard nalUnit.count > 4 else {
            NSLog("[WARN] Ignoring too small NAL unit (\(nalUnit.count) bytes)")
            return
        }
        
        // Estrai il tipo di NAL unit (si trova nel 5° byte, bit 0-4)
        let nalType = (nalUnit[4] & 0x1F)
        
        NSLog("[DEBUG] Found NAL unit type \(nalType) with size \(nalUnit.count) bytes")
        
        // Gestione speciale per SPS e PPS che sono necessari per inizializzare il decoder
        if nalType == NAL_TYPE_SPS {
            NSLog("[INFO] 🟢 Found SPS NAL unit")
            haveSPS = true
        } else if nalType == NAL_TYPE_PPS {
            NSLog("[INFO] 🟢 Found PPS NAL unit")
            havePPS = true
        } else if nalType == NAL_TYPE_IDR {
            NSLog("[DEBUG] Found IDR frame (keyframe)")
        }
        
        // Invia i NAL units al decoder solo se abbiamo ricevuto SPS e PPS
        // oppure se è un NAL di tipo SPS o PPS
        if haveSPS && havePPS || nalType == NAL_TYPE_SPS || nalType == NAL_TYPE_PPS {
            dataQueue.sync {
                if nalUnits.count < maxQueueSize {
                    nalUnits.append(nalUnit)
                } else if !nalUnits.isEmpty {
                    nalUnits.removeFirst()
                    nalUnits.append(nalUnit)
                }
            }
        } else {
            NSLog("[DEBUG] Waiting for SPS and PPS before queueing regular NAL units")
        }
    }
    
    func stopPlayback() {
        isPlaying = false
        
        if socketFd != -1 {
            close(socketFd)
            socketFd = -1
        }
        
        dataQueue.sync {
            nalUnits.removeAll()
        }
    }
    
    func dispose() {
        stopPlayback()
        decoder?.onFrameDecoded = nil
    }
    
    func captureCurrentFrame() -> Data? {
        NSLog("[DEBUG] Capturing current frame")
        
        // Se abbiamo già un frame in memoria, lo restituiamo direttamente
        if let currentFrame = currentFrame {
            NSLog("[DEBUG] Returning cached frame, size: \(currentFrame.count) bytes")
            return currentFrame
        }
        
        // Altrimenti aspettiamo brevemente per un nuovo frame
        NSLog("[DEBUG] No cached frame available, waiting for next frame")
        
        // Creiamo un semaforo per attendere il prossimo frame
        let semaphore = DispatchSemaphore(value: 0)
        var capturedFrame: Data? = nil
        
        // Sostituisci temporaneamente il callback di decodifica
        let originalCallback = decoder?.onFrameDecoded
        
        // Imposta un nuovo callback che salva il frame e segnala il semaforo
        decoder?.onFrameDecoded = { jpegData in
            // Chiamiamo comunque il callback originale
            originalCallback?(jpegData)
            
            // Salviamo il frame catturato
            capturedFrame = jpegData
            
            // Segnaliamo il semaforo
            semaphore.signal()
        }
        
        // Attendi fino a 1 secondo per un nuovo frame
        let result = semaphore.wait(timeout: .now() + 1.0)
        
        // Ripristina il callback originale
        decoder?.onFrameDecoded = originalCallback
        
        if result == .timedOut {
            NSLog("[WARN] Capture timed out, no new frame received")
            // In caso di timeout, restituisci comunque l'ultimo frame se disponibile
            return currentFrame
        }
        
        NSLog("[DEBUG] Frame captured successfully, size: \(capturedFrame?.count ?? 0) bytes")
        return capturedFrame
    }
} 