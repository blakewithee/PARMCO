import Foundation
import CoreBluetooth

/**
 * =============================================================================
 * BLE MOTOR MANAGER
 * =============================================================================
 * Manages Bluetooth Low Energy (BLE) communication between iPhone and Raspberry Pi.
 * Implements the Nordic UART Service (NUS) protocol for simple command/response.
 * 
 * ARCHITECTURE:
 * iPhone (BLEMotorManager) ←→ BLE ←→ RPi (ble_server.c) ←→ Pipe ←→ motor_control_ble_pipe.c
 * 
 * NORDIC UART SERVICE (NUS):
 * - Service UUID: 6E400001... (well-known service supported by BlueZ)
 * - RX Characteristic: 6E400002... (iPhone writes commands here)
 * - TX Characteristic: 6E400003... (iPhone reads RPM updates here)
 * 
 * RX = Receive (from iPhone's perspective) = Write commands TO Raspberry Pi
 * TX = Transmit (from iPhone's perspective) = Read RPM FROM Raspberry Pi
 * 
 * CALLBACKS:
 * - onReadyStateChanged: Called when BLE connection is established/lost
 * - onRPMUpdate: Called when new RPM data arrives
 * - onStatusUpdate: Called for general status messages
 */

// Nordic UART Service (NUS) UUIDs
let UART_SERVICE_UUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")  // Service
let UART_RX_UUID      = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")  // Write commands
let UART_TX_UUID      = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")  // Read RPM

class BLEMotorManager: NSObject {
    
    // BLE connection state
    var peripheral: CBPeripheral?                       // Connected Raspberry Pi device
    var motorControlCharacteristic: CBCharacteristic?   // RX: For sending commands
    var motorStatusCharacteristic: CBCharacteristic?    // TX: For receiving RPM
    
    // Callbacks to UI
    var onStatusUpdate: ((String) -> Void)?             // General status messages
    var onReadyStateChanged: ((Bool) -> Void)?          // Connection ready/not ready
    var onRPMUpdate: ((String) -> Void)?                 // RPM updates from motor
    
    /**
     * SETUP BLE CONNECTION
     * Called after iPhone successfully connects to the Raspberry Pi.
     * Discovers the Nordic UART Service and its characteristics (RX/TX).
     * 
     * FLOW:
     * 1. Set peripheral delegate to receive BLE events
     * 2. Discover services (Nordic UART Service)
     * 3. Discover characteristics (RX for commands, TX for RPM)
     * 4. Enable notifications on TX characteristic for RPM updates
     * 
     * @param peripheral: Connected CBPeripheral (Raspberry Pi)
     */
    func setup(with peripheral: CBPeripheral) {
        print("🔧 BLEMotorManager: Setting up with peripheral: \(peripheral.name ?? "unknown")")
        NSLog("🔧 BLEMotorManager: Setting up with peripheral: \(peripheral.name ?? "unknown")")
        
        self.peripheral = peripheral
        self.peripheral?.delegate = self  // Receive BLE events
        
        // Discover Nordic UART Service (6E400001...)
        print("🔍 Looking for Nordic UART Service: \(UART_SERVICE_UUID.uuidString)")
        NSLog("🔍 Looking for Nordic UART Service")
        peripheral.discoverServices([UART_SERVICE_UUID])
        
        // Also discover all services (for debugging/verification)
        print("🔍 Also discovering all services...")
        peripheral.discoverServices(nil)
    }
    
    // MARK: - Motor Control Commands
    /**
     * These functions send commands to the Raspberry Pi via BLE.
     * Commands are text strings sent to the RX characteristic (UART_RX_UUID).
     * The BLE server (ble_server.c) receives these and forwards them to motor_control_ble_pipe.c.
     */
    
    /**
     * SEND COMMAND TO RASPBERRY PI
     * Encodes command as UTF-8 and sends via BLE UART RX characteristic.
     * 
     * PROTOCOL:
     * - Commands are newline-terminated strings: "command\n"
     * - Examples: "on\n", "off\n", "s 50\n", "auto 1000\n"
     * - Uses .withoutResponse for faster communication (no ACK needed)
     * 
     * FLOW:
     * iPhone → BLE RX → ble_server.c → named pipe → motor_control_ble_pipe.c
     * 
     * @param command: Command string (e.g., "on", "off", "s 50", "auto 1000")
     */
    func sendCommand(_ command: String) {
        // Check if RX characteristic is available
        guard let characteristic = motorControlCharacteristic else {
            print("⚠️  UART RX characteristic not found - cannot send command")
            NSLog("⚠️  UART RX characteristic not found")
            return
        }
        
        // Add newline delimiter (C server expects this)
        let commandWithNewline = command + "\n"
        
        // Convert string to UTF-8 data
        guard let data = commandWithNewline.data(using: .utf8) else {
            print("❌ Failed to encode command")
            return
        }
        
        // Send command via BLE (withoutResponse = faster, no ACK)
        peripheral?.writeValue(data, for: characteristic, type: .withoutResponse)
        print("📤 Sent command via BLE UART: \(command)")
        NSLog("📤 Sent: \(command)")
    }
    
    // Basic motor control commands
    // All commands are lowercase as expected by motor_control_ble_pipe.c
    
    /** Turn motor ON */
    func turnOn() {
        sendCommand("on")
    }
    
    /** Turn motor OFF */
    func turnOff() {
        sendCommand("off")
    }
    
    /** Set direction FORWARD (clockwise) */
    func setDirectionForward() {
        sendCommand("f")
    }
    
    /** Set direction REVERSE (counter-clockwise) */
    func setDirectionReverse() {
        sendCommand("r")
    }
    
    /**
     * SET MOTOR SPEED
     * @param speed: Speed percentage (0-100%)
     * Sends "s 50" format command
     */
    func setSpeed(_ speed: Int) {
        let clampedSpeed = min(max(speed, 0), 100)  // Clamp to 0-100
        sendCommand("s \(clampedSpeed)")  // Format: "s 50"
    }
    
    /** Increase speed by 10% */
    func increaseSpeed() {
        sendCommand("+")
    }
    
    /** Decrease speed by 10% */
    func decreaseSpeed() {
        sendCommand("-")
    }
    
    func readStatus() {
        guard let characteristic = motorStatusCharacteristic else {
            print("⚠️  Motor status characteristic not found")
            return
        }
        
        peripheral?.readValue(for: characteristic)
    }
}

// MARK: - CBPeripheralDelegate

extension BLEMotorManager: CBPeripheralDelegate {
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            print("❌ Error discovering services: \(error.localizedDescription)")
            return
        }
        
        guard let services = peripheral.services else {
            print("⚠️  No services found on peripheral")
            return
        }
        
        print("📋 Found \(services.count) service(s):")
        NSLog("📋 Found \(services.count) service(s)")
        
        for service in services {
            print("   - Service UUID: \(service.uuid.uuidString)")
            NSLog("   Service: \(service.uuid.uuidString)")
            
            if service.uuid == UART_SERVICE_UUID {
                print("   ✅ Nordic UART Service found! Discovering characteristics...")
                NSLog("   ✅ Found UART Service!")
                peripheral.discoverCharacteristics([UART_RX_UUID, UART_TX_UUID], for: service)
            } else {
                // Discover all characteristics to see what's available
                print("   🔍 Discovering all characteristics for: \(service.uuid.uuidString)")
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            print("❌ Error discovering characteristics: \(error.localizedDescription)")
            return
        }
        
        guard let characteristics = service.characteristics else {
            print("⚠️  No characteristics found for service: \(service.uuid.uuidString)")
            return
        }
        
        print("📋 Found \(characteristics.count) characteristic(s) for service \(service.uuid.uuidString):")
        NSLog("📋 Found \(characteristics.count) characteristics")
        
        for characteristic in characteristics {
            print("   - Characteristic UUID: \(characteristic.uuid.uuidString)")
            NSLog("   Char: \(characteristic.uuid.uuidString)")
            
            print("     Properties: ", terminator: "")
            if characteristic.properties.contains(.read) { print("READ ", terminator: "") }
            if characteristic.properties.contains(.write) { print("WRITE ", terminator: "") }
            if characteristic.properties.contains(.writeWithoutResponse) { print("WRITE_NO_RESPONSE ", terminator: "") }
            if characteristic.properties.contains(.notify) { print("NOTIFY ", terminator: "") }
            print("")
            
            // UART RX = where we write commands TO the Pi
            if characteristic.uuid == UART_RX_UUID {
                motorControlCharacteristic = characteristic
                print("   ✅ UART RX (command) characteristic ready!")
                NSLog("   ✅ UART RX ready!")
            }
            
            // UART TX = where we read status FROM the Pi
            if characteristic.uuid == UART_TX_UUID {
                motorStatusCharacteristic = characteristic
                // Enable notifications if supported
                if characteristic.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: characteristic)
                    print("   ✅ UART TX (status) notifications enabled!")
                }
            }
        }
        
        // Summary
        if motorControlCharacteristic != nil {
            print("🎉 BLE UART connection fully configured and ready!")
            NSLog("🎉 BLE ready!")
            onReadyStateChanged?(true)
        } else {
            print("⚠️  WARNING: UART RX characteristic not found!")
            print("   The Raspberry Pi is not advertising Nordic UART Service properly.")
            print("   Commands will not work until the service is available.")
            NSLog("⚠️  UART service not found")
            onReadyStateChanged?(false)
        }
    }
    
    /**
     * HANDLE VALUE UPDATES FROM RASPBERRY PI
     * Called when Raspberry Pi sends RPM data via BLE notification.
     * 
     * PROTOCOL:
     * - RPM data arrives as notifications on TX characteristic (UART_TX_UUID)
     * - Format: Plain number string (e.g., "1234.56")
     * - Updates are sent every 100ms by ble_server.c
     * 
     * PARSING:
     * - If value is numeric (e.g., "1234.56") → RPM update
     * - If value is text → Status message
     * 
     * @param peripheral: The Raspberry Pi peripheral
     * @param characteristic: The characteristic that updated (should be TX)
     * @param error: Error if read failed
     */
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("❌ Error reading value: \(error.localizedDescription)")
            return
        }
        
        // Check if this is the TX characteristic (RPM data)
        if characteristic.uuid == UART_TX_UUID {
            if let data = characteristic.value, let status = String(data: data, encoding: .utf8) {
                print("📥 Motor status from UART TX: \(status)")
                NSLog("📥 Status: \(status)")
                
                // PARSE VALUE: Is it RPM (number) or status (text)?
                let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.range(of: #"^\d+\.?\d*$"#, options: .regularExpression) != nil {
                    // It's a numeric value → RPM update
                    onRPMUpdate?(trimmed)
                } else {
                    // It's text → Status message
                    onStatusUpdate?(status)
                }
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("❌ Error writing value: \(error.localizedDescription)")
        }
    }
}

