Write-Host ""
Write-Host "This Script is use for remove the VMware tools from local servers" -ForegroundColor green

try {
    Set-ExecutionPolicy Bypass -Scope Process -Force
}
catch {}

function Get-VMwareToolsInstallerID {
    foreach ($item in $(Get-ChildItem Registry::HKEY_CLASSES_ROOT\Installer\Products)) {
        if ($item.GetValue('ProductName') -eq 'VMware Tools') {
            return @{
                reg_id = $item.PSChildName;
                msi_id = [Regex]::Match($item.GetValue('ProductIcon'), '(?<={)(.*?)(?=})') | Select-Object -ExpandProperty Value
            }
        }
    }
}

$datafolder = Join-Path $env:ProgramData 'VMwareToolsUninstall'
if (-not (Test-Path -Path $datafolder)) {
    New-Item -Path $datafolder -ItemType Directory -Force | Out-Null
}

$ToolsRemove_status = 'Failed'
$comment = 'The uninstall script did not complete.'

try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
try { Start-Transcript (Join-Path $datafolder 'Task1_VMtools_Uninstall_script_log.txt') -ErrorAction Stop | Out-Null } catch {}

Write-Host "Script start time: $(Get-Date -Format 'M/d/yyyy, h:mm:ss tt')"

#region Find the server model
# KVM model is "CloudStack KVM Hypervisor"
# VMware model is "VMware Virtual Platform"
try {
    $sysmodel = (Get-WmiObject Win32_ComputerSystem | Select-Object -ExpandProperty Model)
}
catch {
    $sysmodel = (systeminfo | Select-String "System Model") -replace ".*System Model:\s+", ""
}

if ($sysmodel -eq 'CloudStack KVM Hypervisor') {
    Write-Host 'Server is in CloudStack KVM Hypervisor'
}
else {
    Write-Host 'Server is not in CloudStack KVM Hypervisor; uninstall skipped.' -ForegroundColor Magenta
    $ToolsRemove_status = 'NotApplicable'
    $comment = 'Server is not running on the supported CloudStack KVM hypervisor.'
    Write-Host "ToolsRemove_status: $ToolsRemove_status"
    Write-Host "comment: $comment"
    try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
    exit 0
}
#endregion Find the server model

# Main code: uninstall VMware Tools
$vmToolsdata = Get-WmiObject -Class Win32_Product | Where-Object { $_.Name -like '*VMware Tools*' }
$vmToolsver = $vmToolsdata.Version
$vmToolsGUID = $vmToolsdata.IdentifyingNumber

if ($vmToolsGUID) {
    Write-Host "$(systeminfo | find 'System Boot Time')"
    Write-Host "VMware Tools version $vmToolsver"

    # This script manually removes VMware Tools registry entries and files.
    # Step 1: Find VMware Tools services, files, and registry entries.
    Write-Host 'Step-1: Finding VMware Tools services, files, and registry entries' -ForegroundColor Yellow

    $vmware_tools_ids = Get-VMwareToolsInstallerID
    if ($vmware_tools_ids) { Write-Host "VMware Tools version $vmToolsver found on server" }

    $reg_targets = @(
        'Registry::HKEY_CLASSES_ROOT\Installer\Features\',
        'Registry::HKEY_CLASSES_ROOT\Installer\Products\',
        'HKLM:\SOFTWARE\Classes\Installer\Features\',
        'HKLM:\SOFTWARE\Classes\Installer\Products\',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\'
    )

    $targets = @()
    if ($vmware_tools_ids) {
        foreach ($item in $reg_targets) {
            $targets += $item + $vmware_tools_ids.reg_id
        }
        $targets += "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{$($vmware_tools_ids.msi_id)}"
    }

    $services = @()
    $services += Get-Service -Name VMTools -ErrorAction SilentlyContinue
    $services += Get-Service -Name VGAuthService -ErrorAction SilentlyContinue
    $services += Get-Service -Name VM3DService -ErrorAction SilentlyContinue
    $services += Get-Service -Name VMUSBArbService -ErrorAction SilentlyContinue
    $services += Get-Service -Name vmvss -ErrorAction SilentlyContinue
    $services += Get-Service -Name GISvc -ErrorAction SilentlyContinue

    if (!$targets -and !$services) {
        Write-Host 'VMware Tools not found'
    }
    else {
        # Step 2: Stop and remove VMware Tools services.
        Write-Host 'Step-2: Stopping and removing VMware Tools services' -ForegroundColor Yellow
        foreach ($s in $services) {
            $S_displayname = $s.DisplayName
            $S_name = $s.Name
            $S_status = $s.Status
            Write-Host "`n@@@ $S_displayname @@@"
            Write-Host "Service $S_displayname found on server with status $S_status"

            try {
                $s | Stop-Service -Confirm:$false -ErrorAction Stop
                Write-Host "Stopped service $S_displayname: success"
            }
            catch {
                Write-Host "Failed to stop service $S_displayname: $_"
            }

            if (Get-Command Remove-Service -ErrorAction SilentlyContinue) {
                try {
                    $s | Remove-Service -Confirm:$false -ErrorAction Stop
                    Write-Host "Removed service $S_name: success"
                }
                catch {
                    Write-Host "Failed to remove service $S_name: $_"
                }
            }
            else {
                try {
                    & sc.exe DELETE $s.Name | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "sc.exe returned exit code $LASTEXITCODE" }
                    Write-Host "Deleted service $S_name: success"
                }
                catch {
                    Write-Host "Failed to delete service $S_name: $_"
                }
            }
        }

        # Step 3: Remove Vmxnet3 drivers.
        Write-Host ' ' 
        Write-Host 'Step-3: Removing Vmxnet3 drivers' -ForegroundColor Yellow
        $drivers = pnputil /enum-drivers
        $vmxnet3INF = $drivers -match 'Published Name' |
            ForEach-Object {
                $i = [array]::IndexOf($drivers, $_)
                $block = $drivers[$i..($i + 5)]
                if ($block -match 'vmxnet3.inf') {
                    ($_ -split ':')[1].Trim()
                }
            }

        if ($vmxnet3INF) {
            try {
                Remove-Item -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\vmxnet*' -Recurse -Force -ErrorAction SilentlyContinue
            } catch {}
            try {
                pnputil /delete-driver $vmxnet3INF /uninstall /force
                if ($LASTEXITCODE -ne 0) { throw "pnputil returned exit code $LASTEXITCODE" }
                Write-Host 'Removed the Vmxnet3 drivers: success'
            }
            catch {
                Write-Host "Failed to remove the Vmxnet3 drivers: $_"
            }
        }
        else {
            Write-Host 'Vmxnet3 drivers not found'
        }

        # Stop the vmtoolsd process.
        try {
            Get-Process vmtoolsd -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction Stop
            Write-Host "Stopped Vmtools process 'vmtoolsd': success"
        }
        catch {
            Write-Host "Could not stop Vmtools process 'vmtoolsd': $_"
        }

        # Step 4: Remove registry entries.
        Write-Host ' '
        Write-Host 'Step-4: Removing VMware Tools registry entries' -ForegroundColor Yellow
        foreach ($item in $targets) {
            if (Test-Path $item) {
                try {
                    Remove-Item -Path $item -Recurse -ErrorAction Stop
                    Write-Host "Deleted $item: success"
                }
                catch {
                    Write-Host "Failed to delete $item: $_"
                }
            }
        }

        try {
            Remove-ItemProperty -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'VMware User Process' -ErrorAction Stop
            Write-Host 'Removed VMware Tools startup entry'
        }
        catch {
            Write-Host "Could not remove VMware Tools startup entry: $_"
        }

        foreach ($eventLogKey in @(
            'HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application\vmStatsProvider',
            'HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application\vmtools',
            'HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application\VMware Tools'
        )) {
            try { Remove-Item $eventLogKey -Recurse -Force -ErrorAction Stop } catch {}
        }

        # Step 5: Delete VMware Tools folders.
        Write-Host ' '
        Write-Host 'Step-5: Deleting VMware Tools folders' -ForegroundColor Yellow
        $VMware_Tools_Directory = 'C:\Program Files\VMware\VMware Tools'
        $VMware_Common_Directory = 'C:\Program Files\Common Files\VMware'

        if (Test-Path $VMware_Tools_Directory) {
            try {
                Remove-Item -Path $VMware_Tools_Directory -Recurse -Force -ErrorAction Stop
            }
            catch {
                cmd /c "rd /s /q `"$VMware_Tools_Directory`""
            }
        }
        if (Test-Path $VMware_Tools_Directory) {
            Write-Host 'Delete the VMware Tools folder in Program Files: failed'
        }
        else {
            Write-Host 'Delete the VMware Tools folder in Program Files: success'
        }

        if (Test-Path $VMware_Common_Directory) {
            try {
                Remove-Item -Path $VMware_Common_Directory -Recurse -Force -ErrorAction Stop
            }
            catch {
                cmd /c "rd /s /q `"$VMware_Common_Directory`""
            }
        }
        if (Test-Path $VMware_Common_Directory) {
            Write-Host 'Delete the VMware Common Files folder: failed'
        }
        else {
            Write-Host 'Delete the VMware Common Files folder: success'
        }

        # Retry deleting the VMware Tools folder for up to six minutes.
        if (Test-Path $VMware_Tools_Directory) {
            $n = 0
            $delete = $null
            do {
                $n++
                Write-Host "Retrying VMware Tools folder deletion (attempt $n of 6); waiting one minute."
                Start-Sleep -Seconds 60
                if ($n -ge 6) {
                    try { Get-Process vmtoolsd -ErrorAction SilentlyContinue | Stop-Process -Force } catch {}
                    try { Get-ChildItem $VMware_Tools_Directory -Recurse -Force | ForEach-Object { $_.Attributes = 'Normal' } } catch {}
                }

                try { Remove-Item -Path $VMware_Tools_Directory -Recurse -Force -ErrorAction Stop }
                catch { cmd /c "rd /s /q `"$VMware_Tools_Directory`"" }

                if (Test-Path $VMware_Tools_Directory) {
                    Write-Host 'Delete the VMware Tools folder: still present'
                }
                else {
                    Write-Host 'Delete the VMware Tools folder: success'
                    $delete = 'Yes'
                }
            }
            until ($delete -eq 'Yes' -or $n -ge 6)
        }

        Write-Host ' '
        Write-Host 'A server reboot may be required to complete removal.' -ForegroundColor Yellow
    }

    # Step 6: Validate removal.
    Write-Host 'Step-6: Validating VMware Tools uninstallation' -ForegroundColor Yellow
    $vmware_tools_ids = Get-VMwareToolsInstallerID
    if ($vmware_tools_ids) {
        $ToolsRemove_status = 'Failed'
        $comment = 'VMware Tools registry product entry remains.'
        Write-Host 'VMware Tools uninstallation: failed' -ForegroundColor Magenta
    }
    else {
        $services = Get-Service -Name VMTools -ErrorAction SilentlyContinue
        if ($services) {
            $ToolsRemove_status = 'Failed'
            $comment = 'VMware Tools product entry removed, but the VMTools service remains.'
            Write-Host 'VMware Tools service remains: failed' -ForegroundColor Magenta
        }
        elseif (Test-Path $VMware_Tools_Directory) {
            $ToolsRemove_status = 'Failed'
            $comment = 'VMware Tools product entry and service removed, but the installation folder remains.'
            Write-Host 'VMware Tools folder remains: failed' -ForegroundColor Magenta
        }
        else {
            $ToolsRemove_status = 'Success'
            $comment = 'VMware Tools removal validated.'
            Write-Host 'VMware Tools uninstallation: success' -ForegroundColor Green
        }
    }
}
else {
    $ToolsRemove_status = 'Success'
    $comment = 'VMware Tools is not installed.'
    Write-Host 'VMware Tools is not installed.' -ForegroundColor Green
}

Write-Host "ToolsRemove_status: $ToolsRemove_status"
Write-Host "comment: $comment"

try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}

if ($ToolsRemove_status -eq 'Success') {
    exit 0
}
else {
    exit 1
}
