import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    self.setContentSize(NSSize(width: 1100, height: 760))
    self.contentMinSize = NSSize(width: 400, height: 600)
    self.center()
    self.delegate = self

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  // Closing the only window quits (AppDelegate), so route it through Quit:
  // that goes through applicationShouldTerminate, where the Dart side
  // (AppLifecycleListener.onExitRequested) can refuse while an upload runs.
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    NSApp.terminate(nil)
    return false
  }
}
