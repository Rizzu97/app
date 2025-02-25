package com.example.a

import java.io.InputStream
import java.net.Socket
import java.net.InetSocketAddress
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

class VideoPlayer(private val decoder: VideoDecoder) {
    private var socket: Socket? = null
    private var isPlaying = AtomicBoolean(false)
    private var networkThread: Thread? = null
    private var currentFrame: ByteArray? = null
    private var cameraProtocolType = 0 // 0 = standard, 1 = HTTP, 2 = RTSP, 3 = ONVIF
    
    fun startPlayback(ip: String, port: Int, onFrame: (ByteArray) -> Unit) {
        if (isPlaying.get()) {
            println("[DEBUG] Playback already in progress, ignoring request")
            return
        }
        
        isPlaying.set(true)
        
        // Imposta il callback per ricevere i frame decodificati
        decoder.onFrameDecoded = { jpegData ->
            currentFrame = jpegData
            onFrame(jpegData)
        }
        
        networkThread = thread {
            try {
                // Seleziona la porta in base al protocollo
                val actualPort = when (cameraProtocolType) {
                    0 -> port  // Porta standard (40005)
                    1 -> 80    // HTTP
                    2 -> 554   // RTSP
                    3 -> 80    // ONVIF (di solito usa HTTP)
                    else -> port
                }
                
                println("[DEBUG] Connecting to $ip:$actualPort using protocol type $cameraProtocolType")
                
                // Utilizziamo un timeout per la connessione
                socket = Socket()
                socket?.connect(InetSocketAddress(ip, actualPort), 5000)
                
                if (socket?.isConnected == true) {
                    println("[DEBUG] Successfully connected to $ip:$actualPort")
                    
                    // Verifica che il socket sia effettivamente aperto
                    if (socket?.isClosed == true) {
                        println("[ERROR] Socket is closed immediately after connection")
                        isPlaying.set(false)
                        return@thread
                    }
                    
                    val inputStream = socket?.getInputStream()
                    if (inputStream == null) {
                        println("[ERROR] Failed to get input stream from socket")
                        isPlaying.set(false)
                        return@thread
                    }
                    
                    println("[DEBUG] Sending initialization command for protocol type $cameraProtocolType")
                    val initSuccess = sendInitCommand()
                    if (!initSuccess) {
                        println("[ERROR] Failed to send initialization command")
                        isPlaying.set(false)
                        return@thread
                    }
                    
                    // Attendi un breve periodo dopo l'invio del comando di inizializzazione
                    Thread.sleep(1000)
                    
                    println("[DEBUG] Starting to read video stream")
                    println("[DEBUG] Input stream available bytes: ${inputStream.available()}")
                    
                    // Seleziona il metodo di lettura in base al protocollo
                    when (cameraProtocolType) {
                        0 -> readStandardVideoStream(inputStream)
                        1 -> readHttpVideoStream(inputStream)
                        2 -> readRtspVideoStream(inputStream)
                        3 -> readOnvifVideoStream(inputStream)
                        else -> readStandardVideoStream(inputStream)
                    }
                } else {
                    println("[ERROR] Failed to connect to $ip:$actualPort")
                    isPlaying.set(false)
                }
            } catch (e: Exception) {
                println("[ERROR] Error in playback thread: ${e.message}")
                e.printStackTrace()
                isPlaying.set(false)
            }
        }
    }
    
    private fun sendInitCommand(): Boolean {
        try {
            val outputStream = socket?.getOutputStream()
            if (outputStream == null) {
                println("[ERROR] Failed to get output stream from socket")
                return false
            }
            
            val command = createInitCommand()
            println("[DEBUG] Sending command: ${command.joinToString(", ") { "0x${it.toInt().and(0xFF).toString(16).padStart(2, '0')}" }}")
            
            outputStream.write(command)
            outputStream.flush()
            println("[DEBUG] Initialization command sent successfully")
            return true
        } catch (e: Exception) {
            println("[ERROR] Error sending init command: ${e.message}")
            e.printStackTrace()
            return false
        }
    }
    
    private fun createInitCommand(): ByteArray {
        return when (cameraProtocolType) {
            0 -> createStandardInitCommand()
            1 -> createHttpCommand()
            2 -> createRtspCommand()
            3 -> createOnvifCommand()
            else -> createStandardInitCommand()
        }
    }
    
    private fun createStandardInitCommand(): ByteArray {
        val calendar = java.util.Calendar.getInstance()
        return byteArrayOf(
            0x5f, 0x6f,  // Magic number
            0x00, 0x00,  // Reserved
            (calendar.get(java.util.Calendar.YEAR) - 2000).toByte(),
            (calendar.get(java.util.Calendar.MONTH) + 1).toByte(),
            calendar.get(java.util.Calendar.DAY_OF_MONTH).toByte(),
            calendar.get(java.util.Calendar.HOUR_OF_DAY).toByte(),
            calendar.get(java.util.Calendar.MINUTE).toByte(),
            calendar.get(java.util.Calendar.SECOND).toByte(),
            11,  // Fixed value
            0    // Reserved
        )
    }
    
    private fun createHttpCommand(): ByteArray {
        // Comando HTTP per telecamere che supportano lo streaming HTTP
        val request = "GET /videostream.cgi?user=admin&pwd=admin HTTP/1.1\r\n" +
                     "Host: ${socket?.inetAddress?.hostAddress}\r\n" +
                     "Connection: keep-alive\r\n\r\n"
        return request.toByteArray()
    }
    
    private fun createRtspCommand(): ByteArray {
        // Comando RTSP per telecamere che supportano RTSP
        val request = "OPTIONS rtsp://${socket?.inetAddress?.hostAddress}:554/h264/ch1/main/av_stream RTSP/1.0\r\n" +
                     "CSeq: 1\r\n" +
                     "User-Agent: IP Camera Client\r\n\r\n"
        return request.toByteArray()
    }
    
    private fun createOnvifCommand(): ByteArray {
        // Comando ONVIF per telecamere che supportano ONVIF
        val request = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\r\n" +
                     "<s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\">\r\n" +
                     "  <s:Body>\r\n" +
                     "    <GetSystemDateAndTime xmlns=\"http://www.onvif.org/ver10/device/wsdl\"/>\r\n" +
                     "  </s:Body>\r\n" +
                     "</s:Envelope>\r\n"
        return request.toByteArray()
    }
    
    private fun readStandardVideoStream(inputStream: InputStream) {
        val buffer = ByteArray(16384)
        val nalBuffer = ByteArray(1000000)
        var nalBufferPosition = 0
        var totalBytesRead = 0
        var framesProcessed = 0
        
        println("[DEBUG] Starting to read standard video stream loop")
        
        // Aggiungi un flag per tracciare se abbiamo trovato l'inizio di un NAL
        var foundNalStart = false
        
        while (isPlaying.get()) {
            try {
                // Verifica se ci sono dati disponibili
                if (inputStream.available() <= 0) {
                    Thread.sleep(10)  // Ridotto a 10ms per una risposta più rapida
                    continue
                }
                
                val bytesRead = inputStream.read(buffer)
                totalBytesRead += bytesRead
                
                if (bytesRead <= 0) {
                    println("[DEBUG] End of stream reached after reading $totalBytesRead bytes total")
                    break
                }
                
                // Elabora i dati ricevuti
                for (i in 0 until bytesRead) {
                    // Cerca il codice di inizio NAL (0x00 0x00 0x00 0x01)
                    if (i >= 3 && 
                        buffer[i-3] == 0.toByte() && 
                        buffer[i-2] == 0.toByte() && 
                        buffer[i-1] == 0.toByte() && 
                        buffer[i] == 1.toByte()) {
                        
                        // Abbiamo trovato l'inizio di un nuovo NAL
                        if (foundNalStart && nalBufferPosition > 4) {
                            // Invia il NAL precedente al decoder
                            val nalUnit = ByteArray(nalBufferPosition)
                            System.arraycopy(nalBuffer, 0, nalUnit, 0, nalBufferPosition)
                            
                            // Log del tipo di NAL per debug
                            val nalType = if (nalUnit.size > 4) nalUnit[4].toInt() and 0x1F else -1
                            println("[DEBUG] Found NAL unit of type $nalType with size $nalBufferPosition bytes")
                            
                            decoder.queueNalUnit(nalUnit)
                            framesProcessed++
                        }
                        
                        // Inizia un nuovo NAL
                        nalBufferPosition = 0
                        foundNalStart = true
                        
                        // Aggiungi il codice di inizio NAL al buffer
                        nalBuffer[nalBufferPosition++] = 0
                        nalBuffer[nalBufferPosition++] = 0
                        nalBuffer[nalBufferPosition++] = 0
                        nalBuffer[nalBufferPosition++] = 1
                        continue
                    }
                    
                    // Aggiungi il byte corrente al buffer NAL
                    if (foundNalStart && nalBufferPosition < nalBuffer.size) {
                        nalBuffer[nalBufferPosition++] = buffer[i]
                    }
                }
                
                // Stampa un log periodico
                if (framesProcessed % 10 == 0 && framesProcessed > 0) {
                    println("[DEBUG] Processed $framesProcessed NAL units so far")
                }
                
            } catch (e: Exception) {
                println("[ERROR] Error reading video stream: ${e.message}")
                e.printStackTrace()
                break
            }
        }
        
        // Invia l'ultimo NAL se presente
        if (foundNalStart && nalBufferPosition > 4) {
            val nalUnit = ByteArray(nalBufferPosition)
            System.arraycopy(nalBuffer, 0, nalUnit, 0, nalBufferPosition)
            decoder.queueNalUnit(nalUnit)
            framesProcessed++
        }
        
        println("[DEBUG] Video stream reading stopped after processing $framesProcessed frames")
    }
    
    private fun readHttpVideoStream(inputStream: InputStream) {
        println("[DEBUG] Starting to read HTTP video stream")
        
        // Per i flussi HTTP, dobbiamo prima leggere l'intestazione HTTP
        val headerBuffer = StringBuilder()
        var byte: Int
        var contentLength = -1
        var isChunked = false
        
        // Leggi l'intestazione HTTP
        while (isPlaying.get()) {
            byte = inputStream.read()
            if (byte == -1) break
            
            headerBuffer.append(byte.toChar())
            
            // Cerca la fine dell'intestazione HTTP
            if (headerBuffer.endsWith("\r\n\r\n")) {
                println("[DEBUG] HTTP header received: ${headerBuffer.toString()}")
                
                // Estrai Content-Length se presente
                val contentLengthMatch = Regex("Content-Length: (\\d+)").find(headerBuffer.toString())
                if (contentLengthMatch != null) {
                    contentLength = contentLengthMatch.groupValues[1].toInt()
                    println("[DEBUG] Content-Length: $contentLength")
                }
                
                // Verifica se il trasferimento è chunked
                isChunked = headerBuffer.contains("Transfer-Encoding: chunked")
                println("[DEBUG] Chunked encoding: $isChunked")
                
                break
            }
        }
        
        // Leggi il corpo della risposta
        if (isChunked) {
            readChunkedHttpStream(inputStream)
        } else if (contentLength > 0) {
            readFixedLengthHttpStream(inputStream, contentLength)
        } else {
            readContinuousHttpStream(inputStream)
        }
    }
    
    private fun readRtspVideoStream(inputStream: InputStream) {
        println("[DEBUG] Starting to read RTSP video stream")
        
        // Implementazione semplificata per RTSP
        // In una implementazione reale, dovresti gestire il protocollo RTSP completo
        val buffer = ByteArray(16384)
        
        while (isPlaying.get()) {
            try {
                val bytesRead = inputStream.read(buffer)
                if (bytesRead <= 0) break
                
                println("[DEBUG] Read $bytesRead bytes from RTSP stream")
                
                // Qui dovresti elaborare i dati RTP/RTSP
                // Per semplicità, inviamo i dati grezzi al decoder
                val frameData = ByteArray(bytesRead)
                System.arraycopy(buffer, 0, frameData, 0, bytesRead)
                decoder.queueNalUnit(frameData)
                
            } catch (e: Exception) {
                println("[ERROR] Error reading RTSP stream: ${e.message}")
                e.printStackTrace()
                break
            }
        }
    }
    
    private fun readOnvifVideoStream(inputStream: InputStream) {
        println("[DEBUG] Starting to read ONVIF video stream")
        
        // Implementazione semplificata per ONVIF
        // In una implementazione reale, dovresti gestire il protocollo ONVIF completo
        val buffer = ByteArray(16384)
        
        while (isPlaying.get()) {
            try {
                val bytesRead = inputStream.read(buffer)
                if (bytesRead <= 0) break
                
                println("[DEBUG] Read $bytesRead bytes from ONVIF stream")
                
                // Qui dovresti elaborare i dati ONVIF
                // Per semplicità, inviamo i dati grezzi al decoder
                val frameData = ByteArray(bytesRead)
                System.arraycopy(buffer, 0, frameData, 0, bytesRead)
                decoder.queueNalUnit(frameData)
                
            } catch (e: Exception) {
                println("[ERROR] Error reading ONVIF stream: ${e.message}")
                e.printStackTrace()
                break
            }
        }
    }
    
    private fun readChunkedHttpStream(inputStream: InputStream) {
        println("[DEBUG] Reading chunked HTTP stream")
        
        val buffer = ByteArray(16384)
        val nalBuffer = ByteArray(1000000)
        var nalBufferPosition = 0
        
        while (isPlaying.get()) {
            try {
                // Leggi la dimensione del chunk
                val chunkSizeStr = readLine(inputStream)
                if (chunkSizeStr.isNullOrEmpty()) break
                
                val chunkSize = chunkSizeStr.trim().toInt(16)
                println("[DEBUG] Chunk size: $chunkSize")
                
                if (chunkSize == 0) {
                    // Fine dei chunk
                    println("[DEBUG] End of chunked data")
                    break
                }
                
                // Leggi il chunk
                var bytesRemaining = chunkSize
                while (bytesRemaining > 0) {
                    val toRead = Math.min(bytesRemaining, buffer.size)
                    val bytesRead = inputStream.read(buffer, 0, toRead)
                    if (bytesRead <= 0) break
                    
                    // Elabora i dati ricevuti
                    processVideoData(buffer, bytesRead, nalBuffer, nalBufferPosition)
                    bytesRemaining -= bytesRead
                }
                
                // Leggi CRLF dopo il chunk
                inputStream.read() // CR
                inputStream.read() // LF
                
            } catch (e: Exception) {
                println("[ERROR] Error reading chunked HTTP stream: ${e.message}")
                e.printStackTrace()
                break
            }
        }
    }
    
    private fun readFixedLengthHttpStream(inputStream: InputStream, contentLength: Int) {
        println("[DEBUG] Reading fixed length HTTP stream: $contentLength bytes")
        
        val buffer = ByteArray(16384)
        val nalBuffer = ByteArray(1000000)
        var nalBufferPosition = 0
        var bytesRemaining = contentLength
        
        while (isPlaying.get() && bytesRemaining > 0) {
            try {
                val toRead = Math.min(bytesRemaining, buffer.size)
                val bytesRead = inputStream.read(buffer, 0, toRead)
                if (bytesRead <= 0) break
                
                // Elabora i dati ricevuti
                processVideoData(buffer, bytesRead, nalBuffer, nalBufferPosition)
                bytesRemaining -= bytesRead
                
            } catch (e: Exception) {
                println("[ERROR] Error reading fixed length HTTP stream: ${e.message}")
                e.printStackTrace()
                break
            }
        }
        
        println("[DEBUG] Fixed length HTTP stream completed")
    }
    
    private fun readContinuousHttpStream(inputStream: InputStream) {
        println("[DEBUG] Reading continuous HTTP stream")
        
        val buffer = ByteArray(16384)
        val nalBuffer = ByteArray(1000000)
        var nalBufferPosition = 0
        
        while (isPlaying.get()) {
            try {
                val bytesRead = inputStream.read(buffer)
                if (bytesRead <= 0) break
                
                // Elabora i dati ricevuti
                processVideoData(buffer, bytesRead, nalBuffer, nalBufferPosition)
                
            } catch (e: Exception) {
                println("[ERROR] Error reading continuous HTTP stream: ${e.message}")
                e.printStackTrace()
                break
            }
        }
        
        println("[DEBUG] Continuous HTTP stream completed")
    }
    
    private fun readLine(inputStream: InputStream): String? {
        val line = StringBuilder()
        var byte: Int
        
        while (true) {
            byte = inputStream.read()
            if (byte == -1) return null
            
            if (byte == '\r'.toInt()) {
                // Ignora CR
                continue
            } else if (byte == '\n'.toInt()) {
                // Fine della riga
                break
            } else {
                line.append(byte.toChar())
            }
        }
        
        return line.toString()
    }
    
    fun stopPlayback() {
        println("[DEBUG] Stopping playback")
        isPlaying.set(false)
        try {
            println("[DEBUG] Closing socket")
            socket?.close()
            socket = null
            
            println("[DEBUG] Waiting for network thread to finish")
            networkThread?.join(1000)  // Attendi al massimo 1 secondo
            networkThread = null
        } catch (e: Exception) {
            println("[ERROR] Error stopping playback: ${e.message}")
            e.printStackTrace()
        }
    }
    
    fun captureCurrentFrame(): ByteArray? {
        try {
            println("[DEBUG] Attempting to capture current frame")
            val frame = decoder.getCurrentFrame()
            if (frame != null) {
                println("[DEBUG] Got frame from decoder, size: ${frame.size} bytes")
                return frame
            }
            
            println("[DEBUG] No frame from decoder, using cached frame")
            return currentFrame
        } catch (e: Exception) {
            println("[ERROR] Error in captureCurrentFrame: ${e.message}")
            e.printStackTrace()
            
            // In caso di errore, restituisci il frame memorizzato nella cache
            println("[DEBUG] Using cached frame due to error")
            return currentFrame
        }
    }
    
    fun dispose() {
        stopPlayback()
        decoder.onFrameDecoded = null
    }
    
    fun tryAlternativeProtocol() {
        cameraProtocolType = (cameraProtocolType + 1) % 4
        println("[DEBUG] Switching to camera protocol type: $cameraProtocolType")
    }
    
    /**
     * Elabora i dati video ricevuti cercando le unità NAL
     * @param buffer Buffer contenente i dati ricevuti
     * @param bytesRead Numero di byte letti
     * @param nalBuffer Buffer per memorizzare l'unità NAL corrente
     * @param nalBufferPosition Posizione corrente nel buffer NAL
     * @return Numero di unità NAL trovate
     */
    private fun processVideoData(buffer: ByteArray, bytesRead: Int, nalBuffer: ByteArray, nalBufferPosition: Int): Int {
        var pos = 0
        var currentNalPos = nalBufferPosition
        var nalsFound = 0
        
        // Cerca le unità NAL nel buffer
        while (pos < bytesRead) {
            // Cerca il codice di inizio NAL (0x00 0x00 0x00 0x01)
            if (pos >= 3 && 
                buffer[pos-3] == 0.toByte() && 
                buffer[pos-2] == 0.toByte() && 
                buffer[pos-1] == 0.toByte() && 
                buffer[pos] == 1.toByte()) {
                
                // Abbiamo trovato l'inizio di un nuovo NAL
                if (currentNalPos > 4) {  // Se abbiamo già un NAL in corso (escludendo il codice di inizio)
                    // Invia il NAL precedente al decoder
                    val nalUnit = ByteArray(currentNalPos)
                    System.arraycopy(nalBuffer, 0, nalUnit, 0, currentNalPos)
                    
                    // Log del tipo di NAL per debug
                    val nalType = if (nalUnit.size > 4) nalUnit[4].toInt() and 0x1F else -1
                    println("[DEBUG] Found NAL unit of type $nalType with size $currentNalPos bytes")
                    
                    decoder.queueNalUnit(nalUnit)
                    nalsFound++
                }
                
                // Inizia un nuovo NAL
                currentNalPos = 0
                
                // Aggiungi il codice di inizio NAL al buffer
                nalBuffer[currentNalPos++] = 0
                nalBuffer[currentNalPos++] = 0
                nalBuffer[currentNalPos++] = 0
                nalBuffer[currentNalPos++] = 1
                pos++
                continue
            }
            
            // Aggiungi il byte corrente al buffer NAL
            if (currentNalPos < nalBuffer.size) {
                nalBuffer[currentNalPos++] = buffer[pos]
            } else {
                // Buffer NAL pieno, dobbiamo scartare i dati
                println("[WARN] NAL buffer overflow, discarding data")
            }
            pos++
        }
        
        return nalsFound
    }
} 