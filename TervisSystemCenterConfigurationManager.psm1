function Remove-InactiveDevicesFromSCCM {
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
    param (
        $EnvironmentName
    )
    Invoke-ApplicationProvision -ApplicationName "SCCM 2016" -EnvironmentName $EnvironmentName
    #$Nodes = Get-TervisApplicationNode -ApplicationName "SCCM 2016" -EnvironmentName $EnvironmentName
    $Nodes | Invoke-SCCMSQLServer2014Install
    $Nodes | Set-SQLTCPEnabled -InstanceName MSSQL -Architecture x64
    $Nodes | Set-SQLTCPIPAllTcpPort -InstanceName MSSQL -Architecture x64
    $Nodes | New-SQLNetFirewallRule
}

function Invoke-SCCMSQLServer2014Install {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory,ValueFromPipeline)]$ComputerName,
        [Parameter(Mandatory,ValueFromPipeline)]$ApplicationName
    )
	$ApplicationDefinition = Get-TervisApplicationDefinition -Name $ApplicationName
	$SQLSACredentials = Get-PasswordstateCredential -PasswordID ($ApplicationDefinition.Environments).SQLSAPassword -AsPlainText
	$SCCMServiceAccountCredentials = Get-PasswordstateCredential -PasswordID ($ApplicationDefinition.Environments).SCCMServiceAccountPassword -AsPlainText
	$ChocolateyPackageParameters = "/SAPWD=($SQLSACredentials).Password /AGTSVCACCOUNT=($SCCMServiceAccountCredentials).Username /AGTSVCPASSWORD=($SCCMServiceAccountCredentials).Password /SQLSVCACCOUNT=($SCCMServiceAccountCredentials).Username /SQLSVCPASSWORD=($SCCMServiceAccountCredentials).Password /RSSVCACCOUNT=($SCCMServiceAccountCredentials).Username /RSSVCPASSWORD=($SCCMServiceAccountCredentials).Password"
	Invoke-Command -ComputerName $Node.ComputerName -ScriptBlock {
		choco install -y "\\tervis.prv\Applications\Chocolatey\SQLServer2014SP2.1.0.1.nupkg" --package-parameters=$($using:ChocolateyPackageParameters)
	}
}
