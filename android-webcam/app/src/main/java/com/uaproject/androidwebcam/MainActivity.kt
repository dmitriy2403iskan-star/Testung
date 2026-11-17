package com.uaproject.androidwebcam

import android.Manifest
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat

class MainActivity : ComponentActivity() {
    private lateinit var preview: PreviewView
    private val permission = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { r ->
        if (r[Manifest.permission.CAMERA] == true) startCamera() else Toast.makeText(this, "Нужен доступ к камере", Toast.LENGTH_LONG).show()
    }
    override fun onCreate(savedInstanceState: Bundle?) { super.onCreate(savedInstanceState); preview = PreviewView(this); setContentView(preview); permission.launch(arrayOf(Manifest.permission.CAMERA)) }
    private fun startCamera() {
        val future = ProcessCameraProvider.getInstance(this)
        future.addListener({
            val provider = future.get()
            val p = androidx.camera.core.Preview.Builder().build().also { it.surfaceProvider = preview.surfaceProvider }
            provider.unbindAll(); provider.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, p)
        }, ContextCompat.getMainExecutor(this))
    }
}
