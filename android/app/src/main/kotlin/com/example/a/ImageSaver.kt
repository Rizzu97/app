package com.example.a

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import java.io.File
import java.io.FileOutputStream

object ImageSaver {
    fun saveImage(data: ByteArray, path: String) {
        try {
            println("[DEBUG] Decoding image data")
            val bitmap = BitmapFactory.decodeByteArray(data, 0, data.size)
            if (bitmap == null) {
                println("[ERROR] Failed to decode image data")
                throw Exception("Failed to decode image data")
            }
            
            println("[DEBUG] Creating file: $path")
            val file = File(path)
            
            // Assicurati che la directory esista
            file.parentFile?.also {
                if (!it.exists()) {
                    println("[DEBUG] Creating parent directories")
                    if (!it.mkdirs()) {
                        println("[WARNING] Failed to create parent directories")
                    }
                }
            }
            
            println("[DEBUG] Opening output stream")
            val out = FileOutputStream(file)
            
            println("[DEBUG] Compressing and saving image")
            bitmap.compress(Bitmap.CompressFormat.JPEG, 100, out)
            
            println("[DEBUG] Flushing and closing output stream")
            out.flush()
            out.close()
            
            println("[DEBUG] Image saved successfully")
        } catch (e: Exception) {
            println("[ERROR] Error saving image: ${e.message}")
            e.printStackTrace()
            throw e
        }
    }
} 