import Flutter
import UIKit
import AVFoundation

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  private let CHANNEL = "com.example.video_decoder"
  private var videoDecoder: VideoDecoder?
  private var videoPlayer: VideoPlayer?
  private var buttonListener: ButtonListener?
  
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Configura AVFoundation
    let audioSession = AVAudioSession.sharedInstance()
    do {
        try audioSession.setCategory(.playback, mode: .default)
        try audioSession.setActive(true)
    } catch {
        print("Failed to set audio session category: \(error)")
    }
    
    let controller = window?.rootViewController as! FlutterViewController
    let methodChannel = FlutterMethodChannel(name: CHANNEL, binaryMessenger: controller.binaryMessenger)
    
    methodChannel.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self else { return }
      
      switch call.method {
      case "initializeDecoder":
          let args = call.arguments as? [String: Any]
          let width = args?["width"] as? Int ?? 640
          let height = args?["height"] as? Int ?? 480
          let bufferSize = args?["bufferSize"] as? Int ?? 4096
        
        print("[DEBUG] Initializing decoder with width: \(width), height: \(height), buffer size: \(bufferSize)")
        
        self.initializeDecoder(width: width, height: height, bufferSize: bufferSize, result: result)
        
      case "startPlayback":
        DispatchQueue.global(qos: .background).async {
          do {
            let args = call.arguments as? [String: Any]
            let ip = args?["ip"] as? String ?? "192.168.1.1"
            let port = args?["port"] as? Int ?? 40005
            let bufferSize = args?["bufferSize"] as? Int ?? 4096
            
            print("[DEBUG] Starting playback from \(ip):\(port) with buffer size \(bufferSize)")
            print("[DEBUG] Starting playback with detailed logging")
            
            // Ferma il listener precedente se esiste
            self.buttonListener?.stopListening()
            self.buttonListener = nil
            
            // Avvia il listener del pulsante
            print("[DEBUG] Creating button listener for \(ip)")
            self.buttonListener = ButtonListener(ip: ip)
            self.buttonListener?.onButtonPressed = {
              print("[DEBUG] Button press event received in AppDelegate")
              DispatchQueue.main.async {
                methodChannel.invokeMethod("onButtonPressed", arguments: nil)
              }
            }
            print("[DEBUG] Starting button listener")
            self.buttonListener?.startListening()
            
            // Imposta la dimensione del buffer
            self.videoPlayer?.setBufferSize(size: bufferSize)
            
            // Avvia la riproduzione
            self.videoPlayer?.startPlayback(ip: ip, port: port) { (frameData) in
              DispatchQueue.main.async {
                methodChannel.invokeMethod("onFrame", arguments: frameData)
              }
            }
            
            result(true)
          } catch {
            print("[ERROR] Error starting playback: \(error.localizedDescription)")
            result(FlutterError(code: "PLAYBACK_ERROR", message: error.localizedDescription, details: nil))
          }
        }
        
      case "stopPlayback":
        DispatchQueue.global(qos: .background).async {
          print("[DEBUG] Stopping playback")
          self.videoPlayer?.stopPlayback()
          result(true)
        }
        
      case "captureFrame":
        DispatchQueue.global(qos: .background).async {
          print("[DEBUG] Capturing frame")
          if let frame = self.videoPlayer?.captureCurrentFrame() {
            result(frame)
          } else {
            result(FlutterError(code: "CAPTURE_ERROR", message: "Failed to capture frame", details: nil))
          }
        }
        
      case "saveImage":
        DispatchQueue.global(qos: .background).async {
          do {
            let args = call.arguments as? [String: Any]
            guard let data = args?["data"] as? FlutterStandardTypedData,
                  let path = args?["path"] as? String else {
              result(FlutterError(code: "INVALID_ARGS", message: "Invalid arguments", details: nil))
              return
            }
            
            try ImageSaver.saveImage(data: data.data, path: path)
            result(true)
          } catch {
            print("[ERROR] Error saving image: \(error.localizedDescription)")
            result(FlutterError(code: "SAVE_ERROR", message: error.localizedDescription, details: nil))
          }
        }
        
      case "switchProtocol":
        DispatchQueue.global(qos: .background).async {
          print("[DEBUG] Trying alternative connection methods")
          
          if let args = call.arguments as? [String: Any],
             let ip = args["ip"] as? String {
            // Prova connessioni alternative
            self.videoPlayer?.tryAlternativeConnections(ip: ip) { (frameData) in
                DispatchQueue.main.async {
                    methodChannel.invokeMethod("onFrame", arguments: frameData)
                }
            }
          }
          
          result(true)
        }
        
      case "checkStatus":
        result("Decoder: \(self.videoDecoder != nil ? "Initialized" : "Not initialized"), Player: \(self.videoPlayer != nil ? "Initialized" : "Not initialized")")
        
      case "testConnection":
        DispatchQueue.global(qos: .background).async {
          do {
            let args = call.arguments as? [String: Any]
            let ip = args?["ip"] as? String ?? "192.168.1.1"
            
            let success = try self.testConnection(ip: ip)
            result("Connection to \(ip): \(success ? "Success" : "Failed")")
          } catch {
            result(FlutterError(code: "TEST_ERROR", message: error.localizedDescription, details: nil))
          }
        }
        
      case "pingHost":
        DispatchQueue.global(qos: .background).async {
          do {
            let args = call.arguments as? [String: Any]
            let ip = args?["ip"] as? String ?? "192.168.1.1"
            
            let pingResult = try self.pingHost(ip: ip)
            result("Ping to \(ip): \(pingResult)")
          } catch {
            result(FlutterError(code: "PING_ERROR", message: error.localizedDescription, details: nil))
          }
        }
        
      case "forceFrameUpdate":
        DispatchQueue.global(qos: .background).async {
          if let frame = self.videoPlayer?.captureCurrentFrame() {
            DispatchQueue.main.async {
              methodChannel.invokeMethod("onFrame", arguments: frame)
            }
            result(true)
          } else {
            result(FlutterError(code: "NO_FRAME", message: "No frame available", details: nil))
          }
        }
        
      case "dispose":
        self.releaseDecoder()
        result(true)
        
      case "debugConnection":
        DispatchQueue.global(qos: .background).async {
          do {
            let args = call.arguments as? [String: Any]
            let ip = args?["ip"] as? String ?? "192.168.1.1"
            let port = args?["port"] as? Int ?? 40005
            
            print("[DEBUG] Testing connection to \(ip):\(port)")
            
            // Test TCP
            var tcpSuccess = false
            let socket = CFSocketCreate(kCFAllocatorDefault, PF_INET, SOCK_STREAM, IPPROTO_TCP, 0, nil, nil)
            if let socket = socket {
              var addr = sockaddr_in()
              addr.sin_family = sa_family_t(AF_INET)
              addr.sin_port = in_port_t(port).bigEndian
              inet_pton(AF_INET, (ip as NSString).utf8String, &addr.sin_addr)
              
              let addrData = Data(bytes: &addr, count: MemoryLayout<sockaddr_in>.size)
              let connectResult = CFSocketConnectToAddress(socket, addrData as CFData, 5.0)
              
              print("[DEBUG] TCP connection result: \(connectResult)")
              tcpSuccess = (connectResult == .success)
              
              // Prova a inviare una richiesta
              if connectResult == .success {
                let request = "GET / HTTP/1.0\r\n\r\n"
                if let data = request.data(using: .ascii) {
                  let fd = CFSocketGetNative(socket)
                  data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Void in
                    if let baseAddress = bytes.baseAddress {
                      let sent = send(fd, baseAddress, data.count, 0)
                      print("[DEBUG] Sent request: \(sent) bytes")
                    }
                  }
                  
                  // Leggi la risposta
                  let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                  defer { buffer.deallocate() }
                  
                  let bytesRead = recv(fd, buffer, 4096, 0)
                  print("[DEBUG] Received response: \(bytesRead) bytes")
                  
                  if bytesRead > 0 {
                    let responseData = Data(bytes: buffer, count: bytesRead)
                    let hexString = responseData.prefix(100).map { String(format: "%02X", $0) }.joined(separator: " ")
                    print("[DEBUG] Response data: \(hexString)")
                  }
                }
              }
              
              CFSocketInvalidate(socket)
            }
            
            // Test HTTP
            let url = URL(string: "http://\(ip):\(port)")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            
            let semaphore = DispatchSemaphore(value: 0)
            var httpSuccess = false
            
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
              if let error = error {
                print("[DEBUG] HTTP error: \(error.localizedDescription)")
              } else if let httpResponse = response as? HTTPURLResponse {
                print("[DEBUG] HTTP response: \(httpResponse.statusCode)")
                httpSuccess = true
              }
              semaphore.signal()
            }
            
            task.resume()
            _ = semaphore.wait(timeout: .now() + 6)
            
            print("[DEBUG] HTTP connection success: \(httpSuccess)")
            
            result(["tcp": tcpSuccess, "http": httpSuccess])
          } catch {
            print("[ERROR] Debug connection error: \(error.localizedDescription)")
            result(FlutterError(code: "DEBUG_ERROR", message: error.localizedDescription, details: nil))
          }
        }
        
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
  
  private func initializeDecoder(width: Int, height: Int, bufferSize: Int, result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .background).async {
      do {
        print("[DEBUG] Creating video decoder with real frame processing")
        self.videoDecoder = VideoDecoder()
        
        if self.videoDecoder?.initialize(width: width, height: height) == true {
          print("[DEBUG] Video decoder initialized")
          
          print("[DEBUG] Creating video player")
          self.videoPlayer = VideoPlayer(decoder: self.videoDecoder!)
          
          result(true)
        } else {
          print("[ERROR] Failed to initialize decoder")
          result(FlutterError(code: "INIT_ERROR", message: "Failed to initialize decoder", details: nil))
        }
      }
      
      result(true)
    }
  }
  
  private func releaseDecoder() {
    print("[DEBUG] Releasing decoder")
    videoPlayer?.dispose()
    videoPlayer = nil
    videoDecoder = nil
    buttonListener?.stopListening()
    buttonListener = nil
  }
  
  private func testConnection(ip: String) throws -> Bool {
    let hostURL = URL(string: "http://\(ip)")!
    var request = URLRequest(url: hostURL)
    request.timeoutInterval = 5
    
    let semaphore = DispatchSemaphore(value: 0)
    var success = false
    
    let task = URLSession.shared.dataTask(with: request) { _, response, error in
      if let httpResponse = response as? HTTPURLResponse {
        success = (200...299).contains(httpResponse.statusCode)
      }
      semaphore.signal()
    }
    
    task.resume()
    _ = semaphore.wait(timeout: .now() + 6)
    
    return success
  }
  
  private func pingHost(ip: String) throws -> String {
    // Su iOS non abbiamo accesso diretto al comando ping
    // Implementiamo un ping semplificato usando una richiesta HTTP
    let hostURL = URL(string: "http://\(ip)")!
    var request = URLRequest(url: hostURL)
    request.timeoutInterval = 2
    
    let semaphore = DispatchSemaphore(value: 0)
    var responseTime: TimeInterval = 0
    var errorMessage: String?
    
    let startTime = Date()
    
    let task = URLSession.shared.dataTask(with: request) { _, response, error in
      responseTime = Date().timeIntervalSince(startTime)
      
      if let error = error {
        errorMessage = error.localizedDescription
      }
      
      semaphore.signal()
    }
    
    task.resume()
    _ = semaphore.wait(timeout: .now() + 3)
    
    if let errorMessage = errorMessage {
      return "Failed to ping \(ip): \(errorMessage)"
    } else {
      return "Ping to \(ip): \(Int(responseTime * 1000)) ms"
    }
  }
  
  private func tryAlternativePorts(ip: String, methodChannel: FlutterMethodChannel) {
    // Array di porte comuni per telecamere IP
    let commonPorts = [80, 8080, 554, 8554, 40005, 40004, 8000, 8081, 9000]
    
    DispatchQueue.global(qos: .background).async {
        for port in commonPorts {
            print("[DEBUG] Trying connection to \(ip):\(port)")
            
            // Ferma la riproduzione corrente
            self.videoPlayer?.stopPlayback()
            
            // Avvia la riproduzione sulla nuova porta
            self.videoPlayer?.startPlayback(ip: ip, port: port) { (frameData) in
                DispatchQueue.main.async {
                    methodChannel.invokeMethod("onFrame", arguments: frameData)
                }
            }
            
            // Attendi un po' per vedere se riceviamo immagini
            Thread.sleep(forTimeInterval: 3.0)
            
            // Se abbiamo ricevuto un frame valido, interrompi il ciclo
            if let _ = self.videoPlayer?.captureCurrentFrame() {
                print("[DEBUG] Successfully connected to \(ip):\(port)")
                break
            }
        }
    }
  }
}
