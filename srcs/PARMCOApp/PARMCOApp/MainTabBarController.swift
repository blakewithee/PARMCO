import UIKit
import CoreBluetooth

/**
 * =============================================================================
 * MAIN TAB BAR CONTROLLER
 * =============================================================================
 * Root view controller that manages the app's tab-based navigation.
 * Dynamically shows/hides tabs based on BLE connection status.
 * 
 * TAB STRUCTURE:
 * ALWAYS VISIBLE:
 * - Main: Welcome/info screen
 * - Connections: BLE device scanning and connection
 * 
 * VISIBLE ONLY WHEN CONNECTED:
 * - Motor Control: Manual and automatic motor control
 * - Game: Flappy Bird style game with motor integration
 * 
 * BLE ARCHITECTURE:
 * - Single BLEMotorManager instance shared across all tabs
 * - Callbacks set up to update Motor Control UI when RPM data arrives
 * - Connection status triggers tab visibility changes
 * 
 * FLOW:
 * 1. App starts → Show Main + Connections tabs only
 * 2. User connects to Raspberry Pi → Add Motor Control + Game tabs
 * 3. User disconnects → Remove Motor Control + Game tabs
 */
class MainTabBarController: UITabBarController {
    
    // View controllers for each tab
    let mainVC = ViewController()
    let connectionsVC = ConnectionsViewController()
    let motorControlVC = MotorControlViewController()
    let gameVC = GameViewController()
    
    // Shared BLE manager (single instance for entire app)
    let bleManager = BLEMotorManager()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // SETUP TAB BAR ITEMS
        // Main tab (always visible)
        mainVC.tabBarItem = UITabBarItem(title: "Main", image: UIImage(systemName: "house.fill"), tag: 0)
        
        // Connections tab (always visible)
        connectionsVC.tabBarItem = UITabBarItem(title: "Connections", image: UIImage(systemName: "wifi"), tag: 1)
        
        // Motor Control tab (shown when connected)
        motorControlVC.tabBarItem = UITabBarItem(title: "Motor Control", image: UIImage(systemName: "gearshape.fill"), tag: 2)
        motorControlVC.bleManager = bleManager  // Share BLE manager
        
        // Game tab (shown when connected)
        gameVC.tabBarItem = UITabBarItem(title: "Game", image: UIImage(systemName: "gamecontroller.fill"), tag: 3)
        gameVC.bleManager = bleManager  // Share BLE manager
        
        // SETUP BLE CALLBACKS
        // Update motor control UI when connection is ready
        bleManager.onReadyStateChanged = { [weak self] isReady in
            self?.motorControlVC.updateBLEStatus(isReady: isReady)
        }
        
        // Forward RPM updates to motor control UI
        bleManager.onRPMUpdate = { [weak self] rpmString in
            self?.motorControlVC.updateRPM(rpmString)
        }
        
        // SETUP CONNECTION CALLBACK
        // Show/hide Motor Control and Game tabs based on connection status
        connectionsVC.onConnectionChanged = { [weak self] isConnected, peripheral in
            self?.updateMotorControlVisibility(isConnected: isConnected, peripheral: peripheral)
        }
        
        // INITIAL STATE: Show only Main and Connections
        viewControllers = [mainVC, connectionsVC]
    }
    
    /**
     * UPDATE TAB VISIBILITY BASED ON CONNECTION STATUS
     * Called when BLE connection state changes (connected or disconnected).
     * 
     * CONNECTED:
     * - Setup BLE manager with peripheral
     * - Show all 4 tabs: Main, Connections, Motor Control, Game
     * 
     * DISCONNECTED:
     * - Hide Motor Control and Game tabs
     * - Show only Main and Connections
     * 
     * @param isConnected: True if connected to Raspberry Pi
     * @param peripheral: The connected peripheral (if connected)
     */
    func updateMotorControlVisibility(isConnected: Bool, peripheral: CBPeripheral?) {
        if isConnected, let peripheral = peripheral {
            // CONNECTED: Setup BLE and show all tabs
            bleManager.setup(with: peripheral)
            
            // Add Motor Control and Game tabs (if not already added)
            if !(viewControllers?.contains(motorControlVC) ?? false) {
                viewControllers = [mainVC, connectionsVC, motorControlVC, gameVC]
            }
        } else {
            // DISCONNECTED: Hide Motor Control and Game tabs
            viewControllers = [mainVC, connectionsVC]
        }
    }
}


