import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        
        print("🚀 ========== PARMCO APP STARTING ==========")
        NSLog("🚀 ========== PARMCO APP STARTING ==========")
        
        window = UIWindow(frame: UIScreen.main.bounds)
        let splashVC = SplashViewController()
        window?.rootViewController = splashVC
        window?.makeKeyAndVisible()
        
        print("✅ App window created")
        NSLog("✅ App window created")
        
        return true
    }
}

