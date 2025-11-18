import UIKit
import SpriteKit

class GameViewController: UIViewController {
    
    var bleManager: BLEMotorManager?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = .black
        setupGame()
    }
    
    func setupGame() {
        // Create and configure the scene
        let scene = GameScene(size: view.bounds.size)
        scene.scaleMode = .aspectFill
        scene.bleMotorManager = bleManager
        
        // Create the view
        let skView = SKView(frame: view.bounds)
        skView.presentScene(scene)
        skView.ignoresSiblingOrder = true
        
        // Debug options (optional)
        skView.showsFPS = false
        skView.showsNodeCount = false
        
        view.addSubview(skView)
    }
    
    override var prefersStatusBarHidden: Bool {
        return true
    }
}

