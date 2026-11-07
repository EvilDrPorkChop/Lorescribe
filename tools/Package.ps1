# Builds dist\Lorescribe-<version>.zip containing a Lorescribe folder to drop
# straight into Interface\AddOns.
#   powershell -ExecutionPolicy Bypass -File tools\Package.ps1
#
# The zip is made from the last commit (git archive), so uncommitted changes are
# never included. .gitattributes lists what's left out.
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot
Set-Location $root

$version = (Select-String -Path "Lorescribe.toc" -Pattern '^## Version:\s*(\S+)').Matches[0].Groups[1].Value
$coreVersion = (Select-String -Path "Core.lua" -Pattern '^ns\.VERSION = "([^"]+)"').Matches[0].Groups[1].Value
if ($version -ne $coreVersion) { throw "Version mismatch: Lorescribe.toc says $version, Core.lua says $coreVersion." }

if (git status --porcelain) {
    Write-Warning "You have uncommitted changes. They won't be in the zip; commit first if you want them."
}

New-Item -ItemType Directory -Force "dist" | Out-Null
$zip = Join-Path $root "dist\Lorescribe-$version.zip"
git archive --format=zip --prefix=Lorescribe/ -o $zip HEAD
if ($LASTEXITCODE -ne 0) { throw "git archive failed." }

$size = [math]::Round((Get-Item $zip).Length / 1KB)
Write-Host "Built $zip ($size KB) from commit $(git rev-parse --short HEAD)." -ForegroundColor Green
