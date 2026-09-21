$ErrorActionPreference = "Stop"
$required = @(
  ".github\workflows\build-unsigned-ipa.yml",
  "CoreValidation\Package.swift",
  "PinoAutoLogger\Info.plist",
  "PinoAutoLogger\KWPProtocol.swift",
  "PinoAutoLogger.xcodeproj\project.pbxproj"
)
foreach ($p in $required) {
  if (-not (Test-Path $p)) {
    throw "Missing: $p"
  }
}
Write-Host "Repository layout OK"
