import UIKit

class MotorControlViewController: UIViewController {
    
    // BLE Manager
    var bleManager: BLEMotorManager?
    
    // MARK: - UI Components
    let titleLabel = UILabel()
    
    // 1. Rotation Control & Start/Stop (side by side)
    let rotationButton = UIButton()
    let startStopButton = UIButton()
    var isClockwise = true
    var isRunning = false
    
    // 2. Speed Control (Horizontal slider with liquid glass effect)
    let speedLabel = UILabel()
    let speedSlider = UISlider()
    let speedValueLabel = UILabel()
    let speedSliderContainer = UIView()  // Container for liquid glass effect
    var currentSpeed: Int = 50
    
    // 4. Desired RPM Input (slider in automatic mode)
    let desiredRPMLabel = UILabel()
    let desiredRPMSlider = UISlider()
    let desiredRPMValueLabel = UILabel()
    let desiredRPMSliderContainer = UIView()  // Container for visual effect
    var currentDesiredRPM: Int = 1000
    
    // 5. Manual/Automatic Mode
    let modeLabel = UILabel()
    let modeSegmentedControl = UISegmentedControl(items: ["Manual", "Automatic"])
    var isAutomatic = false
    
    // 6. Actual RPM Display (Speedometer with needle)
    let rpmSpeedometer = SpeedometerView()
    let rpmValueLabel = UILabel()  // Separate label below speedometer
    let MAX_RPM: CGFloat = 14500.0
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = .black  // Dark mode background
        setupUI()
    }
    
    func setupUI() {
        // Title
        titleLabel.text = "Motor Control"
        titleLabel.font = UIFont.systemFont(ofSize: 32, weight: .bold)
        titleLabel.textColor = .white  // High contrast on dark background
        titleLabel.textAlignment = .center
        
        // 1. Start/Stop Button
        startStopButton.setTitle("START", for: .normal)
        startStopButton.titleLabel?.font = UIFont.systemFont(ofSize: 20, weight: .bold)
        startStopButton.backgroundColor = .systemGreen
        startStopButton.setTitleColor(.white, for: .normal)
        startStopButton.layer.cornerRadius = 10
        startStopButton.addTarget(self, action: #selector(startStopTapped), for: .touchUpInside)
        
        // 1. Rotation Button
        rotationButton.setTitle("↻ Clockwise", for: .normal)
        rotationButton.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        rotationButton.backgroundColor = .systemBlue
        rotationButton.setTitleColor(.white, for: .normal)
        rotationButton.layer.cornerRadius = 10
        rotationButton.addTarget(self, action: #selector(rotationButtonTapped), for: .touchUpInside)
        
        // 2. Speed Control (Horizontal slider with liquid glass effect)
        speedLabel.text = "Speed"
        speedLabel.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        speedLabel.textColor = .white
        speedLabel.textAlignment = .center
        
        // Container for liquid glass effect
        speedSliderContainer.backgroundColor = .clear
        speedSliderContainer.layer.cornerRadius = 8
        speedSliderContainer.clipsToBounds = false
        
        speedSlider.minimumValue = 0
        speedSlider.maximumValue = 100
        speedSlider.value = Float(currentSpeed)
        speedSlider.addTarget(self, action: #selector(speedSliderChanged), for: .valueChanged)
        speedSlider.addTarget(self, action: #selector(speedSliderEnded), for: [.touchUpInside, .touchUpOutside])
        
        // Create thick, visible track
        let trackHeight: CGFloat = 8
        let trackImage = createSliderTrackImage(height: trackHeight, color: .systemGray4)
        speedSlider.setMinimumTrackImage(trackImage, for: .normal)
        speedSlider.setMaximumTrackImage(trackImage, for: .normal)
        
        // Add liquid glass effect (gradient overlay)
        updateSliderColor()
        
        speedValueLabel.text = "\(currentSpeed)%"
        speedValueLabel.font = UIFont.systemFont(ofSize: 24, weight: .bold)
        speedValueLabel.textColor = .systemBlue
        speedValueLabel.textAlignment = .center
        
        // 4. Desired RPM Slider (shown in automatic mode, replaces speed slider)
        desiredRPMLabel.text = "Desired RPM"
        desiredRPMLabel.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        desiredRPMLabel.textColor = .white
        desiredRPMLabel.textAlignment = .center
        
        // Container for slider
        desiredRPMSliderContainer.backgroundColor = .clear
        desiredRPMSliderContainer.layer.cornerRadius = 8
        desiredRPMSliderContainer.clipsToBounds = false
        
        // Slider setup (0 to 10000 RPM - matches C program safety limit)
        desiredRPMSlider.minimumValue = 0
        desiredRPMSlider.maximumValue = 10000
        desiredRPMSlider.value = Float(currentDesiredRPM)
        desiredRPMSlider.addTarget(self, action: #selector(desiredRPMSliderChanged), for: .valueChanged)
        desiredRPMSlider.addTarget(self, action: #selector(desiredRPMSliderEnded), for: [.touchUpInside, .touchUpOutside])
        
        // Create thick, visible track (same style as speed slider)
        let rpmTrackImage = createSliderTrackImage(height: 8, color: .systemGray4)
        desiredRPMSlider.setMinimumTrackImage(rpmTrackImage, for: .normal)
        desiredRPMSlider.setMaximumTrackImage(rpmTrackImage, for: .normal)
        
        // Orange track for automatic mode
        let orangeTrackImage = createSliderTrackImage(height: 8, color: .systemOrange)
        desiredRPMSlider.setMinimumTrackImage(orangeTrackImage, for: .normal)
        
        // Value label below slider
        desiredRPMValueLabel.text = "\(currentDesiredRPM) RPM"
        desiredRPMValueLabel.font = UIFont.systemFont(ofSize: 24, weight: .bold)
        desiredRPMValueLabel.textColor = .systemOrange
        desiredRPMValueLabel.textAlignment = .center
        
        // 5. Mode Segmented Control
        modeLabel.text = "Control Mode"
        modeLabel.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        modeLabel.textColor = .white  // High contrast on dark background
        
        modeSegmentedControl.selectedSegmentIndex = 0  // Start in Manual mode
        modeSegmentedControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        
        // Style the segmented control for dark mode
        if #available(iOS 13.0, *) {
            modeSegmentedControl.selectedSegmentTintColor = .systemOrange
            modeSegmentedControl.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
            modeSegmentedControl.setTitleTextAttributes([.foregroundColor: UIColor.systemGray], for: .normal)
        }
        
        // Initially hide desired RPM slider in manual mode
        desiredRPMLabel.isHidden = true
        desiredRPMSliderContainer.isHidden = true
        desiredRPMValueLabel.isHidden = true
        
        // 6. Actual RPM Display (Speedometer with needle)
        rpmSpeedometer.maxValue = MAX_RPM
        rpmSpeedometer.currentValue = 0
        rpmSpeedometer.label.text = "Actual RPM"
        rpmSpeedometer.valueLabel.isHidden = true  // Hide center label, show below instead
        rpmSpeedometer.backgroundColor = .clear
        rpmSpeedometer.showNeedle = true  // Show needle instead of filled arc
        
        // Separate RPM value label below speedometer
        rpmValueLabel.text = "0 RPM"
        rpmValueLabel.font = UIFont.systemFont(ofSize: 28, weight: .bold)
        rpmValueLabel.textColor = .systemBlue
        rpmValueLabel.textAlignment = .center
        
        // Add all subviews
        view.addSubview(titleLabel)
        view.addSubview(startStopButton)
        view.addSubview(rotationButton)
        view.addSubview(speedLabel)
        view.addSubview(speedSliderContainer)
        speedSliderContainer.addSubview(speedSlider)
        view.addSubview(speedValueLabel)
        view.addSubview(rpmSpeedometer)
        view.addSubview(rpmValueLabel)
        view.addSubview(modeLabel)
        view.addSubview(modeSegmentedControl)
        view.addSubview(desiredRPMLabel)
        view.addSubview(desiredRPMSliderContainer)
        desiredRPMSliderContainer.addSubview(desiredRPMSlider)
        view.addSubview(desiredRPMValueLabel)
        
        // Disable autoresizing masks
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        startStopButton.translatesAutoresizingMaskIntoConstraints = false
        rotationButton.translatesAutoresizingMaskIntoConstraints = false
        speedLabel.translatesAutoresizingMaskIntoConstraints = false
        speedSliderContainer.translatesAutoresizingMaskIntoConstraints = false
        speedSlider.translatesAutoresizingMaskIntoConstraints = false
        speedValueLabel.translatesAutoresizingMaskIntoConstraints = false
        rpmSpeedometer.translatesAutoresizingMaskIntoConstraints = false
        rpmValueLabel.translatesAutoresizingMaskIntoConstraints = false
        modeLabel.translatesAutoresizingMaskIntoConstraints = false
        modeSegmentedControl.translatesAutoresizingMaskIntoConstraints = false
        desiredRPMLabel.translatesAutoresizingMaskIntoConstraints = false
        desiredRPMSliderContainer.translatesAutoresizingMaskIntoConstraints = false
        desiredRPMSlider.translatesAutoresizingMaskIntoConstraints = false
        desiredRPMValueLabel.translatesAutoresizingMaskIntoConstraints = false
        
        // Layout constraints - REORGANIZED ORDER:
        // 1. START/STOP and Rotation side by side
        // 2. Speed
        // 3. Control Mode
        // 4. RPM inputs/outputs
        NSLayoutConstraint.activate([
            // Title
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            // 1. Start/Stop and Rotation Buttons (side by side)
            startStopButton.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 20),
            startStopButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            startStopButton.trailingAnchor.constraint(equalTo: rotationButton.leadingAnchor, constant: -15),
            startStopButton.heightAnchor.constraint(equalToConstant: 50),
            startStopButton.widthAnchor.constraint(equalTo: rotationButton.widthAnchor),
            
            rotationButton.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 20),
            rotationButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            rotationButton.heightAnchor.constraint(equalToConstant: 50),
            
            // 2. Speed Control (Horizontal slider with liquid glass effect) - MANUAL MODE
            speedLabel.topAnchor.constraint(equalTo: startStopButton.bottomAnchor, constant: 25),
            speedLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            
            speedSliderContainer.topAnchor.constraint(equalTo: speedLabel.bottomAnchor, constant: 15),
            speedSliderContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            speedSliderContainer.widthAnchor.constraint(equalToConstant: 280),
            speedSliderContainer.heightAnchor.constraint(equalToConstant: 50),
            
            speedSlider.centerXAnchor.constraint(equalTo: speedSliderContainer.centerXAnchor),
            speedSlider.centerYAnchor.constraint(equalTo: speedSliderContainer.centerYAnchor),
            speedSlider.widthAnchor.constraint(equalTo: speedSliderContainer.widthAnchor),
            speedSlider.heightAnchor.constraint(equalToConstant: 40),
            
            speedValueLabel.topAnchor.constraint(equalTo: speedSliderContainer.bottomAnchor, constant: 10),
            speedValueLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            
            // 2B. Desired RPM Slider (Same position as speed slider) - AUTOMATIC MODE
            desiredRPMLabel.topAnchor.constraint(equalTo: startStopButton.bottomAnchor, constant: 25),
            desiredRPMLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            
            desiredRPMSliderContainer.topAnchor.constraint(equalTo: desiredRPMLabel.bottomAnchor, constant: 15),
            desiredRPMSliderContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            desiredRPMSliderContainer.widthAnchor.constraint(equalToConstant: 280),
            desiredRPMSliderContainer.heightAnchor.constraint(equalToConstant: 50),
            
            desiredRPMSlider.centerXAnchor.constraint(equalTo: desiredRPMSliderContainer.centerXAnchor),
            desiredRPMSlider.centerYAnchor.constraint(equalTo: desiredRPMSliderContainer.centerYAnchor),
            desiredRPMSlider.widthAnchor.constraint(equalTo: desiredRPMSliderContainer.widthAnchor),
            desiredRPMSlider.heightAnchor.constraint(equalToConstant: 40),
            
            desiredRPMValueLabel.topAnchor.constraint(equalTo: desiredRPMSliderContainer.bottomAnchor, constant: 10),
            desiredRPMValueLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            
            // 3. RPM Section - Actual RPM Display (Speedometer - bigger)
            // Positioned below EITHER speedValueLabel (manual) OR desiredRPMTextField (automatic)
            rpmSpeedometer.topAnchor.constraint(equalTo: speedValueLabel.bottomAnchor, constant: 25),
            rpmSpeedometer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            rpmSpeedometer.widthAnchor.constraint(equalToConstant: 350),
            rpmSpeedometer.heightAnchor.constraint(equalToConstant: 220),
            
            // RPM value label below speedometer
            rpmValueLabel.topAnchor.constraint(equalTo: rpmSpeedometer.bottomAnchor, constant: 10),
            rpmValueLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            
            // 4. Control Mode (centered)
            modeLabel.topAnchor.constraint(equalTo: rpmValueLabel.bottomAnchor, constant: 25),
            modeLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            
            modeSegmentedControl.topAnchor.constraint(equalTo: modeLabel.bottomAnchor, constant: 10),
            modeSegmentedControl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            modeSegmentedControl.widthAnchor.constraint(equalToConstant: 280),
            modeSegmentedControl.heightAnchor.constraint(equalToConstant: 40)
        ])
    }
    
    // MARK: - Actions
    @objc func rotationButtonTapped() {
        isClockwise.toggle()
        if isClockwise {
            rotationButton.setTitle("↻ Clockwise", for: .normal)
            bleManager?.setDirectionForward()
        } else {
            rotationButton.setTitle("↺ Counter-Clockwise", for: .normal)
            bleManager?.setDirectionReverse()
        }
        print("Rotation: \(isClockwise ? "Clockwise" : "Counter-Clockwise")")
    }
    
    @objc func speedSliderChanged(_ slider: UISlider) {
        let newSpeed = Int(slider.value)
        currentSpeed = newSpeed
        speedValueLabel.text = "\(currentSpeed)%"
        updateSliderColor()
        updateLiquidGlassEffect()
    }
    
    @objc func speedSliderEnded(_ slider: UISlider) {
        let newSpeed = Int(slider.value)
        currentSpeed = newSpeed
        // Send speed command to motor
        bleManager?.setSpeed(currentSpeed)
        print("Speed set to: \(currentSpeed)%")
    }
    
    @objc func desiredRPMSliderChanged(_ slider: UISlider) {
        let newRPM = Int(slider.value)
        currentDesiredRPM = newRPM
        desiredRPMValueLabel.text = "\(currentDesiredRPM) RPM"
    }
    
    @objc func desiredRPMSliderEnded(_ slider: UISlider) {
        let newRPM = Int(slider.value)
        currentDesiredRPM = newRPM
        // Send automatic mode command with new target RPM
        bleManager?.sendCommand("auto \(currentDesiredRPM)")
        print("Target RPM set to: \(currentDesiredRPM)")
    }
    
    func createSliderTrackImage(height: CGFloat, color: UIColor) -> UIImage {
        let size = CGSize(width: 1, height: height)
        UIGraphicsBeginImageContextWithOptions(size, false, 0)
        let context = UIGraphicsGetCurrentContext()!
        context.setFillColor(color.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        let image = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        return image.resizableImage(withCapInsets: .zero)
    }
    
    func updateSliderColor() {
        let normalizedValue = CGFloat(currentSpeed) / 100.0
        let color: UIColor
        if normalizedValue < 0.5 {
            color = .systemGreen
        } else if normalizedValue < 0.75 {
            color = .systemYellow
        } else {
            color = .systemRed
        }
        // Create colored track image for the filled portion
        let filledTrackImage = createSliderTrackImage(height: 8, color: color)
        speedSlider.setMinimumTrackImage(filledTrackImage, for: .normal)
        // Keep the unfilled portion gray and visible
        let unfilledTrackImage = createSliderTrackImage(height: 8, color: .systemGray4)
        speedSlider.setMaximumTrackImage(unfilledTrackImage, for: .normal)
    }
    
    func updateLiquidGlassEffect() {
        // Remove existing gradient layers
        speedSliderContainer.layer.sublayers?.forEach { layer in
            if layer is CAGradientLayer {
                layer.removeFromSuperlayer()
            }
        }
        
        // Create liquid glass effect with gradient overlay
        let gradientLayer = CAGradientLayer()
        gradientLayer.frame = speedSliderContainer.bounds
        gradientLayer.cornerRadius = 8
        
        // Calculate gradient position based on slider value
        let normalizedValue = CGFloat(currentSpeed) / 100.0
        let gradientStart = max(0, normalizedValue - 0.1)
        let gradientEnd = min(1, normalizedValue + 0.1)
        
        // Create shimmer/glass effect
        gradientLayer.colors = [
            UIColor.white.withAlphaComponent(0.0).cgColor,
            UIColor.white.withAlphaComponent(0.3).cgColor,
            UIColor.white.withAlphaComponent(0.0).cgColor
        ]
        gradientLayer.locations = [NSNumber(value: Double(gradientStart)), NSNumber(value: Double(normalizedValue)), NSNumber(value: Double(gradientEnd))]
        gradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
        
        speedSliderContainer.layer.insertSublayer(gradientLayer, at: 0)
        
        // Add subtle glow
        speedSliderContainer.layer.shadowColor = UIColor.white.withAlphaComponent(0.3).cgColor
        speedSliderContainer.layer.shadowRadius = 8
        speedSliderContainer.layer.shadowOpacity = 0.5
        speedSliderContainer.layer.shadowOffset = .zero
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateLiquidGlassEffect()
    }
    
    @objc func startStopTapped() {
        print("🔘 START/STOP button tapped")
        isRunning.toggle()
        if isRunning {
            startStopButton.setTitle("STOP", for: .normal)
            startStopButton.backgroundColor = .systemRed
            print("   Sending ON command to BLE manager...")
            if bleManager == nil {
                print("   ❌ ERROR: bleManager is nil!")
            }
            bleManager?.turnOn()
            print("   Motor started")
        } else {
            startStopButton.setTitle("START", for: .normal)
            startStopButton.backgroundColor = .systemGreen
            print("   Sending OFF command to BLE manager...")
            bleManager?.turnOff()
            print("   Motor stopped")
        }
    }
    
    @objc func modeChanged(_ sender: UISegmentedControl) {
        let selectedIndex = sender.selectedSegmentIndex
        isAutomatic = (selectedIndex == 1)  // 0 = Manual, 1 = Automatic
        
        if isAutomatic {
            // Switch to AUTOMATIC mode
            print("🎯 Switching to AUTOMATIC mode")
            
            // HIDE speed controls completely
            speedLabel.isHidden = true
            speedSliderContainer.isHidden = true
            speedValueLabel.isHidden = true
            
            // SHOW desired RPM slider in their place
            desiredRPMLabel.isHidden = false
            desiredRPMSliderContainer.isHidden = false
            desiredRPMValueLabel.isHidden = false
            
            // Switch to automatic mode with current desired RPM
            bleManager?.sendCommand("auto \(currentDesiredRPM)")
            print("   📤 Sent: auto \(currentDesiredRPM)")
            
        } else {
            // Switch to MANUAL mode
            print("✋ Switching to MANUAL mode")
            
            // SHOW speed controls
            speedLabel.isHidden = false
            speedSliderContainer.isHidden = false
            speedValueLabel.isHidden = false
            
            // HIDE desired RPM slider
            desiredRPMLabel.isHidden = true
            desiredRPMSliderContainer.isHidden = true
            desiredRPMValueLabel.isHidden = true
            
            // Switch to manual mode and immediately apply current speed
            bleManager?.sendCommand("manual")
            print("   📤 Sent: manual")
            
            // Apply the current manual speed setting
            bleManager?.setSpeed(currentSpeed)
            print("   📤 Sent: s \(currentSpeed)")
        }
    }
    
    @objc func dismissKeyboard() {
        view.endEditing(true)
    }
    
    // MARK: - BLE Status Update (removed - no longer showing status label)
    func updateBLEStatus(isReady: Bool) {
        // Status label removed per user request
    }
    
    // MARK: - RPM Update
    func updateRPM(_ rpmString: String) {
        DispatchQueue.main.async {
            // Parse RPM value from string (format: "123.45" or "123.45\n")
            let cleaned = rpmString.trimmingCharacters(in: .whitespacesAndNewlines)
            if let rpmValue = Double(cleaned) {
                let rpm = CGFloat(rpmValue)
                // Update speedometer
                self.rpmSpeedometer.currentValue = min(rpm, self.MAX_RPM)
                self.rpmSpeedometer.setNeedsDisplay()
                
                // Update label below speedometer
                self.rpmValueLabel.text = String(format: "%.0f RPM", rpmValue)
            } else {
                print("⚠️ Could not parse RPM: \(cleaned)")
            }
        }
    }
}

