import Flutter
import UIKit
import AVFoundation

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
    private let CHANNEL = "com.example.video_decoder"
    private var avccDecoder: AVCCDecoder?
    private var videoPlayer: VideoPlayer?
    private var testFrameGeneratorActive = false
    private var buttonListener: ButtonListener?
    
    // View container per l'output video
    private var videoView: UIView?
    
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)
        
        // Richiedi i permessi necessari
        requestCameraAndMicrophonePermissions()
        
        // Configura il channel Flutter
        let controller = window?.rootViewController as! FlutterViewController
        let methodChannel = FlutterMethodChannel(name: CHANNEL, binaryMessenger: controller.binaryMessenger)
        
        methodChannel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
            guard let self = self else { return }
            
            switch call.method {
            case "initPlayer":
                if let args = call.arguments as? [String: Any],
                   let ip = args["ip"] as? String {
                    self.initVideoPlayer(ip: ip, result: result)
                } else {
                    result(FlutterError(code: "INVALID_ARGS", message: "Missing IP address", details: nil))
                }
                
            case "startTestFrameGenerator":
                testFrameGeneratorActive = true
                result(true)
                
            case "stopTestFrameGenerator":
                testFrameGeneratorActive = false
                result(true)
                
            case "takePicture":
                if let videoPlayer = self.videoPlayer {
                    videoPlayer.takePicture { success in
                        result(success)
                    }
                } else {
                    result(FlutterError(code: "PLAYER_NOT_INIT", message: "Video player not initialized", details: nil))
                }
                
            case "ping":
                if let args = call.arguments as? [String: Any],
                   let ip = args["ip"] as? String {
                    self.pingHost(ip: ip, result: result)
                } else {
                    result(FlutterError(code: "INVALID_ARGS", message: "Missing IP address", details: nil))
                }
                
            case "checkStatus":
                DispatchQueue.main.async {
                    let status = [
                        "decoderInitialized": self.avccDecoder != nil,
                        "playerInitialized": self.videoPlayer != nil,
                        "isPlaying": self.videoPlayer != nil && self.testFrameGeneratorActive
                    ]
                    result(status)
                }
                
            case "generateTestFrame":
                DispatchQueue.global(qos: .userInitiated).async {
                    self.testFrameGeneratorActive = true
                    if let testFrame = self.avccDecoder?.getCurrentFrame() {
                        DispatchQueue.main.async {
                            methodChannel.invokeMethod("onFrame", arguments: testFrame)
                            result(true)
                        }
                    } else {
                        DispatchQueue.main.async {
                            result(false)
                        }
                    }
                }
                
            case "initializeDecoder":
                if let args = call.arguments as? [String: Any],
                   let ip = args["ip"] as? String {
                    self.initVideoPlayer(ip: ip, result: result)
                } else {
                    result(FlutterError(code: "INVALID_ARGS", message: "Missing IP address", details: nil))
                }
                
            case "startPlayback":
                if let args = call.arguments as? [String: Any],
                   let ip = args["ip"] as? String,
                   let port = args["port"] as? Int {
                    self.startVideoPlayback(ip: ip, port: port, result: result)
                } else {
                    result(FlutterError(code: "INVALID_ARGS", message: "Missing IP or port", details: nil))
                }
                
            default:
                result(FlutterMethodNotImplemented)
            }
        }
        
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
    
    private func initVideoPlayer(ip: String, result: @escaping FlutterResult) {
        NSLog("[DEBUG] Initializing video player with IP: \(ip)")
        
        // Bypassiamo completamente i controlli di raggiungibilità
        // Non verifichiamo la connettività e procediamo direttamente con l'inizializzazione
        
        // Crea un nuovo decoder AVCC
        let decoder = AVCCDecoder()
        
        // Configura il decoder
        decoder.setDimensions(width: 1280, height: 720)
        
        // Crea il video player con il decoder AVCC
        let player = VideoPlayer(decoder: decoder)
        player.connect(toHost: ip)
        
        // Arresta il listener precedente se esiste
        buttonListener?.stopListening()
        
        // Crea un nuovo listener per i pulsanti
        let listener = ButtonListener(ip: ip)
        listener.onButtonPressed = { [weak self, weak player] in
            guard let player = player else { return }
            player.takePicture { success in
                NSLog("[DEBUG] Button pressed - Picture taken: \(success)")
            }
        }
        
        // Avvia il listener
        listener.startListening()
        
        // Memorizza i riferimenti
        videoPlayer = player
        avccDecoder = decoder
        buttonListener = listener
        
        NSLog("[DEBUG] Video player initialized successfully")
        result(true)
    }
    
    private func pingHost(ip: String, result: @escaping FlutterResult) {
        NetworkUtility.pingHost(ip) { success, message in
            if success {
                result(true)
            } else {
                result(FlutterError(code: "PING_FAILED", message: message, details: nil))
            }
        }
    }
    
    private func requestCameraAndMicrophonePermissions() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            if granted {
                NSLog("[DEBUG] Camera permission granted")
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    if granted {
                        NSLog("[DEBUG] Microphone permission granted")
                    } else {
                        NSLog("[WARN] Microphone permission denied")
                    }
                }
            } else {
                NSLog("[WARN] Camera permission denied")
            }
        }
    }
    
    private func startVideoPlayback(ip: String, port: Int, result: @escaping FlutterResult) {
        NSLog("[DEBUG] Starting video playback from \(ip):\(port)")
        
        // Verifica se il player è inizializzato, altrimenti lo inizializza
        if videoPlayer == nil {
            NSLog("[INFO] Player not initialized, initializing now with IP: \(ip)")
            initVideoPlayer(ip: ip) { initSuccess in
                if initSuccess as? Bool == true {
                    self.startVideoPlaybackInternal(ip: ip, port: port, result: result)
                } else {
                    result(FlutterError(code: "INIT_FAILED", message: "Player initialization failed", details: nil))
                }
            }
        } else {
            startVideoPlaybackInternal(ip: ip, port: port, result: result)
        }
    }
    
    private func startVideoPlaybackInternal(ip: String, port: Int, result: @escaping FlutterResult) {
        NSLog("[DEBUG] 🎮 Starting video playback with port: \(port)")
        guard let videoPlayer = self.videoPlayer else {
            result(FlutterError(code: "PLAYER_NOT_INIT", message: "Video player not initialized", details: nil))
            return
        }
        
        // Recupera il controller Flutter
        let controller = window?.rootViewController as! FlutterViewController
        let methodChannel = FlutterMethodChannel(name: CHANNEL, binaryMessenger: controller.binaryMessenger)
        
        // Avvia la riproduzione con una callback per i frame
        videoPlayer.startPlayback(ip: ip, port: port) { jpegData in
            // Invia i frame ricevuti a Flutter
            methodChannel.invokeMethod("onFrame", arguments: jpegData)
        }
        
        result(true)
    }
    
    override func applicationWillTerminate(_ application: UIApplication) {
        // Ferma il listener del pulsante
        buttonListener?.stopListening()
        buttonListener = nil
        
        // Rilascia le risorse
        videoPlayer?.dispose()
        
        // Se utilizziamo AVCCDecoder, aggiungiamo un metodo di pulizia
        super.applicationWillTerminate(application)
    }
}
