package com.example.a

import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

class ButtonListener(private val ip: String, private val port: Int = 40004) {
    private var serverSocket: ServerSocket? = null
    private var clientSocket: Socket? = null
    private var isListening = AtomicBoolean(false)
    private var listenerThread: Thread? = null
    
    // Callback per notificare quando il pulsante viene premuto
    var onButtonPressed: (() -> Unit)? = null
    var onButtonReleased: (() -> Unit)? = null
    
    fun startListening() {
        if (isListening.get()) {
            println("[DEBUG] Button listener already running")
            return
        }
        
        isListening.set(true)
        
        listenerThread = thread {
            try {
                println("[DEBUG] Starting button listener on port $port in SERVER mode")
                // Utilizziamo principalmente la modalità server
                listenForConnections()
            } catch (e: Exception) {
                println("[ERROR] Failed to start button listener: ${e.message}")
                e.printStackTrace()
            } finally {
                stopListening()
            }
        }
    }
    
    // Modalità server: ascolta le connessioni in arrivo
    private fun listenForConnections() {
        try {
            println("[DEBUG] Creating server socket on port $port")
            // Crea un server socket che accetta connessioni da qualsiasi indirizzo
            serverSocket = ServerSocket(port, 50, null)
            
            println("[DEBUG] Server socket created successfully, waiting for connections")
            
            while (isListening.get()) {
                try {
                    println("[DEBUG] Waiting for connection on port $port")
                    val socket = serverSocket?.accept()
                    if (socket != null) {
                        println("[DEBUG] Received connection from ${socket.inetAddress.hostAddress}")
                        
                        // Gestisci la connessione in un thread separato
                        thread {
                            try {
                                handleConnection(socket)
                            } catch (e: Exception) {
                                println("[ERROR] Error handling connection: ${e.message}")
                                e.printStackTrace()
                            } finally {
                                try {
                                    socket.close()
                                } catch (e: Exception) {
                                    // Ignora errori di chiusura
                                }
                            }
                        }
                    }
                } catch (e: Exception) {
                    if (isListening.get()) {
                        println("[ERROR] Error accepting connection: ${e.message}")
                        e.printStackTrace()
                        // Breve pausa prima di riprovare
                        Thread.sleep(1000)
                    }
                }
            }
        } catch (e: Exception) {
            println("[ERROR] Failed to create server socket: ${e.message}")
            e.printStackTrace()
        }
    }
    
    private fun handleConnection(socket: Socket) {
        println("[DEBUG] Handling connection from ${socket.inetAddress.hostAddress}")
        
        try {
            val inputStream = socket.getInputStream()
            val buffer = ByteArray(10)
            
            // Continua a leggere dati finché la connessione è attiva
            while (isListening.get() && !socket.isClosed) {
                val bytesRead = inputStream.read(buffer)
                if (bytesRead <= 0) {
                    println("[DEBUG] End of stream reached")
                    break
                }
                
                println("[DEBUG] Received $bytesRead bytes")
                
                // Stampa i byte ricevuti per debug
                val hexString = buffer.take(bytesRead).joinToString(" ") { 
                    String.format("%02X", it) 
                }
                println("[DEBUG] Received data: $hexString")
                
                // Analizza il pacchetto - l'ottavo byte (indice 7) indica lo stato del pulsante
                if (bytesRead >= 8) {
                    val buttonState = buffer[7].toInt() and 0xFF
                    println("[DEBUG] Received button state: $buttonState")
                    
                    if (buttonState > 0) {
                        println("[DEBUG] Button pressed!")
                        onButtonPressed?.invoke()
                    } else {
                        println("[DEBUG] Button released!")
                        onButtonReleased?.invoke()
                    }
                }
            }
        } catch (e: Exception) {
            if (isListening.get()) {
                println("[ERROR] Error reading from socket: ${e.message}")
                e.printStackTrace()
            }
        }
    }
    
    fun stopListening() {
        isListening.set(false)
        try {
            println("[DEBUG] Stopping button listener")
            
            serverSocket?.close()
            serverSocket = null
            
            clientSocket?.close()
            clientSocket = null
            
            listenerThread?.join(1000)
            listenerThread = null
            
            println("[DEBUG] Button listener stopped")
        } catch (e: Exception) {
            println("[ERROR] Error stopping button listener: ${e.message}")
            e.printStackTrace()
        }
    }
} 