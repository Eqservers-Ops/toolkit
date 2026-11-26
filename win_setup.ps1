# =====================================================================
# EQSERVERS WINDOWS DIAGNOSTIC & SPEEDTEST REPORT v3.0 (Production)
# Read-only hardware/OS audit + isolated Ookla & iPerf3 throughput tests
# Compatible with Windows Server 2012 R2 (PS 4.0) through 2022 (PS 5.1)
# Zero registry, firewall, or RDP modifications.
# =====================================================================

$ErrorActionPreference = "SilentlyContinue"
$ProgressPreference    = "SilentlyContinue"

# Enforce TLS 1.2 in memory for this session only (no registry changes)
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch {}

# AV-safe & PS 4.0-compatible ZIP extractor (avoids ExtractToFile LastWriteTime lock)
function Expand-ZipSafe {
    param(
        [Parameter(Mandatory = $true)] [string]$ZipPath,
        [Parameter(Mandatory = $true)] [string]$DestDir
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (-not (Test-Path $DestDir)) {
        New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
    }
    $zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $ZipPath).Path)
    try {
        foreach ($entry in $zip.Entries) {
            if ([string]::IsNullOrEmpty($entry.Name)) { continue }
            $targetPath = Join-Path $DestDir $entry.Name
            $written = $false
            for ($attempt = 1; $attempt -le 4; $attempt++) {
                $inStream  = $null
                $outStream = $null
                try {
                    $inStream  = $entry.Open()
                    $outStream = [System.IO.File]::Open($targetPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
                    $inStream.CopyTo($outStream)
                    $written = $true
                    break
                } catch {
                    Start-Sleep -Milliseconds (500 * $attempt)
                } finally {
                    if ($outStream) { $outStream.Dispose() }
                    if ($inStream)  { $inStream.Dispose() }
                }
            }
            if (-not $written) {
                throw "File locked during extraction: $($entry.Name)"
            }
        }
    } finally {
        $zip.Dispose()
    }
}

# --- System & OS Metadata ---
$cs   = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
$os   = Get-CimInstance Win32_OperatingSystem
$up   = (Get-Date) - $os.LastBootUpTime
$utc  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm 'UTC'")

Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host " EQSERVERS WINDOWS DIAGNOSTIC & SPEEDTEST REPORT v3.0" -ForegroundColor Cyan
Write-Host " Vendor : $($cs.Manufacturer.Trim())"
Write-Host " Model  : $($cs.Model.Trim()) (S/N: $($bios.SerialNumber.Trim()))"
Write-Host " OS     : $($os.Caption.Trim()) | Build: $($os.BuildNumber) | Uptime: $($up.Days)d $($up.Hours)h"
Write-Host " Host   : $env:COMPUTERNAME | Date: $utc"
Write-Host "=================================================================" -ForegroundColor Cyan

# --- [1] CPU & RAM SUMMARY ---
Write-Host "`n[1] CPU & RAM SUMMARY:" -ForegroundColor Yellow
$cpus = Get-CimInstance Win32_Processor
foreach ($cpu in $cpus) {
    Write-Host "  CPU: $($cpu.Name.Trim()) | Cores: $($cpu.NumberOfCores) | Logical: $($cpu.NumberOfLogicalProcessors)"
}
$totalMemGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
$freeMemGB  = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
Write-Host "  Memory: Total = $totalMemGB GB | Free = $freeMemGB GB"

# --- [2] NETWORK INTERFACES & PORT SPEED CHECK ---
Write-Host "`n[2] NETWORK INTERFACES & PORT SPEED CHECK:" -ForegroundColor Yellow
$adapters = Get-NetAdapter -ErrorAction SilentlyContinue
if ($adapters) {
    foreach ($nic in $adapters) {
        $ipObj = Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
        $ipStr = if ($ipObj) { $ipObj.IPAddress } else { "N/A" }
        $line  = "  - {0,-18} | Status: {1,-12} | Speed: {2,-9} | MAC: {3} | IP: {4}" -f $nic.Name, $nic.Status, $nic.LinkSpeed, $nic.MacAddress, $ipStr
        Write-Host $line
    }
} else {
    Write-Host "  [WARN] Unable to enumerate network adapters." -ForegroundColor Yellow
}

# --- [3] INTERNET BANDWIDTH SPEEDTEST (Ookla Speedtest CLI) ---
Write-Host "`n[3] INTERNET BANDWIDTH SPEEDTEST (Ookla Speedtest CLI):" -ForegroundColor Yellow
$stDir  = "C:\Windows\Temp\eq_speedtest"
$stPath = "$stDir\speedtest.exe"

Stop-Process -Name "speedtest" -Force -ErrorAction SilentlyContinue

if (-not (Test-Path $stPath)) {
    try {
        $stZip = "$env:TEMP\ookla_$(Get-Random).zip"
        Invoke-WebRequest -Uri "https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-win64.zip" -OutFile $stZip -UseBasicParsing
        Expand-ZipSafe -ZipPath $stZip -DestDir $stDir
        Remove-Item $stZip -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
    } catch {
        Write-Host "  [WARN] Ookla Speedtest download failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

if (Test-Path $stPath) {
    Write-Host "  Running Ookla Speedtest against nearest server..." -ForegroundColor Cyan
    $stOut = "$stDir\st_out_$(Get-Random).json"
    $stErr = "$stDir\st_err_$(Get-Random).txt"
    try {
        $pSt = Start-Process -FilePath $stPath -ArgumentList "--accept-license --accept-gdpr --format=json" -NoNewWindow -RedirectStandardOutput $stOut -RedirectStandardError $stErr -PassThru
        if ($pSt.WaitForExit(45000) -and (Test-Path $stOut)) {
            $stRaw = Get-Content $stOut -Raw -ErrorAction SilentlyContinue
            if ($stRaw) {
                $stJson  = $stRaw | ConvertFrom-Json
                $dlMbps  = [math]::Round(($stJson.download.bandwidth * 8) / 1e6, 2)
                $ulMbps  = [math]::Round(($stJson.upload.bandwidth * 8) / 1e6, 2)
                $pingMs  = [math]::Round($stJson.ping.latency, 1)
                $srvName = "$($stJson.server.name) ($($stJson.server.location))"
                Write-Host ("  - Download Speed : {0} Mbps" -f $dlMbps) -ForegroundColor Green
                Write-Host ("  - Upload Speed   : {0} Mbps" -f $ulMbps) -ForegroundColor Green
                Write-Host ("  - Ping / Latency : {0} ms" -f $pingMs) -ForegroundColor Green
                Write-Host ("  - Test Server    : {0}" -f $srvName) -ForegroundColor Cyan
            } else {
                Write-Host "  [WARN] Ookla Speedtest returned empty output." -ForegroundColor Yellow
            }
        } else {
            try { $pSt.Kill() } catch {}
            Write-Host "  [WARN] Ookla Speedtest timed out." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  [WARN] Ookla Speedtest execution failed: $($_.Exception.Message)" -ForegroundColor Yellow
    } finally {
        Remove-Item $stOut, $stErr -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-Host "  [SKIP] Speedtest tool unavailable." -ForegroundColor Yellow
}

# --- [3.5] IPERF3 RAW THROUGHPUT TEST (Multi-Mirror Failover) ---
Write-Host "`n[3.5] IPERF3 RAW THROUGHPUT TEST (Multi-Mirror Failover):" -ForegroundColor Yellow
$iperfDir  = "C:\Windows\Temp\eq_iperf3"
$iperfPath = "$iperfDir\iperf3.exe"
$cygwinDll = "$iperfDir\cygwin1.dll"

Stop-Process -Name "iperf3" -Force -ErrorAction SilentlyContinue

if (-not (Test-Path $iperfPath) -or -not (Test-Path $cygwinDll)) {
    try {
        $zipFile = "$env:TEMP\iperf3_$(Get-Random).zip"
        Invoke-WebRequest -Uri "https://github.com/ar51an/iperf3-win-builds/releases/download/3.22/iperf-3.22-win64.zip" -OutFile $zipFile -UseBasicParsing
        Expand-ZipSafe -ZipPath $zipFile -DestDir $iperfDir
        Remove-Item $zipFile -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
    } catch {
        Write-Host "  [WARN] iPerf3 download failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Invoke-IperfTimed ($arguments) {
    $outFile = "$iperfDir\out_$(Get-Random).json"
    $errFile = "$iperfDir\err_$(Get-Random).txt"
    $p = Start-Process -FilePath $iperfPath -ArgumentList $arguments -NoNewWindow -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru
    if (-not $p.WaitForExit(12000)) {
        try { $p.Kill() } catch {}
        Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
        return $null
    }
    $raw = $null
    if (Test-Path $outFile) {
        $raw = Get-Content $outFile -Raw -ErrorAction SilentlyContinue
    }
    Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
    return $raw
}

if (Test-Path $iperfPath) {
    Write-Host "  Running iPerf3 throughput tests (Download & Upload)..." -ForegroundColor Cyan
    $iperfMirrors = @(
        "speedtest.ams1.nl.leaseweb.net",
        "ams.speedtest.clouvider.net",
        "nl.iperf.014.fr",
        "speedtest.wtnet.de",
        "fra.speedtest.clouvider.net",
        "ping.online.net"
    )
    $iperfSuccess = $false
    foreach ($m in $iperfMirrors) {
        $rawDl = Invoke-IperfTimed "-c $m -p 5201 -P 4 -t 4 -R --connect-timeout 2000 --json"
        if ($rawDl) {
            try {
                $jDl = $rawDl | ConvertFrom-Json
                $dlMbps = [math]::Round($jDl.end.sum_received.bits_per_second / 1e6, 2)
                if ($dlMbps -gt 0) {
                    Write-Host ("  - iPerf3 Download ({0}): {1} Mbps" -f $m, $dlMbps) -ForegroundColor Green
                    $rawUl = Invoke-IperfTimed "-c $m -p 5201 -P 4 -t 4 --connect-timeout 2000 --json"
                    if ($rawUl) {
                        $jUl = $rawUl | ConvertFrom-Json
                        $ulMbps = [math]::Round($jUl.end.sum_sent.bits_per_second / 1e6, 2)
                        if ($ulMbps -gt 0) {
                            Write-Host ("  - iPerf3 Upload   ({0}): {1} Mbps" -f $m, $ulMbps) -ForegroundColor Green
                        }
                    }
                    $iperfSuccess = $true
                    break
                }
            } catch {}
        }
    }
    if (-not $iperfSuccess) {
        Write-Host "  [WARN] All public iPerf3 mirrors were busy or unreachable." -ForegroundColor Yellow
    }
} else {
    Write-Host "  [SKIP] iPerf3 binary unavailable." -ForegroundColor Yellow
}

# --- [4] STORAGE CONTROLLERS & PHYSICAL DISK HEALTH ---
Write-Host "`n[4] STORAGE CONTROLLERS & PHYSICAL DISK HEALTH:" -ForegroundColor Yellow
Write-Host ">>> Storage / RAID Controllers:" -ForegroundColor Cyan
$controllers = Get-CimInstance Win32_SCSIController -ErrorAction SilentlyContinue
if ($controllers) {
    foreach ($ctrl in $controllers) {
        Write-Host "  - $($ctrl.Name) (Status: $($ctrl.Status))"
    }
} else {
    Write-Host "  - None detected via WMI"
}

Write-Host ">>> Physical Disks & Reliability Counters (Uncorrected Errors / Wear):" -ForegroundColor Cyan
$disks = Get-PhysicalDisk -ErrorAction SilentlyContinue | Sort-Object { if ($_.DeviceId -match '^\d+$') { [int]$_.DeviceId } else { 999 } }
if ($disks) {
    foreach ($d in $disks) {
        $sizeGB = [math]::Round($d.Size / 1GB, 1)
        $rel    = $d | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
        $rErr   = if ($null -ne $rel.ReadErrorsUncorrected) { $rel.ReadErrorsUncorrected } else { 0 }
        $wErr   = if ($null -ne $rel.WriteErrorsUncorrected) { $rel.WriteErrorsUncorrected } else { 0 }
        $wear   = if ($null -ne $rel.Wear) { "$($rel.Wear)%" } else { "0%" }
        $temp   = if ($null -ne $rel.Temperature) { "$($rel.Temperature) C" } else { "0 C" }
        $poh    = if ($null -ne $rel.PowerOnHours) { $rel.PowerOnHours } else { "N/A" }
        $serial = if ($d.SerialNumber) { $d.SerialNumber.Trim() } else { "N/A" }

        Write-Host "  --- Disk #$($d.DeviceId): $($d.FriendlyName) ($sizeGB GB | $($d.MediaType) | Bus: $($d.BusType)) ---"
        Write-Host "      Serial: $serial | Health: $($d.HealthStatus) | OperationalStatus: $($d.OperationalStatus)"
        $errColor = if ($rErr -gt 0 -or $wErr -gt 0 -or $d.HealthStatus -ne "Healthy") { "Red" } else { "Gray" }
        Write-Host "      ReadErrorsUncorrected: $rErr | WriteErrorsUncorrected: $wErr | SSD Wear: $wear | Temp: $temp | PowerOnHours: $poh" -ForegroundColor $errColor
    }
} else {
    Write-Host "  [WARN] Get-PhysicalDisk unavailable on this OS/controller." -ForegroundColor Yellow
}

# Hardware RAID safeguard (read-only alert + optional read-only vendor CLI query)
$raidDisks = $disks | Where-Object { $_.BusType -eq 'RAID' -or $_.FriendlyName -match 'LOGICAL VOLUME|PERC|MegaRAID|RAID' }
if ($raidDisks) {
    Write-Host "  [WARN] Hardware RAID detected: Windows only reports virtual logical volumes, not individual member drives." -ForegroundColor Yellow
    Write-Host "         Verify physical drive SMART/array health via HP iLO, Dell iDRAC, or vendor RAID CLI." -ForegroundColor Yellow
    $ssacli = Get-Command ssacli, hpssacli -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($ssacli) {
        Write-Host "  [INFO] Found $($ssacli.Name) - querying physical drives (read-only):" -ForegroundColor Cyan
        & $ssacli.Source ctrl all show config 2>$null | Select-String -Pattern "array|logicaldrive|physicaldrive" | ForEach-Object { Write-Host "         $($_.Line.Trim())" }
    }
    $storcli = Get-Command storcli64, storcli -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($storcli) {
        Write-Host "  [INFO] Found $($storcli.Name) - querying physical drives (read-only):" -ForegroundColor Cyan
        & $storcli.Source /call /eall /sall show 2>$null | Select-String -Pattern "Drive /c|Onln|UGood|UBad|DHS|GHS|Rbld|Failed" | ForEach-Object { Write-Host "         $($_.Line.Trim())" }
    }
}

# --- [5] WINDOWS SYSTEM EVENT LOG: DISK I/O & HARDWARE (WHEA) ERRORS ---
Write-Host "`n[5] WINDOWS SYSTEM EVENT LOG: DISK I/O & HARDWARE (WHEA) ERRORS (Last 7 Days):" -ForegroundColor Yellow
$since = (Get-Date).AddDays(-7)
$hwEvents = @()
try {
    $rawEvents = Get-WinEvent -FilterHashtable @{
        LogName      = 'System'
        StartTime    = $since
        Level        = 1, 2, 3
        ProviderName = 'Microsoft-Windows-WHEA-Logger', 'disk', 'ntfs', 'storahci', 'stornvme', 'MegaSAS', 'HpCISSs2', 'HpSAMD'
    } -ErrorAction Stop
    $hwEvents = $rawEvents | Where-Object {
        $_.ProviderName -eq 'Microsoft-Windows-WHEA-Logger' -or
        $_.Level -le 2 -or
        $_.Id -in @(7, 11, 15, 51, 55, 129, 153)
    }
} catch {}

if ($hwEvents.Count -eq 0) {
    Write-Host "  [OK] Zero WHEA Hardware/RAM errors or Disk Bad Block/I/O errors in the last 7 days." -ForegroundColor Green
} else {
    Write-Host "  [ALERT] Found $($hwEvents.Count) hardware/disk events in the last 7 days (showing latest 10):" -ForegroundColor Red
    $hwEvents | Select-Object -First 10 | ForEach-Object {
        $msg = ($_.Message -replace '\r?\n', ' ').Trim()
        if ($msg.Length -gt 120) { $msg = $msg.Substring(0, 120) + "..." }
        Write-Host ("  - [{0}] {1} (ID {2}): {3}" -f $_.TimeCreated.ToString("yyyy-MM-dd HH:mm"), $_.ProviderName, $_.Id, $msg) -ForegroundColor Red
    }
}

# --- [6] RDP CONFIGURATION & HOTFIX VERIFICATION ---
Write-Host "`n[6] RDP CONFIGURATION & HOTFIX VERIFICATION:" -ForegroundColor Yellow
$hotfixes = Get-HotFix -ErrorAction SilentlyContinue | Sort-Object { if ($_.InstalledOn) { $_.InstalledOn } else { [datetime]::MinValue } } -Descending
$targetKB = $hotfixes | Where-Object { $_.HotFixID -eq "KB5129237" } | Select-Object -First 1
if ($targetKB) {
    Write-Host "  [OK] Target hotfix KB5129237 installed ($($targetKB.InstalledOn))." -ForegroundColor Green
} else {
    $latestKB = $hotfixes | Select-Object -First 1
    if ($latestKB) {
        Write-Host "  [INFO] Specific hotfix KB5129237 not listed. Latest installed update: $($latestKB.HotFixID) ($($latestKB.InstalledOn))"
    } else {
        Write-Host "  [INFO] No hotfix history returned."
    }
}

$rdpSvc  = Get-Service -Name "TermService" -ErrorAction SilentlyContinue
$rdpDeny = (Get-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -ErrorAction SilentlyContinue).fDenyTSConnections
$rdpFw   = Get-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -eq "True" }

if ($rdpSvc.Status -eq "Running" -and $rdpDeny -eq 0 -and $rdpFw) {
    Write-Host "  [OK] Remote Desktop (RDP) service & Windows Firewall rules verified active." -ForegroundColor Green
} else {
    Write-Host "  [WARN] Check RDP status -> Service: $($rdpSvc.Status) | fDenyTSConnections: $rdpDeny | Active Firewall Rules: $($rdpFw.Count)" -ForegroundColor Yellow
}

# Clean up isolated temporary speedtest folders so zero footprint remains
Remove-Item "C:\Windows\Temp\eq_speedtest", "C:\Windows\Temp\eq_iperf3" -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "=================================================================" -ForegroundColor Cyan
