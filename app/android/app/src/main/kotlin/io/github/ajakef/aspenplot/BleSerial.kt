package io.github.ajakef.aspenplot

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import java.util.UUID

// Bluetooth Low Energy (BLE) text stream from a logger that offers the "Nordic UART" service (the CO2/multigas
// Artemis firmware does). View-only: the phone only listens. Used by the Raw tab.
//
// Dart calls "connect" (start looking for loggers), "connectTo" (connect to the one the user chose, by address) and
// "disconnect" on the method channel "aspen/ble". Back on the event channel "aspen/ble/events" come status strings
// ("scanning", "connected", "disconnected", "error: ..."), the list of loggers found so far (a list of
// {address, name} maps, sent each time a new one appears) and the received bytes.
class BleSerial(private val activity: Activity, private val send: (Any) -> Unit) {
    companion object {
        val serviceUuid: UUID = UUID.fromString("6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
        val txUuid: UUID = UUID.fromString("6E400003-B5A3-F393-E0A9-E50E24DCCA9E") // logger -> phone
        val cccdUuid: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        const val scanSeconds = 15L
        const val permissionRequest = 7
    }

    private val handler = Handler(Looper.getMainLooper())
    private var gatt: BluetoothGatt? = null
    private var scanning = false
    private val found = LinkedHashMap<String, String>() // address -> name of loggers seen in this scan
    private var wantConnection = false // false once the user disconnects, so no automatic reconnecting

    private val adapter: BluetoothAdapter?
        get() = (activity.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter

    private fun status(text: String) = handler.post { send(text) }

    // Android 12+ asks for "nearby devices"; older versions ask for location (needed for scanning).
    private fun neededPermissions(): Array<String> =
        if (Build.VERSION.SDK_INT >= 31) arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)

    private fun hasPermissions() = neededPermissions().all {
        activity.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
    }

    fun connect() {
        wantConnection = true
        if (!hasPermissions()) {
            status("asking permission")
            activity.requestPermissions(neededPermissions(), permissionRequest)
            return
        }
        startScan()
    }

    // The user chose a logger from the list.
    @SuppressLint("MissingPermission")
    fun connectTo(address: String) {
        stopScan()
        closeGatt()
        val bt = adapter
        if (bt == null || !bt.isEnabled) {
            status("error: turn Bluetooth on")
            return
        }
        wantConnection = true
        status("connecting to ${found[address] ?: address}")
        gatt = bt.getRemoteDevice(address).connectGatt(activity, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
    }

    // Called by MainActivity when the permission dialog is answered.
    fun onPermissionResult(granted: Boolean) {
        if (!wantConnection) return
        if (granted) startScan() else status("error: Bluetooth permission refused")
    }

    @SuppressLint("MissingPermission")
    private fun startScan() {
        val bt = adapter
        if (bt == null || !bt.isEnabled) {
            status("error: turn Bluetooth on")
            return
        }
        stopScan()
        closeGatt()
        found.clear()
        handler.post { send(emptyList<Map<String, String>>()) }
        val scanner = bt.bluetoothLeScanner
        if (scanner == null) {
            status("error: turn Bluetooth on")
            return
        }
        val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid(serviceUuid)).build()
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        scanning = true
        status("scanning")
        try {
            scanner.startScan(listOf(filter), settings, scanCallback)
        } catch (e: Exception) {
            scanning = false
            status("error: ${e.message}")
            return
        }
        handler.postDelayed(scanTimeout, scanSeconds * 1000)
    }

    private val scanTimeout = Runnable {
        if (scanning) {
            stopScan()
            status("disconnected") // the list stays; the Dart side says the scan is over
        }
    }

    @SuppressLint("MissingPermission")
    private fun stopScan() {
        handler.removeCallbacks(scanTimeout)
        if (!scanning) return
        scanning = false
        try { adapter?.bluetoothLeScanner?.stopScan(scanCallback) } catch (_: Exception) {}
    }

    private val scanCallback = object : ScanCallback() {
        @SuppressLint("MissingPermission")
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            if (!scanning) return
            val address = result.device.address
            val name = result.scanRecord?.deviceName ?: result.device.name ?: address
            if (found[address] == name) return
            found[address] = name
            val list = found.map { mapOf("address" to it.key, "name" to it.value) }
            handler.post { send(list) }
        }

        override fun onScanFailed(errorCode: Int) {
            scanning = false
            status("error: scan failed ($errorCode)")
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(g: BluetoothGatt, st: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                g.discoverServices()
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                g.close()
                if (gatt === g) gatt = null
                status("disconnected")
            }
        }

        @SuppressLint("MissingPermission")
        override fun onServicesDiscovered(g: BluetoothGatt, st: Int) {
            val tx = g.getService(serviceUuid)?.getCharacteristic(txUuid)
            val cccd = tx?.getDescriptor(cccdUuid)
            if (tx == null || cccd == null) {
                status("error: this device has no text stream")
                return
            }
            g.setCharacteristicNotification(tx, true)
            // Tell the logger we want notifications; the "connected" status is sent when it accepts.
            @Suppress("DEPRECATION")
            run {
                cccd.value = android.bluetooth.BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                g.writeDescriptor(cccd)
            }
        }

        override fun onDescriptorWrite(g: BluetoothGatt, d: android.bluetooth.BluetoothGattDescriptor, st: Int) {
            if (st == BluetoothGatt.GATT_SUCCESS) status("connected") else status("error: could not start the stream ($st)")
        }

        // Deprecated on Android 13+, but Android still calls it there, so one version works everywhere.
        @Suppress("DEPRECATION")
        @Deprecated("Deprecated in Java")
        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic) {
            if (c.uuid != txUuid) return
            val data = c.value ?: return
            handler.post { send(data.copyOf()) }
        }
    }

    @SuppressLint("MissingPermission")
    private fun closeGatt() {
        val g = gatt ?: return
        gatt = null
        try { g.disconnect(); g.close() } catch (_: Exception) {}
    }

    fun disconnect() {
        wantConnection = false
        stopScan()
        closeGatt()
        status("disconnected")
    }
}
