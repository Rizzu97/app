import Foundation
import Network

class NetworkUtility {
    // Verifica se un host è raggiungibile
    static func isHostReachable(_ ip: String, port: UInt16 = 40005) -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket != -1 else { return false }
        
        defer { close(socket) }
        
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(ip)
        
        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        
        // Se la connessione è rifiutata o non riuscita, proviamo un ping
        if connectResult == -1 {
            NSLog("[INFO] Connect failed, trying ping")
            return isHostPingable(ip)
        }
        
        return true
    }
    
    // Sostituisci il metodo isHostPingable con questa implementazione compatibile con iOS
    static func isHostPingable(_ ip: String) -> Bool {
        // Su iOS non possiamo eseguire comandi di sistema come ping
        // Usiamo invece un timeout più breve per una connessione TCP
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket != -1 else { return false }
        
        defer { close(socket) }
        
        // Imposta un timeout breve (500ms)
        var timeout = timeval(tv_sec: 0, tv_usec: 500000)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        
        // Prova diverse porte comuni
        for port in [80, 443, 22, 40000, 40005] {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(port).bigEndian
            addr.sin_addr.s_addr = inet_addr(ip)
            
            let connectResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            
            if connectResult == 0 || errno == ECONNREFUSED {
                // Se la connessione ha successo o se viene rifiutata,
                // significa che l'host è raggiungibile
                return true
            }
        }
        
        return false
    }
    
    // Ping asincrono
    static func pingHost(_ ip: String, completion: @escaping (Bool, String?) -> Void) {
        DispatchQueue.global(qos: .background).async {
            let result = isHostReachable(ip)
            DispatchQueue.main.async {
                if result {
                    completion(true, nil)
                } else {
                    completion(false, "Host non raggiungibile")
                }
            }
        }
    }
}
