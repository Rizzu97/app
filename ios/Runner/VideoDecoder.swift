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
        // Parametri per il formato H.264
        let parameterSetPointers: [UnsafePointer<UInt8>?] = []
        let parameterSetSizes: [Int] = []
        
        // Creare la descrizione del formato video
        var status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_H264,
            width: width,
            height: height,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        
        if status != noErr {
            throw NSError(domain: "VideoDecoder", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to create format description"])
        }
        
        // Callback per la decodifica
        let decoderCallback: VTDecompressionOutputCallback = { decompressionOutputRefCon, sourceFrameRefCon, status, infoFlags, imageBuffer, presentationTimeStamp, duration in
            guard let refCon = decompressionOutputRefCon else { return }
            
            let decoder = Unmanaged<VideoDecoder>.fromOpaque(refCon).takeUnretainedValue()
            decoder.handleDecodedFrame(status: status, imageBuffer: imageBuffer)
        }
        
        // Attributi di decodifica
        let decoderParameters = NSMutableDictionary()
        let destinationAttributes = NSMutableDictionary()
        
        // Formato pixel per l'output
        destinationAttributes[kCVPixelBufferPixelFormatTypeKey] = kCVPixelFormatType_32BGRA
        
        // Creare la sessione di decompressione
        var outputCallback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: decoderCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        
        guard let formatDescription = formatDescription else {
            throw NSError(domain: "VideoDecoder", code: -1, userInfo: [NSLocalizedDescriptionKey: "Format description is nil"])
        }
        
        status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: decoderParameters,
            imageBufferAttributes: destinationAttributes,
            outputCallback: &outputCallback,
            decompressionSessionOut: &decompressionSession
        )
        
        if status != noErr {
            throw NSError(domain: "VideoDecoder", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to create decompression session"])
        }
        
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
        guard isInitialized, let decompressionSession = decompressionSession else {
            NSLog("[ERROR] Decoder not initialized or decompression session is nil")
            return
        }
        
        do {
            // Creare il buffer di blocco
            var blockBuffer: CMBlockBuffer?
            var status = CMBlockBufferCreateWithMemoryBlock(
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
            
            if status != kCMBlockBufferNoErr {
                throw NSError(domain: "VideoDecoder", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to create block buffer"])
            }
            
            // Copiare i dati nel buffer
            status = CMBlockBufferReplaceDataBytes(
                with: (nalUnit as NSData).bytes,
                blockBuffer: blockBuffer!,
                offsetIntoDestination: 0,
                dataLength: nalUnit.count
            )
            
            if status != kCMBlockBufferNoErr {
                throw NSError(domain: "VideoDecoder", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to copy data to block buffer"])
            }
            
            // Creare il sample buffer
            var sampleBuffer: CMSampleBuffer?
            var sampleSizeArray = [nalUnit.count]
            
            status = CMSampleBufferCreateReady(
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
            
            if status != noErr {
                throw NSError(domain: "VideoDecoder", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to create sample buffer"])
            }
            
            // Decodificare il frame
            let flagsOut = UnsafeMutablePointer<VTDecodeInfoFlags>.allocate(capacity: 1)
            flagsOut.initialize(to: [])
            
            status = VTDecompressionSessionDecodeFrame(
                decompressionSession,
                sampleBuffer: sampleBuffer!,
                flags: [._EnableAsynchronousDecompression],
                frameRefcon: nil,
                infoFlagsOut: flagsOut
            )
            
            if status != noErr {
                NSLog("[ERROR] Failed to decode frame: \(status)")
            }
            
            flagsOut.deallocate()
            
        } catch {
            NSLog("[ERROR] Error decoding NAL unit: \(error.localizedDescription)")
        }
    }
    
    private func handleDecodedFrame(status: OSStatus, imageBuffer: CVImageBuffer?) {
        guard status == noErr, let imageBuffer = imageBuffer else {
            NSLog("[ERROR] Error decoding frame or imageBuffer is nil")
            return
        }
        
        // Convertire il CVImageBuffer in UIImage e quindi in Data
        if let jpegData = createJPEGFromImageBuffer(imageBuffer) {
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
} 
