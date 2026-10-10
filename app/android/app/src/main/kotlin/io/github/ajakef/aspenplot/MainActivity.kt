package com.example.serial_spectrogram

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import com.hoho.android.usbserial.driver.UsbSerialPort
import com.hoho.android.usbserial.driver.UsbSerialProber
import com.hoho.android.usbserial.util.SerialInputOutputManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

// Bridge between the Flutter (Dart) code and the USB serial port.
// Dart calls "connect"/"write"/"disconnect" on the method channel; bytes from the
// logger and status messages are sent back to Dart on the event channel.
class MainActivity : FlutterActivity(), SerialInputOutputManager.Listener {
    private val baudRate = 500000
    private val permissionAction = "com.example.serial_spectrogram.USB_PERMISSION"

    private val mainHandler = Handler(Looper.getMainLooper())
    private var events: EventChannel.EventSink? = null
    private var port: UsbSerialPort? = null
    private var ioManager: SerialInputOutputManager? = null

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
                "connect" -> { connect(); result.success(null) }
                "write" -> {
                    try {
                        port?.write(call.arguments as ByteArray, 1000)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("write", e.message, null)
                    }
                }
                "disconnect" -> { disconnect(); result.success(null) }
                else -> result.notImplemented()
            }
        }
        EventChannel(messenger, "aspen/serial/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) { events = sink }
            override fun onCancel(arguments: Any?) { events = null }
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

    override fun onDestroy() {
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
            // Python's pyserial turns these on when opening a port; match it.
            p.dtr = true
            p.rts = true
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
