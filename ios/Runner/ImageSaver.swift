import Foundation
import UIKit

class ImageSaver {
    static func saveImage(data: Data, path: String) throws {
        print("[DEBUG] Decoding image data")
        guard let image = UIImage(data: data) else {
            print("[ERROR] Failed to decode image data")
            throw NSError(domain: "ImageSaver", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to decode image data"])
        }
        
        print("[DEBUG] Creating file: \(path)")
        let fileURL = URL(fileURLWithPath: path)
        
        // Assicurati che la directory esista
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        
        print("[DEBUG] Compressing and saving image")
        guard let jpegData = image.jpegData(compressionQuality: 1.0) else {
            print("[ERROR] Failed to compress image")
            throw NSError(domain: "ImageSaver", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to compress image"])
        }
        
        try jpegData.write(to: fileURL)
        
        print("[DEBUG] Image saved successfully")
    }
} 