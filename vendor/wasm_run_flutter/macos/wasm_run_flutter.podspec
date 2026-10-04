release_tag_name = 'wasm_run-v0.1.0' # generated; do not edit

# We cannot distribute the XCFramework alongside the library directly,
# so we have to fetch the correct version here.
framework_name = 'WasmRun.xcframework'
remote_zip_name = "#{framework_name}.zip"
url = "https://github.com/juancastillo0/wasm_run/releases/download/#{release_tag_name}/#{remote_zip_name}"
local_zip_name = "#{release_tag_name}.zip"
`
cd Frameworks

if [ ! -f #{local_zip_name} ]
then
  rm -rf #{framework_name}
  curl -L #{url} -o #{local_zip_name}
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

  # This will ensure the source files in Classes/ are included in the native
  # builds of apps using this FFI plugin. Podspec does not support relative
  # paths, so Classes contains a forwarder C file that relatively imports
  # `../src/*` so that the C sources can be shared among all target platforms.
  s.source              = { :path => '.' }
  s.source_files        = 'Classes/**/*'
  s.public_header_files = 'Classes/**/*.h'
  # No s.vendored_frameworks (#1096 AC4): the macOS app resolves the
  # wasm_run FFI surface via dlsym on its OWN executable — Runner.xcodeproj
  # force_loads WasmRun.xcframework/macos-arm64_x86_64/libwasm_run_dart.a
  # and exports the _wire_* symbols (CI verifies them per build). The
  # embedded dynamic wasm_run_flutter.framework (27 MB unpacked) was a
  # never-loaded fallback; vendoring it here is what put it in
  # Frameworks/. The XCFramework download block above STAYS — the static
  # archive inside it feeds the force_load and the Podfile symbol check.

  s.ios.deployment_target = '11.0'
  s.osx.deployment_target = '10.13'
end
