import Foundation
import UIKit
import VideoToolbox
import AVFoundation

class VideoDecoder {
    // Callback per ricevere i frame decodificati
    var onFrameDecoded: ((Data) -> Void)?
    
    // Frame corrente
    private var currentFrame: Data?
    
    // Contatori per le statistiche
    private var frameCount = 0
    
    // Decoder H.264
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    
    // Buffer per accumulare i dati
    private var dataBuffer = Data()
    
    // Parametri SPS e PPS
    private var spsData: Data?
    private var ppsData: Data?
    
    // Costanti per i tipi di NAL
    private let NAL_SLICE: UInt8 = 1
    private let NAL_IDR_SLICE: UInt8 = 5
    private let NAL_SPS: UInt8 = 7
    private let NAL_PPS: UInt8 = 8
    
    // Dimensioni del video
    private var videoWidth = 1920
    private var videoHeight = 1080
    
    // Descrizione dei tipi di NALU per debug
    private let naluTypeStrings = [
        "0: Unspecified (non-VCL)",
        "1: Coded slice of a non-IDR picture (VCL) - P frame",
        "2: Coded slice data partition A (VCL)",
        "3: Coded slice data partition B (VCL)",
        "4: Coded slice data partition C (VCL)",
        "5: Coded slice of an IDR picture (VCL) - I frame",
        "6: Supplemental enhancement information (SEI) (non-VCL)",
        "7: Sequence parameter set (non-VCL) - SPS",
        "8: Picture parameter set (non-VCL) - PPS",
        "9: Access unit delimiter (non-VCL)",
        "10: End of sequence (non-VCL)",
        "11: End of stream (non-VCL)",
        "12: Filler data (non-VCL)",
        "13: Sequence parameter set extension (non-VCL)",
        "14: Prefix NAL unit (non-VCL)",
        "15: Subset sequence parameter set (non-VCL)",
        "16: Reserved (non-VCL)",
        "17: Reserved (non-VCL)",
        "18: Reserved (non-VCL)",
        "19: Coded slice of an auxiliary coded picture without partitioning (non-VCL)",
        "20: Coded slice extension (non-VCL)",
        "21: Coded slice extension for depth view components (non-VCL)",
        "22: Reserved (non-VCL)",
        "23: Reserved (non-VCL)",
        "24: STAP-A Single-time aggregation packet (non-VCL)",
        "25: STAP-B Single-time aggregation packet (non-VCL)",
        "26: MTAP16 Multi-time aggregation packet (non-VCL)",
        "27: MTAP24 Multi-time aggregation packet (non-VCL)",
        "28: FU-A Fragmentation unit (non-VCL)",
        "29: FU-B Fragmentation unit (non-VCL)",
        "30: Unspecified (non-VCL)",
        "31: Unspecified (non-VCL)"
    ]
    
    func initialize(width: Int, height: Int) -> Bool {
        print("[DEBUG] Initializing decoder with width: \(width), height: \(height)")
        videoWidth = width
        videoHeight = height
        frameCount = 0
        return true
    }
    
    func queueNalUnit(nalUnit: Data) {
        // Aggiungi i dati al buffer
        dataBuffer.append(nalUnit)
        
        // Cerca NAL units nel buffer
        processBuffer()
    }
    
    private func processBuffer() {
        // Cerca il pattern di inizio NAL (0x00 0x00 0x00 0x01)
        var searchIndex = 0
        
        while searchIndex < dataBuffer.count - 4 {
            // Cerca l'inizio di un NAL
            if dataBuffer[searchIndex] == 0x00 && 
               dataBuffer[searchIndex + 1] == 0x00 && 
               dataBuffer[searchIndex + 2] == 0x00 && 
               dataBuffer[searchIndex + 3] == 0x01 {
                
                // Abbiamo trovato l'inizio di un NAL
                let nalType = dataBuffer[searchIndex + 4] & 0x1F
                
                // Cerca l'inizio del prossimo NAL
                var nextNalIndex = searchIndex + 4
                while nextNalIndex < dataBuffer.count - 4 {
                    if dataBuffer[nextNalIndex] == 0x00 && 
                       dataBuffer[nextNalIndex + 1] == 0x00 && 
                       dataBuffer[nextNalIndex + 2] == 0x00 && 
                       dataBuffer[nextNalIndex + 3] == 0x01 {
                        break
                    }
                    nextNalIndex += 1
                }
                
                // Se abbiamo trovato un NAL completo
                if nextNalIndex < dataBuffer.count - 4 || nalType == NAL_SPS || nalType == NAL_PPS {
                    let nalEndIndex = nextNalIndex < dataBuffer.count - 4 ? nextNalIndex : dataBuffer.count
                    let nalData = dataBuffer.subdata(in: searchIndex..<nalEndIndex)
                    
                    // Processa il NAL in base al tipo
                    switch nalType {
                    case NAL_SPS:
                        print("[DEBUG] Found SPS NAL")
                        spsData = nalData
                        
                    case NAL_PPS:
                        print("[DEBUG] Found PPS NAL")
                        ppsData = nalData
                        
                        // Se abbiamo sia SPS che PPS, possiamo configurare il decoder
                        if spsData != nil && ppsData != nil {
                            createDecompressionSession()
                        }
                        
                    case NAL_IDR_SLICE:
                        print("[DEBUG] Found IDR frame (I-frame)")
                        if decompressionSession != nil {
                            decodeFrame(nalData)
                        } else {
                            print("[DEBUG] Skipping IDR frame, no decompression session")
                        }
                        
                    case NAL_SLICE:
                        print("[DEBUG] Found non-IDR frame (P-frame)")
                        if decompressionSession != nil {
                            decodeFrame(nalData)
                        } else {
                            print("[DEBUG] Skipping P-frame, no decompression session")
                        }
                        
                    default:
                        print("[DEBUG] Ignoring NAL type \(nalType)")
                    }
                    
                    // Rimuovi i dati processati dal buffer
                    if nextNalIndex < dataBuffer.count - 4 {
                        searchIndex = nextNalIndex
                    } else {
                        dataBuffer.removeSubrange(0..<nalEndIndex)
                        searchIndex = 0
                    }
                } else {
                    // NAL incompleto, aspetta più dati
                    break
                }
            } else {
                searchIndex += 1
            }
        }
        
        // Se abbiamo processato abbastanza dati, pulisci il buffer
        if dataBuffer.count > 1_000_000 {  // 1MB
            dataBuffer.removeAll()
        }
    }
    
    private func createDecompressionSession() {
        guard let spsData = spsData, let ppsData = ppsData else {
            print("[ERROR] Cannot create decompression session without SPS and PPS")
            return
        }
        
        print("[DEBUG] Creating decompression session with SPS (\(spsData.count) bytes) and PPS (\(ppsData.count) bytes)")
        
        // Pulisci la sessione precedente
        if decompressionSession != nil {
            VTDecompressionSessionInvalidate(decompressionSession!)
            decompressionSession = nil
        }
        
        // Estrai i dati SPS e PPS (salta il codice di inizio 0x00 0x00 0x00 0x01)
        let spsStart = spsData.startIndex + 4
        let spsSize = spsData.count - 4
        let ppsStart = ppsData.startIndex + 4
        let ppsSize = ppsData.count - 4
        
        // Crea i parametri per il formato di descrizione
        var parameterSetPointers: [UnsafePointer<UInt8>] = []
        var parameterSetSizes: [Int] = []
        
        spsData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            if let baseAddress = bytes.baseAddress {
                parameterSetPointers.append(baseAddress.assumingMemoryBound(to: UInt8.self) + 4)
                parameterSetSizes.append(spsSize)
            }
        }
        
        ppsData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            if let baseAddress = bytes.baseAddress {
                parameterSetPointers.append(baseAddress.assumingMemoryBound(to: UInt8.self) + 4)
                parameterSetSizes.append(ppsSize)
            }
        }
        
        // Crea il formato di descrizione video
        var formatDesc: CMVideoFormatDescription?
        let status = parameterSetPointers.withUnsafeBufferPointer { pointers in
            parameterSetSizes.withUnsafeBufferPointer { sizes in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers.baseAddress!,
                    parameterSetSizes: sizes.baseAddress!,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDesc
                )
            }
        }
        
        if status != noErr {
            print("[ERROR] Failed to create format description: \(status)")
            return
        }
        
        self.formatDescription = formatDesc
        
        // Crea il callback per la decompressione
        var outputCallback = VTDecompressionOutputCallbackRecord()
        outputCallback.decompressionOutputCallback = { (decompressionOutputRefCon, sourceFrameRefCon, status, infoFlags, imageBuffer, presentationTimeStamp, duration) in
            let decoder = unsafeBitCast(decompressionOutputRefCon, to: VideoDecoder.self)
            
            if status != noErr {
                print("[ERROR] Decompression failed: \(status)")
                return
            }
            
            guard let imageBuffer = imageBuffer else {
                print("[ERROR] No image buffer")
                return
            }
            
            // Converti il CVPixelBuffer in UIImage
            if let image = decoder.createUIImage(from: imageBuffer) {
                if let jpegData = image.jpegData(compressionQuality: 0.8) {
                    decoder.currentFrame = jpegData
                    DispatchQueue.main.async {
                        decoder.onFrameDecoded?(jpegData)
                    }
                }
            }
        }
        
        outputCallback.decompressionOutputRefCon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        // Crea la sessione di decompressione
        let decoderSpecification: [String: Any] = [:]
        let destinationImageBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: videoWidth,
            kCVPixelBufferHeightKey as String: videoHeight,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        
        var session: VTDecompressionSession?
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc!,
            decoderSpecification: decoderSpecification as CFDictionary,
            imageBufferAttributes: destinationImageBufferAttributes as CFDictionary,
            outputCallback: &outputCallback,
            decompressionSessionOut: &session
        )
        
        if sessionStatus != noErr {
            print("[ERROR] Failed to create decompression session: \(sessionStatus)")
            return
        }
        
        decompressionSession = session
        print("[DEBUG] Decompression session created successfully")
    }
    
    private func decodeFrame(_ frameData: Data) {
        guard let decompressionSession = decompressionSession,
              let formatDescription = formatDescription else {
            print("[DEBUG] Cannot decode frame: missing decompression session or format description")
            return
        }
        
        // Converti il NAL in formato AVCC (sostituisci il codice di inizio con la lunghezza)
        var avccData = Data()
        let nalDataSize = frameData.count - 4  // Escludi il codice di inizio
        var nalSize = UInt32(nalDataSize).bigEndian
        avccData.append(Data(bytes: &nalSize, count: 4))
        avccData.append(frameData.subdata(in: 4..<frameData.count))
        
        // Crea un CMBlockBuffer dal frame data
        var blockBuffer: CMBlockBuffer?
        let blockBufferStatus = avccData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> OSStatus in
            guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferStructureAllocationFailedErr }
            return CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: avccData.count,
                blockAllocator: nil,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: avccData.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }
        
        if blockBufferStatus != noErr {
            print("[ERROR] Failed to create block buffer: \(blockBufferStatus)")
            return
        }
        
        // Copia i dati nel block buffer
        let copyStatus = avccData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> OSStatus in
            guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferStructureAllocationFailedErr }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer!,
                offsetIntoDestination: 0,
                dataLength: avccData.count
            )
        }
        
        if copyStatus != noErr {
            print("[ERROR] Failed to copy data to block buffer: \(copyStatus)")
            return
        }
        
        // Crea un CMSampleBuffer dal block buffer
        var sampleBuffer: CMSampleBuffer?
        var sampleSizeArray = [avccData.count]
        let sampleBufferStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSizeArray,
            sampleBufferOut: &sampleBuffer
        )
        
        if sampleBufferStatus != noErr {
            print("[ERROR] Failed to create sample buffer: \(sampleBufferStatus)")
            return
        }
        
        // Imposta gli attributi del sample buffer
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer!, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        
        // Decodifica il frame
        let flags = VTDecodeFrameFlags._EnableAsynchronousDecompression
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            decompressionSession,
            sampleBuffer: sampleBuffer!,
            flags: flags,
            frameRefcon: nil,
            infoFlagsOut: nil
        )
        
        if decodeStatus != noErr {
            print("[ERROR] Failed to decode frame: \(decodeStatus)")
            
            // Se l'errore è grave, ricreiamo il decoder
            if decodeStatus == kVTInvalidSessionErr || decodeStatus == kVTVideoDecoderBadDataErr {
                print("[DEBUG] Recreating decoder due to serious error")
                createDecompressionSession()
            }
        }
    }
    
    private func createUIImage(from pixelBuffer: CVPixelBuffer) -> UIImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        
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
            return nil
        }
        
        guard let cgImage = context.makeImage() else {
            return nil
        }
        
        return UIImage(cgImage: cgImage)
    }
    
    func getCurrentFrame() -> Data? {
        return currentFrame
    }
    
    // Metodo per mostrare un'immagine di debug
    func showDebugImage(message: String) {
        let size = CGSize(width: 640, height: 480)
        UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
        defer { UIGraphicsEndImageContext() }
        
        guard let context = UIGraphicsGetCurrentContext() else { return }
        
        // Sfondo nero
        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        
        // Attributi del testo
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 24),
            .foregroundColor: UIColor.white
        ]
        
        // Disegna il messaggio
        let rect = CGRect(x: 20, y: size.height/2 - 50, width: size.width - 40, height: 100)
        message.draw(in: rect, withAttributes: attributes)
        
        guard let image = UIGraphicsGetImageFromCurrentImageContext() else { return }
        if let jpegData = image.jpegData(compressionQuality: 0.9) {
            DispatchQueue.main.async {
                self.onFrameDecoded?(jpegData)
            }
        }
    }
}

// Estensione per Data per facilitare la ricerca di byte
extension Data {
    func firstIndex(of byte: UInt8, in range: Range<Int>, where condition: (Int) -> Bool) -> Int? {
        for i in range {
            if self[i] == byte && condition(i) {
                return i
            }
        }
        return nil
    }
} 

