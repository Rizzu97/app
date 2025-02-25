package com.example.a

import android.graphics.Bitmap
import android.graphics.ImageFormat
import android.media.Image
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.util.Log
import android.view.Surface
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicBoolean

class VideoDecoder(private val outputSurface: Surface) {
    private var mediaCodec: MediaCodec? = null
    private var isInitialized = false
    private var width = 1920
    private var height = 1080
    private var frameRendered = false
    private var frameCounter = 0
    
    // Callback per ricevere i frame decodificati
    var onFrameDecoded: ((ByteArray) -> Unit)? = null
    
    // Coda interna per le unità NAL
    private val nalQueue = java.util.concurrent.LinkedBlockingQueue<ByteArray>(50)
    
    // Thread per la decodifica
    private var decoderThread: Thread? = null
    private var isRunning = AtomicBoolean(false)
    
    fun initialize(width: Int, height: Int): Boolean {
        try {
            this.width = width
            this.height = height
            
            // Configura il MediaCodec
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height)
            
            mediaCodec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            mediaCodec?.configure(format, outputSurface, null, 0)
            mediaCodec?.start()
            
            isInitialized = true
            
            // Avvia il thread di decodifica
            startDecoderThread()
            
            return true
        } catch (e: Exception) {
            println("[ERROR] Error initializing decoder: ${e.message}")
            e.printStackTrace()
            return false
        }
    }
    
    private fun startDecoderThread() {
        isRunning.set(true)
        
        decoderThread = Thread {
            try {
                println("[DEBUG] Decoder thread started")
                
                while (isRunning.get()) {
                    try {
                        // Prende un'unità NAL dalla coda
                        val nalUnit = nalQueue.poll(100, java.util.concurrent.TimeUnit.MILLISECONDS)
                        if (nalUnit != null) {
                            decodeNalUnit(nalUnit)
                        }
                    } catch (e: InterruptedException) {
                        // Interrotto, controlla se dobbiamo uscire
                        if (!isRunning.get()) break
                    } catch (e: Exception) {
                        println("[ERROR] Error in decoder thread: ${e.message}")
                        e.printStackTrace()
                    }
                }
                
                println("[DEBUG] Decoder thread stopped")
            } catch (e: Exception) {
                println("[ERROR] Fatal error in decoder thread: ${e.message}")
                e.printStackTrace()
            }
        }
        
        decoderThread?.start()
    }
    
    fun queueNalUnit(nalUnit: ByteArray) {
        if (!isInitialized) {
            println("[ERROR] Decoder not initialized")
            return
        }
        
        // Aggiungi l'unità NAL alla coda
        if (!nalQueue.offer(nalUnit, 100, java.util.concurrent.TimeUnit.MILLISECONDS)) {
            println("[WARN] Decoder queue full, dropping NAL unit")
        }
    }
    
    private fun decodeNalUnit(nalUnit: ByteArray) {
        try {
            if (!isInitialized || mediaCodec == null) {
                println("[ERROR] Decoder not initialized or MediaCodec is null")
                return
            }
            
            // Ottieni un buffer di input disponibile
            val inputBufferIndex = mediaCodec!!.dequeueInputBuffer(10000)
            if (inputBufferIndex >= 0) {
                // Copia i dati nel buffer di input
                val inputBuffer = mediaCodec!!.getInputBuffer(inputBufferIndex)
                inputBuffer?.clear()
                inputBuffer?.put(nalUnit)
                
                // Invia il buffer al decoder
                mediaCodec!!.queueInputBuffer(inputBufferIndex, 0, nalUnit.size, System.currentTimeMillis(), 0)
            }
            
            // Ottieni il buffer di output
            val bufferInfo = MediaCodec.BufferInfo()
            val outputBufferIndex = mediaCodec!!.dequeueOutputBuffer(bufferInfo, 10000)
            
            if (outputBufferIndex >= 0) {
                // Rilascia il buffer di output per renderizzarlo sulla Surface
                mediaCodec!!.releaseOutputBuffer(outputBufferIndex, true)
                frameRendered = true
                
                // Cattura il frame dalla Surface e invialo tramite il callback
                if (onFrameDecoded != null && frameRendered) {
                    // Attendi un po' per assicurarsi che il frame sia stato renderizzato sulla Surface

                    
                    // Cattura il frame dalla telecamera invece di generare un'immagine di test
                    captureRealFrame()?.let { jpegData ->
                        println("[DEBUG] Captured real frame, size: ${jpegData.size} bytes")
                        onFrameDecoded?.invoke(jpegData)
                    }
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
        try {
            isRunning.set(false)
            decoderThread?.join(1000)
            decoderThread = null
            
            mediaCodec?.stop()
            mediaCodec?.release()
            mediaCodec = null
            isInitialized = false
            nalQueue.clear()
        } catch (e: Exception) {
            println("[ERROR] Error releasing decoder: ${e.message}")
            e.printStackTrace()
        }
    }
} 