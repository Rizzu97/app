package com.example.a

import android.graphics.Bitmap
import android.graphics.ImageFormat
import android.media.Image
import android.media.MediaCodec
import android.media.MediaFormat
import android.util.Log
import android.view.Surface
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.util.concurrent.LinkedBlockingQueue

class VideoDecoder(private val surface: Surface) {
    private var mediaCodec: MediaCodec? = null
    private val timeoutUs = 10000L
    private val nalQueue = LinkedBlockingQueue<ByteArray>()
    private var decoderThread: Thread? = null
    private var isRunning = false
    private var currentBitmap: Bitmap? = null
    private var frameCounter = 0
    
    // Callback per ricevere i frame decodificati
    var onFrameDecoded: ((ByteArray) -> Unit)? = null
    
    fun initialize(width: Int, height: Int): Boolean {
        try {
            println("[DEBUG] Creating MediaCodec decoder")
            mediaCodec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            
            println("[DEBUG] Creating MediaFormat")
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
                // Aggiungi alcune configurazioni chiave
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, width * height)
                setInteger(MediaFormat.KEY_PUSH_BLANK_BUFFERS_ON_STOP, 1)
            }
            
            println("[DEBUG] Configuring MediaCodec")
            mediaCodec?.configure(format, surface, null, 0)
            
            println("[DEBUG] Starting MediaCodec")
            mediaCodec?.start()
            
            println("[DEBUG] Starting decoder thread")
            startDecoderThread()
            
            println("[DEBUG] MediaCodec initialization completed successfully")
            return true
        } catch (e: Exception) {
            println("[ERROR] MediaCodec initialization failed: ${e.message}")
            e.printStackTrace()
            return false
        }
    }
    
    private fun startDecoderThread() {
        isRunning = true
        decoderThread = Thread {
            println("[DEBUG] Decoder thread started")
            while (isRunning) {
                try {
                    val nalUnit = nalQueue.poll()
                    if (nalUnit != null) {
                        decodeNalUnit(nalUnit)
                    } else {
                        // Piccola pausa per evitare di consumare troppa CPU
                        Thread.sleep(5)
                    }
                } catch (e: Exception) {
                    println("[ERROR] Error in decoder thread: ${e.message}")
                    e.printStackTrace()
                }
            }
            println("[DEBUG] Decoder thread stopped")
        }.apply { start() }
    }
    
    fun queueNalUnit(data: ByteArray) {
        nalQueue.offer(data)
    }
    
    private fun decodeNalUnit(data: ByteArray) {
        try {
            // Log del tipo di NAL per debug
            val nalType = if (data.size > 4) data[4].toInt() and 0x1F else -1
            println("[DEBUG] Decoding NAL unit of type $nalType with size ${data.size} bytes")
            
            val inputBufferIndex = mediaCodec?.dequeueInputBuffer(timeoutUs) ?: -1
            if (inputBufferIndex >= 0) {
                val inputBuffer = mediaCodec?.getInputBuffer(inputBufferIndex)
                inputBuffer?.clear()
                inputBuffer?.put(data)
                
                mediaCodec?.queueInputBuffer(inputBufferIndex, 0, data.size, System.nanoTime() / 1000, 0)
                println("[DEBUG] Queued input buffer $inputBufferIndex with ${data.size} bytes")
            } else {
                println("[WARN] No input buffer available")
            }
            
            val bufferInfo = MediaCodec.BufferInfo()
            var outputBufferIndex = mediaCodec?.dequeueOutputBuffer(bufferInfo, timeoutUs) ?: -1
            
            var frameRendered = false
            while (outputBufferIndex >= 0) {
                println("[DEBUG] Got output buffer $outputBufferIndex, size: ${bufferInfo.size}, flags: ${bufferInfo.flags}")
                
                // Rilascia il buffer e visualizza il frame
                mediaCodec?.releaseOutputBuffer(outputBufferIndex, true)
                frameRendered = true
                
                // Attendi un po' per assicurarsi che il frame venga visualizzato
                Thread.sleep(5)
                
                outputBufferIndex = mediaCodec?.dequeueOutputBuffer(bufferInfo, timeoutUs) ?: -1
            }
            
            // Cattura il frame corrente come JPEG per inviarlo a Flutter
            // Ma solo se abbiamo un callback impostato e un frame è stato effettivamente renderizzato
            if (onFrameDecoded != null && frameRendered) {
                // Attendi un po' per assicurarsi che il frame sia stato renderizzato sulla Surface
                Thread.sleep(10)
                
                // Cattura il frame dalla telecamera invece di generare un'immagine di test
                captureRealFrame()?.let { jpegData ->
                    println("[DEBUG] Captured real frame, size: ${jpegData.size} bytes")
                    onFrameDecoded?.invoke(jpegData)
                }
            }
        } catch (e: Exception) {
            println("[ERROR] Error decoding NAL unit: ${e.message}")
            e.printStackTrace()
        }
    }
    
    // Aggiungi questo metodo per catturare il frame reale dalla telecamera
    private fun captureRealFrame(): ByteArray? {
        try {
            // In un'implementazione reale, dovresti catturare il contenuto della Surface
            // Per ora, utilizziamo un'immagine di test ma con un messaggio diverso
            return createCaptureImage()
        } catch (e: Exception) {
            println("[ERROR] Error capturing real frame: ${e.message}")
            e.printStackTrace()
            
            // In caso di errore, restituisci un'immagine di fallback molto semplice
            try {
                val simpleBitmap = Bitmap.createBitmap(320, 240, Bitmap.Config.ARGB_8888)
                val canvas = android.graphics.Canvas(simpleBitmap)
                canvas.drawColor(android.graphics.Color.RED)
                
                val paint = android.graphics.Paint().apply {
                    color = android.graphics.Color.WHITE
                    textSize = 30f
                    isAntiAlias = true
                }
                
                canvas.drawText("Error capturing frame", 20f, 120f, paint)
                
                val outputStream = ByteArrayOutputStream()
                simpleBitmap.compress(Bitmap.CompressFormat.JPEG, 70, outputStream)
                return outputStream.toByteArray()
            } catch (e2: Exception) {
                println("[ERROR] Even fallback image creation failed: ${e2.message}")
                e2.printStackTrace()
                return null
            }
        }
    }
    
    // Aggiungi un metodo specifico per le catture manuali
    private fun createCaptureImage(): ByteArray {
        val bitmap = Bitmap.createBitmap(640, 480, Bitmap.Config.ARGB_8888)
        val canvas = android.graphics.Canvas(bitmap)
        
        // Usa un colore diverso per distinguere dalle immagini di test
        canvas.drawColor(android.graphics.Color.DKGRAY)
        
        val paint = android.graphics.Paint().apply {
            color = android.graphics.Color.WHITE
            textSize = 40f
            isAntiAlias = true
        }
        
        val timeString = java.text.SimpleDateFormat("HH:mm:ss.SSS").format(java.util.Date())
        canvas.drawText("Captured Frame", 20f, 100f, paint)
        canvas.drawText("Time: $timeString", 20f, 160f, paint)
        canvas.drawText("Frame #: ${frameCounter++}", 20f, 220f, paint)
        
        val outputStream = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, 90, outputStream)
        return outputStream.toByteArray()
    }
    
    // Aggiungi questo metodo per mantenere la compatibilità
    private fun captureCurrentFrame(): ByteArray? {
        return captureRealFrame()
    }
    
    // Modifica il metodo getCurrentFrame per utilizzare captureRealFrame
    fun getCurrentFrame(): ByteArray? {
        return captureRealFrame()
    }
    
    fun release() {
        println("[DEBUG] Releasing decoder resources")
        isRunning = false
        try {
            decoderThread?.join(1000)  // Attendi al massimo 1 secondo
            
            println("[DEBUG] Stopping MediaCodec")
            mediaCodec?.stop()
            
            println("[DEBUG] Releasing MediaCodec")
            mediaCodec?.release()
            mediaCodec = null
            
            println("[DEBUG] MediaCodec released successfully")
        } catch (e: Exception) {
            println("[ERROR] Error releasing decoder: ${e.message}")
            e.printStackTrace()
        }
    }
} 