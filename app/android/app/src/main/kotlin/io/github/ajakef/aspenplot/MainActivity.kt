package io.github.ajakef.aspenplot

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.GeomagneticField
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.view.WindowManager
import com.hoho.android.usbserial.driver.UsbSerialPort
import com.hoho.android.usbserial.driver.UsbSerialProber
import com.hoho.android.usbserial.util.SerialInputOutputManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File

// Bridge between the Flutter (Dart) code and the USB serial port.
// Dart calls "connect"/"write"/"setBaud"/"setRts"/"disconnect" on the method channel; bytes from the
// logger and status messages are sent back to Dart on the event channel.
class MainActivity : FlutterActivity(), SerialInputOutputManager.Listener {
    private val baudRate = 500000
    private val permissionAction = "io.github.ajakef.aspenplot.USB_PERMISSION"

    private val mainHandler = Handler(Looper.getMainLooper())
    private var events: EventChannel.EventSink? = null
    private var port: UsbSerialPort? = null
    private var ioManager: SerialInputOutputManager? = null
    private var ble: BleSerial? = null
    private var bleEvents: EventChannel.EventSink? = null
    private var pendingPick: MethodChannel.Result? = null
    private var pickToCache = false // "pickFileToCache": copy the chosen file to the cache instead of sending its bytes
    private val pickRequest = 1
    private val maxPickBytes = 2 * 1024 * 1024

    // Opening the port normally asserts DTR and RTS, which restarts the logger (like Python's pyserial). The Raw tab asks
    // for "connect" without that, so looking at a running logger doesn't restart it. Used up by the next connection.
    private var resetOnConnect = true

    private val usbReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                permissionAction -> connect()
                UsbManager.ACTION_USB_DEVICE_DETACHED -> {
                    disconnect()
                    sendStatus("disconnected")
                }
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) // while the app is on screen
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "aspen/serial").setMethodCallHandler { call, result ->
            when (call.method) {
                "connect" -> {
                    resetOnConnect = (call.arguments as? Boolean) ?: true
                    connect()
                    result.success(null)
                }
                "write" -> {
                    try {
                        port?.write(call.arguments as ByteArray, 1000)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("write", e.message, null)
                    }
                }
                "filesDir" -> result.success(filesDir.path)
                "pickFile", "pickFileToCache" -> {
                    pendingPick?.success(null)
                    pendingPick = result
                    pickToCache = call.method == "pickFileToCache"
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
                        .addCategory(Intent.CATEGORY_OPENABLE)
                        .setType("*/*")
                    startActivityForResult(intent, pickRequest)
                }
                "setBaud" -> {
                    try {
                        port?.setParameters(call.arguments as Int, 8, UsbSerialPort.STOPBITS_1, UsbSerialPort.PARITY_NONE)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("setBaud", e.message, null)
                    }
                }
                "setRts" -> {
                    try {
                        port?.rts = call.arguments as Boolean
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("setRts", e.message, null)
                    }
                }
                "disconnect" -> { disconnect(); result.success(null) }
                "saveToDownloads" -> {
                    // Copies a file into Download/Aspen, where the Files app and a computer (over USB) can see it.
                    val args = call.arguments as Map<*, *>
                    try {
                        result.success(saveToDownloads(args["path"] as String, args["name"] as String, args["mime"] as String))
                    } catch (e: Exception) {
                        result.error("saveToDownloads", e.message, null)
                    }
                }
                "declination" -> {
                    // Degrees east of true north that a compass points, from Android's world magnetic model.
                    val args = call.arguments as Map<*, *>
                    val field = GeomagneticField(
                        (args["lat"] as Double).toFloat(),
                        (args["lon"] as Double).toFloat(),
                        (args["alt"] as Double).toFloat(),
                        System.currentTimeMillis()
                    )
                    result.success(field.declination.toDouble())
                }
                else -> result.notImplemented()
            }
        }
        EventChannel(messenger, "aspen/serial/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) { events = sink }
            override fun onCancel(arguments: Any?) { events = null }
        })

        // Bluetooth Low Energy text stream (Raw tab); see BleSerial.kt
        val bleSerial = BleSerial(this) { bleEvents?.success(it) }.also { ble = it }
        MethodChannel(messenger, "aspen/ble").setMethodCallHandler { call, result ->
            when (call.method) {
                "connect" -> { bleSerial.connect(); result.success(null) }
                "connectTo" -> { bleSerial.connectTo(call.arguments as String); result.success(null) }
                "disconnect" -> { bleSerial.disconnect(); result.success(null) }
                else -> result.notImplemented()
            }
        }
        EventChannel(messenger, "aspen/ble/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) { bleEvents = sink }
            override fun onCancel(arguments: Any?) { bleEvents = null }
        })

        val filter = IntentFilter(permissionAction).apply { addAction(UsbManager.ACTION_USB_DEVICE_DETACHED) }
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(usbReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(usbReceiver, filter)
        }
    }

    // Called when the logger is plugged in while the app is already open.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.action == UsbManager.ACTION_USB_DEVICE_ATTACHED) connect()
    }

    // Result of the file chooser: sends Dart the file's name and contents, or null if cancelled.
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != pickRequest) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pendingPick ?: return
        pendingPick = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        try {
            val name = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                if (it.moveToFirst()) it.getString(0) else null
            } ?: "file"
            if (pickToCache) {
                val copy = File(cacheDir, "picked_" + name.replace('/', '_'))
                contentResolver.openInputStream(uri)!!.use { input -> copy.outputStream().use { input.copyTo(it) } }
                result.success(mapOf("name" to name, "path" to copy.path))
                return
            }
            val bytes = contentResolver.openInputStream(uri)!!.use { it.readNBytes(maxPickBytes + 1) }
            if (bytes.size > maxPickBytes) {
                result.error("pickFile", "That file is too big to be firmware.", null)
            } else {
                result.success(mapOf("name" to name, "bytes" to bytes))
            }
        } catch (e: Exception) {
            result.error("pickFile", e.message, null)
        }
    }

    private fun saveToDownloads(path: String, name: String, mime: String): String {
        if (Build.VERSION.SDK_INT >= 29) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/Aspen")
            }
            val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw Exception("Android refused to create the file")
            contentResolver.openOutputStream(uri)!!.use { out -> File(path).inputStream().use { it.copyTo(out) } }
            return "Download/Aspen/$name"
        } else {
            throw Exception("needs Android 10 or newer; use Send instead")
        }
    }

    // Answer to the Bluetooth permission dialog (other plugins' requests are passed on).
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == BleSerial.permissionRequest) {
            ble?.onPermissionResult(grantResults.isNotEmpty() && grantResults.all { it == android.content.pm.PackageManager.PERMISSION_GRANTED })
        }
    }

    override fun onDestroy() {
        ble?.disconnect()
        disconnect()
        unregisterReceiver(usbReceiver)
        super.onDestroy()
    }

    private fun connect() {
        if (port != null) return
        val usbManager = getSystemService(Context.USB_SERVICE) as UsbManager
        val driver = UsbSerialProber.getDefaultProber().findAllDrivers(usbManager).firstOrNull()
        if (driver == null) {
            sendStatus("no device")
            return
        }
        if (!usbManager.hasPermission(driver.device)) {
            sendStatus("asking permission")
            val intent = Intent(permissionAction).setPackage(packageName)
            val flags = if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
            usbManager.requestPermission(driver.device, PendingIntent.getBroadcast(this, 0, intent, flags))
            return
        }
        val connection = usbManager.openDevice(driver.device)
        if (connection == null) {
            sendStatus("error: could not open device")
            return
        }
        try {
            val p = driver.ports[0]
            p.open(connection)
            p.setParameters(baudRate, 8, UsbSerialPort.STOPBITS_1, UsbSerialPort.PARITY_NONE)
            if (resetOnConnect) {
                // Python's pyserial turns these on when opening a port; match it.
                p.dtr = true
                p.rts = true
            }
            resetOnConnect = true
            port = p
            ioManager = SerialInputOutputManager(p, this).also { it.start() }
            sendStatus("connected")
        } catch (e: Exception) {
            disconnect()
            sendStatus("error: ${e.message}")
        }
    }

    private fun disconnect() {
        ioManager?.listener = null
        ioManager?.stop()
        ioManager = null
        try { port?.close() } catch (_: Exception) {}
        port = null
    }

    private fun sendStatus(status: String) {
        mainHandler.post { events?.success(status) }
    }

    // SerialInputOutputManager.Listener: runs on a background thread.
    override fun onNewData(data: ByteArray) {
        mainHandler.post { events?.success(data) }
    }

    override fun onRunError(e: Exception) {
        mainHandler.post {
            disconnect()
            sendStatus("disconnected")
        }
    }
}
