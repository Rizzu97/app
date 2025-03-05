import Foundation
import AVFoundation
import VideoToolbox
import UIKit

class VideoDecoder {
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var width: Int32 = 1920
    private var height: Int32 = 1080
    private var isInitialized: Bool = false
    private var frameCounter: Int = 0
    
    // Coda per le unità NAL
    private let nalQueue = DispatchQueue(label: "com.example.a.nalQueue")
    private var nalBuffer = [Data]()
    private let maxNalQueueSize = 50
    
    // Thread per la decodifica
    private var decoderThread: Thread?
    private var isRunning: Bool = false
    
    // Output view
    private weak var outputView: UIView?
    private var outputLayer: AVSampleBufferDisplayLayer?
    
    // Callback per i frame decodificati
    var onFrameDecoded: ((Data) -> Void)?
    
    var receivedKeyframe = false
    
    // Aggiungi queste variabili
    private var accumulatedNALs = [Data]()
    private var canStartDecoding = false
    
    // Aggiungi questo metodo all'inizio della classe
    private var shouldCreatePreviewFrames = true
    private var frameGenerationTimer: Timer?
    
    init(outputView: UIView?) {
        self.outputView = outputView
        setupOutputLayer()
    }
    
    private func setupOutputLayer() {
        guard let outputView = outputView else { return }
        
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.frame = outputView.bounds
        
        DispatchQueue.main.async {
            outputView.layer.addSublayer(layer)
            self.outputLayer = layer
        }
    }
    
    func initialize(width: Int32, height: Int32) -> Bool {
        NSLog("[DEBUG] Initializing decoder with width: \(width), height: \(height)")
        
        self.width = width
        self.height = height
        
        do {
            try setupDecompressionSession()
            isInitialized = true
            startDecoderThread()
            return true
        } catch {
            NSLog("[ERROR] Error initializing decoder: \(error.localizedDescription)")
            return false
        }
    }
    
    private func setupDecompressionSession() throws {
        // Crea configurazione di base se non abbiamo un format description
        if formatDescription == nil {
            // Crea un CMVideoFormatDescription di default per H.264
            let dimensions = CMVideoDimensions(width: width, height: height)
            var formatDescriptionOut: CMFormatDescription?
            
            // Crea un dictionary con la configurazione minima
            let extensions = [
                kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
                kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
                kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2
            ]
            
            let status = CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                codecType: kCMVideoCodecType_H264,
                width: width,
                height: height,
                extensions: extensions as CFDictionary,
                formatDescriptionOut: &formatDescriptionOut
            )
            
            if status == noErr {
                formatDescription = formatDescriptionOut
            } else {
                NSLog("[WARN] Impossibile creare format description, errore: \(status)")
            }
        }
        
        guard let formatDesc = formatDescription else {
            return
        }
        
        // Configurazione alternativa del decompressore VideoToolbox
        let decoderParameters = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferOpenGLCompatibilityKey: true,
            "EnableHardwareAcceleratedVideoDecoder": true,
            "RequireHardwareAcceleratedVideoDecoder": true,
            "AllowFrameReordering": false
        ] as CFDictionary
        
        // Configura per ignorare i problemi di conformità degli stream H.264
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { (decompressionOutputRefCon, sourceFrameRefCon, status, infoFlags, imageBuffer, presentationTimeStamp, duration) in
                if let context = decompressionOutputRefCon {
                    let decoder = Unmanaged<VideoDecoder>.fromOpaque(context).takeUnretainedValue()
                    decoder.handleDecodedFrame(status: status, imageBuffer: imageBuffer)
                }
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        
        // Crea la sessione di decompressione
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            decoderSpecification: nil,
            imageBufferAttributes: decoderParameters,
            outputCallback: &callback,
            decompressionSessionOut: &session
        )
        
        if status != noErr {
            NSLog("[ERROR] Failed to create decompression session: \(status)")
            throw NSError(domain: "VideoDecoder", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to create decompression session"])
        }
        
        decompressionSession = session
        NSLog("[DEBUG] Decompression session created successfully")
    }
    
    private func startDecoderThread() {
        isRunning = true
        
        decoderThread = Thread {
            NSLog("[DEBUG] Decoder thread started")
            
            while self.isRunning {
                autoreleasepool {
                    var nalUnit: Data?
                    
                    // Prelevare un'unità NAL dalla coda
                    self.nalQueue.sync {
                        if !self.nalBuffer.isEmpty {
                            nalUnit = self.nalBuffer.removeFirst()
                        }
                    }
                    
                    if let nalData = nalUnit {
                        self.decodeNalUnit(nalData)
                    } else {
                        // Attendi un po' se non ci sono dati
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                }
            }
            
            NSLog("[DEBUG] Decoder thread stopped")
        }
        
        decoderThread?.start()
    }
    
    func queueNalUnit(_ nalUnit: Data) {
        guard isInitialized else {
            NSLog("[ERROR] Decoder not initialized")
            return
        }
        
        nalQueue.sync {
            if nalBuffer.count < maxNalQueueSize {
                nalBuffer.append(nalUnit)
            } else {
                NSLog("[WARN] Decoder queue full, dropping NAL unit")
                // Rimuovere il più vecchio
                nalBuffer.removeFirst()
                nalBuffer.append(nalUnit)
            }
        }
    }
    
    private func decodeNalUnit(_ nalUnit: Data) {
        // Extract the NAL unit type
        let nalType = nalUnit.count > 4 ? Int(nalUnit[4] & 0x1F) : -1
        
        // Log the NAL unit type and length
        NSLog("[DEBUG] Attempting to decode NAL type \(nalType), length \(nalUnit.count)")
        
        // If it's an SPS, update the format description
        if nalType == 7 {
            do {
                try createFormatDescriptionFromSPS(nalUnit)
                resetDecompressionSession()
            } catch {
                NSLog("[ERROR] Error creating format description: \(error)")
            }
            return
        }
        
        // If we don't have a valid format description, skip
        guard let formatDescription = formatDescription,
              let session = decompressionSession else {
            return
        }
        
        // Create blockBuffer
        var blockBuffer: CMBlockBuffer?
        let status1 = nalUnit.withUnsafeBytes { (bufferPtr) -> OSStatus in
            return CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: nalUnit.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: nalUnit.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }
        
        if status1 != noErr {
            NSLog("[ERROR] Failed to create block buffer: \(status1)")
            return
        }
        
        // Copy data into blockBuffer
        nalUnit.withUnsafeBytes { (bufferPtr) -> Void in
            let status2 = CMBlockBufferReplaceDataBytes(
                with: bufferPtr.baseAddress!,
                blockBuffer: blockBuffer!,
                offsetIntoDestination: 0,
                dataLength: nalUnit.count
            )
            if status2 != noErr {
                NSLog("[ERROR] Failed to copy data to block buffer: \(status2)")
            }
        }
        
        // Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = nalUnit.count
        let status3 = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        
        if status3 != noErr {
            NSLog("[ERROR] Failed to create sample buffer: \(status3)")
            return
        }
        
        // Decode the frame
        let flagsOut = UnsafeMutablePointer<VTDecodeInfoFlags>.allocate(capacity: 1)
        flagsOut.initialize(to: VTDecodeInfoFlags())
        
        let status4 = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer!,
            flags: [._EnableAsynchronousDecompression],
            frameRefcon: nil,
            infoFlagsOut: flagsOut
        )
        
        if status4 != noErr {
            NSLog("[ERROR] Failed to decode frame: \(status4) (\(String(describing: (status4 as OSStatus).description)))")
        }
        
        flagsOut.deallocate()
    }
    
    private func handleDecodedFrame(status: OSStatus, imageBuffer: CVImageBuffer?) {
        guard status == noErr else {
            NSLog("[ERROR] Error decoding frame, status: \(status) (\(String(describing: (status as OSStatus).description)))")
            return
        }
        
        guard let imageBuffer = imageBuffer else {
            NSLog("[ERROR] ImageBuffer è nil dopo la decodifica")
            return
        }
        
        // Log delle informazioni sul buffer decodificato
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        let format = CVPixelBufferGetPixelFormatType(imageBuffer)
        NSLog("[DEBUG] Frame decodificato con successo: \(width)x\(height), formato: \(format)")
        
        // Convertire il CVImageBuffer in UIImage e quindi in Data
        if let jpegData = createJPEGFromImageBuffer(imageBuffer) {
            NSLog("[DEBUG] JPEG creato con successo, dimensione: \(jpegData.count) bytes")
            
            // Inviare i dati attraverso il callback
            DispatchQueue.main.async {
                self.onFrameDecoded?(jpegData)
            }
            
            // Se c'è un layer di output, aggiornarlo
            if let outputLayer = outputLayer, let formatDescription = formatDescription {
                do {
                    let sampleBuffer = try createSampleBufferFrom(imageBuffer: imageBuffer, formatDescription: formatDescription)
                    DispatchQueue.main.async {
                        outputLayer.enqueue(sampleBuffer)
                    }
                } catch {
                    NSLog("[ERROR] Failed to create sample buffer for display: \(error.localizedDescription)")
                }
            }
        } else {
            NSLog("[ERROR] Errore nella creazione del JPEG dal frame decodificato")
        }
    }
    
    private func createJPEGFromImageBuffer(_ imageBuffer: CVImageBuffer) -> Data? {
        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }
        
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        let baseAddress = CVPixelBufferGetBaseAddress(imageBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            NSLog("[ERROR] Failed to create CGContext")
            return createErrorImage()
        }
        
        guard let cgImage = context.makeImage() else {
            NSLog("[ERROR] Failed to create CGImage")
            return createErrorImage()
        }
        
        let uiImage = UIImage(cgImage: cgImage)
        return uiImage.jpegData(compressionQuality: 0.9)
    }
    
    private func createSampleBufferFrom(imageBuffer: CVImageBuffer, formatDescription: CMFormatDescription) throws -> CMSampleBuffer {
        var sampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(duration: CMTime.invalid, presentationTimeStamp: CMTime(), decodeTimeStamp: CMTime.invalid)
        
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )
        
        if status != noErr {
            throw NSError(domain: "VideoDecoder", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to create sample buffer from image buffer"])
        }
        
        return sampleBuffer!
    }
    
    func getCurrentFrame() -> Data? {
        // Per test, generare un'immagine di test
        return createTestImage()
    }
    
    private func createTestImage() -> Data {
        let size = CGSize(width: 640, height: 480)
        UIGraphicsBeginImageContextWithOptions(size, true, 1.0)
        defer { UIGraphicsEndImageContext() }
        
        let context = UIGraphicsGetCurrentContext()!
        
        // Sfondo grigio scuro
        context.setFillColor(UIColor.darkGray.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        
        // Testo bianco
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .left
        
        let timeString = DateFormatter()
        timeString.dateFormat = "HH:mm:ss.SSS"
        
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 24),
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraphStyle
        ]
        
        "Captured Frame".draw(at: CGPoint(x: 20, y: 50), withAttributes: attributes)
        "Time: \(timeString.string(from: Date()))".draw(at: CGPoint(x: 20, y: 90), withAttributes: attributes)
        "Frame #: \(frameCounter)".draw(at: CGPoint(x: 20, y: 130), withAttributes: attributes)
        
        frameCounter += 1
        
        let image = UIGraphicsGetImageFromCurrentImageContext()!
        return image.jpegData(compressionQuality: 0.9)!
    }
    
    private func createErrorImage() -> Data? {
        let size = CGSize(width: 320, height: 240)
        UIGraphicsBeginImageContextWithOptions(size, true, 1.0)
        defer { UIGraphicsEndImageContext() }
        
        let context = UIGraphicsGetCurrentContext()!
        
        // Sfondo rosso
        context.setFillColor(UIColor.red.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        
        // Testo bianco
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 20),
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraphStyle
        ]
        
        "Error capturing frame".draw(at: CGPoint(x: 20, y: 110), withAttributes: attributes)
        
        let image = UIGraphicsGetImageFromCurrentImageContext()!
        return image.jpegData(compressionQuality: 0.7)
    }
    
    func release() {
        isRunning = false
        
        // Attendere che il thread si fermi
        decoderThread?.cancel()
        
        // Rilasciare le risorse
        if let decompressionSession = decompressionSession {
            VTDecompressionSessionInvalidate(decompressionSession)
            self.decompressionSession = nil
        }
        
        formatDescription = nil
        isInitialized = false
        
        // Rimuovere il layer di output
        DispatchQueue.main.async {
            self.outputLayer?.removeFromSuperlayer()
            self.outputLayer = nil
        }
        
        nalQueue.sync {
            nalBuffer.removeAll()
        }
    }
    
    func resetDecompressionSession() {
        // Ricreare la sessione di decompressione
        NSLog("[INFO] Forzando reset della sessione di decompressione")
        if decompressionSession != nil {
            VTDecompressionSessionInvalidate(decompressionSession!)
            decompressionSession = nil
        }
        
        do {
            try setupDecompressionSession()
            NSLog("[INFO] Sessione di decompressione reinizializzata con successo")
        } catch {
            NSLog("[ERROR] Impossibile reinizializzare la sessione: \(error)")
        }
    }
    
    private func createFormatDescriptionFromSPS(_ spsData: Data) throws {
        NSLog("[DEBUG] Creazione format description da SPS, lunghezza: \(spsData.count)")
        
        // Prima estraiamo l'SPS reale eliminando l'header NAL
        var actualSPS = spsData
        if spsData.count > 4 && spsData[0] == 0 && spsData[1] == 0 && spsData[2] == 0 && spsData[3] == 1 {
            // Rimuovi l'header 0x00 0x00 0x00 0x01
            actualSPS = spsData.subdata(in: 4..<spsData.count)
        }
        
        // Crea format description con più informazioni di debug
        var formatDesc: CMFormatDescription?
        let parameterSetPointers: [UnsafePointer<UInt8>] = [
            actualSPS.withUnsafeBytes { $0.baseAddress!.assumingMemoryBound(to: UInt8.self) }
        ]
        let parameterSetSizes: [Int] = [actualSPS.count]
        
        // Stampa i dati SPS per debug
        let hexSPS = actualSPS.map { String(format: "%02X ", $0) }.joined()
        NSLog("[DEBUG] SPS data (hex): \(hexSPS)")
        
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: 1,
            parameterSetPointers: parameterSetPointers,
            parameterSetSizes: parameterSetSizes,
            nalUnitHeaderLength: 0, // Abbiamo già rimosso l'header
            formatDescriptionOut: &formatDesc
        )
        
        if status != noErr {
            NSLog("[ERROR] Failed to create format description: \(status)")
            throw NSError(domain: "VideoDecoder", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to create format description"])
        }
        
        self.formatDescription = formatDesc
        
        // Ottieni dimensione dal format description - correzione errore di tipo
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDesc!)
        self.width = dimensions.width
        self.height = dimensions.height
        
        NSLog("[INFO] Format description creato con successo per risoluzione \(width)x\(height)")
    }
    
    private func actualDecodeNAL(_ nalUnit: Data) throws {
        // Estrai il tipo di NAL unit
        let nalType = nalUnit.count > 4 ? Int(nalUnit[4] & 0x1F) : -1
        
        do {
            // Se è un keyframe (IDR), imposta il flag
            if nalType == 5 { // IDR Frame
                NSLog("[INFO] 🔑 Ricevuto keyframe IDR, ora possiamo iniziare la decodifica")
                receivedKeyframe = true
            }
            
            // Se è un SPS, aggiorna il format description e resetta la sessione
            if nalType == 7 { // SPS
                NSLog("[DEBUG] Ricevuto SPS, aggiornamento formato di decodifica")
                try createFormatDescriptionFromSPS(nalUnit)
                resetDecompressionSession()
                receivedKeyframe = false // Richiedi un nuovo keyframe dopo un SPS
            }
            
            // Se non abbiamo ancora ricevuto un keyframe e questo è un P-frame, saltalo
            if !receivedKeyframe && nalType == 1 {
                NSLog("[DEBUG] Saltato P-frame in attesa di un keyframe")
                return
            }
            
            // Se non abbiamo ancora un format description, saltiamo
            guard let formatDescription = formatDescription else {
                NSLog("[ERROR] Format description non inizializzato, in attesa di SPS")
                return
            }

            // Log del buffer in input per debug
            let hexData = nalUnit.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
            NSLog("[DEBUG] Decodifica NAL tipo \(nalType) lunghezza \(nalUnit.count) bytes, inizio: \(hexData)")
            
            // Log dello stato del decoder
            NSLog("[DEBUG] Stato decoder: formatDescription creato: \(formatDescription != nil), decompression session: \(decompressionSession != nil)")
            
            // Crea blockBuffer
            var blockBuffer: CMBlockBuffer?
            let status1 = nalUnit.withUnsafeBytes { (bufferPtr) -> OSStatus in
                return CMBlockBufferCreateWithMemoryBlock(
                    allocator: kCFAllocatorDefault,
                    memoryBlock: nil,
                    blockLength: nalUnit.count,
                    blockAllocator: kCFAllocatorDefault,
                    customBlockSource: nil,
                    offsetToData: 0,
                    dataLength: nalUnit.count,
                    flags: 0,
                    blockBufferOut: &blockBuffer
                )
            }
            
            if status1 != noErr {
                NSLog("[ERROR] Failed to create block buffer: \(status1)")
                return
            }
            
            // Copia i dati nel blockBuffer
            nalUnit.withUnsafeBytes { (bufferPtr) -> Void in
                let status2 = CMBlockBufferReplaceDataBytes(
                    with: bufferPtr.baseAddress!,
                    blockBuffer: blockBuffer!,
                    offsetIntoDestination: 0,
                    dataLength: nalUnit.count
                )
                if status2 != noErr {
                    NSLog("[ERROR] Failed to copy data to block buffer: \(status2)")
                }
            }
            
            // Crea sample buffer
            var sampleBuffer: CMSampleBuffer?
            var sampleSize = nalUnit.count
            let status3 = CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                formatDescription: formatDescription,
                sampleCount: 1,
                sampleTimingEntryCount: 0,
                sampleTimingArray: nil,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSize,
                sampleBufferOut: &sampleBuffer
            )
            
            if status3 != noErr {
                NSLog("[ERROR] Failed to create sample buffer: \(status3)")
                return
            }
            
            guard let session = decompressionSession, let buffer = sampleBuffer else {
                NSLog("[ERROR] Decompression session or sample buffer is nil")
                return
            }
            
            // Decodifica il frame
            let flagsOut = UnsafeMutablePointer<VTDecodeInfoFlags>.allocate(capacity: 1)
            flagsOut.initialize(to: VTDecodeInfoFlags())
            
            let status4 = VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: buffer,
                flags: [._EnableAsynchronousDecompression],
                frameRefcon: nil,
                infoFlagsOut: flagsOut
            )
            
            if status4 != noErr {
                NSLog("[ERROR] Failed to decode frame: \(status4) (\(String(describing: (status4 as OSStatus).description)))")
            }
            
            flagsOut.deallocate()
        } catch {
            NSLog("[ERROR] Error decoding NAL unit: \(error.localizedDescription)")
        }
    }
    
    // Sostituisci questa funzione o aggiungila se non esiste
    func startPreviewMode() {
        // Abilita la generazione di immagini di anteprima
        shouldCreatePreviewFrames = true
        
        // Cancella eventuali timer esistenti
        frameGenerationTimer?.invalidate()
        
        // Crea un timer che genera immagini di anteprima
        frameGenerationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, self.shouldCreatePreviewFrames else { return }
            
            // Genera un'immagine di anteprima
            if let previewImage = self.createPreviewImage() {
                DispatchQueue.main.async {
                    self.onFrameDecoded?(previewImage)
                }
            }
        }
    }
    
    private func createPreviewImage() -> Data? {
        let size = CGSize(width: CGFloat(width), height: CGFloat(height))
        UIGraphicsBeginImageContextWithOptions(size, true, 1.0)
        defer { UIGraphicsEndImageContext() }
        
        let context = UIGraphicsGetCurrentContext()!
        
        // Sfondo nero
        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        
        // Aggiunge una griglia o pattern visivo
        context.setStrokeColor(UIColor(white: 0.3, alpha: 1.0).cgColor)
        context.setLineWidth(1.0)
        
        // Disegna una griglia o pattern che rende evidente che il video è attivo
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
        
        // Disegna un messaggio di anteprima
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
        NSString(string: "Anteprima Video").draw(in: titleRect, withAttributes: attributes)
        
        let timeRect = CGRect(x: 0, y: size.height/2, width: size.width, height: 40)
        NSString(string: timeString).draw(in: timeRect, withAttributes: attributes)
        
        let infoRect = CGRect(x: 0, y: size.height/2 + 60, width: size.width, height: 40)
        NSString(string: "Risoluzione: \(width)x\(height)").draw(in: infoRect, withAttributes: attributes)
        
        // Aggiungi il nome dell'IP per confermare che siamo connessi al dispositivo corretto
        let ipRect = CGRect(x: 0, y: size.height - 50, width: size.width, height: 30)
        let smallAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 16),
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraphStyle
        ]
        NSString(string: "Connesso a: \(VideoPlayer.lastConnectedIp ?? "sconosciuto")").draw(in: ipRect, withAttributes: smallAttributes)
        
        let image = UIGraphicsGetImageFromCurrentImageContext()!
        return image.jpegData(compressionQuality: 0.8)
    }
} 
