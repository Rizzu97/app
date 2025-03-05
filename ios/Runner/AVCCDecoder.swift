import Foundation
import VideoToolbox
import UIKit

class AVCCDecoder {
    // Callback per i frame decodificati
    var onFrameDecoded: ((Data) -> Void)?
    
    // Dimensioni video e stato
    private var width: Int32 = 1280
    private var height: Int32 = 720
    private var formatDescription: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    
    // Stato di decodifica
    var receivedKeyframe = false
    private var foundSPS = false
    private var foundPPS = false
    private var spsData: Data?
    private var ppsData: Data?
    
    // Coda NAL
    private let nalQueue = DispatchQueue(label: "com.example.a.avccdecoder.nalqueue")
    private var nalBuffer = [Data]()
    
    func setDimensions(width: Int32, height: Int32) {
        self.width = width
        self.height = height
    }
    
    func queueNalUnit(_ nalUnit: Data) {
        guard nalUnit.count > 4 else { return }
        let nalType = nalUnit[4] & 0x1F
        
        // Log dettagliato con hex dump per debugging
        var hexString = ""
        for i in 0..<min(16, nalUnit.count) {
            hexString += String(format: "%02X ", nalUnit[i])
        }
        NSLog("[AVCC] NAL type \(nalType), size \(nalUnit.count), header: \(hexString)")
        
        switch nalType {
        case 7: // SPS
            spsData = convertToAVCCFormat(nalUnit)
            foundSPS = true
            NSLog("[AVCC] Ricevuto SPS NAL")
            tryCreateFormatDescription()
            
        case 8: // PPS
            ppsData = convertToAVCCFormat(nalUnit)
            foundPPS = true
            NSLog("[AVCC] Ricevuto PPS NAL")
            tryCreateFormatDescription()
            
        case 5: // IDR (keyframe)
            receivedKeyframe = true
            NSLog("[AVCC] Ricevuto IDR keyframe")
            
            let avccData = convertToAVCCFormat(nalUnit)
            decodeFrame(avccData)
            
        case 1: // Non-IDR slice (P-frame)
            // Decodifica P-frame solo se abbiamo già ricevuto un keyframe
            if !receivedKeyframe && decompressionSession != nil {
                // Forza decodifica se siamo bloccati
                receivedKeyframe = true
                NSLog("[AVCC] Forzatura decodifica P-frame")
            }
            
            if receivedKeyframe {
                let avccData = convertToAVCCFormat(nalUnit)
                decodeFrame(avccData)
            } else {
                NSLog("[AVCC] Saltato P-frame in attesa di keyframe")
            }
            
        default:
            NSLog("[AVCC] Tipo NAL non gestito: \(nalType)")
        }
    }
    
    // Converte da start code a formato AVCC (lunghezza header 4 byte)
    private func convertToAVCCFormat(_ nalData: Data) -> Data {
        // Se i primi 4 byte sono già un header di lunghezza, ritorna i dati così come sono
        if nalData.count >= 4 && !(nalData[0] == 0 && nalData[1] == 0 && (nalData[2] == 0 || nalData[2] == 1)) {
            return nalData
        }
        
        // Trova l'inizio del NAL dopo lo start code
        var startIdx = 0
        if nalData.count >= 4 && nalData[0] == 0 && nalData[1] == 0 && nalData[2] == 0 && nalData[3] == 1 {
            startIdx = 4
        } else if nalData.count >= 3 && nalData[0] == 0 && nalData[1] == 0 && nalData[2] == 1 {
            startIdx = 3
        }
        
        // Calcola la lunghezza del NAL senza lo start code
        let nalLength = nalData.count - startIdx
        let lengthBytes = withUnsafeBytes(of: UInt32(nalLength).bigEndian) { Data($0) }
        
        // Crea nuovo buffer con header lunghezza + dati NAL
        var avccData = Data()
        avccData.append(lengthBytes)
        avccData.append(nalData.subdata(in: startIdx..<nalData.count))
        
        return avccData
    }
    
    private func tryCreateFormatDescription() {
        guard foundSPS, foundPPS, let spsData = spsData, let ppsData = ppsData else {
            return
        }
        
        // Estrai i dati SPS e PPS dai buffer AVCC (salta i primi 4 byte che sono l'header lunghezza)
        let spsBytes = [UInt8](spsData.subdata(in: 4..<spsData.count))
        let ppsBytes = [UInt8](ppsData.subdata(in: 4..<ppsData.count))
        
        var parameterSetPointers: [UnsafePointer<UInt8>] = [
            spsBytes.withUnsafeBufferPointer { $0.baseAddress! },
            ppsBytes.withUnsafeBufferPointer { $0.baseAddress! }
        ]
        
        var parameterSetSizes: [Int] = [
            spsBytes.count,
            ppsBytes.count
        ]
        
        var formatDescriptionOut: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: 2,
            parameterSetPointers: &parameterSetPointers,
            parameterSetSizes: &parameterSetSizes,
            nalUnitHeaderLength: 4,
            formatDescriptionOut: &formatDescriptionOut
        )
        
        if status == noErr, let formatDesc = formatDescriptionOut {
            formatDescription = formatDesc
            resetDecompressionSession()
            NSLog("[AVCC] Format description creato con successo")
        } else {
            NSLog("[AVCC] Errore creazione format description: \(status)")
        }
    }
    
    func resetDecompressionSession() {
        guard let formatDesc = formatDescription else {
            NSLog("[AVCC] Impossibile creare sessione: manca format description")
            return
        }
        
        // Distruggi la sessione esistente se presente
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        
        // Parametri ottimizzati per la decodifica
        let decoderParameters = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferOpenGLCompatibilityKey: true,
            "RequireHardwareAcceleratedVideoDecoder": true
        ] as CFDictionary
        
        // Crea callback per ricevere frame decodificati
        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { (decompressionOutputRefCon, sourceFrameRefCon, status, infoFlags, imageBuffer, presentationTimeStamp, duration) in
                if let context = decompressionOutputRefCon, status == noErr, let imageBuffer = imageBuffer {
                    let decoder = Unmanaged<AVCCDecoder>.fromOpaque(context).takeUnretainedValue()
                    decoder.handleDecodedFrame(imageBuffer: imageBuffer)
                }
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        
        // Crea la sessione di decodifica
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            decoderSpecification: nil,
            imageBufferAttributes: decoderParameters,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &session
        )
        
        if status == noErr, let session = session {
            decompressionSession = session
            NSLog("[AVCC] Sessione di decodifica creata con successo")
        } else {
            NSLog("[AVCC] Errore creazione sessione di decodifica: \(status)")
        }
    }
    
    private func decodeFrame(_ avccData: Data) {
        guard let session = decompressionSession, let formatDesc = formatDescription else {
            NSLog("[AVCC] Sessione di decodifica o format description non disponibili")
            return
        }
        
        // Crea block buffer con i dati AVCC
        var blockBuffer: CMBlockBuffer?
        let status1 = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avccData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avccData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        
        if status1 != noErr {
            NSLog("[AVCC] Errore creazione block buffer: \(status1)")
            return
        }
        
        // Copia i dati nel block buffer
        avccData.withUnsafeBytes { bufferPtr in
            CMBlockBufferReplaceDataBytes(
                with: bufferPtr.baseAddress!,
                blockBuffer: blockBuffer!,
                offsetIntoDestination: 0,
                dataLength: avccData.count
            )
        }
        
        // Crea sample buffer
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = avccData.count
        let status2 = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        
        if status2 != noErr {
            NSLog("[AVCC] Errore creazione sample buffer: \(status2)")
            return
        }
        
        // Decodifica il frame
        let flagsOut = UnsafeMutablePointer<VTDecodeInfoFlags>.allocate(capacity: 1)
        defer { flagsOut.deallocate() }
        
        let status3 = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer!,
            flags: [._EnableAsynchronousDecompression],
            frameRefcon: nil,
            infoFlagsOut: flagsOut
        )
        
        if status3 != noErr {
            NSLog("[AVCC] Errore decodifica frame: \(status3)")
        }
    }
    
    // Gestisce il frame decodificato
    private func handleDecodedFrame(imageBuffer: CVImageBuffer) {
        NSLog("[DEBUG] 🎬 Successfully decoded H.264 frame")
        // Crea un context per convertire il frame decodificato in un'immagine JPEG
        let ciImage = CIImage(cvImageBuffer: imageBuffer)
        let context = CIContext(options: nil)
        
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            NSLog("[AVCC] Errore creazione CGImage")
            return
        }
        
        let uiImage = UIImage(cgImage: cgImage)
        if let jpegData = uiImage.jpegData(compressionQuality: 0.85) {
            // Passa l'immagine decodificata attraverso il callback
            DispatchQueue.main.async {
                self.onFrameDecoded?(jpegData)
            }
        }
    }
    
    func startPreviewMode() {
        // Crea un timer che genera immagini di anteprima
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            if let previewImage = self.createPreviewImage() {
                DispatchQueue.main.async {
                    self.onFrameDecoded?(previewImage)
                }
            }
        }
    }
    
    // Crea un'immagine di anteprima visuale
    func createPreviewImage() -> Data? {
        let size = CGSize(width: CGFloat(width), height: CGFloat(height))
        UIGraphicsBeginImageContextWithOptions(size, true, 1.0)
        defer { UIGraphicsEndImageContext() }
        
        guard let context = UIGraphicsGetCurrentContext() else { return nil }
        
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
        
        // Aggiungi testo informativo
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
        
        NSString(string: "AVCC Decoder").draw(
            in: CGRect(x: 0, y: size.height/2 - 60, width: size.width, height: 40),
            withAttributes: attributes
        )
        
        NSString(string: timeString).draw(
            in: CGRect(x: 0, y: size.height/2, width: size.width, height: 40),
            withAttributes: attributes
        )
        
        NSString(string: "Risoluzione: \(width)x\(height)").draw(
            in: CGRect(x: 0, y: size.height/2 + 60, width: size.width, height: 40),
            withAttributes: attributes
        )
        
        let smallAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 16),
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraphStyle
        ]
        
        NSString(string: "Connesso a: \(VideoPlayer.lastConnectedIp ?? "sconosciuto")").draw(
            in: CGRect(x: 0, y: size.height - 50, width: size.width, height: 30),
            withAttributes: smallAttributes
        )
        
        guard let image = UIGraphicsGetImageFromCurrentImageContext() else { return nil }
        return image.jpegData(compressionQuality: 0.8)
    }
    
    func dispose() {
        // Distruggi la sessione di decompressione
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        
        // Pulisci il buffer
        spsData = nil
        ppsData = nil
        nalBuffer.removeAll()
    }
    
    func getCurrentFrame() -> Data? {
        // Tenta di recuperare un frame dall'ultimo frame decodificato
        // o genera un'immagine di anteprima se non ci sono frame decodificati
        return createPreviewImage()
    }
} 