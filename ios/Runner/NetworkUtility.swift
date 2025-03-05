import Foundation
import Network

class NetworkUtility {
    static func pingHost(_ host: String, completion: @escaping (Bool, String) -> Void) {
        // Su iOS, il comando ping non è disponibile per le app, quindi usiamo una connessione TCP
        let hostEndpoint = NWEndpoint.Host(host)
        let port = NWEndpoint.Port(integerLiteral: 80) // Usiamo la porta HTTP standard
        
        let connection = NWConnection(host: hostEndpoint, port: port, using: .tcp)
        
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                NSLog("[DEBUG] Connection successful to \(host)")
                connection.cancel()
                completion(true, "Host is reachable")
            case .failed(let error):
                NSLog("[DEBUG] Connection failed to \(host): \(error.localizedDescription)")
                connection.cancel()
                completion(false, "Host is unreachable: \(error.localizedDescription)")
            case .cancelled:
                break
            default:
                break
            }
        }
        
        // Impostiamo un timeout di 5 secondi
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            connection.cancel()
            completion(false, "Connection timeout")
        }
        
        connection.start(queue: .global())
    }
    
    static func isHostReachable(_ host: String) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var isReachable = false
        
        pingHost(host) { success, _ in
            isReachable = success
            semaphore.signal()
        }
        
        _ = semaphore.wait(timeout: .now() + 5)
        return isReachable
    }
}
