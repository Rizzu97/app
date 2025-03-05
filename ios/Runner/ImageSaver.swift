import Foundation
import UIKit

class ImageSaver {
    static func saveImage(data: Data, path: String) throws {
        NSLog("[DEBUG] Decoding image data")
        
        // Verifica che i dati possano essere convertiti in un'immagine
        guard let image = UIImage(data: data) else {
            NSLog("[ERROR] Failed to decode image data")
            throw NSError(domain: "ImageSaver", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to decode image data"])
        }
        
        NSLog("[DEBUG] Creating file: \(path)")
        let fileURL = URL(fileURLWithPath: path)
        
        // Assicurati che la directory esista
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        
        // Salva l'immagine come JPEG
        NSLog("[DEBUG] Compressing and saving image")
        guard let jpegData = image.jpegData(compressionQuality: 1.0) else {
            NSLog("[ERROR] Failed to create JPEG data from image")
            throw NSError(domain: "ImageSaver", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to create JPEG data from image"])
        }
        
        NSLog("[DEBUG] Writing file to disk")
        try jpegData.write(to: fileURL, options: .atomic)
        
        NSLog("[DEBUG] Image saved successfully")
    }
    
    static func saveImageToPhotosAlbum(data: Data, completion: @escaping (Bool, Error?) -> Void) {
        guard let image = UIImage(data: data) else {
            let error = NSError(domain: "ImageSaver", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to decode image data"])
            completion(false, error)
            return
        }
        
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        completion(true, nil)
    }
} 