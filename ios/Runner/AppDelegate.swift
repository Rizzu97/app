import Flutter
import UIKit
import AVFoundation

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
    private let CHANNEL = "com.example.video_decoder"
    private var videoDecoder: VideoDecoder?
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
            case "initializeDecoder":
                do {
                    let arguments = call.arguments as? [String: Any]
                    let width = arguments?["width"] as? Int32 ?? 1920
                    let height = arguments?["height"] as? Int32 ?? 1080
                    let bufferSize = arguments?["bufferSize"] as? Int ?? 4096
                    
                    NSLog("Initializing decoder with width: \(width), height: \(height), buffer size: \(bufferSize)")
                    
                    // Crea una view per l'output video se non esiste
                    if self.videoView == nil {
                        self.createVideoView(controller: controller)
                    }
                    
                    self.initializeDecoder(width: width, height: height, bufferSize: bufferSize, result: result)
                } catch {
                    NSLog("[ERROR] Initialization error: \(error.localizedDescription)")
                    result(FlutterError(code: "INIT_ERROR", message: error.localizedDescription, details: nil))
                }
                
            case "startPlayback":
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let arguments = call.arguments as? [String: Any]
                        let ip = arguments?["ip"] as? String ?? "192.168.1.1"
                        let port = arguments?["port"] as? Int ?? 40005
                        let bufferSize = arguments?["bufferSize"] as? Int ?? 4096
                        
                        NSLog("[DEBUG] Starting playback from \(ip):\(port) with buffer size \(bufferSize)")
                        
                        // Disattiva il generatore di frame di test
                        self.testFrameGeneratorActive = false
                        
                        // Imposta la dimensione del buffer
                        self.videoPlayer?.setBufferSize(bufferSize)
                        
                        // Ferma il listener precedente se esiste
                        self.buttonListener?.stopListening()
                        self.buttonListener = nil
                        
                        // Avvia il listener del pulsante
                        NSLog("[DEBUG] Creating button listener for \(ip)")
                        self.buttonListener = ButtonListener(ip: ip)
                        self.buttonListener?.onButtonPressed = {
                            NSLog("[DEBUG] Button press event received in AppDelegate")
                            DispatchQueue.main.async {
                                methodChannel.invokeMethod("onButtonPressed", arguments: nil)
                            }
                        }
                        
                        NSLog("[DEBUG] Starting button listener")
                        self.buttonListener?.startListening()
                        
                        // Avvia la riproduzione video
                        self.videoPlayer?.startPlayback(ip: ip, port: port) { frame in
                            DispatchQueue.main.async {
                                methodChannel.invokeMethod("onFrame", arguments: frame)
                            }
                        }
                        
                        DispatchQueue.main.async {
                            result(true)
                        }
                    } catch {
                        NSLog("[ERROR] Playback error: \(error.localizedDescription)")
                        DispatchQueue.main.async {
                            result(FlutterError(code: "PLAYBACK_ERROR", message: error.localizedDescription, details: nil))
                        }
                    }
                }
                
            case "stopPlayback":
                DispatchQueue.global(qos: .userInitiated).async {
                    NSLog("[DEBUG] Stopping playback")
                    self.videoPlayer?.stopPlayback()
                    DispatchQueue.main.async {
                        result(true)
                    }
                }
                
            case "captureFrame":
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        NSLog("[DEBUG] Capturing frame")
                        if let frameData = self.videoPlayer?.captureCurrentFrame() {
                            // Salva il frame
                            let arguments = call.arguments as? [String: Any]
                            if let savePath = arguments?["savePath"] as? String {
                                NSLog("[DEBUG] Saving frame to \(savePath)")
                                try ImageSaver.saveImage(data: frameData, path: savePath)
                                DispatchQueue.main.async {
                                    result(savePath)
                                }
                            } else {
                                DispatchQueue.main.async {
                                    result(nil)
                                }
                            }
                        } else {
                            DispatchQueue.main.async {
                                result(FlutterError(code: "CAPTURE_ERROR", message: "No frame available", details: nil))
                            }
                        }
                    } catch {
                        NSLog("[ERROR] Error capturing frame: \(error.localizedDescription)")
                        DispatchQueue.main.async {
                            result(FlutterError(code: "CAPTURE_ERROR", message: error.localizedDescription, details: nil))
                        }
                    }
                }
                
            case "testConnection":
                DispatchQueue.global(qos: .userInitiated).async {
                    let arguments = call.arguments as? [String: Any]
                    let ip = arguments?["ip"] as? String ?? "192.168.1.1"
                    
                    NSLog("[DEBUG] Testing connection to \(ip)")
                    
                    // Test semplificato: prova a creare un socket e connettersi
                    do {
                        let testSocket = try Socket(host: ip, port: 40005)
                        let testData = Data([0x01, 0x02, 0x03])
                        let writeResult = testSocket.write(testData)
                        
                        if writeResult > 0 {
                            NSLog("[DEBUG] Connection test successful")
                            testSocket.close()
                            DispatchQueue.main.async {
                                result("Connection successful to \(ip)")
                            }
                        } else {
                            NSLog("[DEBUG] Connection test failed")
                            testSocket.close()
                            DispatchQueue.main.async {
                                result("Connection failed to \(ip)")
                            }
                        }
                    } catch {
                        NSLog("[ERROR] Connection test error: \(error.localizedDescription)")
                        DispatchQueue.main.async {
                            result("Connection error: \(error.localizedDescription)")
                        }
                    }
                }
                
            case "pingHost":
                DispatchQueue.global(qos: .userInitiated).async {
                    let arguments = call.arguments as? [String: Any]
                    let ip = arguments?["ip"] as? String ?? "192.168.1.1"
                    
                    NSLog("[DEBUG] Pinging host \(ip)")
                    
                    // Esecuzione del comando ping
                    NetworkUtility.pingHost(ip) { success, message in
                        DispatchQueue.main.async {
                            if success {
                                result("Ping successful: \(message)")
                            } else {
                                result("Ping failed: \(message)")
                            }
                        }
                    }
                }
                
            case "checkStatus":
                DispatchQueue.main.async {
                    let status = [
                        "decoderInitialized": self.videoDecoder != nil,
                        "playerInitialized": self.videoPlayer != nil,
                        "isPlaying": self.videoPlayer != nil && self.testFrameGeneratorActive
                    ]
                    result(status)
                }
                
            case "generateTestFrame":
                DispatchQueue.global(qos: .userInitiated).async {
                    self.testFrameGeneratorActive = true
                    if let testFrame = self.videoDecoder?.getCurrentFrame() {
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
                
            default:
                result(FlutterMethodNotImplemented)
            }
        }
        
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
    
    private func createVideoView(controller: FlutterViewController) {
        videoView = UIView(frame: CGRect(x: 0, y: 0, width: controller.view.bounds.width, height: controller.view.bounds.height))
        videoView?.isHidden = true  // Nascondi la view ma mantienila attiva per la decodifica
        controller.view.addSubview(videoView!)
    }
    
    private func initializeDecoder(width: Int32, height: Int32, bufferSize: Int, result: @escaping FlutterResult) {
        // Inizializza il VideoDecoder
        videoDecoder = VideoDecoder(outputView: videoView)
        if let success = videoDecoder?.initialize(width: width, height: height), success {
            NSLog("[DEBUG] Decoder initialized successfully")
            
            // Inizializza il VideoPlayer
            videoPlayer = VideoPlayer(decoder: videoDecoder!)
            videoPlayer?.setBufferSize(bufferSize)
            
            result(true)
        } else {
            NSLog("[ERROR] Failed to initialize decoder")
            result(FlutterError(code: "INIT_ERROR", message: "Failed to initialize decoder", details: nil))
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
    
    override func applicationWillTerminate(_ application: UIApplication) {
        // Ferma il listener del pulsante
        buttonListener?.stopListening()
        buttonListener = nil
        
        // Rilascia le risorse
        videoPlayer?.dispose()
        videoDecoder?.release()
        
        super.applicationWillTerminate(application)
    }
}
