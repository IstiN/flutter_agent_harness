# Build a signed MSIX from a Windows Flutter app bundle.
#
# Usage:
#   pwsh scripts/msix/make_msix.ps1 -BuildDir <dir-with-Fa.exe> `
#     -Version 1.2.3.0 -OutMsix fa-app-windows-x64.msix `
#     -CerPath fa-app-windows.cer [-PfxPassword fa-msix]
#
# Produces:
#   -OutMsix : the signed .msix package
#   -CerPath : the self-signed public certificate the user must import
#              (Trusted People) before Add-AppxPackage — the package is
#              NOT Store-signed; this is the sideload artifact.
#
# The manifest is assembled here (no package:msix dependency — the CI
# windows runners already ship the Windows SDK that carries makeappx and
# signtool, and keeping the pack steps in-repo keeps the identity,
# version stamping and signing explicit and reviewable).
param(
  [Parameter(Mandatory = $true)][string] $BuildDir,
  [Parameter(Mandatory = $true)][string] $Version,
  [Parameter(Mandatory = $true)][string] $OutMsix,
  [Parameter(Mandatory = $true)][string] $CerPath,
  [string] $PfxPassword = 'fa-msix',
  [string] $IdentityName = 'dev.fa1.app.Fa',
  [string] $DisplayName = 'Fa'
)

$ErrorActionPreference = 'Stop'

$kitRoot = 'C:\Program Files (x86)\Windows Kits\10\bin'
$makeappx = Get-ChildItem $kitRoot -Recurse -Filter makeappx.exe -ErrorAction SilentlyContinue |
  Where-Object { $_.DirectoryName -like '*\x64' } |
  Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
$signtool = Get-ChildItem $kitRoot -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
  Where-Object { $_.DirectoryName -like '*\x64' } |
  Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
if (-not $makeappx) { throw 'makeappx.exe not found under Windows Kits' }
if (-not $signtool) { throw 'signtool.exe not found under Windows Kits' }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$assetsDir = Join-Path $scriptDir 'assets'

$stage = Join-Path $env:TEMP ('fa-msix-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $stage | Out-Null
try {
  # Bundle content
  Copy-Item (Join-Path $BuildDir '*') $stage -Recurse -Force

  # Logo assets (committed PNGs — see scripts/msix/assets/)
  $logoDir = Join-Path $stage 'assets'
  New-Item -ItemType Directory $logoDir | Out-Null
  foreach ($a in 'Square44x44Logo.png', 'Square150x150Logo.png', 'StoreLogo.png') {
    Copy-Item (Join-Path $assetsDir $a) $logoDir -Force
  }

  $escapedName = [System.Security.SecurityElement]::Escape($DisplayName)
  $manifest = @"
<?xml version="1.0" encoding="utf-8"?>
<Package
  xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"
  xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10"
  xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities">
  <Identity Name="$IdentityName" Version="$Version" ProcessorArchitecture="x64" Publisher="CN=fa1.dev, O=Fa" />
  <Properties>
    <DisplayName>$escapedName</DisplayName>
    <PublisherDisplayName>Fa (fa1.dev)</PublisherDisplayName>
    <Logo>assets\StoreLogo.png</Logo>
  </Properties>
  <Dependencies>
    <TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.17763.0" MaxVersionTested="10.0.26100.0" />
  </Dependencies>
  <Resources>
    <Resource Language="en-us" />
  </Resources>
  <Applications>
    <Application Id="Fa" Executable="Fa.exe" EntryPoint="Windows.FullTrustApplication">
      <uap:VisualElements
        DisplayName="$escapedName"
        Description="Fa — cross-platform AI coding agent (flutter_agent_harness desktop app)"
        BackgroundColor="transparent"
        Square150x150Logo="assets\Square150x150Logo.png"
        Square44x44Logo="assets\Square44x44Logo.png">
      </uap:VisualElements>
    </Application>
  </Applications>
  <Capabilities>
    <rescap:Capability Name="runFullTrust" />
  </Capabilities>
</Package>
"@
  [System.IO.File]::WriteAllText((Join-Path $stage 'AppxManifest.xml'), $manifest)

  # Pack
  & $makeappx pack /o /d $stage /p $OutMsix 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "makeappx failed ($LASTEXITCODE)" }

  # Self-signed cert (per-run) + sign
  $existing = Get-ChildItem 'Cert:\CurrentUser\My' |
    Where-Object { $_.FriendlyName -eq 'Fa MSIX (self-signed)' } |
    Sort-Object NotAfter -Descending | Select-Object -First 1
  $cert = if ($existing) {
    $existing
  } else {
    New-SelfSignedCertificate -Type CodeSigningCert `
      -Subject 'CN=fa1.dev, O=Fa' `
      -KeyUsage DigitalSignature -FriendlyName 'Fa MSIX (self-signed)' `
      -CertStoreLocation 'Cert:\CurrentUser\My' -NotAfter (Get-Date).AddYears(3)
  }
  $pfx = Join-Path $env:TEMP 'fa-msix.pfx'
  $secret = ConvertTo-SecureString -String $PfxPassword -Force -AsPlainText
  Export-PfxCertificate -Cert $cert -FilePath $pfx -Password $secret | Out-Null
  Export-Certificate -Cert $cert -FilePath $CerPath | Out-Null

  & $signtool sign /fd SHA256 /f $pfx /p $PfxPassword $OutMsix 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "signtool failed ($LASTEXITCODE)" }

  "msix written: $OutMsix ($([math]::Round((Get-Item $OutMsix).Length / 1MB, 1)) MB)"
  "cer  written: $CerPath"
} finally {
  Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
  Remove-Item -Force (Join-Path $env:TEMP 'fa-msix.pfx') -ErrorAction SilentlyContinue
}
exit 0
