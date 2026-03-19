import UIKit
import Flutter

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)
        
        // Register MediaPipe plugin
        if let registrar = self.registrar(forPlugin: "MediaPipePlugin") {
            MediaPipePlugin.register(with: registrar)
        }
        
        return super.application(application, 
                                  didFinishLaunchingWithOptions: launchOptions)
    }
}