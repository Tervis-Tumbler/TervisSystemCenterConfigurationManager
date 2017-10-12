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

function Invoke-SCCM2016Provision {
    Invoke-ApplicationProvision -ApplicationName "SCCM2016" -EnvironmentName Infrastructure
    #$Nodes = Get-TervisApplicationNode -ApplicationName "SCCM 2016" -EnvironmentName $EnvironmentName
    $Nodes | Invoke-SCCMSQLServer2016Install
    $Nodes | Set-SQLTCPEnabled -InstanceName MSSQLSERVER -Architecture x64
    $Nodes | Set-SQLTCPIPAllTcpPort -InstanceName MSSQLSERVER -Architecture x64
    $Nodes | New-SQLNetFirewallRule
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
        $SQLSACredentials = Get-PasswordstateCredential -PasswordID ($ApplicationDefinition.Environments).SQLSAPassword -AsPlainText
        $SCCMServiceAccountCredentials = Get-PasswordstateCredential -PasswordID ($ApplicationDefinition.Environments).SCCMServiceAccountPassword -AsPlainText
	    $ChocolateyPackageParameters = "/SAPWD=$($SQLSACredentials.Password) /AGTSVCACCOUNT=$($SCCMServiceAccountCredentials.Username) /AGTSVCPASSWORD=$($SCCMServiceAccountCredentials.Password) /SQLSVCACCOUNT=$($SCCMServiceAccountCredentials.Username) /SQLSVCPASSWORD=$($SCCMServiceAccountCredentials.Password) /RSSVCACCOUNT=$($SCCMServiceAccountCredentials.Username) /RSSVCPASSWORD=$($SCCMServiceAccountCredentials.Password)"
        $ChocolateyPackage = '\\' + $DNSRoot + '\Applications\Chocolatey\SQLServer2016.1702.nupkg'

    }
    Process {
	    Invoke-Command -ComputerName $ComputerName -ScriptBlock {
		    choco install -y $ChocolateyPackage --package-parameters=$($using:ChocolateyPackageParameters)
	    }
    }
}
