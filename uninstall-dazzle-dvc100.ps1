[CmdletBinding()]
param([switch]$SkipPrompt, [switch]$DryRun)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Removal is deliberately conservative: a published INF is never deleted while shared.
function Get-DazzleDrivers {
    Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceID -like 'USB\VID_1B80&PID_E60A*' } |
        Select-Object DeviceID, DeviceName, InfName, DriverProviderName, DriverVersion
}
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run from an elevated PowerShell session.' }
    $drivers = @(Get-DazzleDrivers)
    if (-not $drivers) { Write-Host 'No connected Dazzle DVC100 interfaces were found.'; return }
    $wanted = $drivers | Where-Object { $_.DeviceID -match 'MI_00' }
    $wanted | Format-Table -AutoSize | Out-Host
    foreach ($item in $wanted) {
        $users = @(Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.InfName -eq $item.InfName })
        Write-Host "`nPublished INF $($item.InfName) is used by $($users.Count) device(s):"
        $users | Select-Object DeviceID,DeviceName | Format-Table -AutoSize | Out-Host
        if ($users.Count -ne 1) { Write-Warning "Not removing $($item.InfName): the package is shared or usage cannot be proven exclusive."; continue }
        if (-not $SkipPrompt) { $answer = Read-Host "Remove ONLY $($item.InfName) from the Driver Store? [y/N]"; if ($answer -notmatch '^(?i)y(es)?$') { continue } }
        if ($DryRun) { Write-Host "DRYRUN: pnputil /delete-driver $($item.InfName) /uninstall" } else { & pnputil.exe /delete-driver $item.InfName /uninstall; if ($LASTEXITCODE -ne 0) { throw "pnputil failed for $($item.InfName)" } }
    }
} catch { Write-Error $_.Exception.Message; exit 1 }
