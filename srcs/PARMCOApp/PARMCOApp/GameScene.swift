import SpriteKit
import GameplayKit

/**
 * =============================================================================
 * GAME SCENE - Flappy Bird Style Motor Control Game
 * =============================================================================
 * A game where the propeller speed increases with score, and you win when reaching 100% speed.
 * 
 * GAME MECHANICS:
 * - Tap screen to make propeller jump
 * - Avoid gray pipe obstacles (top and bottom)
 * - Each point scored increases motor speed by 5%
 * - Win at 16 points (100% motor speed)
 * - Motor starts at 20% speed
 * 
 * MOTOR INTEGRATION:
 * - Game starts: Motor turns ON at 20% speed
 * - Each score: Motor speed increases 5% (20%, 25%, 30%, ...)
 * - Game over/win: Motor turns OFF and resets to 0%
 * 
 * PHYSICS:
 * - Propeller: Dynamic body with gravity and collision
 * - Obstacles: Static bodies (pipes)
 * - Score zones: Invisible collision detectors between pipes
 * 
 * COLLISION DETECTION:
 * Uses category bitmasks to detect:
 * - Propeller hitting obstacle → Game over
 * - Propeller passing score zone → Increment score
 */
class GameScene: SKScene, SKPhysicsContactDelegate {
    
    // Game objects
    var propeller: SKSpriteNode!    // Player character (propeller sprite)
    var scoreLabel: SKLabelNode!    // Score display at top
    var speedLabel: SKLabelNode!    // Motor speed display
    var score = 0                   // Current game score
    var gameStarted = false         // Has game begun?
    var gameOver = false            // Is game over?
    
    // Motor control
    var bleMotorManager: BLEMotorManager?  // BLE connection to Raspberry Pi
    var currentMotorSpeed = 0              // Current motor speed (0-100%)
    var isMotorForward = true              // Motor direction (true=forward, false=reverse)
    
    // Category bitmasks for collision detection (binary flags)
    let propellerCategory: UInt32 = 0x1 << 0  // 0001 = Propeller
    let obstacleCategory: UInt32  = 0x1 << 1  // 0010 = Pipes/walls
    let scoreCategory: UInt32     = 0x1 << 2  // 0100 = Score zones
    
    /**
     * SCENE INITIALIZATION
     * Called when scene is presented. Sets up all game elements.
     */
    override func didMove(to view: SKView) {
        physicsWorld.contactDelegate = self  // Receive collision callbacks
        backgroundColor = .black              // Dark background
        setupPropeller()
        setupGround()
        setupScoreLabel()
        setupSpeedLabel()
        setupStartLabel()
    }
    
    /**
     * SETUP PROPELLER (Player Character)
     * Creates the propeller sprite with physics body for collision detection.
     * 
     * PHYSICS:
     * - circleOfRadius: 24 (smaller than sprite for easier gameplay)
     * - affectedByGravity: false initially (enabled when game starts)
     * - contactTestBitMask: Detect collisions with obstacles and score zones
     * - collisionBitMask: Physically collide with obstacles (bounce off)
     * 
     * ANIMATION:
     * - Constantly rotates to look like a spinning propeller
     */
    func setupPropeller() {
        // Create propeller sprite from assets
        propeller = SKSpriteNode(imageNamed: "propeller_sprite")
        propeller.position = CGPoint(x: frame.midX / 2, y: frame.midY)
        propeller.size = CGSize(width: 80, height: 80)
        
        // PHYSICS BODY: Smaller hitbox for easier gameplay (radius 24 vs sprite 40)
        propeller.physicsBody = SKPhysicsBody(circleOfRadius: 24)
        propeller.physicsBody?.affectedByGravity = false  // No gravity until game starts
        propeller.physicsBody?.allowsRotation = false     // Keep upright (no tumbling)
        propeller.physicsBody?.isDynamic = true            // Affected by forces
        propeller.physicsBody?.categoryBitMask = propellerCategory
        propeller.physicsBody?.contactTestBitMask = obstacleCategory | scoreCategory  // Detect hits
        propeller.physicsBody?.collisionBitMask = obstacleCategory  // Bounce off obstacles
        addChild(propeller)
        
        // ANIMATION: Constant rotation (looks like spinning propeller)
        let rotate = SKAction.rotate(byAngle: .pi * 2, duration: 0.5)
        propeller.run(SKAction.repeatForever(rotate))
    }
    
    func setupGround() {
        let ground = SKNode()
        ground.position = CGPoint(x: 0, y: 0)
        ground.physicsBody = SKPhysicsBody(edgeLoopFrom: frame)
        ground.physicsBody?.categoryBitMask = obstacleCategory
        addChild(ground)
    }
    
    func setupScoreLabel() {
        scoreLabel = SKLabelNode(fontNamed: "AvenirNext-Bold")
        scoreLabel.fontSize = 40
        scoreLabel.text = "Score: 0"
        scoreLabel.position = CGPoint(x: frame.midX, y: frame.height - 80)
        scoreLabel.fontColor = .white
        scoreLabel.zPosition = 5
        addChild(scoreLabel)
    }
    
    func setupSpeedLabel() {
        speedLabel = SKLabelNode(fontNamed: "AvenirNext-Bold")
        speedLabel.fontSize = 30
        speedLabel.text = "Motor: 0%"
        speedLabel.position = CGPoint(x: frame.midX, y: frame.height - 130)
        speedLabel.fontColor = .systemOrange
        speedLabel.zPosition = 5
        addChild(speedLabel)
    }
    
    func setupStartLabel() {
        let startLabel = SKLabelNode(fontNamed: "AvenirNext-Bold")
        startLabel.text = "TAP TO START"
        startLabel.fontSize = 30
        startLabel.fontColor = .white
        startLabel.position = CGPoint(x: frame.midX, y: frame.midY - 100)
        startLabel.zPosition = 5
        startLabel.name = "startLabel"
        addChild(startLabel)
    }
    
    func spawnObstacles() {
        let gapHeight = CGFloat(300)  // Larger gap for easier gameplay
        let obstacleWidth = CGFloat(60)
        let randomHeight = CGFloat.random(in: 100...400)
        
        let bottomObstacle = SKSpriteNode(color: .systemGray, size: CGSize(width: obstacleWidth, height: randomHeight))
        bottomObstacle.position = CGPoint(x: frame.width + obstacleWidth, y: bottomObstacle.size.height / 2)
        bottomObstacle.physicsBody = SKPhysicsBody(rectangleOf: bottomObstacle.size)
        bottomObstacle.physicsBody?.isDynamic = false
        bottomObstacle.physicsBody?.categoryBitMask = obstacleCategory
        
        let topObstacleHeight = frame.height - randomHeight - gapHeight
        let topObstacle = SKSpriteNode(color: .systemGray, size: CGSize(width: obstacleWidth, height: topObstacleHeight))
        topObstacle.position = CGPoint(x: frame.width + obstacleWidth, y: frame.height - topObstacle.size.height / 2)
        topObstacle.physicsBody = SKPhysicsBody(rectangleOf: topObstacle.size)
        topObstacle.physicsBody?.isDynamic = false
        topObstacle.physicsBody?.categoryBitMask = obstacleCategory
        
        // Score detector (invisible node)
        let scoreNode = SKNode()
        scoreNode.position = CGPoint(x: frame.width + obstacleWidth + (obstacleWidth / 2), y: frame.midY)
        scoreNode.physicsBody = SKPhysicsBody(rectangleOf: CGSize(width: 1, height: frame.height))
        scoreNode.physicsBody?.isDynamic = false
        scoreNode.physicsBody?.categoryBitMask = scoreCategory
        scoreNode.physicsBody?.contactTestBitMask = propellerCategory
        
        // Move obstacles
        let move = SKAction.moveBy(x: -frame.width - 200, y: 0, duration: 4)
        let remove = SKAction.removeFromParent()
        let sequence = SKAction.sequence([move, remove])
        
        bottomObstacle.run(sequence)
        topObstacle.run(sequence)
        scoreNode.run(sequence)
        
        addChild(bottomObstacle)
        addChild(topObstacle)
        addChild(scoreNode)
    }
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if gameOver {
            // Restart game
            restartGame()
            return
        }
        
        if !gameStarted {
            gameStarted = true
            propeller.physicsBody?.affectedByGravity = true
            childNode(withName: "startLabel")?.removeFromParent()
            
            // IMPORTANT: Switch to manual mode so game has direct control
            // (if coming from automatic mode, disable PID controller)
            bleMotorManager?.sendCommand("manual")
            
            // Set initial direction to forward
            isMotorForward = true
            bleMotorManager?.setDirectionForward()
            
            // Turn motor ON and set initial speed to 20%
            bleMotorManager?.turnOn()
            currentMotorSpeed = 20
            bleMotorManager?.setSpeed(20)
            speedLabel.text = "Motor: 20%"
            
            // Start spawning obstacles
            let spawn = SKAction.run { [weak self] in self?.spawnObstacles() }
            let delay = SKAction.wait(forDuration: 2.5)
            let sequence = SKAction.sequence([spawn, delay])
            run(SKAction.repeatForever(sequence), withKey: "spawnObstacles")
            return  // Don't jump on first tap, just start the game
        }
        
        // Flap (gentle impulse for precise control)
        propeller.physicsBody?.velocity = CGVector(dx: 0, dy: 0)
        propeller.physicsBody?.applyImpulse(CGVector(dx: 0, dy: 50))
    }
    
    func updateMotorSpeed() {
        // Calculate motor speed based on score (0-100%)
        // Start at 20%, increment by 5% per score, win at 16 points (100%)
        currentMotorSpeed = min(20 + (score * 5), 100)
        speedLabel.text = "Motor: \(currentMotorSpeed)%"
        
        // Send speed to motor
        bleMotorManager?.setSpeed(currentMotorSpeed)
        
        // Check win condition
        if currentMotorSpeed >= 100 {
            winGame()
        }
    }
    
    /**
     * TOGGLE MOTOR DIRECTION
     * Alternates motor direction between forward and reverse each time called.
     * Called every time the player scores a point (passes through pipes).
     * 
     * This adds a fun gameplay element where motor direction changes with score.
     */
    func toggleMotorDirection() {
        // Toggle direction flag
        isMotorForward.toggle()
        
        // Send command to motor
        if isMotorForward {
            bleMotorManager?.setDirectionForward()
            print("🔄 Motor direction: FORWARD")
        } else {
            bleMotorManager?.setDirectionReverse()
            print("🔄 Motor direction: REVERSE")
        }
    }
    
    override func update(_ currentTime: TimeInterval) {
        if gameOver { return }
        
        // Keep propeller from going too high or low
        if propeller.position.y > frame.height - 50 {
            propeller.position.y = frame.height - 50
        }
    }
    
    func didBegin(_ contact: SKPhysicsContact) {
        let firstBody: SKPhysicsBody
        let secondBody: SKPhysicsBody
        
        if contact.bodyA.categoryBitMask < contact.bodyB.categoryBitMask {
            firstBody = contact.bodyA
            secondBody = contact.bodyB
        } else {
            firstBody = contact.bodyB
            secondBody = contact.bodyA
        }
        
        // Check for score contact
        if firstBody.categoryBitMask == propellerCategory && secondBody.categoryBitMask == scoreCategory {
            score += 1
            scoreLabel.text = "Score: \(score)"
            
            // Toggle motor direction on each score
            toggleMotorDirection()
            
            // Update motor speed
            updateMotorSpeed()
            
            secondBody.node?.removeFromParent()
        }
        
        // Check for obstacle collision
        if firstBody.categoryBitMask == propellerCategory && secondBody.categoryBitMask == obstacleCategory {
            endGame()
        }
    }
    
    func winGame() {
        guard !gameOver else { return }
        gameOver = true
        removeAction(forKey: "spawnObstacles")
        removeAllActions()
        
        // Reset motor speed to 0 and turn off
        currentMotorSpeed = 0
        bleMotorManager?.setSpeed(0)
        bleMotorManager?.turnOff()
        speedLabel.text = "Motor: 0%"
        
        let label = SKLabelNode(text: "🎉 YOU WIN! 🎉")
        label.fontSize = 40
        label.fontColor = .systemGreen
        label.position = CGPoint(x: frame.midX, y: frame.midY)
        label.zPosition = 10
        addChild(label)
        
        let subLabel = SKLabelNode(text: "Motor at 100%!")
        subLabel.fontSize = 25
        subLabel.fontColor = .white
        subLabel.position = CGPoint(x: frame.midX, y: frame.midY - 50)
        subLabel.zPosition = 10
        addChild(subLabel)
        
        let restartLabel = SKLabelNode(text: "TAP TO RESTART")
        restartLabel.fontSize = 20
        restartLabel.fontColor = .systemGray
        restartLabel.position = CGPoint(x: frame.midX, y: frame.midY - 100)
        restartLabel.zPosition = 10
        addChild(restartLabel)
    }
    
    func endGame() {
        guard !gameOver else { return }
        gameOver = true
        removeAction(forKey: "spawnObstacles")
        propeller.removeFromParent()
        
        // Reset motor speed to 0 and turn off
        currentMotorSpeed = 0
        bleMotorManager?.setSpeed(0)
        bleMotorManager?.turnOff()
        speedLabel.text = "Motor: 0%"
        
        let label = SKLabelNode(text: "Game Over!")
        label.fontSize = 40
        label.fontColor = .systemRed
        label.position = CGPoint(x: frame.midX, y: frame.midY)
        label.zPosition = 10
        addChild(label)
        
        let scoreEndLabel = SKLabelNode(text: "Final Score: \(score)")
        scoreEndLabel.fontSize = 25
        scoreEndLabel.fontColor = .white
        scoreEndLabel.position = CGPoint(x: frame.midX, y: frame.midY - 50)
        scoreEndLabel.zPosition = 10
        addChild(scoreEndLabel)
        
        let restartLabel = SKLabelNode(text: "TAP TO RESTART")
        restartLabel.fontSize = 20
        restartLabel.fontColor = .systemGray
        restartLabel.position = CGPoint(x: frame.midX, y: frame.midY - 100)
        restartLabel.zPosition = 10
        addChild(restartLabel)
    }
    
    func restartGame() {
        // Reset motor speed to 0 and turn off
        currentMotorSpeed = 0
        bleMotorManager?.setSpeed(0)
        bleMotorManager?.turnOff()
        
        // Remove all nodes and restart
        removeAllChildren()
        removeAllActions()
        
        score = 0
        gameStarted = false
        gameOver = false
        isMotorForward = true  // Reset direction to forward
        
        setupPropeller()
        setupGround()
        setupScoreLabel()
        setupSpeedLabel()
        setupStartLabel()
    }
}

