import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerProjectFolderChannel(registry: flutterViewController)

    super.awakeFromNib()
  }
}

/// The `fah/project_folder` method channel: native directory picking via
/// NSOpenPanel plus security-scoped bookmark lifecycle, so a user-selected
/// project folder stays accessible to the sandboxed app across restarts.
private func registerProjectFolderChannel(registry: FlutterPluginRegistry) {
  guard let messenger = registry as? FlutterBinaryMessenger else { return }
  let channel = FlutterMethodChannel(
    name: "fah/project_folder",
    binaryMessenger: messenger,
  )
  channel.setMethodCallHandler { call, result in
    switch call.method {
    case "pickDirectory":
      result(pickDirectoryWithBookmark())
    case "startAccessing":
      let bookmark = call.arguments as? String ?? ""
      result(startAccessing(bookmarkBase64: bookmark))
    case "stopAccessing":
      let bookmark = call.arguments as? String ?? ""
      stopAccessing(bookmarkBase64: bookmark)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// Opens an NSOpenPanel for a single directory and returns the chosen path
/// plus a security-scoped bookmark for it, or nil when cancelled.
private func pickDirectoryWithBookmark() -> [String: String]? {
  let panel = NSOpenPanel()
  panel.canChooseDirectories = true
  panel.canChooseFiles = false
  panel.allowsMultipleSelection = false
  panel.prompt = "Open"
  panel.message = "Choose a project folder the agent may work in"
  guard panel.runModal() == .OK, let url = panel.url else { return nil }
  guard let bookmark = try? url.bookmarkData(
    options: .withSecurityScope,
    includingResourceValuesForKeys: nil,
    relativeTo: nil,
  ) else { return nil }
  return [
    "path": url.path,
    "bookmark": bookmark.base64EncodedString(),
  ]
}

/// Resolves a security-scoped bookmark and starts accessing the resource.
/// False when the bookmark is stale or the folder is gone.
private func startAccessing(bookmarkBase64: String) -> Bool {
  guard let data = Data(base64Encoded: bookmarkBase64) else { return false }
  var stale = ObjCBool(false)
  guard
    let url = try? URL(
      resolvingSecurityScopedBookmarkData: data,
      options: [],
      relativeTo: nil,
      bookmarkDataIsStale: &stale,
    ), !stale.boolValue
  else { return false }
  return url.startAccessingSecurityScopedResource()
}

/// Best-effort stop of a previously started security-scoped access.
private func stopAccessing(bookmarkBase64: String) {
  guard let data = Data(base64Encoded: bookmarkBase64),
    let url = try? URL(
      resolvingSecurityScopedBookmarkData: data,
      options: [],
      relativeTo: nil,
      bookmarkDataIsStale: nil,
    )
  else { return }
  url.stopAccessingSecurityScopedResource()
}
