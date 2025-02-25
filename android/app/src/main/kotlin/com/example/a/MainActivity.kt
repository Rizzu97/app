package com.example.a

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.ViewGroup
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.example.video_decoder"
    private var videoDecoder: VideoDecoder? = null
    private var videoPlayer: VideoPlayer? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    
    // Flag per controllare se il generatore di frame di test è attivo
    private var testFrameGeneratorActive = false
    
    private val PERMISSIONS = arrayOf(
        Manifest.permission.INTERNET,
        Manifest.permission.WRITE_EXTERNAL_STORAGE,
        Manifest.permission.READ_EXTERNAL_STORAGE
    )
    private val PERMISSION_REQUEST_CODE = 123

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        checkAndRequestPermissions()
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "initializeDecoder" -> {
                        try {
                            val width = call.argument<Int>("width") ?: 1920
                            val height = call.argument<Int>("height") ?: 1080
                            val bufferSize = call.argument<Int>("bufferSize") ?: 4096
                            
                            println("Initializing decoder with width: $width, height: $height, buffer size: $bufferSize")
                            
                            val surfaceView = SurfaceView(this)
                            addContentView(
                                surfaceView,
                                ViewGroup.LayoutParams(
                                    ViewGroup.LayoutParams.MATCH_PARENT,
                                    ViewGroup.LayoutParams.MATCH_PARENT
                                )
                            )
                            
                            surfaceView.holder.addCallback(object : SurfaceHolder.Callback {
                                override fun surfaceCreated(holder: SurfaceHolder) {
                                    println("[DEBUG] Surface created")
                                    initializeDecoderWithSurface(holder.surface, width, height, bufferSize, result)
                                }
                                
                                override fun surfaceChanged(holder: SurfaceHolder, 
                                                          format: Int, 
                                                          width: Int, 
                                                          height: Int) {
                                    println("[DEBUG] Surface changed: format=$format, width=$width, height=$height")
                                }
                                
                                override fun surfaceDestroyed(holder: SurfaceHolder) {
                                    println("[DEBUG] Surface destroyed")
                                    releaseDecoder()
                                }
                            })
                            
                        } catch (e: Exception) {
                            println("[ERROR] Initialization error: ${e.message}")
                            e.printStackTrace()
                            result.error("INIT_ERROR", e.message, null)
                        }
                    }
                    
                    "startPlayback" -> {
                        Thread {
                            try {
                                val ip = call.argument<String>("ip") ?: "192.168.1.1"
                                val port = call.argument<Int>("port") ?: 40005
                                val bufferSize = call.argument<Int>("bufferSize") ?: 4096
                                
                                println("[DEBUG] Starting playback from $ip:$port with buffer size $bufferSize")
                                
                                // Disattiva il generatore di frame di test quando inizia la riproduzione reale
                                testFrameGeneratorActive = false
                                
                                // Imposta la dimensione del buffer
                                videoPlayer?.setBufferSize(bufferSize)
                                
                                videoPlayer?.startPlayback(ip, port) { frame ->
                                    mainHandler.post {
                                        try {
                                            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
                                                .invokeMethod("onFrame", frame)
                                        } catch (e: Exception) {
                                            Log.e("VideoPlayer", "Error sending frame", e)
                                        }
                                    }
                                }
                                mainHandler.post { result.success(true) }
                            } catch (e: Exception) {
                                println("[ERROR] Playback error: ${e.message}")
                                e.printStackTrace()
                                mainHandler.post { result.error("PLAYBACK_ERROR", e.message, null) }
                            }
                        }.start()
                    }
                    
                    "stopPlayback" -> {
                        Thread {
                            try {
                                videoPlayer?.stopPlayback()
                                mainHandler.post { result.success(true) }
                            } catch (e: Exception) {
                                println("[ERROR] Error stopping playback: ${e.message}")
                                e.printStackTrace()
                                mainHandler.post { result.error("STOP_ERROR", e.message, null) }
                            }
                        }.start()
                    }
                    
                    "captureFrame" -> {
                        try {
                            println("[DEBUG] Capturing current frame")
                            val frame = videoPlayer?.captureCurrentFrame()
                            if (frame != null) {
                                println("[DEBUG] Frame captured successfully, size: ${frame.size} bytes")
                                result.success(frame)
                            } else {
                                println("[ERROR] Failed to capture frame: null result")
                                // Crea un'immagine di errore
                                val errorFrame = createErrorImage("Failed to capture frame")
                                result.success(errorFrame)
                            }
                        } catch (e: Exception) {
                            println("[ERROR] Error capturing frame: ${e.message}")
                            e.printStackTrace()
                            try {
                                // Crea un'immagine di errore
                                val errorFrame = createErrorImage("Error: ${e.message}")
                                result.success(errorFrame)
                            } catch (e2: Exception) {
                                result.error("CAPTURE_ERROR", e.message, null)
                            }
                        }
                    }
                    
                    "saveFrame" -> {
                        Thread {
                            try {
                                val data = call.argument<ByteArray>("data")
                                val path = call.argument<String>("path")
                                if (data != null && path != null) {
                                    ImageSaver.saveImage(data, path)
                                    mainHandler.post { result.success(true) }
                                } else {
                                    mainHandler.post { 
                                        result.error("INVALID_ARGUMENTS", "Missing data or path", null)
                                    }
                                }
                            } catch (e: Exception) {
                                println("[ERROR] Error saving frame: ${e.message}")
                                e.printStackTrace()
                                mainHandler.post { result.error("SAVE_ERROR", e.message, null) }
                            }
                        }.start()
                    }
                    
                    "switchProtocol" -> {
                        try {
                            println("[DEBUG] Switching camera protocol")
                            videoPlayer?.tryAlternativeProtocol()
                            result.success(true)
                        } catch (e: Exception) {
                            println("[ERROR] Error switching protocol: ${e.message}")
                            e.printStackTrace()
                            result.error("PROTOCOL_ERROR", e.message, null)
                        }
                    }
                    
                    "testFrame" -> {
                        try {
                            // Genera un singolo frame di test su richiesta
                            val testFrame = videoDecoder?.getCurrentFrame()
                            if (testFrame != null) {
                                MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
                                    .invokeMethod("onFrame", testFrame)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            println("[ERROR] Error generating test frame: ${e.message}")
                            e.printStackTrace()
                            result.error("TEST_FRAME_ERROR", e.message, null)
                        }
                    }
                    
                    "enableTestFrames" -> {
                        try {
                            val enable = call.argument<Boolean>("enable") ?: false
                            testFrameGeneratorActive = enable
                            result.success(true)
                        } catch (e: Exception) {
                            println("[ERROR] Error toggling test frames: ${e.message}")
                            e.printStackTrace()
                            result.error("TEST_FRAME_ERROR", e.message, null)
                        }
                    }
                    
                    "dispose" -> {
                        releaseDecoder()
                        result.success(true)
                    }
                    
                    "forceFrameUpdate" -> {
                        try {
                            // Forza l'aggiornamento del frame corrente
                            val frame = videoPlayer?.captureCurrentFrame()
                            if (frame != null) {
                                MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
                                    .invokeMethod("onFrame", frame)
                                result.success(true)
                            } else {
                                result.error("NO_FRAME", "No frame available", null)
                            }
                        } catch (e: Exception) {
                            println("[ERROR] Error forcing frame update: ${e.message}")
                            e.printStackTrace()
                            result.error("UPDATE_ERROR", e.message, null)
                        }
                    }
                    
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                handleCrash(e, result, call.method)
            }
        }
        
        // Non avviare automaticamente il generatore di frame di test
        // startTestFrameGenerator(flutterEngine)
    }

    private fun initializeDecoderWithSurface(surface: Surface, width: Int, height: Int, bufferSize: Int, result: MethodChannel.Result) {
        try {
            println("[DEBUG] Starting decoder initialization")
            
            // Assicurati che l'esecuzione avvenga sul thread principale
            mainHandler.post {
                try {
                    // Crea l'istanza del decoder
                    videoDecoder = VideoDecoder(surface).also { decoder ->
                        println("[DEBUG] Created decoder instance")
                        
                        // Inizializza il decoder
                        val success = decoder.initialize(width, height)
                        println("[DEBUG] Decoder initialization result: $success")
                        
                        if (success) {
                            // Crea l'istanza del player
                            videoPlayer = VideoPlayer(decoder)
                            println("[DEBUG] Created video player instance")
                            
                            // Dopo aver creato il videoPlayer, imposta la dimensione del buffer
                            videoPlayer?.setBufferSize(bufferSize)
                            
                            result.success(true)
                        } else {
                            result.error("INIT_FAILED", "Failed to initialize decoder", null)
                        }
                    }
                } catch (e: Exception) {
                    println("[ERROR] Decoder initialization error: ${e.message}")
                    e.printStackTrace()
                    result.error("INIT_ERROR", e.message, null)
                }
            }
        } catch (e: Exception) {
            println("[ERROR] Surface initialization error: ${e.message}")
            e.printStackTrace()
            result.error("SURFACE_ERROR", e.message, null)
        }
    }

    private fun releaseDecoder() {
        try {
            mainHandler.post {
                try {
                    println("[DEBUG] Releasing decoder resources")
                    videoPlayer?.dispose()
                    videoDecoder?.release()
                    videoPlayer = null
                    videoDecoder = null
                } catch (e: Exception) {
                    println("[ERROR] Error releasing decoder: ${e.message}")
                    e.printStackTrace()
                }
            }
        } catch (e: Exception) {
            println("[ERROR] Error in releaseDecoder: ${e.message}")
            e.printStackTrace()
        }
    }

    private fun checkAndRequestPermissions() {
        val permissionsToRequest = mutableListOf<String>()
        
        for (permission in PERMISSIONS) {
            if (ContextCompat.checkSelfPermission(this, permission) 
                != PackageManager.PERMISSION_GRANTED) {
                permissionsToRequest.add(permission)
            }
        }
        
        if (permissionsToRequest.isNotEmpty()) {
            ActivityCompat.requestPermissions(
                this,
                permissionsToRequest.toTypedArray(),
                PERMISSION_REQUEST_CODE
            )
        }
    }

    // Questo metodo è ora controllato dal flag testFrameGeneratorActive
    private fun startTestFrameGenerator(flutterEngine: FlutterEngine) {
        Thread {
            try {
                var frameCount = 0
                while (true) {
                    if (videoDecoder != null && testFrameGeneratorActive) {
                        val testFrame = videoDecoder?.getCurrentFrame()
                        if (testFrame != null) {
                            mainHandler.post {
                                try {
                                    println("[DEBUG] Sending test frame #${frameCount++}")
                                    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
                                        .invokeMethod("onFrame", testFrame)
                                } catch (e: Exception) {
                                    println("[ERROR] Error sending test frame: ${e.message}")
                                }
                            }
                        }
                    }
                    Thread.sleep(1000) // Invia un frame ogni secondo
                }
            } catch (e: Exception) {
                println("[ERROR] Test frame generator stopped: ${e.message}")
            }
        }.start()
    }

    override fun onDestroy() {
        releaseDecoder()
        super.onDestroy()
    }

    private fun createErrorImage(errorMessage: String): ByteArray {
        try {
            val bitmap = Bitmap.createBitmap(640, 480, Bitmap.Config.ARGB_8888)
            val canvas = android.graphics.Canvas(bitmap)
            canvas.drawColor(android.graphics.Color.RED)
            
            val paint = android.graphics.Paint().apply {
                color = android.graphics.Color.WHITE
                textSize = 40f
                isAntiAlias = true
            }
            
            // Dividi il messaggio di errore in più righe se necessario
            val lines = errorMessage.chunked(30)
            for ((index, line) in lines.withIndex()) {
                canvas.drawText(line, 20f, 100f + index * 50, paint)
            }
            
            val outputStream = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.JPEG, 90, outputStream)
            return outputStream.toByteArray()
        } catch (e: Exception) {
            println("[ERROR] Error creating error image: ${e.message}")
            e.printStackTrace()
            
            // Fallback estremo: restituisci un'immagine molto semplice
            val simpleBitmap = Bitmap.createBitmap(320, 240, Bitmap.Config.ARGB_8888)
            val outputStream = ByteArrayOutputStream()
            simpleBitmap.compress(Bitmap.CompressFormat.JPEG, 70, outputStream)
            return outputStream.toByteArray()
        }
    }

    // Aggiungi questo metodo per gestire i crash
    private fun handleCrash(e: Exception, result: MethodChannel.Result, methodName: String) {
        println("[ERROR] Crash in $methodName: ${e.message}")
        e.printStackTrace()
        
        try {
            // Prova a rilasciare le risorse
            releaseDecoder()
            
            // Prova a reinizializzare il decoder
            println("[DEBUG] Attempting to recover from crash")
            
            // Informa Flutter del crash
            result.error("CRASH", "L'app ha subito un crash ma sta tentando di recuperare: ${e.message}", null)
        } catch (e2: Exception) {
            println("[ERROR] Failed to recover from crash: ${e2.message}")
            e2.printStackTrace()
            result.error("FATAL_CRASH", "Impossibile recuperare dal crash: ${e2.message}", null)
        }
    }
}
