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
    ".github",
    "CoreValidation",
    "PinoAutoLogger",
    "PinoAutoLogger.xcodeproj",
    "README_JA.md",
    "INSTALL_JA.md",
    "SOURCES.md",
    "TEST_REPORT.md",
    "scripts"
)

foreach ($item in $items) {
    $src = Join-Path $SourceRoot $item
    $dst = Join-Path $RepoPath $item
    if (Test-Path $dst) {
        Remove-Item $dst -Recurse -Force
    }
    Copy-Item $src $dst -Recurse -Force
}

Write-Host "HC24S v3 files copied to: $RepoPath"
Write-Host "Next: GitHub Desktop -> Commit to main -> Push origin"
