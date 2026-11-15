// fa-clip — the Fa CLI's native macOS pasteboard image reader (gh-2040).
//
// gh-2040: the CLI's paste-image probe used to deliver Apple Events
// (`the clipboard as «class PNGf»` driven through the system script
// runner) — an Apple Events delivery gated by TCC
// kTCCServiceSystemPolicyAppData on macOS 15+, which put users in front
// of the recurring «"fa" would like to access data from other apps»
// dialog (and on some machines the Allow grant never persisted). Reading
// NSPasteboard directly delivers no Apple Events, so that consent class
// never fires: no entitlements, no Automation entry, no prompt — on any
// macOS version, signed or not (ad-hoc included).
//
// Usage: fa-clip <png|jpeg|tiff>
//   exit 0  — the requested flavor's bytes on stdout
//   exit 2  — the pasteboard holds no data of the requested flavor
//   exit 1  — the pasteboard could not be read (message on stderr)
//   exit 64 — usage error (message on stderr)
//
// One flavor per invocation: the Dart side (lib/src/cli/clipboard_reader.dart)
// owns the flavor ladder PNG → JPEG → TIFF (+ the sips PNG conversion,
// gh-1575) by probing this helper per flavor and falling through on exit 2.
// The helper resolves beside the fa binary — never from PATH.

import AppKit

// UTI types: AppKit names png/tiff natively; jpeg has no AppKit constant,
// so every flavor uses the raw UTI string (same identifiers the ladder
// probes).
let flavorArgs: [String: NSPasteboard.PasteboardType] = [
  "png": NSPasteboard.PasteboardType("public.png"),
  "jpeg": NSPasteboard.PasteboardType("public.jpeg"),
  "tiff": NSPasteboard.PasteboardType("public.tiff"),
]

let args = CommandLine.arguments
guard args.count == 2, let flavor = flavorArgs[args[1].lowercased()] else {
  FileHandle.standardError.write(Data("usage: fa-clip <png|jpeg|tiff>\n".utf8))
  exit(64)
}

guard let data = NSPasteboard.general.data(forType: flavor) else {
  exit(2)  // flavor absent — the caller's ladder falls through
}
FileHandle.standardOutput.write(data)
exit(0)
