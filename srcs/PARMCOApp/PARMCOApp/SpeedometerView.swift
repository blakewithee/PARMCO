import UIKit

class SpeedometerView: UIView {
    
    // Configuration
    var maxValue: CGFloat = 100.0  // Max value for the speedometer
    var currentValue: CGFloat = 0.0 {
        didSet {
            setNeedsDisplay()
        }
    }
    
    var showNeedle: Bool = false  // If true, show needle instead of filled arc
    var slider: UISlider?  // Optional slider along the curve
    
    var label: UILabel!
    var valueLabel: UILabel!
    
    // Computed properties for arc geometry
    var arcCenter: CGPoint {
        return CGPoint(x: bounds.midX, y: bounds.height * 0.9)
    }
    
    var arcRadius: CGFloat {
        return min(bounds.width, bounds.height) * 0.5
    }
    
    var startAngle: CGFloat {
        return .pi  // 180 degrees (left side)
    }
    
    var endAngle: CGFloat {
        return 0  // 0 degrees (right side)
    }
    
    var currentAngle: CGFloat {
        let normalizedValue = min(max(currentValue / maxValue, 0), 1.0)
        // For needle: angle should go from startAngle (left) to endAngle (right)
        // When value is 0, angle = π (left), when value is max, angle = 0 (right)
        return startAngle - (normalizedValue * (startAngle - endAngle))
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLabels()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLabels()
    }
    
    func setupLabels() {
        // Title label
        label = UILabel()
        label.textAlignment = .center
        label.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white  // High contrast for dark mode
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        
        // Value label (shows number)
        valueLabel = UILabel()
        valueLabel.textAlignment = .center
        valueLabel.font = UIFont.systemFont(ofSize: 24, weight: .bold)
        valueLabel.textColor = .systemBlue  // Keep blue for visibility
        addSubview(valueLabel)
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            
            valueLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            valueLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }
    
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        
        let center = self.arcCenter
        let radius = self.arcRadius
        let startAngle = self.startAngle
        let endAngle = self.endAngle
        
        // Draw background arc (lighter gray for dark mode visibility)
        context.setStrokeColor(UIColor.systemGray3.cgColor)
        context.setLineWidth(12)
        context.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        context.strokePath()
        
        let normalizedValue = min(max(currentValue / maxValue, 0), 1.0)
        let currentAngle = self.currentAngle
        
        if showNeedle {
            // Draw needle for RPM speedometer
            drawNeedle(context: context, center: center, angle: currentAngle, radius: radius)
        } else {
            // Draw filled arc (colored based on value) for speed control
            let color: UIColor
            if normalizedValue < 0.5 {
                color = .systemGreen
            } else if normalizedValue < 0.75 {
                color = .systemYellow
            } else {
                color = .systemRed
            }
            
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(12)
            context.setLineCap(.round)
            context.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: currentAngle, clockwise: false)
            context.strokePath()
        }
        
        // Draw tick marks like a car speedometer (white, with major and minor ticks)
        context.setStrokeColor(UIColor.white.cgColor)
        
        // Draw major tick marks (every 10%)
        for i in 0...10 {
            let tickValue = CGFloat(i) / 10.0
            let tickAngle = startAngle - (tickValue * (startAngle - endAngle))
            let innerRadius = radius - 12
            let outerRadius = radius + 8
            
            let x1 = center.x + cos(tickAngle) * innerRadius
            let y1 = center.y - sin(tickAngle) * innerRadius  // Flip Y for upward pointing
            let x2 = center.x + cos(tickAngle) * outerRadius
            let y2 = center.y - sin(tickAngle) * outerRadius  // Flip Y for upward pointing
            
            context.setLineWidth(3)  // Thicker major ticks
            context.move(to: CGPoint(x: x1, y: y1))
            context.addLine(to: CGPoint(x: x2, y: y2))
            context.strokePath()
        }
        
        // Draw minor tick marks (every 5%)
        context.setLineWidth(1.5)  // Thinner minor ticks
        for i in 0...20 {
            if i % 2 == 0 { continue }  // Skip major ticks
            let tickValue = CGFloat(i) / 20.0
            let tickAngle = startAngle - (tickValue * (startAngle - endAngle))
            let innerRadius = radius - 8
            let outerRadius = radius + 4
            
            let x1 = center.x + cos(tickAngle) * innerRadius
            let y1 = center.y - sin(tickAngle) * innerRadius  // Flip Y for upward pointing
            let x2 = center.x + cos(tickAngle) * outerRadius
            let y2 = center.y - sin(tickAngle) * outerRadius  // Flip Y for upward pointing
            
            context.move(to: CGPoint(x: x1, y: y1))
            context.addLine(to: CGPoint(x: x2, y: y2))
            context.strokePath()
        }
    }
    
    func drawNeedle(context: CGContext, center: CGPoint, angle: CGFloat, radius: CGFloat) {
        // Draw needle as a triangle pointing from center to the angle
        let needleLength = radius * 0.8
        let needleWidth: CGFloat = 4
        
        // Calculate needle tip - flip vertically by inverting Y coordinate
        // The center is at the bottom, so we need to flip the Y to point upward
        let tipX = center.x + cos(angle) * needleLength
        // Flip Y: instead of center.y + sin(angle), use center.y - sin(angle) to point upward
        let tipY = center.y - sin(angle) * needleLength
        
        // Calculate perpendicular direction for needle width (perpendicular to the needle direction)
        // Use angle - π/2 to get perpendicular (this ensures needle has proper width)
        let perpAngle = angle - .pi / 2
        let halfWidth = needleWidth / 2
        
        let p1X = center.x + cos(perpAngle) * halfWidth
        let p1Y = center.y - sin(perpAngle) * halfWidth  // Also flip Y for base points
        let p2X = center.x - cos(perpAngle) * halfWidth
        let p2Y = center.y + sin(perpAngle) * halfWidth  // Flip opposite for symmetry
        
        // Draw needle triangle (pointing from center upward to tip)
        context.setFillColor(UIColor.systemRed.cgColor)
        context.move(to: CGPoint(x: tipX, y: tipY))
        context.addLine(to: CGPoint(x: p1X, y: p1Y))
        context.addLine(to: CGPoint(x: p2X, y: p2Y))
        context.closePath()
        context.fillPath()
        
        // Draw center circle (pivot point) - lighter for dark mode
        context.setFillColor(UIColor.systemGray.cgColor)
        context.fillEllipse(in: CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12))
    }
    
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // If we have a slider, let it handle touches along the arc
        if let slider = slider {
            let center = self.arcCenter
            let radius = self.arcRadius
            let distance = sqrt(pow(point.x - center.x, 2) + pow(point.y - center.y, 2))
            
            // If point is near the arc (within reasonable distance for touch)
            if abs(distance - radius) < 40 {
                // Convert point to angle
                var angle = atan2(point.y - center.y, point.x - center.x)
                
                // Normalize angle to match our arc (π to 0, left to right)
                // Our arc goes from π (left) to 0 (right)
                if angle < 0 {
                    angle = angle + 2 * .pi  // Convert to 0-2π range
                }
                
                // Map to our arc range (π to 0)
                let startAngle = self.startAngle  // π
                let endAngle = self.endAngle      // 0
                
                // Check if angle is in the upper semicircle (0 to π)
                if angle <= .pi {
                    // Angle is in the correct range
                    // Convert from angle range (0 to π) to value range (1 to 0)
                    let normalizedValue = 1.0 - (angle / .pi)
                    let clampedValue = min(max(normalizedValue, 0), 1.0)
                    
                    slider.value = Float(clampedValue) * slider.maximumValue
                    slider.sendActions(for: .valueChanged)
                    
                    return self  // Return self to handle the touch
                }
            }
        }
        
        return super.hitTest(point, with: event)
    }
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        if let touch = touches.first, let slider = slider {
            let point = touch.location(in: self)
            let center = self.arcCenter
            let radius = self.arcRadius
            let distance = sqrt(pow(point.x - center.x, 2) + pow(point.y - center.y, 2))
            
            if abs(distance - radius) < 40 {
                var angle = atan2(point.y - center.y, point.x - center.x)
                if angle < 0 {
                    angle = angle + 2 * .pi
                }
                
                if angle <= .pi {
                    let normalizedValue = 1.0 - (angle / .pi)
                    let clampedValue = min(max(normalizedValue, 0), 1.0)
                    slider.value = Float(clampedValue) * slider.maximumValue
                    slider.sendActions(for: .valueChanged)
                }
            }
        }
    }
    
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        if let touch = touches.first, let slider = slider {
            let point = touch.location(in: self)
            let center = self.arcCenter
            let radius = self.arcRadius
            let distance = sqrt(pow(point.x - center.x, 2) + pow(point.y - center.y, 2))
            
            if abs(distance - radius) < 40 {
                var angle = atan2(point.y - center.y, point.x - center.x)
                if angle < 0 {
                    angle = angle + 2 * .pi
                }
                
                if angle <= .pi {
                    let normalizedValue = 1.0 - (angle / .pi)
                    let clampedValue = min(max(normalizedValue, 0), 1.0)
                    slider.value = Float(clampedValue) * slider.maximumValue
                    slider.sendActions(for: .valueChanged)
                }
            }
        }
    }
    
    func updateValue(_ value: CGFloat) {
        currentValue = value
        // Update label will be handled by the view controller
    }
}

