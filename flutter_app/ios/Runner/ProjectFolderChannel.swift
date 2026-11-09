import Flutter
import UIKit
import UniformTypeIdentifiers

/// A user-granted folder exposed as `/project` to the Dart mount layer and
/// the WASI preopened-directory list. The URL is retained for the app's
/// lifetime; stopping one bookmark must not revoke a live WASI command.
private final class FaProjectFolderPicker: NSObject, UIDocumentPickerDelegate {
  var completion: ((URL?) -> Void)?
  var grantedURL: URL?

  func pick(from controller: UIViewController?, completion: @escaping (URL?) -> Void) {
    self.completion = completion
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
    picker.delegate = self
    picker.allowsMultipleSelection = false
    picker.shouldShowFileExtensions = true
    guard let controller else {
      self.completion = nil
      completion(nil)
      return
    }
    controller.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let url = urls.first else {
      completion?(nil)
      completion = nil
      return
    }
    grantedURL?.stopAccessingSecurityScopedResource()
    grantedURL = url
    _ = url.startAccessingSecurityScopedResource()
    completion?(url)
    completion = nil
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    completion?(nil)
    completion = nil
  }
}

private let faProjectFolderPicker = FaProjectFolderPicker()
private var faProjectFolderBookmarks: [String: URL] = [:]

/// The iOS implementation of the shared `fah/project_folder` channel used by
/// the existing macOS mount flow. Bookmarks never contain file contents.
func registerProjectFolderChannel(messenger: FlutterBinaryMessenger) {
  let channel = FlutterMethodChannel(name: "fah/project_folder", binaryMessenger: messenger)
  channel.setMethodCallHandler { call, result in
    switch call.method {
    case "pickDirectory":
      let controller = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap { $0.windows }
        .first { $0.isKeyWindow }?.rootViewController
      faProjectFolderPicker.pick(from: controller) { url in
        guard let url else {
          result(nil)
          return
        }
        do {
          let bookmark = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
          )
          faProjectFolderBookmarks[bookmark.base64EncodedString()] = url
          result(["path": url.path, "bookmark": bookmark.base64EncodedString()])
        } catch {
          result(FlutterError(code: "bookmark_failed", message: error.localizedDescription, details: nil))
        }
      }
    case "startAccessing":
      guard let encoded = call.arguments as? String,
            let bookmark = Data(base64Encoded: encoded) else {
        result(false)
        return
      }
      do {
        var stale = false
        let url = try URL(
          resolvingBookmarkData: bookmark,
          options: [],
          relativeTo: nil,
          bookmarkDataIsStale: &stale
        )
        let granted = url.startAccessingSecurityScopedResource()
        if granted {
          faProjectFolderBookmarks[encoded] = url
          faProjectFolderPicker.grantedURL = url
        }
        result(granted)
      } catch {
        result(false)
      }
    case "stopAccessing":
      guard let encoded = call.arguments as? String else {
        result(nil)
        return
      }
      faProjectFolderBookmarks.removeValue(forKey: encoded)?.stopAccessingSecurityScopedResource()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
