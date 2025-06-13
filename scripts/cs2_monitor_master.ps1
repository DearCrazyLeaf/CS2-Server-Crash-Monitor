param (
    [Parameter(Mandatory=$true)]
    [string]$CS2Path
)

# Basic setup
$ErrorActionPreference = "Stop"
$Host.UI.RawUI.WindowTitle = "CS2 Server Monitor"

# Normalize path
$CS2Path = $CS2Path.Replace('/', '\')
$CS2Path = [System.IO.Path]::GetFullPath($CS2Path)

# Global variables
$script:MonitoringActive = $true
$script:CrashLogPath = Join-Path (Split-Path $CS2Path -Parent) "crash_logs"
$script:LastCheckTime = Get-Date

function Write-Status {
    param([string]$Message, [string]$Color = "White")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] $Message" -ForegroundColor $Color
}

# Ensure valid paths
function Test-ValidPath {
    param([string]$Path)
    try {
        $null = [System.IO.Path]::GetFullPath($Path)
        return $true
    } catch {
        return $false
    }
}

# Initialize monitoring
function Initialize-Monitoring {
    if (-not (Test-ValidPath $CS2Path)) {
        throw "Invalid characters in server path: $CS2Path"
    }
    
    if (-not (Test-Path $CS2Path)) {
        throw "Server path not found: $CS2Path"
    }

    # Create crash logs directory
    try {
        if (-not (Test-Path $script:CrashLogPath)) {
            New-Item -ItemType Directory -Path $script:CrashLogPath -Force | Out-Null
        }
        Write-Status "Crash logs will be saved to: $script:CrashLogPath" "Cyan"
    } catch {
        throw "Failed to create crash logs directory: $_"
    }
}

try {
    Clear-Host
    
    # Display header
    Write-Status "================================" "Cyan"
    Write-Status "    CS2 Server Monitor System    " "Cyan"
    Write-Status "      By: DearCrazyLeaf         " "Cyan"
    Write-Status "================================" "Cyan"
    Write-Status ""
    
    # Initialize with path validation
    Write-Status "Server Path: $CS2Path" "Yellow"
    Write-Status "Initializing..." "Green"
    Initialize-Monitoring
    
    # Monitor system started
    Write-Status "Monitor system started" "Green"
    Write-Status "Press Ctrl+C to exit" "Yellow"
    
    # Keep script running
    while ($true) {
        Start-Sleep -Seconds 1
    }
}
catch {
    Write-Status "Error: $_" "Red"
    Write-Status "Press any key to continue..." "Yellow"
    [System.Console]::ReadKey($true) | Out-Null
}