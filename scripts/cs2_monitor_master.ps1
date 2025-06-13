param (
    [Parameter(Mandatory=$true)]
    [string]$CS2Path,
    
    [Parameter(Mandatory=$false)]
    [string]$AnimationDllPath = ""
)

# Basic setup
$ErrorActionPreference = "Stop"
$Host.UI.RawUI.WindowTitle = "CS2 Server Monitor"

# Normalize paths
$CS2Path = $CS2Path.Replace('/', '\')
$CS2Path = [System.IO.Path]::GetFullPath($CS2Path)

if ($AnimationDllPath) {
    $AnimationDllPath = $AnimationDllPath.Replace('/', '\')
    $AnimationDllPath = [System.IO.Path]::GetFullPath($AnimationDllPath)
}

# Global variables
$script:MonitoringActive = $true
$script:CrashLogPath = Join-Path (Split-Path $CS2Path -Parent) "crash_logs"
$script:LastCheckTime = Get-Date
$script:LastDllHash = $null
$script:DllMonitoringEnabled = $AnimationDllPath -and (Test-Path $AnimationDllPath)
$script:ProcessStartTime = $null
$script:LastMemoryUsage = 0
$script:LastCPUTime = $null
$script:LastCheckpoint = Get-Date

function Write-Status {
    param([string]$Message, [string]$Color = "White")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] $Message" -ForegroundColor $Color
}

# Get file hash and metadata
function Get-FileHashAndMetadata {
    param([string]$FilePath)
    try {
        $fileInfo = Get-Item $FilePath
        $hash = Get-FileHash $FilePath -Algorithm SHA256
        return @{
            Hash = $hash.Hash
            Size = $fileInfo.Length
            LastWrite = $fileInfo.LastWriteTime
            Version = $fileInfo.VersionInfo.FileVersion
        }
    } catch {
        return $null
    }
}

# Get process performance metrics
function Get-ProcessMetrics {
    param([System.Diagnostics.Process]$Process)
    
    if (-not $Process) { return $null }
    
    $cpuTime = $Process.TotalProcessorTime
    $workingSet = $Process.WorkingSet64
    $elapsed = (Get-Date) - $script:LastCheckpoint
    
    $cpuUsage = if ($script:LastCPUTime) {
        $cpuDiff = ($cpuTime - $script:LastCPUTime).TotalSeconds
        [math]::Round(($cpuDiff / $elapsed.TotalSeconds) * 100, 2)
    } else { 0 }
    
    $memoryDiff = if ($script:LastMemoryUsage -gt 0) {
        [math]::Round(($workingSet - $script:LastMemoryUsage) / 1MB, 2)
    } else { 0 }
    
    $script:LastCPUTime = $cpuTime
    $script:LastMemoryUsage = $workingSet
    $script:LastCheckpoint = Get-Date
    
    return @{
        CPU = $cpuUsage
        MemoryMB = [math]::Round($workingSet / 1MB, 2)
        MemoryDiffMB = $memoryDiff
        ThreadCount = $Process.Threads.Count
        HandleCount = $Process.HandleCount
    }
}

# Monitor DLL status
function Test-DllStatus {
    if (-not $script:DllMonitoringEnabled) { return $true }
    
    $currentInfo = Get-FileHashAndMetadata $AnimationDllPath
    if (-not $currentInfo) { return $false }
    
    $changed = $false
    if ($script:LastDllHash) {
        $changed = $currentInfo.Hash -ne $script:LastDllHash.Hash -or
                  $currentInfo.Size -ne $script:LastDllHash.Size
    }
    
    $script:LastDllHash = $currentInfo
    return -not $changed
}

# Save crash report
function Save-CrashReport {
    param(
        [string]$ProcessName = "cs2",
        [string]$CrashReason,
        [System.Diagnostics.Process]$LastProcess = $null,
        [hashtable]$LastMetrics = $null
    )
    
    $crashTime = Get-Date -Format "yyyyMMdd_HHmmss"
    $crashLogFile = Join-Path $script:CrashLogPath "crash_$crashTime.txt"
    
    # System information
    $systemInfo = @{
        "Crash Time" = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "Process Start Time" = $script:ProcessStartTime
        "Process Runtime" = if($script:ProcessStartTime) {
            (Get-Date) - $script:ProcessStartTime
        } else { "Unknown" }
        "System Memory" = Get-WmiObject Win32_OperatingSystem | 
            Select-Object @{N='TotalGB';E={[math]::Round($_.TotalVisibleMemorySize/1MB,2)}},
                         @{N='FreeGB';E={[math]::Round($_.FreePhysicalMemory/1MB,2)}}
        "CPU Usage" = (Get-WmiObject Win32_Processor).LoadPercentage
    }

    # Process metrics
    if ($LastMetrics) {
        $systemInfo["Process Metrics"] = $LastMetrics
    }
    
    # Animation DLL status
    if ($script:DllMonitoringEnabled -and $script:LastDllHash) {
        $systemInfo["Animation DLL"] = @{
            "Hash" = $script:LastDllHash.Hash
            "Size" = [math]::Round($script:LastDllHash.Size / 1KB, 2)
            "Last Modified" = $script:LastDllHash.LastWrite
            "Version" = $script:LastDllHash.Version
        }
    }
    
    # Recent errors
    $recentErrors = Get-EventLog -LogName Application -EntryType Error -Newest 20 | 
        Where-Object { $_.TimeGenerated -gt $script:LastCheckTime } |
        Select-Object TimeGenerated, Source, Message
    
    # Generate report
    @"
============================
CS2 Server Crash Report
============================
Crash Time: $($systemInfo["Crash Time"])
Crash Reason: $CrashReason

Process Information:
------------------
Start Time: $($systemInfo["Process Start Time"])
Runtime: $($systemInfo["Process Runtime"])
Last Known Metrics: $($systemInfo["Process Metrics"] | ConvertTo-Json)

Animation DLL Status:
------------------
$($systemInfo["Animation DLL"] | ConvertTo-Json -Depth 10)

System Information:
------------------
Total Memory: $($systemInfo["System Memory"].TotalGB) GB
Free Memory: $($systemInfo["System Memory"].FreeGB) GB
CPU Usage: $($systemInfo["CPU Usage"])%

Performance History:
------------------
Last CPU Usage: $($LastMetrics.CPU)%
Memory Usage: $($LastMetrics.MemoryMB) MB
Memory Change: $($LastMetrics.MemoryDiffMB) MB
Thread Count: $($LastMetrics.ThreadCount)
Handle Count: $($LastMetrics.HandleCount)

Recent Application Errors:
------------------------
$($recentErrors | ForEach-Object { "$($_.TimeGenerated) - $($_.Source)`n$($_.Message)`n" })

Server Information:
-----------------
Server Path: $CS2Path
Animation DLL Path: $AnimationDllPath
DLL Monitoring: $($script:DllMonitoringEnabled)
"@ | Out-File -FilePath $crashLogFile -Encoding UTF8
    
    Write-Status "Crash report saved to: $crashLogFile" "Yellow"
    return $crashLogFile
}

# Initialize monitoring
function Initialize-Monitoring {
    # Create crash logs directory
    try {
        if (-not (Test-Path $script:CrashLogPath)) {
            New-Item -ItemType Directory -Path $script:CrashLogPath -Force | Out-Null
        }
        Write-Status "Crash logs will be saved to: $script:CrashLogPath" "Cyan"
    } catch {
        throw "Failed to create crash logs directory: $_"
    }

    # Initialize DLL monitoring
    if ($script:DllMonitoringEnabled) {
        $script:LastDllHash = Get-FileHashAndMetadata $AnimationDllPath
        Write-Status "Animation DLL monitoring enabled" "Green"
        Write-Status "Initial DLL Hash: $($script:LastDllHash.Hash)" "Cyan"
    } else {
        Write-Status "Animation DLL monitoring disabled - DLL not found" "Yellow"
    }
}

# Monitor server process
function Monitor-ServerProcess {
    $processName = "cs2"
    $wasRunning = $false
    $lastProcess = $null
    $lastMetrics = $null
    
    while ($script:MonitoringActive) {
        $process = Get-Process $processName -ErrorAction SilentlyContinue
        
        if ($process) {
            if (-not $wasRunning) {
                $script:ProcessStartTime = $process.StartTime
                Write-Status "Server process detected - PID: $($process.Id)" "Green"
                $wasRunning = $true
            }
            
            # Get current metrics
            $currentMetrics = Get-ProcessMetrics $process
            
            # Monitor process health
            if ($currentMetrics.MemoryMB -gt 8192) { # 8GB warning threshold
                Write-Status "Warning: High memory usage - $($currentMetrics.MemoryMB) MB" "Yellow"
            }
            if ($currentMetrics.CPU -gt 90) { # 90% CPU warning threshold
                Write-Status "Warning: High CPU usage - $($currentMetrics.CPU)%" "Yellow"
            }
            
            # Check animation DLL status
            if (-not (Test-DllStatus)) {
                Write-Status "Animation DLL changed or corrupted!" "Red"
                $crashReport = Save-CrashReport -ProcessName $processName `
                    -CrashReason "Animation DLL modified" `
                    -LastProcess $process `
                    -LastMetrics $currentMetrics
                Write-Status "Detailed crash report saved: $crashReport" "Yellow"
            }
            
            # Store metrics for crash report
            $lastMetrics = $currentMetrics
            $lastProcess = $process
        }
        else {
            if ($wasRunning) {
                Write-Status "Server process stopped or crashed!" "Red"
                $crashReport = Save-CrashReport -ProcessName $processName `
                    -CrashReason "Process terminated" `
                    -LastProcess $lastProcess `
                    -LastMetrics $lastMetrics
                Write-Status "Detailed crash report saved: $crashReport" "Yellow"
                $wasRunning = $false
                $script:ProcessStartTime = $null
            }
        }
        
        Start-Sleep -Seconds 2
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
    
    # Initialize monitoring
    Write-Status "Server Path: $CS2Path" "Yellow"
    Write-Status "Animation DLL Path: $AnimationDllPath" "Yellow"
    Write-Status "Initializing..." "Green"
    Initialize-Monitoring
    
    # Start monitoring
    Write-Status "Monitor system started" "Green"
    Write-Status "Press Ctrl+C to exit" "Yellow"
    
    # Begin monitoring loop
    Monitor-ServerProcess
}
catch {
    Write-Status "Error: $_" "Red"
    Write-Status "Stack Trace:" "Red"
    Write-Status $_.ScriptStackTrace "Red"
    Write-Status "Press any key to continue..." "Yellow"
    [System.Console]::ReadKey($true) | Out-Null
}