import UIKit
import CoreBluetooth

// Simple test view controller - just connects and sends test messages
class BLETestViewController: UIViewController {
    
    var centralManager: CBCentralManager!
    var peripheral: CBPeripheral?
    var rxCharacteristic: CBCharacteristic?
    
    let statusLabel = UILabel()
    let connectButton = UIButton()
    let sendButton = UIButton()
    let logTextView = UITextView()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = .white
        title = "BLE Test"
        
        setupUI()
        
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    func setupUI() {
        // Status label
        statusLabel.text = "Not Connected"
        statusLabel.textAlignment = .center
        statusLabel.font = .systemFont(ofSize: 18, weight: .medium)
        statusLabel.textColor = .systemRed
        
        // Connect button
        connectButton.setTitle("Scan & Connect", for: .normal)
        connectButton.backgroundColor = .systemBlue
        connectButton.setTitleColor(.white, for: .normal)
        connectButton.layer.cornerRadius = 10
        connectButton.addTarget(self, action: #selector(connectTapped), for: .touchUpInside)
        
        // Send test button
        sendButton.setTitle("Send Test Message", for: .normal)
        sendButton.backgroundColor = .systemGreen
        sendButton.setTitleColor(.white, for: .normal)
        sendButton.layer.cornerRadius = 10
        sendButton.isEnabled = false
        sendButton.addTarget(self, action: #selector(sendTestTapped), for: .touchUpInside)
        
        // Log text view
        logTextView.isEditable = false
        logTextView.font = .systemFont(ofSize: 12)
        logTextView.backgroundColor = .systemGray6
        logTextView.layer.cornerRadius = 10
        
        // Layout
        view.addSubview(statusLabel)
        view.addSubview(connectButton)
        view.addSubview(sendButton)
        view.addSubview(logTextView)
        
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        connectButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        logTextView.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            connectButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 20),
            connectButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            connectButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            connectButton.heightAnchor.constraint(equalToConstant: 50),
            
            sendButton.topAnchor.constraint(equalTo: connectButton.bottomAnchor, constant: 20),
            sendButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            sendButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            sendButton.heightAnchor.constraint(equalToConstant: 50),
            
            logTextView.topAnchor.constraint(equalTo: sendButton.bottomAnchor, constant: 20),
            logTextView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            logTextView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            logTextView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20)
        ])
    }
    
    func log(_ message: String) {
        print(message)
        DispatchQueue.main.async {
            let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            self.logTextView.text += "[\(timestamp)] \(message)\n"
            let bottom = NSRange(location: self.logTextView.text.count - 1, length: 1)
            self.logTextView.scrollRangeToVisible(bottom)
        }
    }
    
    @objc func connectTapped() {
        if centralManager.state == .poweredOn {
            log("🔍 Starting scan...")
            centralManager.scanForPeripherals(withServices: nil, options: nil)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.centralManager.stopScan()
                self.log("🛑 Scan complete")
                self.showDeviceList()
            }
        } else {
            log("❌ Bluetooth not powered on")
        }
    }
    
    func showDeviceList() {
        let alert = UIAlertController(title: "Select Device", message: "Choose a device to connect", preferredStyle: .actionSheet)
        
        // For now, just try to connect to any discovered device
        // In real app, you'd show a list
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        
        if let popover = alert.popoverPresentationController {
            popover.sourceView = connectButton
        }
        
        present(alert, animated: true)
    }
    
    @objc func sendTestTapped() {
        guard let characteristic = rxCharacteristic else {
            log("❌ RX characteristic not found")
            return
        }
        
        let message = "TEST_MESSAGE_\(Int(Date().timeIntervalSince1970))"
        guard let data = message.data(using: .utf8) else {
            log("❌ Failed to encode message")
            return
        }
        
        peripheral?.writeValue(data, for: characteristic, type: .withoutResponse)
        log("📤 Sent: \(message)")
    }
}

extension BLETestViewController: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            log("✅ Bluetooth powered on")
            statusLabel.text = "Ready to Scan"
            statusLabel.textColor = .systemGreen
        case .poweredOff:
            log("❌ Bluetooth powered off")
            statusLabel.text = "Bluetooth Off"
            statusLabel.textColor = .systemRed
        case .unauthorized:
            log("❌ Bluetooth unauthorized")
            statusLabel.text = "Unauthorized"
            statusLabel.textColor = .systemRed
        default:
            log("⚠️ Bluetooth state: \(central.state.rawValue)")
            statusLabel.text = "Not Ready"
            statusLabel.textColor = .systemOrange
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        log("📡 Found device: \(peripheral.name ?? "Unknown")")
        
        // Auto-connect to first device found (for testing)
        if self.peripheral == nil {
            self.peripheral = peripheral
            central.stopScan()
            central.connect(peripheral, options: nil)
            log("🔌 Connecting to: \(peripheral.name ?? "Unknown")")
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("✅ Connected to: \(peripheral.name ?? "Unknown")")
        statusLabel.text = "Connected"
        statusLabel.textColor = .systemGreen
        
        peripheral.delegate = self
        peripheral.discoverServices([CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")])
        log("🔍 Discovering services...")
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("❌ Failed to connect: \(error?.localizedDescription ?? "Unknown error")")
        statusLabel.text = "Connection Failed"
        statusLabel.textColor = .systemRed
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("📴 Disconnected")
        statusLabel.text = "Disconnected"
        statusLabel.textColor = .systemRed
        sendButton.isEnabled = false
        rxCharacteristic = nil
    }
}

extension BLETestViewController: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            log("❌ Error discovering services: \(error.localizedDescription)")
            return
        }
        
        guard let services = peripheral.services else {
            log("⚠️ No services found")
            return
        }
        
        log("📋 Found \(services.count) service(s)")
        
        for service in services {
            log("   Service: \(service.uuid.uuidString)")
            
            if service.uuid == CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E") {
                log("   ✅ Found Nordic UART Service!")
                peripheral.discoverCharacteristics([
                    CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"),  // RX
                    CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")   // TX
                ], for: service)
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            log("❌ Error discovering characteristics: \(error.localizedDescription)")
            return
        }
        
        guard let characteristics = service.characteristics else {
            log("⚠️ No characteristics found")
            return
        }
        
        log("📋 Found \(characteristics.count) characteristic(s)")
        
        for characteristic in characteristics {
            log("   Characteristic: \(characteristic.uuid.uuidString)")
            
            if characteristic.uuid == CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") {
                rxCharacteristic = characteristic
                log("   ✅ RX characteristic ready!")
                sendButton.isEnabled = true
                sendButton.backgroundColor = .systemGreen
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            log("❌ Write error: \(error.localizedDescription)")
        } else {
            log("✅ Write successful")
        }
    }
}

