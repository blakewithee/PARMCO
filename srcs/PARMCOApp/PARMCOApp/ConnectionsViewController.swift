import UIKit
import CoreBluetooth

class ConnectionsViewController: UIViewController {
    
    let scanButton = UIButton()
    let statusLabel = UILabel()
    let tableView = UITableView()
    
    var centralManager: CBCentralManager!
    var discoveredPeripherals: [CBPeripheral] = []
    var connectedPeripheral: CBPeripheral?
    var peripheralRSSI: [UUID: NSNumber] = [:]
    var isScanning = false
    
    // Store discovered characteristics
    var rxCharacteristic: CBCharacteristic?
    var txCharacteristic: CBCharacteristic?
    
    // Callback to notify when connection status changes
    var onConnectionChanged: ((Bool, CBPeripheral?) -> Void)?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = .white
        title = "Connections"
        
        setupUI()
        
        // Initialize Bluetooth
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    func setupUI() {
        // Status label
        statusLabel.text = "Not Connected"
        statusLabel.textAlignment = .center
        statusLabel.font = .systemFont(ofSize: 18, weight: .medium)
        statusLabel.textColor = .systemRed
        
        // Scan button
        scanButton.setTitle("Start Scan", for: .normal)
        scanButton.backgroundColor = .systemBlue
        scanButton.setTitleColor(.white, for: .normal)
        scanButton.layer.cornerRadius = 10
        scanButton.addTarget(self, action: #selector(scanTapped), for: .touchUpInside)
        
        // Table view for devices
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "DeviceCell")
        tableView.backgroundColor = .systemBackground
        tableView.separatorStyle = .singleLine
        
        view.addSubview(statusLabel)
        view.addSubview(scanButton)
        view.addSubview(tableView)
        
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        scanButton.translatesAutoresizingMaskIntoConstraints = false
        tableView.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            scanButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 20),
            scanButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            scanButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            scanButton.heightAnchor.constraint(equalToConstant: 50),
            
            tableView.topAnchor.constraint(equalTo: scanButton.bottomAnchor, constant: 10),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20)
        ])
    }
    
    @objc func scanTapped() {
        if isScanning {
            // Stop scanning
            centralManager.stopScan()
            isScanning = false
            scanButton.setTitle("Start Scan", for: .normal)
            scanButton.backgroundColor = .systemBlue
            print("🛑 Scan stopped")
        } else {
            // Start scanning
            if centralManager.state == .poweredOn {
                discoveredPeripherals.removeAll()
                peripheralRSSI.removeAll()
                tableView.reloadData()
                
                print("🔍 Starting scan for BLE devices...")
                
                // First, retrieve already connected peripherals (these won't advertise)
                let uartServiceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
                let connectedPeripherals = centralManager.retrieveConnectedPeripherals(withServices: [uartServiceUUID])
                print("📱 Checking for connected peripherals with UART service...")
                
                // Also check all connected peripherals
                let allConnected = centralManager.retrieveConnectedPeripherals(withServices: [])
                print("📱 Found \(allConnected.count) total connected peripherals")
                
                for peripheral in allConnected {
                    let name = peripheral.name ?? "Unknown"
                    // Only show devices with actual names (not "Unknown")
                    if name != "Unknown" && !name.isEmpty {
                        print("   ✅ \(name) (\(peripheral.identifier.uuidString.prefix(8)))")
                        if !discoveredPeripherals.contains(where: { $0.identifier == peripheral.identifier }) {
                            discoveredPeripherals.append(peripheral)
                            peripheralRSSI[peripheral.identifier] = NSNumber(value: 0) // Connected devices don't have RSSI
                            DispatchQueue.main.async {
                                self.tableView.reloadData()
                            }
                        }
                    }
                }
                
                // Scan specifically for Nordic UART Service (this is most important)
                print("🔍 Scanning for Nordic UART Service: \(uartServiceUUID.uuidString)")
                
                // Primary scan: Look for our specific service
                centralManager.scanForPeripherals(withServices: [uartServiceUUID], options: [
                    CBCentralManagerScanOptionAllowDuplicatesKey: false
                ])
                
                // Secondary scan: Also scan for all devices (but we'll filter out unknowns)
                // This helps catch devices that might not be advertising the service UUID
                print("🔍 Also scanning for all BLE devices (filtered)...")
                centralManager.scanForPeripherals(withServices: nil, options: [
                    CBCentralManagerScanOptionAllowDuplicatesKey: false
                ])
                isScanning = true
                scanButton.setTitle("Stop Scan", for: .normal)
                scanButton.backgroundColor = .systemRed
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    if self.isScanning {
                        self.centralManager.stopScan()
                        self.isScanning = false
                        self.scanButton.setTitle("Start Scan", for: .normal)
                        self.scanButton.backgroundColor = .systemBlue
                        print("🛑 Scan complete (10 seconds)")
                    }
                }
            } else {
                print("❌ Bluetooth not powered on (state: \(self.centralManager.state.rawValue))")
            }
        }
    }
}

extension ConnectionsViewController: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            print("✅ Bluetooth powered on")
            statusLabel.text = "Ready to Scan"
            statusLabel.textColor = .systemGreen
        case .poweredOff:
            print("❌ Bluetooth powered off")
            statusLabel.text = "Bluetooth Off"
            statusLabel.textColor = .systemRed
        case .unauthorized:
            print("❌ Bluetooth unauthorized")
            statusLabel.text = "Unauthorized"
            statusLabel.textColor = .systemRed
        default:
            print("⚠️ Bluetooth state: \(central.state.rawValue)")
            statusLabel.text = "Not Ready"
            statusLabel.textColor = .systemOrange
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        // Get device name from peripheral or advertisement data
        var deviceName = peripheral.name
        
        // If peripheral.name is nil, try to get it from advertisement data
        if deviceName == nil || deviceName!.isEmpty {
            if let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String {
                deviceName = localName
            } else {
                // Skip devices with no name and no local name in advertisement
                // This filters out most random/unknown devices
                return
            }
        }
        
        // Filter out obviously irrelevant devices
        let name = deviceName!.lowercased()
        if name.contains("unknown") || name.isEmpty {
            return
        }
        
        // Check if this device has our service UUID in advertisement
        var hasOurService = false
        if let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            let uartServiceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
            hasOurService = serviceUUIDs.contains(uartServiceUUID)
        }
        
        // Only log devices with names (not unknown) or our service
        if hasOurService || (!name.contains("unknown") && name.count > 0) {
            print("📡 Found: \(deviceName!) (RSSI: \(RSSI))\(hasOurService ? " [UART Service]" : "")")
        }
        
        // Add to discovered peripherals list if not already there
        if !discoveredPeripherals.contains(where: { $0.identifier == peripheral.identifier }) {
            discoveredPeripherals.append(peripheral)
            peripheralRSSI[peripheral.identifier] = RSSI
            DispatchQueue.main.async {
                self.tableView.reloadData()
            }
        } else {
            // Update RSSI for existing peripheral
            peripheralRSSI[peripheral.identifier] = RSSI
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("✅ Connected to: \(peripheral.name ?? "Unknown")")
        statusLabel.text = "Connected - Discovering Services..."
        statusLabel.textColor = .systemBlue
        
        connectedPeripheral = peripheral
        peripheral.delegate = self
        // Discover ALL services first, then we'll look for the Nordic UART Service
        peripheral.discoverServices(nil)
        print("🔍 Discovering all services...")
        tableView.reloadData()
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("❌ Failed to connect: \(error?.localizedDescription ?? "Unknown error")")
        statusLabel.text = "Connection Failed"
        statusLabel.textColor = .systemRed
        connectedPeripheral = nil
        tableView.reloadData()
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("📴 Disconnected: \(error?.localizedDescription ?? "Normal disconnect")")
        statusLabel.text = "Disconnected"
        statusLabel.textColor = .systemRed
        connectedPeripheral = nil
        tableView.reloadData()
        
        // Notify that we're disconnected
        onConnectionChanged?(false, nil)
    }
}

// MARK: - UITableViewDataSource & UITableViewDelegate
extension ConnectionsViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return discoveredPeripherals.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "DeviceCell", for: indexPath)
        let peripheral = discoveredPeripherals[indexPath.row]
        
        // Get name from peripheral, or use identifier as fallback
        var name = peripheral.name
        if name == nil || name!.isEmpty {
            // For paired devices, name might be nil, use identifier short string
            name = peripheral.identifier.uuidString.prefix(8).uppercased()
        }
        
        let rssi = peripheralRSSI[peripheral.identifier]?.intValue ?? 0
        let isConnected = (peripheral.state == .connected)
        
        cell.textLabel?.text = "\(name ?? "Unknown") (\(rssi) dBm)"
        cell.detailTextLabel?.text = nil
        
        if isConnected {
            cell.backgroundColor = .systemGreen.withAlphaComponent(0.2)
            cell.accessoryType = .checkmark
        } else {
            cell.backgroundColor = .systemBackground
            cell.accessoryType = .disclosureIndicator
        }
        
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        
        let peripheral = discoveredPeripherals[indexPath.row]
        
        if peripheral.state == .connected {
            // Already connected, disconnect
            centralManager.cancelPeripheralConnection(peripheral)
            print("🔌 Disconnecting from: \(peripheral.name ?? "Unknown")")
        } else if peripheral.state == .disconnected {
            // Connect to this peripheral
            connectedPeripheral = peripheral
            centralManager.stopScan()
            isScanning = false
            scanButton.setTitle("Start Scan", for: .normal)
            scanButton.backgroundColor = .systemBlue
            
            centralManager.connect(peripheral, options: nil)
            print("🔌 Connecting to: \(peripheral.name ?? "Unknown")")
            statusLabel.text = "Connecting..."
            statusLabel.textColor = .systemOrange
        }
    }
}

// MARK: - CBPeripheralDelegate
extension ConnectionsViewController: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            print("❌ Error discovering services: \(error.localizedDescription)")
            statusLabel.text = "Service Discovery Failed"
            statusLabel.textColor = .systemRed
            return
        }
        
        guard let services = peripheral.services, !services.isEmpty else {
            print("⚠️ No services found")
            statusLabel.text = "No Services Found"
            statusLabel.textColor = .systemRed
            return
        }
        
        print("📋 Found \(services.count) service(s):")
        
        var foundUARTService = false
        for service in services {
            let serviceUUID = service.uuid.uuidString
            print("   Service UUID: \(serviceUUID)")
            
            if service.uuid == CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E") {
                print("   ✅ Found Nordic UART Service!")
                foundUARTService = true
                // Discover all characteristics for this service
                peripheral.discoverCharacteristics(nil, for: service)
            } else {
                // Also discover characteristics for other services to see what's available
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
        
        if !foundUARTService {
            print("⚠️ Nordic UART Service not found. Available services:")
            for service in services {
                print("   - \(service.uuid.uuidString)")
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            print("❌ Error discovering characteristics: \(error.localizedDescription)")
            return
        }
        
        guard let characteristics = service.characteristics, !characteristics.isEmpty else {
            print("⚠️ No characteristics found for service \(service.uuid.uuidString)")
            return
        }
        
        print("📋 Found \(characteristics.count) characteristic(s) for service \(service.uuid.uuidString):")
        
        var foundRX = false
        var foundTX = false
        
        for characteristic in characteristics {
            var props: [String] = []
            if characteristic.properties.contains(.read) { props.append("READ") }
            if characteristic.properties.contains(.write) { props.append("WRITE") }
            if characteristic.properties.contains(.writeWithoutResponse) { props.append("WRITE_NO_RESPONSE") }
            if characteristic.properties.contains(.notify) { props.append("NOTIFY") }
            
            let charUUID = characteristic.uuid.uuidString
            print("   Characteristic: \(charUUID)")
            print("      Properties: \(props.joined(separator: ", "))")
            
            // Check for RX characteristic (6E400002 = RX, for writing TO the Pi)
            if characteristic.uuid == CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") {
                rxCharacteristic = characteristic
                foundRX = true
                print("   ✅ RX characteristic ready! Can send commands now.")
            }
            
            // Check for TX characteristic (6E400003 = TX, for receiving FROM the Pi)
            if characteristic.uuid == CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E") {
                txCharacteristic = characteristic
                foundTX = true
                print("   ✅ TX characteristic found (for receiving RPM)")
                if characteristic.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: characteristic)
                    print("      Notifications enabled for TX")
                }
            }
        }
        
        // Update UI after checking all characteristics
        DispatchQueue.main.async {
            if foundRX {
                if foundTX {
                    self.statusLabel.text = "✅ Connected - Ready"
                } else {
                    self.statusLabel.text = "✅ Connected - RX Ready"
                }
                self.statusLabel.textColor = .systemGreen
            } else {
                if foundTX {
                    self.statusLabel.text = "⚠️ Connected - TX Only (No RX)"
                } else {
                    self.statusLabel.text = "⚠️ Connected - No UART Characteristics"
                }
                self.statusLabel.textColor = .systemOrange
            }
        }
        
        if !foundRX {
            print("⚠️ RX characteristic (6E400002) not found in service \(service.uuid.uuidString)")
        }
        if !foundTX {
            print("⚠️ TX characteristic (6E400003) not found in service \(service.uuid.uuidString)")
        }
        
        // If we found the UART service and characteristics, notify that we're ready
        if foundRX {
            print("🎉 BLE UART connection fully configured and ready!")
            // Pass the peripheral with characteristics to the callback
            onConnectionChanged?(true, peripheral)
        }
    }
}

