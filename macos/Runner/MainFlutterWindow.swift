import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let project = FlutterDartProject()
    project.dartEntrypointArguments = MainFlutterWindow.launchArguments()
    let flutterViewController = FlutterViewController(project: project)
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  /// 过滤 AppKit 自己塞进来的参数，只把用户参数（--search/--series/…）
  /// 交给 Dart 入口。
  private static func launchArguments() -> [String] {
    let raw = Array(CommandLine.arguments.dropFirst())
    var result: [String] = []
    var i = 0
    while i < raw.count {
      let arg = raw[i]
      if arg == "-NSDocumentRevisionsDebugMode" || arg == "-ApplePersistenceIgnoreState" {
        i += 2
        continue
      }
      if arg.hasPrefix("-psn_") {
        i += 1
        continue
      }
      result.append(arg)
      i += 1
    }
    return result
  }
}
