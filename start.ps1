param(
    [ValidateSet('fs', 'admin')]
    [string]$Service
)

$ErrorActionPreference = 'Stop'
$rootDir = $PSScriptRoot
$adminWebDir = Join-Path $rootDir 'zigfs-admin/web'

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Command '$Name' was not found. Install it and try again."
    }
}

function Invoke-InDirectory([string]$Path, [scriptblock]$Action) {
    Push-Location $Path
    try {
        & $Action
    } finally {
        Pop-Location
    }
}

function Start-Fs {
    Require-Command 'zig'
    Write-Host 'Starting local ZigFS...'
    Invoke-InDirectory (Join-Path $rootDir 'zigfs') {
        & zig build run --watch
        if ($LASTEXITCODE -ne 0) { throw "ZigFS exited with code $LASTEXITCODE" }
    }
}

function Start-Admin {
    Require-Command 'go'

    if (Test-Path (Join-Path $adminWebDir 'node_modules')) {
        Require-Command 'pnpm.cmd'
        Write-Host 'Building Admin Web...'
        Invoke-InDirectory $adminWebDir {
            & pnpm.cmd run build
            if ($LASTEXITCODE -ne 0) { throw "Admin Web build exited with code $LASTEXITCODE" }
        }
    } elseif (-not (Test-Path (Join-Path $adminWebDir 'dist/index.html'))) {
        throw 'Admin Web dependencies are missing. Run pnpm install in zigfs-admin/web.'
    }

    $endpoint = if ($env:ZIGFS_ENDPOINT) { $env:ZIGFS_ENDPOINT.TrimEnd('/') } else { 'http://127.0.0.1:9000' }
    $env:ZIGFS_ENDPOINT = $endpoint
    $env:ZIGFS_WEB_ROOT = Join-Path $adminWebDir 'dist'

    Write-Host 'Starting local Admin (ZigFS must be started separately)...'
    Invoke-InDirectory (Join-Path $rootDir 'zigfs-admin/server') {
        & go run ./cmd/admin
        if ($LASTEXITCODE -ne 0) { throw "Admin exited with code $LASTEXITCODE" }
    }
}

if (-not $Service) {
    Write-Host 'Choose an action:'
    Write-Host '  1) Start local ZigFS'
    Write-Host '  2) Start local Admin'
    Write-Host '  0) Exit'
    $choice = Read-Host 'Enter choice [0-2]'
    $Service = switch ($choice) {
        { $_ -in '1', 'fs' } { 'fs'; break }
        { $_ -in '2', 'admin' } { 'admin'; break }
        { $_ -in '0', 'q' } { return }
        default { throw "Invalid choice: $choice" }
    }
}

switch ($Service) {
    'fs' { Start-Fs }
    'admin' { Start-Admin }
}
