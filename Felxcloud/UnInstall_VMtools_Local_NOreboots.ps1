Write-Host ""
Write-Host "This Script is use for remove the VMware tools from local servers" -ForegroundColor green
Start-Sleep 2

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

Write-Host " "
$datafolder = "C:/Temp/Rehome"
if (-not (Test-Path -Path $DataFolder -ErrorAction Ignore)) {
    New-Item $DataFolder -Type Directory | Out-Null
}

try { Stop-Transcript -ErrorAction ignore | Out-Null } catch {}
try { Start-Transcript "$datafolder/Task1_VMtools_Uninstall_script_log.txt" } catch {}

write-host " Script start time :      $( Get-Date -Format "M/d/yyyy, h:mm:ss tt")"

#region code finding the server model
# KVM model is     "CloudStack KVM Hypervisor"
# Vmwware model is "VMware Virtual Platform"
try {
    $sysmodel = (Get-WmiObject Win32_ComputerSystem | Select-Object Model).model
}
catch {
    $sysmodel = (systeminfo | Select-String "System Model") -replace ".*System Model:\s+",""
}

#$sysmodel = "CloudStack KVM Hypervisor"

if ($sysmodel -eq "CloudStack KVM Hypervisor") {
    write-host " Server is in CloudStack KVM Hypervisor"
}
else {
    write-host " Server is not in CloudStack KVM Hypervisor" -ForegroundColor Magenta
    $table = @()
    $table = [pscustomobject]@{
        Server     = $Server
        ToolsRemove = "Server not in KVM"
    }

    $table
    return
}
#endregion code finding the server model

#Main code ##### Unistall VMware tools #####

$vmToolsdata = (Get-WmiObject -Class Win32_Product | Where-Object { $_.Name -like "*VMware Tools*" })

$vmToolsver = $vmToolsdata.Version
$vmToolsGUID = $vmToolsdata.IdentifyingNumber

if ($vmToolsGUID) {

    write-host " $(systeminfo | find "System Boot Time")"
    Write-host "VMware tools version $vmToolsver"

    # This script will manually rip out all VMware Tools registry entries and files for Windows 2008-2019
    # associated with the MSI for VMware Tools.
    # step1
    #region code Finding the VMware tools services, files and registry _step1

    Write-Host "Step-1 : Finding the VMware tools services, files and registry " -ForegroundColor Yellow

    $vmware_tools_ids = Get-VMwareToolsInstallerID
    if ($vmware_tools_ids) { Write-Host " VMware tools V $vmToolsver found in server" }

    # Targets we can hit with the common registry ID from $vmware_tools_ids.reg_id
    $reg_targets = @(
        "Registry::HKEY_CLASSES_ROOT\Installer\Features\",
        "Registry::HKEY_CLASSES_ROOT\Installer\Products\",
        "HKLM:\SOFTWARE\Classes\Installer\Features\",
        "HKLM:\SOFTWARE\Classes\Installer\Products\",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\"
    )

    # Create an empty array to hold all the uninstallation targets and compose the entries into the target array
    $targets = @()

    if ($vmware_tools_ids) {
        foreach ($item in $reg_targets) {
            $targets += $item + $vmware_tools_ids.reg_id
        }
        # Add the MSI installer ID regkey
        $targets += "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{$($vmware_tools_ids.msi_id)}"
    }

    # Create a list of services to stop and remove
    #$services = Get-Service -DisplayName "VMware*"
    $services = @()
    $services += Get-Service -Name VMTools -ErrorAction SilentlyContinue
    $services += Get-Service -Name VGAuthService -ErrorAction SilentlyContinue
    $services += Get-Service -Name VM3DService -ErrorAction SilentlyContinue
    $services += Get-Service -Name VMUSBArbService -ErrorAction SilentlyContinue
    $services += Get-Service -Name vmvss -ErrorAction SilentlyContinue
    $services += Get-Service -Name GISvc -ErrorAction SilentlyContinue

    # Warn the user about what is about to happen
    # Takes only y for an answer, bails otherwise.

    if (!$targets -and !$services) {
        Write-Host "VMware tools not found" -ForegroundColor Green
    }
    else {

        #endregion code Finding the VMware tools services, files and registry _step1

        # step2
        #region code Stop and removing the services _step2
        Write-Host "Step-2 : Stop and removing the VMware tools services " -ForegroundColor Yellow
        foreach ($s in $services) {
            $S_displayname = $s.DisplayName
            $S_name = $s.Name
            $S_status = $s.Status
            write-host " "
            write-host "@@@ $S_displayname @@@"
            write-host " Services $S_displayname found on server and status $S_status"

            # Stop all running VMware Services
            try {
                $s | Stop-Service -Confirm:$false -ErrorAction SilentlyContinue
                write-host " Stop process service $S_displayname :success"
            }
            catch {
                write-host " Stop process $S_displayname :failed"
            }

            # Cover for Remove-Service not existing in PowerShell versions < 6.0
            if (Get-Command Remove-Service -errorAction SilentlyContinue) {
                try {
                    $s | Remove-Service -Confirm:$false -ErrorAction SilentlyContinue
                    write-host " Removed services $S_name :success"
                }
                catch {
                    write-host " Removed services $S_name :failed"
                }
            }
            else {
                try {
                    sc.exe DELETE $($s.Name)
                    write-host " Dellete services $S_name :success"
                }
                catch {
                    write-host " Dellete services $S_name :failed"
                }
            }
        }

        #endregion code Stop the services

        # step3
        #region code Remove all the Vmxnet3 drivers _step3
        Write-Host " "
        Write-Host "Step-3 : Removing the Vmxnet3 drivers " -ForegroundColor Yellow
        $drivers = pnputil /enum-drivers
        $vmxnet3INF = $drivers -match "Published Name" |
            ForEach-Object {
                $i = [array]::IndexOf($drivers, $_)
                $block = $drivers[$i..($i + 5)]
                if ($block -match "vmxnet3.inf") {
                    ($_ -split ":")[1].Trim()
                }
            }

        if ($vmxnet3INF) {
            try { Remove-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Services\vmxnet*" -Recurse -Force -ErrorAction SilentlyContinue } catch {}
            try {
                pnputil /delete-driver $vmxnet3INF /uninstall /force
                write-host " Removed the Vmxnet3 drivers :success"
            }
            catch {
                write-host " Removed the Vmxnet3 drivers :failed"
            }
        }
        else {
            write-host " Vmxnet3 drivers Not found"
        }
        #endregion code Remove all the Vmxnet3 drivers

        # get the vmtools process  and delete
        try {
            Get-Process vmtoolsd -ErrorAction SilentlyContinue | Stop-Process -Force
            write-host " Delleted Vmtools process 'vmtoolsd'  :Success"
        }
        catch {
            write-host " Delleted Vmtools process 'vmtoolsd' :failed"
        }

        # step4
        #region code Remove the registry files -step4
        Write-Host " "
        Write-Host "Step-4 : Removing the VMware tools from registry files " -ForegroundColor Yellow

        foreach ($item in $targets) {
            if (Test-Path $item) {
                try {
                    Remove-Item -Path $item -Recurse -ErrorAction SilentlyContinue
                    write-host " Dellete $item  :success"
                }
                catch {
                    write-host " Dellete $item  :failed"
                }
            }
        }

        try {
            Remove-ItemProperty -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "VMware User Process" -ErrorAction SilentlyContinue
            write-host " Removed the Vmware tolls from startup :success"
        }
        catch {
            write-host " Removed the Vmware tolls from startup  :failed"
        }

        try {
            Remove-Item "HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application\vmStatsProvider" -Recurse -Force -ErrorAction Stop
            write-host "Removed-Item HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application\vmStatsProvider"
        }
        catch {}
        try {
            Remove-Item "HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application\vmtools" -Recurse -Force -ErrorAction Stop
            write-host "Removed-Item HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application\vmtools"
        }
        catch {}
        try {
            Remove-Item "HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application\VMware Tools" -Recurse -Force -ErrorAction Stop
            write-host "Removed-Item HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application\VMware Tools"
        }
        catch {}

        #endregion code Remove the registry files

        # step5
        #region code Deleting the VMware tools folder in Program files _step5
        Write-Host " "
        Write-Host "Step-5 : Deleting the VMware tools folder in Program files " -ForegroundColor Yellow
        $VMware_Tools_Directory = "C:\Program Files\VMware\VMware Tools"
        $VMware_Common_Directory = "C:\Program Files\Common Files\VMware"

        # Remove the VMware Tools directory
        if (Test-Path $VMware_Tools_Directory) {
            try {
                Remove-Item -Path $VMware_Tools_Directory -Recurse -Force -ErrorAction SilentlyContinue
            }
            catch {
                cmd /c "rd /s /q `"$VMware_Tools_Directory`""
            }
        }
        if (Test-Path $VMware_Tools_Directory) {
            Write-Host " Delete the Vmware tools folder in Program files :Failed"
        }
        else {
            Write-Host " Delete the Vmware tools folder in Program files :success"
        }

        #Remove the Common_Directory
        if (Test-Path $VMware_Common_Directory) {
            try {
                Remove-Item -Path $VMware_Common_Directory -Recurse -Force -ErrorAction SilentlyContinue
            }
            catch {
                cmd /c "rd /s /q `"$VMware_Common_Directory`""
            }
        }

        if (Test-Path $VMware_Common_Directory) {
            Write-Host " Delete the Vmware tools files from VMware_Common_Directory :Failed"
        }
        else {
            Write-Host " Delete the Vmware tools files from VMware_Common_Directory :success"
        }

        # Common_Directory try to delete 6 times in 6 min
        if (Test-Path $VMware_Tools_Directory) {
            $n = 0
            $L = 6
            do {
                $Ln = $L --
                Write-Host " Trying to delete Vmware tools folder in Program files. Wait $Ln minutes  "
                Start-Sleep 60
                $N ++
                if ($N -ge 6) {
                    try { Get-Process vmtoolsd -ErrorAction SilentlyContinue | Stop-Process -Force } catch {}
                    try { Get-ChildItem $VMware_Tools_Directory -Recurse -Force | ForEach-Object { $_.Attributes = 'Normal' } } catch {}
                }

                try { Remove-Item -Path $VMware_Tools_Directory -Recurse -Force -ErrorAction SilentlyContinue }
                catch { cmd /c "rd /s /q `"$VMware_Tools_Directory`"" }
                if (Test-Path $VMware_Tools_Directory) {
                    Write-Host " Delete the Vmware tools folder in Program files :failed"
                }
                else {
                    Write-Host " Delete the Vmware tools folder in Program files :Success"
                    $delete = "Yes"
                }
            }
            until ($delete -eq "Yes" -or $n -eq 6)
        }

        #endregion code Deleting the VMware tools folder in Program files _step5

        Write-Host " "
        Write-Host "Please Reboot the server to complete removal." -ForegroundColor Yellow
    }

    # step6
    #region code ##### Validating VMware tool Uninstallation _step6 #####
    Write-Host "Step-6 : Validating VMware tool Uninstallation" -ForegroundColor Yellow
    $ToolsRemove_status = "Success"
    $vmware_tools_ids = Get-VMwareToolsInstallerID
    if ($vmware_tools_ids) {
        $ToolsRemove_status = "Failed"
        $comment = "VMware tool not removed"
        Write-Host "VMware tool Uninstallation : Failed" -ForegroundColor Magenta
    }
    else {
        $services = Get-Service -Name VMTools -ErrorAction SilentlyContinue
        if ($services) {
            $ToolsRemove_status = "Failed"
            $comment = "VMware tool removed but service not removed"
            Write-Host "VMware tool removed but service not removed : Failed" -ForegroundColor Magenta
        }
        else {
            if (Test-Path $VMware_Tools_Directory -ErrorAction Stop) {
                $ToolsRemove_status = "Failed"
                $comment = "VMware tool and service removed but floder not removed"
                Write-Host "VMware tool and service removed but floder not removed : Failed" -ForegroundColor Magenta
            }
            else {
                $ToolsRemove_status = "Success"
                Write-Host "VMware tool Uninstallation : Success" -ForegroundColor green
            }
        }
    }
    #endregion code ##### Validating VMware tool Uninstallation #####

}
else {
    Write-Host " VMware tool Uninstallation: VMware Tools is not installed." -ForegroundColor Green
}

Write-Host "ToolsRemove_status  $ToolsRemove_status "
Write-Host "comment $comment"

try { Stop-Transcript -ErrorAction ignore | Out-Null } catch {}
