param(
    [Parameter(Mandatory=$true)]
    [string]$RepoPath
)

$ErrorActionPreference = "Stop"
$SourceRoot = Split-Path -Parent $PSScriptRoot

if (-not (Test-Path (Join-Path $RepoPath ".git"))) {
    throw "指定先はGitリポジトリではありません: $RepoPath"
}

$items = @(
    "PinoAutoLogger\ELMBluetooth.swift",
    "PinoAutoLogger\Info.plist",
    "PinoAutoLogger\ContentView.swift",
    "PinoAutoLogger.xcodeproj\project.pbxproj",
    ".github\workflows\build-unsigned-ipa.yml"
)

foreach ($item in $items) {
    $src = Join-Path $SourceRoot $item
    $dst = Join-Path $RepoPath $item
    $dstDir = Split-Path -Parent $dst
    New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
    Copy-Item $src $dst -Force
}

Write-Host "v3.4 crash fix applied."
Write-Host "Next: GitHub Desktop -> Commit to main -> Push origin"
