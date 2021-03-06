﻿function Remove-InactiveDevicesFromSCCM {
    $sitecode = (get-WMIObject -Namespace "root\SMS" -Class "SMS_ProviderLocation" | Select -ExpandProperty SiteCode) + ':'
    $installdrive = "C:"
    $localdomain = Get-ADDomain | Select -ExpandProperty DNSRoot
    $maxdevices = 3000

    IF(test-path ($installdrive + "\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin")) {
        Import-Module ($installdrive + "\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1")
    }
    ELSE
    {IF(test-path ($installdrive + "\Program Files\Microsoft Configuration Manager\AdminConsole\bin")){
        Import-Module ($installdrive + "\Program Files\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1")
        }
        ELSE
        {
        Write-Log -Message "ConfigMgr 2012 R2 Admin console not found!" -severity 1 -component "Error"
        }
    }

    Set-Location $sitecode
    Set-CMQueryResultMaximum -Maximum $maxdevices
    $SCCMComputers = Get-CMDevice -CollectionName "All Systems"

    Foreach ($SCCMComputer in $SCCMComputers) {
        $ADComputer = Get-TervisADComputer ($SCCMComputer).Name -Properties lastlogontimestamp,created 
        If ($ADComputer -and (($ADComputer).TervisLastLogon -lt (Get-Date).AddDays(-30)) -and (($ADComputer).Created -lt (Get-Date).AddDays(-30)) -and (($SCCMComputer).IsActive -eq "False")) {
            ($SCCMComputer).Name + " is inactive"
            Remove-CMDevice $SCCMComputer -Force -Confirm:$false
        } elseif (-NOT ($ADComputer)) {
            if (($SCCMComputer).IsActive -eq "False") {
                ($SCCMComputer).Name + " is no longer in AD"
                Remove-CMDevice $SCCMComputer -Force -Confirm:$false
            }
        }
    }
}

function Invoke-SCCM2019Provision {
    Invoke-ApplicationProvision -ApplicationName "SCCM2019" -EnvironmentName Infrastructure
    $Nodes = Get-TervisApplicationNode -ApplicationName "SCCM 2019" -EnvironmentName Infrastructure
    $Nodes = Get-TervisApplicationNode -ApplicationName SCCM2019 -EnvironmentName Infrastructure
    $Nodes | Add-SCCMDataDrive
    $Nodes | Set-SccmVmMemory
    $Nodes | Invoke-SCCMSQLServer2019Install
    $Nodes | New-SQLNetFirewallRule
    $Nodes | Set-SccmSqlMinMaxMemory
    $Nodes | Set-SCCMSystemManagementOUPermissions
    #$Nodes | Invoke-SCCM2016Install
}

function Invoke-SCCMSQLServer2016Install {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory,ValueFromPipeline)]$ComputerName,
        [Parameter(Mandatory,ValueFromPipeline)]$ApplicationName
    )
    Begin {
        $DNSRoot = Get-ADDomain | Select -ExpandProperty DNSRoot
        $ApplicationDefinition = Get-TervisApplicationDefinition -Name $ApplicationName
        $SQLSACredentials = Get-PasswordstatePassword -ID ($ApplicationDefinition.Environments).SQLSAPassword
        $SCCMServiceAccountCredentials = Get-PasswordstatePassword -ID ($ApplicationDefinition.Environments).SCCMServiceAccountPassword
        Invoke-Command -ComputerName $ComputerName -ScriptBlock {
            If (-NOT (Test-Path "D:\Databases")) {
                New-Item -Path "D:\Databases" -ItemType directory
            }
            $ACL = Get-Acl "D:\Databases"
            $AcessRule = New-Object  system.security.accesscontrol.filesystemaccessrule(($Using:SCCMServiceAccountCredentials).UserName,"FullControl”,”ContainerInherit,ObjectInherit”,”None”,”Allow”)
            $ACL.SetAccessRule($AcessRule)
            Set-Acl "D:\Databases" $ACL
        }
	    $ChocolateyPackageParameters = "/SAPWD=$($SQLSACredentials.Password) /AGTSVCACCOUNT=$($SCCMServiceAccountCredentials.Username) /AGTSVCPASSWORD=$($SCCMServiceAccountCredentials.Password) /SQLSVCACCOUNT=$($SCCMServiceAccountCredentials.Username) /SQLSVCPASSWORD=$($SCCMServiceAccountCredentials.Password) /RSSVCACCOUNT=$($SCCMServiceAccountCredentials.Username) /RSSVCPASSWORD=$($SCCMServiceAccountCredentials.Password) /SQLTEMPDBDIR=D:\Databases /SQLTEMPDBLOGDIR=D:\Databases /SQLUSERDBDIR=D:\Databases /SQLUSERDBLOGDIR=D:\Databases"
        $ChocolateyPackage = '\\' + $DNSRoot + '\Applications\Chocolatey\SQLServer2016Standard.2016.1702.0.nupkg'

    }
    Process {
	    Invoke-Command -ComputerName $ComputerName -ScriptBlock {
		    choco install SQLServer2016Standard -y -s $Using:ChocolateyPackage --package-parameters=$($using:ChocolateyPackageParameters)
	    }
    }
}

function Invoke-SCCM2016Install {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory,ValueFromPipeline)]$ComputerName,
        [Parameter(Mandatory,ValueFromPipeline)]$ApplicationName
    )
    Begin {
        $DNSRoot = Get-ADDomain | Select -ExpandProperty DNSRoot
        $ApplicationDefinition = Get-TervisApplicationDefinition -Name $ApplicationName
        $SCCMLicenseKey = Get-PasswordstatePassword -ID 5112 | Select -ExpandProperty Password
        Get-PasswordstateDocument -DocumentID 16 -DocumentLocation password -OutFile "C:\Temp\ConfigMgrAutoSave.ini"
        $SCCMServiceAccountCredentials = Get-PasswordstatePassword -ID ($ApplicationDefinition.Environments).SCCMServiceAccountPassword
	    $ChocolateyPackageParameters = "/SDKINST=sccm.tervis.com"
        $ChocolateyPackage = '\\' + $DNSRoot + '\Applications\Chocolatey\SCCM2016.2016.1702.0.nupkg'
    }
    Process {
        Invoke-Command -ComputerName $ComputerName -ScriptBlock {
            if (-NOT (Test-Path "C:\Temp")) {
                New-Item "C:\Temp" -ItemType Directory
            }
        }
        Copy-Item "C:\Temp\ConfigMgrAutoSave.ini" -Destination "\\$ComputerName\C$\Temp\ConfigMgrAutoSave.ini"
	    Invoke-Command -ComputerName $ComputerName -ScriptBlock {
		    choco install SCCM2016 -y -s $Using:ChocolateyPackage --package-parameters=$($using:ChocolateyPackageParameters)
	    }
    }
}

function Add-SCCMDataDrive {
    param (
        [Parameter(Mandatory,ValueFromPipeline)]$ComputerName,
        [Parameter(Mandatory,ValueFromPipeline)]$IPAddress
    )
    $VM = Find-TervisVMByIP $IPAddress
    $VMHardDiskDrives = Get-VMHardDiskDrive -ComputerName ($VM).ComputerName -VMName $ComputerName
    if (-NOT (($VMHardDiskDrives).Count -ge 2)) {
        $StoragePath = (Split-Path -Path ($VMHardDiskDrives).Path) + '\' + $ComputerName + '-D.vhdx'
        $CimSession = New-CimSession -ComputerName $ComputerName
        if (-NOT (Test-Path -Path $StoragePath)) {
            New-VHD -Path $StoragePath -Dynamic -SizeBytes 500GB -ComputerName ($VM).ComputerName 
        }
        Get-VMScsiController -ComputerName ($VM).ComputerName -VMName $ComputerName -ControllerNumber 0 |
            Add-VMHardDiskDrive -ComputerName ($VM).ComputerName -VMName $ComputerName -Path $StoragePath -ControllerType SCSI -ControllerNumber 0
        Get-Disk -CimSession $CimSession | 
            Where {$_.NumberOfPartitions -eq 0 -and $_.PartitionStyle -eq "RAW" -and $_.Size -eq 536870912000} |
            Initialize-Disk -Passthru |
            New-Partition -AssignDriveLetter -UseMaximumSize |
            Format-Volume -FileSystem NTFS -Confirm:$false -Force
    }
}

function Set-SCCMSystemManagementOUPermissions {
    param (
        [Parameter(Mandatory,ValueFromPipeline)]$ComputerName
    )
    $Domain = Get-ADDomain | Select -ExpandProperty DistinguishedName
    $OU = 'CN=System Management,CN=System,' + $Domain
    $ComputerSID = Get-ADComputer $ComputerName -Properties SID | Select -ExpandProperty SID
    $objACL = Get-ACL "AD:\\${OU}"
    $objACE = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($ComputerSID,"GenericAll","Allow",'All',[guid]'00000000-0000-0000-0000-000000000000')
    $objACL.AddAccessRule($objACE)
    Set-acl -AclObject $objACL "AD:${OU}"
}

function Set-SccmSqlMinMaxMemory {
    param (
        [Parameter(Mandatory,ValueFromPipeline)]$ComputerName
    )
    Invoke-Command -ComputerName $ComputerName -ScriptBlock {
        [System.Reflection.Assembly]::LoadWithPartialName(‘Microsoft.SqlServer.SMO’) | out-null
        $SqlConfig = New-Object (‘Microsoft.SqlServer.Management.Smo.Server’) $Using:ComputerName
        if (-NOT (($SqlConfig).Configuration.MinServerMemory.ConfigValue -eq "8192")) {
            $SqlConfig.Configuration.MinServerMemory.ConfigValue = 8192
            $Change = "1"
        }
        if (-NOT (($SqlConfig).Configuration.MaxServerMemory.ConfigValue -eq "10240")) {
            $SqlConfig.Configuration.MaxServerMemory.ConfigValue = 10240
            $Change = "1"
        }
        if ($Change) {
            $SqlConfig.Configuration.Alter()
            Restart-Service MSSQLSERVER -Force
            Sleep 30
        }
    }
}

function Set-SccmVmMemory {
    param (
        [Parameter(Mandatory,ValueFromPipeline)]$ComputerName,
        [Parameter(Mandatory,ValueFromPipeline)]$IPAddress
    )
    $VM = Find-TervisVMByIP $IPAddress
    $VmMemory = Get-VMMemory -ComputerName ($VM).ComputerName -VMName $ComputerName
    if (-NOT (($VmMemory).Startup -eq "17179869184")) {
        Set-VMMemory -StartupBytes "17179869184" -VMName $ComputerName -ComputerName ($VM).ComputerName
    }
}
