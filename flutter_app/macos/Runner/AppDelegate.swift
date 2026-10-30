import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    registerClipboardFilesChannel()
  }
}

/// The `fa/clipboard_files` method channel: thin native clipboard FILE
/// reading for the composer's smart paste (issue #1979 — owner decision:
/// our own ~50-line reader instead of the super_native_extensions chain).
/// `readClipboardFiles` pulls the file URLs Finder puts on the pasteboard
/// (`public.file-url` / the legacy `NSFilenamesPboardType`, both surfaced
/// by `readObjects(forClasses: [NSURL.self])`) and reads each file's
/// bytes. Answers `{files: [{name, bytes}], unsupported: bool}` — same
/// contract as the iOS reader.
private func registerClipboardFilesChannel() {
  guard
    let controller = mainFlutterWindow?.contentViewController
      as? FlutterViewController
  else { return }
  let channel = FlutterMethodChannel(
    name: "fa/clipboard_files",
    binaryMessenger: controller.engine.binaryMessenger,
  )
  channel.setMethodCallHandler { call, result in
    switch call.method {
    case "readClipboardFiles":
      result(FaClipboardFilesReader.read())
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

private enum FaClipboardFilesReader {
  static let maxFileBytes = 32 * 1024 * 1024

  static func read() -> [String: Any] {
    guard let urls = NSPasteboard.general.readObjects(
      forClasses: [NSURL.self],
      options: [NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true],
    ) as? [URL] else {
      return ["files": [[String: Any]](), "unsupported": false]
    }
    var files: [[String: Any]] = []
    for url in urls {
      if let entry = readFile(at: url) {
        files.append(entry)
      }
    }
    // Dropped-but-present file URLs we could not read (permissions, size)
    // keep the count honest only via absence — macOS clipboard file reads
    // of user-intent copies are permitted by the sandbox, so failures are
    // rare and surface as plain silence with the text rules intact.
    return ["files": files, "unsupported": false]
  }

  static func readFile(at url: URL) -> [String: Any]? {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    guard
      let data = try? Data(contentsOf: url),
      data.count <= maxFileBytes
    else { return nil }
    return [
      "name": url.lastPathComponent,
      "bytes": data,
    ]
  }
}
