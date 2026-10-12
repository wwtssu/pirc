import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    self.contentMinSize = NSSize(width: 360, height: 600)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
    // Apply after nib restoration, which otherwise restores the template frame.
    DispatchQueue.main.async { [weak self] in
      self?.setContentSize(NSSize(width: 430, height: 820))
      self?.title = "PiRC"
      self?.center()
    }
  }
}
