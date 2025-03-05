import Foundation
import UIKit
import FFmpegKit

class FFmpegDecoder {
    // Callback per i frame decodificati
    var onFrameDecoded: ((Data) -> Void)?
    
    // Dimensioni del video
    private var width: Int32 = 1280
    private var height: Int32 = 720
    
    // Percorsi dei file temporanei
    private let tempH264Path: String
    private let tempJpegPath: String
    
    // Contatore per il salvataggio di file unici
    private var frameCounter = 0
    
    // Flag per indicare se FFmpeg è occupato
    private var isProcessing = false
    
    // Coda di NAL units in attesa di elaborazione
    private var nalQueue = [Data]()
    private let nalQueueLock = DispatchQueue(label: "com.example.a.nalQueueLock")
    
    // Timer per la decodifica periodica
    private var decodeTimer: Timer?
    
    init() {
        // Crea directory temporanea per i file
        let tempDir = NSTemporaryDirectory()
        tempH264Path = tempDir.appending("frame.h264")
        tempJpegPath = tempDir.appending("output.jpg")
        
        // Avvia timer per decodifica periodica
        startDecodeTimer()
    }
    
    private func startDecodeTimer() {
        decodeTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.processNextFrame()
        }
    }
    
    func setDimensions(width: Int32, height: Int32) {
        self.width = width
        self.height = height
    }
    
    func queueNalUnit(_ nalUnit: Data) {
        nalQueueLock.sync {
            nalQueue.append(nalUnit)
            // Limita la dimensione della coda
            if nalQueue.count > 30 {
                nalQueue.removeFirst()
            }
        }
    }
    
    private func processNextFrame() {
        // Evita elaborazioni simultanee
        if isProcessing {
            return
        }
        
        // Ottieni il prossimo NAL unit dalla coda
        var nalData: Data?
        nalQueueLock.sync {
            if !nalQueue.isEmpty {
                nalData = nalQueue.removeFirst()
            }
        }
        
        guard let data = nalData else {
            return
        }
        
        isProcessing = true
        
        // Elabora il frame in un thread separato
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // Crea un file temporaneo univoco per questo frame
            let frameIndex = self.frameCounter
            self.frameCounter += 1
            
            let inputPath = self.tempH264Path.replacingOccurrences(of: ".h264", with: "\(frameIndex).h264")
            let outputPath = self.tempJpegPath.replacingOccurrences(of: ".jpg", with: "\(frameIndex).jpg")
            
            // Salva il NAL unit in un file
            try? data.write(to: URL(fileURLWithPath: inputPath))
            
            // Costruisci il comando FFmpeg
            // -i: file di input
            // -frames:v 1: elabora solo un frame
            // -c:v mjpeg: usa codec JPEG per output
            // -q:v 2: qualità alta (1-31, dove 1 è la migliore)
            // -y: sovrascrivi output senza chiedere
            let command = "-i \(inputPath) -frames:v 1 -c:v mjpeg -q:v 2 -y \(outputPath)"
            
            // Esegui FFmpeg
            NSLog("[FFMPEG] Esecuzione comando: \(command)")
            let session = FFmpegKit.execute(command)
            let returnCode = session.getReturnCode()
            
            if ReturnCode.isSuccess(returnCode) {
                NSLog("[FFMPEG] Decodifica riuscita per frame \(frameIndex)")
                
                // Leggi l'immagine risultante
                if let imageData = try? Data(contentsOf: URL(fileURLWithPath: outputPath)) {
                    // Callback con l'immagine decodificata
                    DispatchQueue.main.async {
                        self.onFrameDecoded?(imageData)
                    }
                } else {
                    NSLog("[FFMPEG] Errore lettura output JPEG")
                }
            } else {
                NSLog("[FFMPEG] Errore decodifica: \(returnCode)")
            }
            
            // Pulizia
            try? FileManager.default.removeItem(atPath: inputPath)
            try? FileManager.default.removeItem(atPath: outputPath)
            
            self.isProcessing = false
        }
    }
    
    func startPreviewMode() {
        // Implementazione del modo anteprima come nel decoder originale
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            if let previewImage = self.createPreviewImage() {
                DispatchQueue.main.async {
                    self.onFrameDecoded?(previewImage)
                }
            }
        }
        
        // Memorizza il timer per riferimento futuro
        decodeTimer = timer
    }
    
    private func createPreviewImage() -> Data? {
        let size = CGSize(width: CGFloat(width), height: CGFloat(height))
        UIGraphicsBeginImageContextWithOptions(size, true, 1.0)
        defer { UIGraphicsEndImageContext() }
        
        let context = UIGraphicsGetCurrentContext()!
        
        // Sfondo nero
        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        
        // Griglia visiva
        context.setStrokeColor(UIColor(white: 0.3, alpha: 1.0).cgColor)
        context.setLineWidth(1.0)
        
        let gridSize: CGFloat = 30
        for x in stride(from: 0, to: size.width, by: gridSize) {
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: size.height))
        }
        
        for y in stride(from: 0, to: size.height, by: gridSize) {
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: size.width, y: y))
        }
        
        context.strokePath()
        
        // Testo informativo
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 24),
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraphStyle
        ]
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss"
        let timeString = dateFormatter.string(from: Date())
        
        let titleRect = CGRect(x: 0, y: size.height/2 - 60, width: size.width, height: 40)
        NSString(string: "FFmpeg Preview").draw(in: titleRect, withAttributes: attributes)
        
        let timeRect = CGRect(x: 0, y: size.height/2, width: size.width, height: 40)
        NSString(string: timeString).draw(in: timeRect, withAttributes: attributes)
        
        let infoRect = CGRect(x: 0, y: size.height/2 + 60, width: size.width, height: 40)
        NSString(string: "Resolution: \(width)x\(height)").draw(in: infoRect, withAttributes: attributes)
        
        let ipRect = CGRect(x: 0, y: size.height - 50, width: size.width, height: 30)
        let smallAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 16),
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraphStyle
        ]
        NSString(string: "Connected to: \(VideoPlayer.lastConnectedIp ?? "unknown")").draw(in: ipRect, withAttributes: smallAttributes)
        
        let image = UIGraphicsGetImageFromCurrentImageContext()!
        return image.jpegData(compressionQuality: 0.8)
    }
    
    func dispose() {
        decodeTimer?.invalidate()
        decodeTimer = nil
    }
} 