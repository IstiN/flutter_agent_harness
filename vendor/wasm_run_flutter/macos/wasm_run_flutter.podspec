release_tag_name = 'wasm_run-v0.1.0' # generated; do not edit

# We cannot distribute the XCFramework alongside the library directly,
# so we have to fetch the correct version here.
framework_name = 'WasmRun.xcframework'
remote_zip_name = "#{framework_name}.zip"
url = "https://github.com/juancastillo0/wasm_run/releases/download/#{release_tag_name}/#{remote_zip_name}"
local_zip_name = "#{release_tag_name}.zip"
`
cd Frameworks

# gh-2055: the guard must key on the artifact pod install actually consumes —
# the exact archive flutter_app/macos/Podfile force_loads and nm-checks —
# NOT on the downloaded-zip marker. A fresh CI clone never has the marker,
# so the old "if [ ! -f <zip> ]" guard made this block run on EVERY build:
# it removed the WasmRun.xcframework the build-macos.yml "Restore vendored
# WasmRun macOS framework" step had already placed (cache → local copy →
# digest-verified resumable download, gh-1149/gh-1759), re-downloaded the
# 92.7 MB asset with a bare curl, and one transient reset ("curl: (56)
# Recv failure: Connection reset by peer", daily leg run 41778615815) left
# pod install with NO framework — the Podfile nm check then failed on the
# missing libwasm_run_dart.a. With the archive in place this block is now
# a no-op; it stays as the local-dev fallback for a truly cold tree.
# --fail keeps an HTTP error page from masquerading as a zip (the same
# posture the workflow restore step is linted for).
if [ ! -f #{framework_name}/macos-arm64_x86_64/libwasm_run_dart.a ]
then
  rm -rf #{framework_name}
  curl --fail -L #{url} -o #{local_zip_name}
  unzip #{local_zip_name}
  truncate -s 0 #{local_zip_name}
  rm -rf #{framework_name}/ios-*
fi

cd -
`

Pod::Spec.new do |s|
  s.name          = 'wasm_run_flutter'
  s.version       = '0.0.1'
  s.summary       = 'iOS/macOS Flutter bindings for wasm_run'
  s.license       = { :file => '../LICENSE' }
  s.homepage      = 'https://github.com/juancastillo0/wasm_run'
  s.authors       = { 'Juan Manuel Castillo' => '42351046+juancastillo0@users.noreply.github.com' }

  # This pod is HEADER-ONLY on macOS (#1096 AC4): Classes/ keeps just
  # frb.h — EnforceBundling.swift was REMOVED because it is an iOS
  # mechanism (there the app statically links the pod's vendored
  # framework and the dummy keeps dead-code stripping from discarding
  # the wire_* roots). With no vendored framework, the pod target links
  # nothing that defines the flutter_rust_bridge symbols the dummy
  # references, so compiling it fails the pod-target link ("Undefined
  # symbols for architecture arm64 … in EnforceBundling.o"). On macOS
  # the app resolves the wasm_run FFI surface via dlsym on its OWN
  # executable — Runner.xcodeproj force_loads
  # WasmRun.xcframework/macos-arm64_x86_64/libwasm_run_dart.a and
  # exports the _wire_* symbols (CI verifies them per build) — so no
  # EnforceBundling dummy is needed. The embedded dynamic
  # wasm_run_flutter.framework (27 MB unpacked) was a never-loaded
  # fallback; vendoring it here is what put it in Frameworks/. The
  # XCFramework download block above STAYS — the static archive inside
  # it feeds the force_load and the Podfile symbol check.
  s.source              = { :path => '.' }
  s.source_files        = 'Classes/**/*'
  s.public_header_files = 'Classes/**/*.h'

  s.ios.deployment_target = '11.0'
  s.osx.deployment_target = '10.13'
end
