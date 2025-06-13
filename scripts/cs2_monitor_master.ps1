<#
.SYNOPSIS
    CS2 Server Monitor and Auto-Recovery Tool
.DESCRIPTION
    Monitors CS2 server process, detects and fixes thread blocks
    Includes detailed logging and crash reporting
.AUTHOR
    DearCrazyLeaf
.VERSION
    2.1.0
.DATE
    2025-06-13
#>

param (
    [Parameter(Mandatory=$true)]
    [string]$CS2Path,
    
    [Parameter(Mandatory=$false)]
    [string]$AnimationDllPath = ""
)

# Add required native methods
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
    
    // 添加辅助方法
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
$script:ThreadStates = @{}
$script:LastThreadAction = $null
$script:Config = @{
    ThreadMonitoring = @{
        WarnThreshold = 30              # Warning threshold in seconds
        ActionThreshold = 120           # Action threshold in seconds
        MaxRecoveryAttempts = 3        # Maximum recovery attempts per thread
        MonitorInterval = 5            # Thread monitoring interval in seconds
    }
    Performance = @{
        MaxMemoryMB = 8192            # Maximum memory threshold in MB
        MaxCPUPercent = 90            # Maximum CPU usage percentage
        ActionCooldown = 300          # Action cooldown in seconds
        MemoryTrimInterval = 1800     # Memory trim interval in seconds
    }
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
    
    # Write to console
    Write-Host $logMessage -ForegroundColor $Color
    
    # If additional data provided, add to crash log
    if ($Data) {
        $logEntry = @{
            Timestamp = $timestamp
            Level = $Level
            Message = $Message
            Data = $Data
        } | ConvertTo-Json -Depth 10
        
        Add-Content -Path (Join-Path $script:CrashLogPath "detailed_log.json") -Value $logEntry
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
        Write-Status "Error checking DLL status: $_" "ERROR" "Red" @{
            ErrorDetails = $_.Exception.Message
            StackTrace = $_.Exception.StackTrace
        }
        return $false
    }
}

function Get-ProcessMetrics {
    param(
        [System.Diagnostics.Process]$Process,
        [switch]$Silent = $false
    )
    
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
    
    $metrics = @{
        CPU = $cpuUsage
        MemoryMB = [math]::Round($workingSet / 1MB, 2)
        MemoryDiffMB = $memoryDiff
        ThreadCount = $Process.Threads.Count
        HandleCount = $Process.HandleCount
        DelayedThreads = ($Process.Threads | Where-Object { $_.WaitReason -eq "ExecutionDelay" }).Count
    }
    
    if (-not $Silent) {
        Write-Status "Performance metrics updated" "DEBUG" "Gray" $metrics
    }
    
    return $metrics
}

function Update-ThreadMonitoring {
    param(
        [System.Diagnostics.Process]$Process
    )
    
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
        Write-Status "Error in thread monitoring: $_" "ERROR" "Red" @{
            ErrorDetails = $_.Exception.Message
            StackTrace = $_.Exception.StackTrace
        }
        return @()
    }
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
        
        switch ($BlockReason) {
            "CriticalSection" {
                # 修改这里：使用安全的方式获取句柄
                try {
                    $threadHandle = $thread.Handle
                    if ($threadHandle) {
                        [void][Win32]::NtAlertThread([IntPtr]$threadHandle)
                        Write-Status "Sent alert signal to thread $ThreadId" "ACTION" "Cyan"
                        return $true
                    }
                }
                catch {
                    Write-Status "Failed to access thread handle: $_" "ERROR" "Red"
                    return $false
                }
            }
            "EventPool" {
                if ($thread.ThreadState -eq "Wait") {
                    try {
                        $threadHandle = $thread.Handle
                        if ($threadHandle) {
                            [void][Win32]::NtAlertThread([IntPtr]$threadHandle)
                            Write-Status "Reset event pool for thread $ThreadId" "ACTION" "Cyan"
                            return $true
                        }
                    }
                    catch {
                        Write-Status "Failed to access thread handle: $_" "ERROR" "Red"
                        return $false
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
                    return $false
                }
            }
        }
    }
    catch {
        Write-Status "Error clearing thread block: $_" "ERROR" "Red" @{
            ThreadId = $ThreadId
            ErrorDetails = $_.Exception.Message
            StackTrace = $_.Exception.StackTrace
        }
        return $false
    }
    
    return $false
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
    
    $threadInfo = @{
        "Delayed Threads" = $script:ThreadStates
        "Recent Actions" = ($script:ThreadStates.Values | 
            Where-Object { $_.RecoveryAttempts -gt 0 } | 
            Select-Object FirstSeen, DelayCount, RecoveryAttempts)
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
------------
Total Delayed Threads: $($script:ThreadStates.Count)
Thread Details:
$($threadInfo | ConvertTo-Json -Depth 10)

System Information:
------------------
Total Memory: $($systemInfo["System Memory"].TotalGB) GB
Free Memory: $($systemInfo["System Memory"].FreeGB) GB
CPU Usage: $($systemInfo["CPU Usage"])%

Animation DLL Status:
------------------
$($script:LastDllHash | ConvertTo-Json -Depth 5)

Server Information:
-----------------
Server Path: $CS2Path
Animation DLL Path: $AnimationDllPath
DLL Monitoring: $($script:DllMonitoringEnabled)

Recovery Actions:
---------------
Total Recovery Attempts: $($script:ThreadStates.Values | Measure-Object -Property RecoveryAttempts -Sum | Select-Object -ExpandProperty Sum)
Last Action Time: $($script:LastThreadAction)
"@ | Out-File -FilePath $crashLogFile -Encoding UTF8
    
    Write-Status "Crash report saved to: $crashLogFile" "INFO" "Yellow"
    return $crashLogFile
}

function Monitor-ServerProcess {
    $processName = "cs2"
    $wasRunning = $false
    $lastProcess = $null
    $lastMetrics = $null
    $lastThreadCheck = Get-Date
    $lastMetricsLog = Get-Date
    $metricsLogInterval = 30
    
    Write-Status "Starting server process monitoring..." "INFO" "Cyan"
    
    while ($script:MonitoringActive) {
        try {
            $process = Get-Process $processName -ErrorAction SilentlyContinue
            
            if ($process) {
                if (-not $wasRunning) {
                    $script:ProcessStartTime = $process.StartTime
                    Write-Status "Server process detected - PID: $($process.Id)" "INFO" "Green" @{
                        ProcessId = $process.Id
                        StartTime = $process.StartTime
                        Path = $process.Path
                    }
                    $wasRunning = $true
                }
                
                $currentTime = Get-Date

                $currentMetrics = Get-ProcessMetrics $process -Silent

                if (($currentTime - $lastMetricsLog).TotalSeconds -ge $metricsLogInterval) {
                    $currentMetrics = Get-ProcessMetrics $process
                    $lastMetricsLog = $currentTime

                    if ($currentMetrics.MemoryMB -gt $script:Config.Performance.MaxMemoryMB) {
                        Write-Status "High memory usage detected: $($currentMetrics.MemoryMB)MB" "WARNING" "Yellow" @{
                            CurrentUsage = $currentMetrics.MemoryMB
                            Threshold = $script:Config.Performance.MaxMemoryMB
                        }
                        
                        if ((-not $script:LastThreadAction) -or 
                            ($currentTime - $script:LastThreadAction).TotalSeconds -gt $script:Config.Performance.ActionCooldown) {
                            Clear-ThreadBlock -Process $process -ThreadId 0 -BlockReason "MemoryPressure"
                            $script:LastThreadAction = $currentTime
                        }
                    }
                }
                
                if (($currentTime - $lastThreadCheck).TotalSeconds -ge $script:Config.ThreadMonitoring.MonitorInterval) {
                    $problemThreads = Update-ThreadMonitoring -Process $process
                    
                    foreach ($thread in $problemThreads) {
                        $severity = if ($thread.Duration -gt $script:Config.ThreadMonitoring.ActionThreshold) {
                            "WARNING" 
                        } else { 
                            "INFO" 
                        }
                        
                        Write-Status "Problem thread $($thread.ThreadId): $($thread.DelayCount) delays, $([Math]::Round($thread.Duration))s duration" $severity "Yellow" @{
                            ThreadId = $thread.ThreadId
                            DelayCount = $thread.DelayCount
                            Duration = $thread.Duration
                            RecoveryAttempts = $thread.RecoveryAttempts
                        }
                        
                        if ($thread.Duration -gt $script:Config.ThreadMonitoring.ActionThreshold -and 
                            $thread.RecoveryAttempts -lt $script:Config.ThreadMonitoring.MaxRecoveryAttempts) {
                            
                            if ((-not $script:LastThreadAction) -or 
                                ($currentTime - $script:LastThreadAction).TotalSeconds -gt $script:Config.Performance.ActionCooldown) {
                                
                                if (Clear-ThreadBlock -Process $process -ThreadId $thread.ThreadId -BlockReason "EventPool") {
                                    $script:ThreadStates[$thread.ThreadId].RecoveryAttempts++
                                    $script:LastThreadAction = $currentTime
                                }
                            }
                        }
                    }
                    
                    $lastThreadCheck = $currentTime
                }
                
                $Host.UI.RawUI.WindowTitle = "CS2 Monitor - PID: $($process.Id) | " + 
                                           "RAM: $($currentMetrics.MemoryMB)MB | " + 
                                           "CPU: $($currentMetrics.CPU)% | " + 
                                           "Delayed Threads: $($currentMetrics.DelayedThreads)"
                
                if (-not (Test-DllStatus)) {
                    Write-Status "Animation DLL changed or corrupted!" "ERROR" "Red"
                    $crashReport = Save-CrashReport -ProcessName $processName `
                        -CrashReason "Animation DLL modified" `
                        -LastProcess $process `
                        -LastMetrics $currentMetrics
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
                    
                    Write-Status "Crash report generated: $crashReport" "INFO" "Yellow"
                    
                    $wasRunning = $false
                    $script:ProcessStartTime = $null
                    $script:ThreadStates.Clear()
                }
                
                $Host.UI.RawUI.WindowTitle = "CS2 Monitor - Waiting for server..."
            }
        }
        catch {
            Write-Status "Error in monitoring loop: $_" "ERROR" "Red" @{
                ErrorDetails = $_.Exception.Message
                StackTrace = $_.Exception.StackTrace
                LastKnownState = @{
                    WasRunning = $wasRunning
                    LastMetrics = $lastMetrics
                    ThreadStates = $script:ThreadStates
                }
            }
        }
        
        Start-Sleep -Seconds 1
    }
}

try {
    Clear-Host
    
    Write-Status "================================" "INFO" "Cyan"
    Write-Status "    CS2 Server Monitor v2.1.0    " "INFO" "Cyan"
    Write-Status "      By: DearCrazyLeaf          " "INFO" "Cyan"
    Write-Status "================================" "INFO" "Cyan"
    Write-Status ""
    
    Write-Status "Server Path: $CS2Path" "INFO" "Yellow"
    Write-Status "Animation DLL Path: $AnimationDllPath" "INFO" "Yellow"
    Write-Status "Initializing..." "INFO" "Green"
    
    if (-not (Test-Path $script:CrashLogPath)) {
        New-Item -ItemType Directory -Path $script:CrashLogPath -Force | Out-Null
    }
    
    if ($script:DllMonitoringEnabled) {
        $script:LastDllHash = Get-FileHashAndMetadata $AnimationDllPath
        Write-Status "Animation DLL monitoring enabled" "INFO" "Green"
    }
    
    Write-Status "Monitor started - Press Ctrl+C to exit" "INFO" "Yellow"
    Monitor-ServerProcess
}
catch {
    Write-Status "Fatal error: $_" "ERROR" "Red" @{
        ErrorDetails = $_.Exception.Message
        StackTrace = $_.Exception.StackTrace
    }
    pause
}