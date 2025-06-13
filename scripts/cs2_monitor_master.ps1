<#
.SYNOPSIS
    CS2 Server Monitor and Auto-Recovery Tool
.DESCRIPTION
    Advanced monitoring and auto-recovery tool for CS2 servers
    - Monitors process health and performance
    - Detects and resolves thread blocks safely
    - Provides real-time performance metrics
    - Logs all activities for analysis
.AUTHOR
    DearCrazyLeaf
.VERSION
    2.2.1
.DATE
    2025-06-13
#>

param (
    [Parameter(Mandatory=$true)]
    [string]$CS2Path,
    
    [Parameter(Mandatory=$false)]
    [string]$AnimationDllPath = ""
)

# Setup error handling and encoding
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::TreatControlCAsInput = $false

# Add native methods
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class Win32
{
    [DllImport("kernel32.dll")]
    public static extern bool DebugBreakProcess(IntPtr Process);
    
    [DllImport("ntdll.dll")]
    public static extern uint NtAlertThread(IntPtr ThreadHandle);
    
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool IsDebuggerPresent();
    
    [DllImport("psapi.dll")]
    public static extern bool EmptyWorkingSet(IntPtr Process);
    
    [DllImport("kernel32.dll")]
    public static extern bool SetThreadPriority(IntPtr hThread, int nPriority);
    
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenThread(int dwDesiredAccess, bool bInheritHandle, int dwThreadId);
    
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);
    
    public static IntPtr GetSafeHandle(object handle)
    {
        try {
            return handle == null ? IntPtr.Zero : new IntPtr(Convert.ToInt64(handle));
        }
        catch {
            return IntPtr.Zero;
        }
    }
}
"@

# Normalize paths
$CS2Path = $CS2Path.Replace('/', '\')
$CS2Path = [System.IO.Path]::GetFullPath($CS2Path)

if ($AnimationDllPath) {
    $AnimationDllPath = $AnimationDllPath.Replace('/', '\')
    $AnimationDllPath = [System.IO.Path]::GetFullPath($AnimationDllPath)
}

# Global configuration
$script:Config = @{
    ThreadMonitoring = @{
        WarnThreshold = 30              # Warning threshold in seconds
        ActionThreshold = 120           # Action threshold in seconds
        CriticalThreshold = 1800        # Critical threshold (30 minutes)
        MaxRecoveryAttempts = 3         # Maximum recovery attempts per thread
        MonitorInterval = 5             # Thread monitoring interval in seconds
        SafetyCheckInterval = 60        # Interval for checking process stability
        MaxThreadRecoveryPerCycle = 2   # Maximum threads to recover in one cycle
    }
    Performance = @{
        MaxMemoryMB = 8192             # Maximum memory threshold in MB
        MaxCPUPercent = 90             # Maximum CPU usage percentage
        ActionCooldown = 300           # Action cooldown in seconds
        MemoryTrimInterval = 1800      # Memory trim interval in seconds
        MetricsLogInterval = 30        # Performance metrics logging interval
    }
    Recovery = @{
        SafeMode = $true               # Enable safe mode
        EnableThreadTermination = $false # Disable thread termination
        MaxDailyRecoveries = 10        # Maximum recovery attempts per day
        RecoveryTimeout = 30           # Timeout for recovery actions in seconds
    }
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
$script:ThreadStates = @{}
$script:LastThreadAction = $null
$script:DailyRecoveryCount = 0
$script:LastRecoveryReset = Get-Date
$script:ProcessStabilityMetrics = @{
    LastStableTime = Get-Date
    RecoveryHistory = @()
    SuccessfulRecoveries = 0
    FailedRecoveries = 0
}

function Write-Status {
    param(
        [string]$Message,
        [string]$Level = "INFO",
        [string]$Color = "White",
        [hashtable]$Data = $null
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    Write-Host $logMessage -ForegroundColor $Color
    
    if ($Data) {
        $logEntry = @{
            Timestamp = $timestamp
            Level = $Level
            Message = $Message
            Data = $Data
        } | ConvertTo-Json -Depth 10
        
        try {
            Add-Content -Path (Join-Path $script:CrashLogPath "detailed_log.json") -Value $logEntry -ErrorAction SilentlyContinue
        }
        catch {}
    }
}

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

function Test-DllStatus {
    if (-not $script:DllMonitoringEnabled) { return $true }
    
    try {
        $currentInfo = Get-FileHashAndMetadata $AnimationDllPath
        if (-not $currentInfo) { 
            Write-Status "Failed to get DLL information" "ERROR" "Red" @{
                Path = $AnimationDllPath
                Time = Get-Date
            }
            return $false 
        }
        
        $changed = $false
        if ($script:LastDllHash) {
            $changed = $currentInfo.Hash -ne $script:LastDllHash.Hash -or
                      $currentInfo.Size -ne $script:LastDllHash.Size
            
            if ($changed) {
                Write-Status "DLL change detected" "WARNING" "Yellow" @{
                    OldHash = $script:LastDllHash.Hash
                    NewHash = $currentInfo.Hash
                    OldSize = $script:LastDllHash.Size
                    NewSize = $currentInfo.Size
                    Time = Get-Date
                }
            }
        }
        
        $script:LastDllHash = $currentInfo
        return -not $changed
    }
    catch {
        Write-Status "Error checking DLL status: $_" "ERROR" "Red"
        return $false
    }
}

function Get-ProcessMetrics {
    param(
        [System.Diagnostics.Process]$Process,
        [switch]$Silent = $false
    )
    
    if (-not $Process) { return $null }
    
    try {
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
        
        $metrics = @{
            CPU = $cpuUsage
            MemoryMB = [math]::Round($workingSet / 1MB, 2)
            MemoryDiffMB = $memoryDiff
            ThreadCount = $Process.Threads.Count
            HandleCount = $Process.HandleCount
            DelayedThreads = ($Process.Threads | Where-Object { $_.WaitReason -eq "ExecutionDelay" }).Count
            PagedMemoryMB = [math]::Round($Process.PagedMemorySize64 / 1MB, 2)
            PrivateMemoryMB = [math]::Round($Process.PrivateMemorySize64 / 1MB, 2)
        }
        
        if (-not $Silent) {
            Write-Status "Performance metrics updated" "DEBUG" "Gray" $metrics
        }
        
        return $metrics
    }
    catch {
        Write-Status "Error getting process metrics: $_" "ERROR" "Red"
        return $null
    }
}

function Update-ThreadMonitoring {
    param([System.Diagnostics.Process]$Process)
    
    $currentTime = Get-Date
    $activeThreads = @{}
    $problemThreads = @()
    
    try {
        $Process.Threads | Where-Object { $_.WaitReason -eq "ExecutionDelay" } | ForEach-Object {
            $threadId = $_.Id
            
            if (-not $script:ThreadStates.ContainsKey($threadId)) {
                $script:ThreadStates[$threadId] = @{
                    FirstSeen = $currentTime
                    DelayCount = 1
                    LastSeen = $currentTime
                    RecoveryAttempts = 0
                    State = "Monitoring"
                    ThreadDetails = @{
                        Priority = $_.PriorityLevel
                        State = $_.ThreadState
                        WaitReason = $_.WaitReason
                        StartTime = $_.StartTime
                        TotalProcessorTime = $_.TotalProcessorTime
                    }
                }
                
                Write-Status "New delayed thread detected: $threadId" "THREAD" "Yellow" $script:ThreadStates[$threadId]
            }
            else {
                $threadInfo = $script:ThreadStates[$threadId]
                $threadInfo.DelayCount++
                $threadInfo.LastSeen = $currentTime
                
                $duration = ($currentTime - $threadInfo.FirstSeen).TotalSeconds
                if ($duration -gt $script:Config.ThreadMonitoring.WarnThreshold) {
                    $problemThreads += @{
                        ThreadId = $threadId
                        Duration = $duration
                        DelayCount = $threadInfo.DelayCount
                        RecoveryAttempts = $threadInfo.RecoveryAttempts
                    }
                }
            }
            
            $activeThreads[$threadId] = $true
        }
        
        $threadsToRemove = @()
        foreach ($threadId in $script:ThreadStates.Keys) {
            if (-not $activeThreads[$threadId]) {
                $threadInfo = $script:ThreadStates[$threadId]
                $timeSinceLastSeen = ($currentTime - $threadInfo.LastSeen).TotalSeconds
                
                if ($timeSinceLastSeen -gt $script:Config.ThreadMonitoring.MonitorInterval * 2) {
                    $threadsToRemove += $threadId
                    Write-Status "Thread $threadId no longer delayed" "THREAD" "Green" @{
                        ThreadId = $threadId
                        FinalState = $threadInfo
                    }
                }
            }
        }
        
        foreach ($threadId in $threadsToRemove) {
            $script:ThreadStates.Remove($threadId)
        }
        
        return $problemThreads
    }
    catch {
        Write-Status "Error in thread monitoring: $_" "ERROR" "Red"
        return @()
    }
}

function Test-ProcessStability {
    param(
        [System.Diagnostics.Process]$Process,
        [hashtable]$CurrentMetrics
    )
    
    try {
        $currentTime = Get-Date
        $isStable = $true
        $reasons = @()
        
        if ($CurrentMetrics.MemoryMB -gt $script:Config.Performance.MaxMemoryMB) {
            $isStable = $false
            $reasons += "High memory usage: $($CurrentMetrics.MemoryMB)MB"
        }
        
        if ($CurrentMetrics.CPU -gt $script:Config.Performance.MaxCPUPercent) {
            $isStable = $false
            $reasons += "High CPU usage: $($CurrentMetrics.CPU)%"
        }
        
        if ($CurrentMetrics.DelayedThreads -gt 5) {
            $isStable = $false
            $reasons += "High number of delayed threads: $($CurrentMetrics.DelayedThreads)"
        }
        
        if ($isStable) {
            $script:ProcessStabilityMetrics.LastStableTime = $currentTime
        }
        elseif ($reasons.Count -gt 0) {
            Write-Status "Process stability issues detected" "WARNING" "Yellow" @{
                Reasons = $reasons
                Metrics = $CurrentMetrics
            }
        }
        
        return $isStable
    }
    catch {
        Write-Status "Error checking process stability: $_" "ERROR" "Red"
        return $true
    }
}

function Save-CrashReport {
    param(
        [string]$ProcessName = "cs2",
        [string]$CrashReason,
        [System.Diagnostics.Process]$LastProcess = $null,
        [hashtable]$LastMetrics = $null
    )
    
    $crashTime = Get-Date -Format "yyyyMMdd_HHmmss"
    $crashLogFile = Join-Path $script:CrashLogPath "crash_$crashTime.txt"
    
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
Last Known Metrics: $($LastMetrics | ConvertTo-Json)

Thread Status:
------------------
$($script:ThreadStates | ConvertTo-Json -Depth 5)

System Information:
------------------
Total Memory: $($systemInfo["System Memory"].TotalGB) GB
Free Memory: $($systemInfo["System Memory"].FreeGB) GB
CPU Usage: $($systemInfo["CPU Usage"])%

Server Information:
------------------
Server Path: $CS2Path
Animation DLL Path: $AnimationDllPath
DLL Monitoring: $($script:DllMonitoringEnabled)

Recovery History:
------------------
Total Recovery Attempts: $($script:ProcessStabilityMetrics.SuccessfulRecoveries + $script:ProcessStabilityMetrics.FailedRecoveries)
Successful Recoveries: $($script:ProcessStabilityMetrics.SuccessfulRecoveries)
Failed Recoveries: $($script:ProcessStabilityMetrics.FailedRecoveries)
Last Stable Time: $($script:ProcessStabilityMetrics.LastStableTime)
"@ | Out-File -FilePath $crashLogFile -Encoding UTF8
    
    Write-Status "Crash report saved to: $crashLogFile" "INFO" "Yellow"
    return $crashLogFile
}

function Clear-ThreadBlock {
    param(
        [System.Diagnostics.Process]$Process,
        [int]$ThreadId,
        [string]$BlockReason
    )
    
    try {
        Write-Status "Attempting to clear block on thread $ThreadId" "ACTION" "Yellow" @{
            ThreadId = $ThreadId
            Reason = $BlockReason
            CurrentState = $script:ThreadStates[$ThreadId]
        }
        
        $thread = $Process.Threads | Where-Object { $_.Id -eq $ThreadId }
        if (-not $thread) { return $false }
        
        if (-not (Test-ProcessStability -Process $Process -CurrentMetrics (Get-ProcessMetrics $Process -Silent))) {
            Write-Status "Skipping thread recovery - process unstable" "WARNING" "Yellow"
            return $false
        }
        
        switch ($BlockReason) {
            "EventPool" {
                if ($thread.ThreadState -eq "Wait") {
                    try {
                        $threadHandle = [Win32]::GetSafeHandle($thread.Handle)
                        if ($threadHandle -ne [IntPtr]::Zero) {
                            [void][Win32]::NtAlertThread($threadHandle)
                            Start-Sleep -Milliseconds 500
                            
                            $thread.Refresh()
                            if ($thread.ThreadState -ne "Wait") {
                                Write-Status "Successfully recovered thread $ThreadId" "SUCCESS" "Green"
                                $script:ProcessStabilityMetrics.SuccessfulRecoveries++
                                return $true
                            }
                            
                            try {
                                [Win32]::SetThreadPriority($threadHandle, 2)
                                Start-Sleep -Milliseconds 500
                                [Win32]::SetThreadPriority($threadHandle, 0)
                            }
                            catch {
                                Write-Status "Failed to adjust thread priority: $_" "WARNING" "Yellow"
                            }
                        }
                    }
                    catch {
                        Write-Status "Failed to recover thread: $_" "ERROR" "Red"
                        $script:ProcessStabilityMetrics.FailedRecoveries++
                    }
                }
            }
            "MemoryPressure" {
                try {
                    [void][Win32]::EmptyWorkingSet($Process.Handle)
                    [System.GC]::Collect()
                    Write-Status "Performed memory optimization" "ACTION" "Cyan"
                    return $true
                }
                catch {
                    Write-Status "Failed to optimize memory: $_" "ERROR" "Red"
                }
            }
        }
    }
    catch {
        Write-Status "Error in thread recovery: $_" "ERROR" "Red"
        $script:ProcessStabilityMetrics.FailedRecoveries++
    }
    
    return $false
}

function Monitor-ServerProcess {
    $processName = "cs2"
    $wasRunning = $false
    $lastProcess = $null
    $lastMetrics = $null
    $lastThreadCheck = Get-Date
    $lastMetricsLog = Get-Date
    $lastStabilityCheck = Get-Date
    $lastMemoryTrim = Get-Date
    
    Write-Status "Starting server process monitoring..." "INFO" "Cyan"
    
    while ($script:MonitoringActive) {
        try {
            $process = Get-Process $processName -ErrorAction SilentlyContinue
            
            if ($process) {
                if (-not $wasRunning) {
                    $script:ProcessStartTime = $process.StartTime
                    Write-Status "Server process detected - PID: $($process.Id)" "INFO" "Green"
                    $wasRunning = $true
                }
                
                $currentTime = Get-Date
                
                $currentMetrics = Get-ProcessMetrics $process -Silent

                if (($currentTime - $lastMetricsLog).TotalSeconds -ge $script:Config.Performance.MetricsLogInterval) {
                    $currentMetrics = Get-ProcessMetrics $process
                    $lastMetricsLog = $currentTime
                }

                if (($currentTime - $lastThreadCheck).TotalSeconds -ge $script:Config.ThreadMonitoring.MonitorInterval) {
                    $problemThreads = Update-ThreadMonitoring -Process $process
                    $recoveredCount = 0
                    
                    foreach ($thread in $problemThreads) {
                        Write-Status "Problem thread $($thread.ThreadId): $($thread.DelayCount) delays, $([Math]::Round($thread.Duration))s duration" "WARNING" "Yellow"
                        
                        if ($recoveredCount -ge $script:Config.ThreadMonitoring.MaxThreadRecoveryPerCycle) {
                            Write-Status "Maximum thread recovery limit reached for this cycle" "WARNING" "Yellow"
                            break
                        }
                        
                        if ($thread.Duration -gt $script:Config.ThreadMonitoring.ActionThreshold -and 
                            $thread.RecoveryAttempts -lt $script:Config.ThreadMonitoring.MaxRecoveryAttempts) {
                            
                            if ((-not $script:LastThreadAction) -or 
                                ($currentTime - $script:LastThreadAction).TotalSeconds -gt $script:Config.Performance.ActionCooldown) {
                                
                                if (Clear-ThreadBlock -Process $process -ThreadId $thread.ThreadId -BlockReason "EventPool") {
                                    $script:ThreadStates[$thread.ThreadId].RecoveryAttempts++
                                    $script:LastThreadAction = $currentTime
                                    $recoveredCount++
                                }
                            }
                        }
                    }
                    
                    $lastThreadCheck = $currentTime
                }

                if (($currentTime - $lastMemoryTrim).TotalSeconds -ge $script:Config.Performance.MemoryTrimInterval) {
                    if ($currentMetrics.MemoryMB -gt ($script:Config.Performance.MaxMemoryMB * 0.8)) {
                        Clear-ThreadBlock -Process $process -ThreadId 0 -BlockReason "MemoryPressure"
                        $lastMemoryTrim = $currentTime
                    }
                }

                if (($currentTime - $lastStabilityCheck).TotalSeconds -ge $script:Config.ThreadMonitoring.SafetyCheckInterval) {
                    Test-ProcessStability -Process $process -CurrentMetrics $currentMetrics
                    $lastStabilityCheck = $currentTime
                }

                $Host.UI.RawUI.WindowTitle = "CS2 Monitor - PID: $($process.Id) | " + 
                                           "RAM: $($currentMetrics.MemoryMB)MB | " + 
                                           "CPU: $($currentMetrics.CPU)% | " + 
                                           "Threads: $($currentMetrics.DelayedThreads)"

                if (-not (Test-DllStatus)) {
                    Write-Status "Animation DLL changed or corrupted!" "WARNING" "Red"
                }
                
                $lastMetrics = $currentMetrics
                $lastProcess = $process
            }
            else {
                if ($wasRunning) {
                    Write-Status "Server process stopped!" "ERROR" "Red"
                    $crashReport = Save-CrashReport -ProcessName $processName `
                        -CrashReason "Process terminated" `
                        -LastProcess $lastProcess `
                        -LastMetrics $lastMetrics
                    $wasRunning = $false
                    $script:ProcessStartTime = $null
                    $script:ThreadStates.Clear()
                }
                
                $Host.UI.RawUI.WindowTitle = "CS2 Monitor - Waiting for server..."
            }
        }
        catch {
            Write-Status "Error in monitoring loop: $_" "ERROR" "Red"
        }
        
        Start-Sleep -Seconds 1
    }
}

try {
    Clear-Host
    $Host.UI.RawUI.WindowTitle = "CS2 Server Monitor v2.2.1"
    
    Write-Status "================================" "INFO" "Cyan"
    Write-Status "    CS2 Server Monitor v2.2.1    " "INFO" "Cyan"
    Write-Status "      By: DearCrazyLeaf          " "INFO" "Cyan"
    Write-Status "================================" "INFO" "Cyan"
    Write-Status ""
    
    Write-Status "Server Path: $CS2Path" "INFO" "Yellow"
    Write-Status "Animation DLL Path: $AnimationDllPath" "INFO" "Yellow"
    Write-Status "Safe Mode: $($script:Config.Recovery.SafeMode)" "INFO" "Yellow"
    Write-Status "Initializing..." "INFO" "Green"
    
    if (-not (Test-Path $script:CrashLogPath)) {
        New-Item -ItemType Directory -Path $script:CrashLogPath -Force | Out-Null
        Write-Status "Created crash logs directory: $script:CrashLogPath" "INFO" "Green"
    }
    
    if ($script:DllMonitoringEnabled) {
        $script:LastDllHash = Get-FileHashAndMetadata $AnimationDllPath
        Write-Status "Animation DLL monitoring enabled" "INFO" "Green"
        Write-Status "Initial DLL Hash: $($script:LastDllHash.Hash)" "DEBUG" "Gray"
    }
    
    Write-Status "Monitor started - Press Ctrl+C to exit" "INFO" "Yellow"
    Monitor-ServerProcess
}
catch {
    Write-Status "Fatal error in monitor: $_" "ERROR" "Red"
    
    try {
        $errorFile = Join-Path $script:CrashLogPath "monitor_error.txt"
        @"
================================
CS2 Monitor Fatal Error Report
================================
Time: $(Get-Date)
Error: $($_.Exception.Message)

Stack Trace:
$($_.ScriptStackTrace)

Error Details:
$($_ | ConvertTo-Json -Depth 10)
"@ | Out-File -FilePath $errorFile
        
        Write-Host "`nError details saved to: $errorFile" -ForegroundColor Yellow
    }
    catch {
        Write-Host "Failed to save error details: $_" -ForegroundColor Red
    }
    
    pause
}
finally {
    $script:MonitoringActive = $false
    Write-Status "Monitor shutdown complete" "INFO" "Yellow"
}