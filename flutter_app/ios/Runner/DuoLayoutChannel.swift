import Flutter
import UIKit

/// UIKit's adaptive-layout signals for the Flutter shell. Device identity is
/// diagnostic; `verticalBarEdge` and reserved regions own layout decisions.
@MainActor
private final class FaDuoLayoutChannel: NSObject {
  private weak var observedController: FlutterViewController?
  private let channel: FlutterMethodChannel

  private var controller: FlutterViewController? {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }?.rootViewController as? FlutterViewController
  }

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "fah/duo_layout", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      switch call.method {
      case "snapshot":
        result(self.snapshot())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(notifySoon), name: UIDevice.orientationDidChangeNotification, object: nil)
    center.addObserver(self, selector: #selector(notifySoon), name: UIApplication.didBecomeActiveNotification, object: nil)
    notifySoon()
  }

  private func installTraitObserverIfNeeded() {
    guard #available(iOS 27.1, *), observedController == nil,
          let controller else { return }
    observedController = controller
    controller.registerForTraitChanges(UITraitCollection.systemTraitsAffectingVerticalBarEdge) {
      [weak self] (_: FlutterViewController, _: UITraitCollection) in
      self?.notifySoon()
    }
  }

  @objc private func notifySoon() {
    // Trait callbacks can precede the view's next layout pass.
    DispatchQueue.main.async { [weak self] in
      self?.installTraitObserverIfNeeded()
      self?.channel.invokeMethod("layoutChanged", arguments: nil)
    }
  }

  private func hardwareModel() -> String {
    if let simulator = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
      return simulator
    }
    var size = 0
    sysctlbyname("hw.machine", nil, &size, nil, 0)
    guard size > 0 else { return "" }
    var machine = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.machine", &machine, &size, nil, 0)
    return String(cString: machine)
  }

  private func snapshot() -> [String: Any] {
    installTraitObserverIfNeeded()
    guard #available(iOS 27.1, *), let view = controller?.view else {
      return [
        "isDuo": false,
        "hardwareModel": hardwareModel(),
        "verticalBarEdge": 0,
        "safeArea": ["left": 0, "top": 0, "right": 0, "bottom": 0],
        "occlusions": [],
        "divisions": [],
      ]
    }
    let model = hardwareModel()
    let edge = controller?.traitCollection.verticalBarEdge ?? .unspecified
    let occlusions = view.reservedRegions(kind: .occlusion, options: [.includeInactive])
    let divisions = view.reservedRegions(kind: .division, options: [.includeInactive])
    // iPhone19,4 is the Xcode 27 Duo simulator/hardware identifier. The
    // vertical-bar trait also recognizes future identifiers; an active fold
    // keeps partially folded poses covered when no vertical bar is preferred.
    let isDuo = model == "iPhone19,4" || model.lowercased().contains("duo") ||
      edge != .unspecified || divisions.contains { $0.isActive }
    let safe = view.safeAreaInsets
    let payload: [String: Any] = [
      "isDuo": isDuo,
      "hardwareModel": model,
      "verticalBarEdge": edge.rawValue,
      "safeArea": ["left": safe.left, "top": safe.top, "right": safe.right, "bottom": safe.bottom],
      "occlusions": occlusions.map(regionPayload),
      "divisions": divisions.map(regionPayload),
    ]
    #if DEBUG
    print("[fah] duo snapshot: \(payload)")
    #endif
    return payload
  }

  @available(iOS 27.1, *)
  private func regionPayload(_ region: UIView.ReservedRegion) -> [String: Any] {
    [
      "left": region.frame.minX,
      "top": region.frame.minY,
      "width": region.frame.width,
      "height": region.frame.height,
      "marginTop": region.margins.top,
      "marginRight": region.margins.right,
      "marginBottom": region.margins.bottom,
      "marginLeft": region.margins.left,
      "active": region.isActive,
    ]
  }
}

private var faDuoLayoutChannel: FaDuoLayoutChannel?

@MainActor
func registerDuoLayoutChannel(messenger: FlutterBinaryMessenger) {
  faDuoLayoutChannel = FaDuoLayoutChannel(messenger: messenger)
}
