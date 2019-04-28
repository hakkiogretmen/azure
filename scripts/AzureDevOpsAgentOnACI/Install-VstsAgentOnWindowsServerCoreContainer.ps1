########################################################################################################################
# Script Disclaimer
########################################################################################################################
# This script is not supported under any Microsoft standard support program or service.
# This script is provided AS IS without warranty of any kind.
# Microsoft disclaims all implied warranties including, without limitation, any implied warranties of
# merchantability or of fitness for a particular purpose. The entire risk arising out of the use or
# performance of this script and documentation remains with you. In no event shall Microsoft, its authors,
# or anyone else involved in the creation, production, or delivery of this script be liable for any damages
# whatsoever (including, without limitation, damages for loss of business profits, business interruption,
# loss of business information, or other pecuniary loss) arising out of the use of or inability to use
# this script or documentation, even if Microsoft has been advised of the possibility of such damages.

<#
.SYNOPSIS
    This scripts configures a Windows Server Core based container with Terraform, json2hcl, the selected PowerShell modules and 
    installs and configures the Visual Studio Team Services build agent on it.
.DESCRIPTION
    This scripts configures a Windows Server Core based container (with the latest version of the 
    microsoft/windowsservercore LTSC image available on Docker Hub),
    with the latest version of the Azure DevOps agent, Terraform, json2hcl and the selected PowerShell modules (by default Az, AzureAD, Pester). 
    This container is intended to be run as an Azure Container Instance.
    After the successfully configuration, it prints the available disk space, and keeps periodically checking of the 
    vstsagent service is in a running state, keeping the container alive by that.
.PARAMETER VSTSAccountName
    Name of the Azure DevOps account - formerly Visual Studio Team Services (VSTS) account, e.g. https://<Azure DevOps Account Name>.visualstudio.com - OR - https://dev.azure.com/<Azure DevOps Account Name>/
.PARAMETER PATToken
    PAT token generated by the user who is configuring the container to be used by VSTS.
.PARAMETER AgentNamePrefix
    Prefix of the name of the agent shown on the Azure DevOps (VSTS) portal.
.PARAMETER PoolName
    Name of the Agent pool. It defaults to the "Default" pool when not defined.
.PARAMETER RequiredPowerShellModules
    List of the required PowerShell modules, e.g. Az, AzureAD, Pester
.EXAMPLE
    .\Install-VstsAgentWindowsServerCoreContainer.ps1 -VSTSAccountName "<Azure DevOps account Name>" -PATToken "<PAT Token value>"
    This installs all the components with the default configuration (Default Agent Pool, "Az", "AzureAD", "Pester" PowerShell modules, randomly generated agent name).
.EXAMPLE
    .\Install-VstsAgentWindowsServerCoreContainer.ps1 -VSTSAccountName "<Azure DevOps account Name>" -PATToken "<PAT Token value>" -AgentNamePrefix "<prefix of the Azure DevOps agent's name>" -PoolName "CoreContainers"
    This installs all the components with the defined Agent name, and Pool name, with the default PowerShell modules.
.EXAMPLE
    .\Install-VstsAgentWindowsServerCoreContainer.ps1 -VSTSAccountName "<Azure DevOps account Name>" -PATToken "<PAT Token value>" -AgentNamePrefix "<prefix of the Azure DevOps agent's name>" -PoolName "CoreContainers" -RequiredPowerShellModules "Az", "AzureAD", "Pester"
    This installs all the components with the defined Agent name, Pool name, and PowerShell modules.
.INPUTS
    <none>
.OUTPUTS
    <none>
.NOTES
    Version:        1.0
    Author:         Mate Barabas, Andrew Auret
    Creation Date:  2018-08-23
    References:     The Install-VstsAgent function is a slightly modified version of the provisioning script available as part of Azure DevTest Labs (available in August 2018).
#>

param (

    [Parameter(Mandatory=$true,
               HelpMessage="Name of the Visual Studio Team Services Account (VSTS), e.g. https://<VSTSAccountName>.visualstudio.com")]
    [ValidateNotNullOrEmpty()]
    [string]$VSTSAccountName,

    [Parameter(Mandatory=$true,
               HelpMessage="PAT token generated by the user who is configuring the container to be used by VSTS.")]
    [ValidateNotNullOrEmpty()]
    [string]$PATToken,

    [Parameter(Mandatory=$false,
               HelpMessage="Prefix of the name of the agent shown on the VSTS portal.")]
    [ValidateNotNullOrEmpty()]
    [string]$AgentNamePrefix,

    [Parameter(Mandatory=$false,
               HelpMessage="Name of the Agent pool. It defaults to the ""Default"" pool when not defined.")]
    [ValidateNotNullOrEmpty()]
    [string]$PoolName="Default",

    [Parameter(Mandatory=$false,
               HelpMessage="List of the required PowerShell modules, e.g. Az, AzureAD, Pester")]
    [ValidateNotNullOrEmpty()]
    [array]$RequiredPowerShellModules=@("Az", "AzureAD", "Pester")

)

#region Functions

    function Install-PowerShellModules {
        param (
            [array]$RequiredModules
        )

        if (-not (Get-PackageProvider -Name "Nuget" -ListAvailable -ErrorAction SilentlyContinue))
        {
            $NewPackageProvider = Find-PackageProvider -Name "Nuget"
            $NewPackageProviderVersion = $NewPackageProvider.Version.ToString()
            Write-Output "Installing Nuget package provider ($NewPackageProviderVersion)..."

            Install-PackageProvider -Name "Nuget" -Force -Confirm:$false | Out-Null

            if (Get-PackageProvider "Nuget")
            {
                Write-Output "Nuget package provider ($NewPackageProviderVersion) successfully installed."
            }
            else
            {
                Write-Error "Nuget package provider ($NewPackageProviderVersion) installation failed."
            }
            Write-Output "Waiting 10 seconds..."
            Start-Sleep -Seconds 10
        }

        Write-Output "PowerShell modules to install: $RequiredModules"
        
        foreach ($Module in $RequiredModules)
        {
            if (-not (Get-Module $Module -ErrorAction SilentlyContinue))
            {
                Write-Output "Getting $Module module..."

                $NewModule = Find-Module $Module
                $NewModuleVersion = $NewModule.Version.ToString()

                Write-Output "Installing $Module ($NewModuleVersion) module..."
                
                Install-Module -Name $Module -Force -Confirm:$false -SkipPublisherCheck
            }
        }

    }

    function Install-Terraform {

        param (

        [Parameter(Mandatory=$false,
                   HelpMessage="Use this parameter to decide if the absolute latest or the latest stable Terraform release should be installed.")]
        [ValidateNotNullOrEmpty()]
        [bool]$SkipNonStableReleases = $true

        )

        # Get the list of available Terraform versions
        $Response = Invoke-WebRequest -Uri "https://releases.hashicorp.com/terraform" -UseBasicParsing

        # Find the latest version
        if ($SkipNonStableReleases -eq $true)
        {
            $Links = $Response.Links | Where-Object {$_.href.Split("/")[2] -match "^(\d|\d\d)\.(\d|\d\d)\.(\d|\d\d)$"}
            $LatestTerraformVersion = $Links[0].href.Split("/")[2]
        }
        else
        {
            $LatestTerraformVersion = $Response.Links[1].href.Split("/")[2]
        }

        $Version = $LatestTerraformVersion

        # Find the download URL for the latest version
        $Response = Invoke-WebRequest -Uri "https://releases.hashicorp.com/terraform/$Version" -UseBasicParsing
        $RelativePath = ($Response.Links | Where-Object {$_.href -like "*windows_amd64*"}).href

        # URL will be similar to this: "https://releases.hashicorp.com/terraform/0.11.8/terraform_0.11.8_windows_amd64.zip"
        $URL = "https://releases.hashicorp.com$RelativePath"

        # Create folder
        $FileName = Split-Path $url -Leaf
        $FolderPath = "C:\terraform"
        $FilePath = "$FolderPath\$FileName"
        New-Item -ItemType Directory -Path $FolderPath -ErrorAction SilentlyContinue | Out-Null

        # Download and extract Terraform, remove the temporary zip file
        Write-Output "Downloading Terraform ($Version) to $FolderPath..."
        Invoke-WebRequest -Uri $URL -OutFile $FilePath -UseBasicParsing
        Expand-Archive -LiteralPath $FilePath -DestinationPath $FolderPath
        Remove-Item -Path $FilePath

        # Setting PATH environmental variable for Terraform
        Write-Output "Setting PATH environmental variable for Terraform..."
        # Get the PATH environmental Variable
        $Path = (Get-ItemProperty -Path 'Registry::HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\Session Manager\Environment' -Name PATH).Path
        # Create New PATH environmental Variable
        $NewPath = $Path + ";" + $FolderPath
        # Set the New PATH environmental Variable
        Set-ItemProperty -Path 'Registry::HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\Session Manager\Environment' -Name PATH -Value $NewPath
        $env:Path += $NewPath

        # Verify the Path
        # (Get-ItemProperty -Path 'Registry::HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\Session Manager\Environment' -Name PATH).Path

    }

    function Install-Json2Hcl {

        # Get the list of available Terraform versions
        $Response = Invoke-WebRequest -Uri "https://github.com/kvz/json2hcl/releases" -UseBasicParsing

        # Find the latest version
        $RelativePathToLatestVersion = (($Response.Links | Where-Object {$_.href -like "*windows_amd64*"}).href)[0]
        $Version = $RelativePathToLatestVersion.Split("/")[-2]

        # URL will be similar to this: "https://github.com/kvz/json2hcl/releases/download/v0.0.6/json2hcl_v0.0.6_windows_amd64.exe"
        $URL = "https://github.com/$RelativePathToLatestVersion"

        # Create folder
        $FileName = Split-Path $url -Leaf
        $FolderPath = "C:\json2hcl"
        $FilePath = "$FolderPath\$FileName"
        New-Item -ItemType Directory -Path $FolderPath -ErrorAction SilentlyContinue | Out-Null

        # Download and extract Json2HCL
        Write-Output "Downloading Json2HCL ($Version) to $FolderPath..."
        Invoke-WebRequest -Uri $URL -OutFile $FilePath -UseBasicParsing
        Rename-Item -Path $FolderPath\$FileName -NewName "json2hcl.exe"

        # Setting PATH environmental variable for Terraform
        Write-Output "Setting PATH environmental variable for Json2HCL..."
        # Get the PATH environmental Variable
        $Path = (Get-ItemProperty -Path 'Registry::HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\Session Manager\Environment' -Name PATH).Path
        # Create New PATH environmental Variable
        $NewPath = $Path + ";" + $FolderPath
        # Set the New PATH environmental Variable
        Set-ItemProperty -Path 'Registry::HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\Session Manager\Environment' -Name PATH -Value $NewPath
        $env:Path += $NewPath

    }

    function Install-AzureCli {
        Write-Output "Searching for the latest version of Azure CLI"
        $AzureCliUrl = "https://aka.ms/installazurecliwindows"
        $AzureCliInstallerFullPath = "C:\azurecli.msi"
        $response = Invoke-WebRequest -UseBasicParsing -Uri $AzureCliUrl -Method Head
        $AzureCliInstallerFileName = $response.BaseResponse.ResponseUri.AbsolutePath.Split("/")[-1]
        Write-Output "Downloading Azure CLI installer ($AzureCliInstallerFileName)"
        Invoke-WebRequest -UseBasicParsing -Uri $AzureCliUrl -Method GET -OutFile $AzureCliInstallerFullPath
        if (Test-Path $AzureCliInstallerFullPath)
        {
            Write-Output "Azure CLI installer ($AzureCliInstallerFileName) was successfully downloaded as $AzureCliInstallerFullPath"
            Write-Output "Installing Azure CLI ($AzureCliInstallerFileName)"
            Start-Process msiexec.exe -Wait -ArgumentList "/i $AzureCliInstallerFullPath /quiet /passive /qn"
            $AzureCli = (Get-WmiObject -Class win32_product) | Where-Object {$_.name -like "*Microsoft Azure CLI*"}
            if ($AzureCli)
            {
                Write-Output "Azure CLI (version $($AzureCli.Version) was successfully installed)"
                Remove-Item -Path $AzureCliInstallerFullPath -Force -Confirm:$false
            }
            else
            {
                Write-Error "Azure CLI could not be installed"
            }
        }
    }

    function Install-PowerShellCore {
        Write-Output "Searching for the latest version of PowerShell Core"
        $PwshInstallerFullPath = "c:\pwsh.msi"
        $response = Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/PowerShell/PowerShell/releases"
        $PwshInstallerRelativeUrl = ($response.Links.href | Where-Object {$_ -like "*win-x64.msi" -and $_ -notlike "*preview*" -and $_ -notlike "*rc*"})[0]
        $PwshInstallerFileName = $PwshInstallerRelativeUrl.Split("/")[-1]
        Write-Output "Downloading PowerShell Core ($PwshInstallerFileName)"
        $PwshInstallerUrl = "https://github.com" + $PwshInstallerRelativeUrl
        Invoke-WebRequest -UseBasicParsing -Uri $PwshInstallerUrl -OutFile $PwshInstallerFullPath
        if (Test-Path $PwshInstallerFullPath)
        {
            Write-Output "PowerShell Core installer ($PwshInstallerFileName) was successfully downloaded as $PwshInstallerFullPath"
            Write-Output "Installing PowerShell Core ($PwshInstallerFileName)"
            Start-Process msiexec.exe -Wait -ArgumentList "/i $PwshInstallerFullPath /quiet /passive /qn"

            $Pwsh = (Get-WmiObject -Class win32_product) | Where-Object {$_.name -like "*PowerShell*-x64"}
            if ($Pwsh)
            {
                Write-Output "PowerShell Core (version $($Pwsh.Version) was successfully installed)"
                Remove-Item -Path $PwshInstallerFullPath -Force -Confirm:$false
            }
            else
            {
                Write-Error "PowerShell Core could not be installed"
            }
        }
    }

    function Install-VstsAgent {
        # Downloads the Visual Studio Online Build Agent, installs on the new machine, registers with the Visual
        # Studio Online account, and adds to the specified build agent pool
        [CmdletBinding()]
        param(
            [Parameter(Mandatory=$true)][string]$vstsAccount,
            [Parameter(Mandatory=$true)][string]$vstsUserPassword,
            [Parameter(Mandatory=$true)][string]$agentName,
            [Parameter(Mandatory=$false)][string]$agentNameSuffix,
            [Parameter(Mandatory=$true)][string]$poolName,
            [Parameter(Mandatory=$true)][string]$windowsLogonAccount,
            [Parameter(Mandatory=$false)][string]$windowsLogonPassword,
            [Parameter(Mandatory=$true)][ValidatePattern("[c-zC-Z]")][ValidateLength(1, 1)][string]$driveLetter,
            [Parameter(Mandatory=$false)][string]$workDirectory,
            [Parameter(Mandatory=$true)][boolean]$runAsAutoLogon
        )

        Write-Output "Installing VSTS Agent..."

        ###################################################################################################

        # if the agentName is empty, use %COMPUTERNAME% as the value
        if ([String]::IsNullOrWhiteSpace($agentName))
        {
            $agentName = $env:COMPUTERNAME
        }

        # if the agentNameSuffix has a value, add this to the end of the agent name
        if (![String]::IsNullOrWhiteSpace($agentNameSuffix))
        {
            $agentName = $agentName + $agentNameSuffix
        }

        #
        # PowerShell configurations
        #

        # NOTE: Because the $ErrorActionPreference is "Stop", this script will stop on first failure.
        #       This is necessary to ensure we capture errors inside the try-catch-finally block.
        $ErrorActionPreference = "Stop"

        # Ensure we set the working directory to that of the script.
        Push-Location $PSScriptRoot

        # Configure strict debugging.
        Set-PSDebug -Strict

        ###################################################################################################

        #
        # Functions used in this script.
        #

        function Show-LastError
        {
            [CmdletBinding()]
            param(
            )

            $message = $error[0].Exception.Message
            if ($message)
            {
                Write-Host -Object "ERROR: $message" -ForegroundColor Red
            }

            # IMPORTANT NOTE: Throwing a terminating error (using $ErrorActionPreference = "Stop") still
            # returns exit code zero from the PowerShell script when using -File. The workaround is to
            # NOT use -File when calling this script and leverage the try-catch-finally block and return
            # a non-zero exit code from the catch block.
            exit -1
        }

        function Test-Parameters
        {
            [CmdletBinding()]
            param(
                [string] $VstsAccount,
                [string] $WorkDirectory
            )

            if ($VstsAccount -match "https*://" -or $VstsAccount -match "visualstudio.com")
            {
                Write-Error "VSTS account '$VstsAccount' should not be the URL, just the account name."
            }

            if (![string]::IsNullOrWhiteSpace($WorkDirectory) -and !(Test-ValidPath -Path $WorkDirectory))
            {
                Write-Error "Work directory '$WorkDirectory' is not a valid path."
            }
        }

        function Test-ValidPath
        {
            param(
                [string] $Path
            )

            $isValid = Test-Path -Path $Path -IsValid -PathType Container

            try
            {
                [IO.Path]::GetFullPath($Path) | Out-Null
            }
            catch
            {
                $isValid = $false
            }

            return $isValid
        }

        function Test-AgentExists
        {
            [CmdletBinding()]
            param(
                [string] $InstallPath,
                [string] $AgentName
            )

            $agentConfigFile = Join-Path $InstallPath '.agent'

            if (Test-Path $agentConfigFile)
            {
                Write-Error "Agent $AgentName is already configured in this machine"
            }
        }

        function Get-AgentPackage
        {
            [CmdletBinding()]
            param(
                [string] $VstsAccount,
                [string] $VstsUserPassword
            )

            # Create a temporary directory where to download from VSTS the agent package (agent.zip).
            $agentTempFolderName = Join-Path $env:temp ([System.IO.Path]::GetRandomFileName())
            New-Item -ItemType Directory -Force -Path $agentTempFolderName | Out-Null

            $agentPackagePath = "$agentTempFolderName\agent.zip"
            $serverUrl = "https://$VstsAccount.visualstudio.com"
            $vstsAgentUrl = "$serverUrl/_apis/distributedtask/packages/agent/win-x64?`$top=1&api-version=3.0"
            $vstsUser = "AzureDevTestLabs"

            $maxRetries = 3
            $retries = 0
            do
            {
                try
                {
                    $basicAuth = ("{0}:{1}" -f $vstsUser, $vstsUserPassword)
                    $basicAuth = [System.Text.Encoding]::UTF8.GetBytes($basicAuth)
                    $basicAuth = [System.Convert]::ToBase64String($basicAuth)
                    $headers = @{ Authorization = ("Basic {0}" -f $basicAuth) }

                    $agentList = Invoke-RestMethod -Uri $vstsAgentUrl -Headers $headers -Method Get -ContentType application/json
                    $agent = $agentList.value
                    if ($agent -is [Array])
                    {
                        $agent = $agentList.value[0]
                    }
                    Invoke-WebRequest -Uri $agent.downloadUrl -Headers $headers -Method Get -OutFile "$agentPackagePath" -UseBasicParsing | Out-Null
                    break
                }
                catch
                {
                    $exceptionText = ($_ | Out-String).Trim()

                    if (++$retries -gt $maxRetries)
                    {
                        Write-Error "Failed to download agent due to $exceptionText"
                    }

                    Start-Sleep -Seconds 1
                }
            }
            while ($retries -le $maxRetries)

            return $agentPackagePath
        }

        function New-AgentInstallPath
        {
            [CmdletBinding()]
            param(
                [string] $DriveLetter,
                [string] $AgentName
            )

            [string] $agentInstallPath = $null

            # Construct the agent folder under the specified drive.
            $agentInstallDir = $DriveLetter + ":"
            try
            {
                # Create the directory for this agent.
                $agentInstallPath = Join-Path -Path $agentInstallDir -ChildPath $AgentName
                New-Item -ItemType Directory -Force -Path $agentInstallPath | Out-Null
            }
            catch
            {
                $agentInstallPath = $null
                Write-Error "Failed to create the agent directory at $installPathDir."
            }

            return $agentInstallPath
        }

        function Get-AgentInstaller
        {
            param(
                [string] $InstallPath
            )

            $agentExePath = [System.IO.Path]::Combine($InstallPath, 'config.cmd')

            if (![System.IO.File]::Exists($agentExePath))
            {
                Write-Error "Agent installer file not found: $agentExePath"
            }

            return $agentExePath
        }


        function Set-MachineForAutologon
        {
            param(
                $Config
            )

            if ([string]::IsNullOrWhiteSpace($Config.WindowsLogonPassword))
            {
                Write-Error "Windows logon password was not provided. Please retry by providing a valid windows logon password to enable autologon."
            }

            # Create a PS session for the user to trigger the creation of the registry entries required for autologon
            $computerName = "localhost"
            $password = ConvertTo-SecureString $Config.WindowsLogonPassword -AsPlainText -Force

            if ($Config.WindowsLogonAccount.Split("\").Count -eq 2)
            {
                $domain = $Config.WindowsLogonAccount.Split("\")[0]
                $userName = $Config.WindowsLogonAccount.Split('\')[1]
            }
            else
            {
            $domain = $Env:ComputerName
            $userName = $Config.WindowsLogonAccount
            }

            $credentials = New-Object System.Management.Automation.PSCredential("$domain\\$userName", $password)
            Enter-PSSession -ComputerName $computerName -Credential $credentials
            Exit-PSSession

            try
            {
                # Check if the HKU drive already exists
                Get-PSDrive -PSProvider Registry -Name HKU | Out-Null
                $canCheckRegistry = $true
            }
            catch [System.Management.Automation.DriveNotFoundException]
            {
                try
                {
                    # Create the HKU drive
                    New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS | Out-Null
                    $canCheckRegistry = $true
                }
                catch
                {
                    # Ignore the failure to create the drive and go ahead with trying to set the agent up
                    Write-Warning "Moving ahead with agent setup as the script failed to create HKU drive necessary for checking if the registry entry for the user's SId exists.\n$_"
                }
            }

            # 120 seconds timeout
            $timeout = 120

            # Check if the registry key required for enabling autologon is present on the machine, if not wait for 120 seconds in case the user profile is still getting created
            while ($timeout -ge 0 -and $canCheckRegistry)
            {
                $objUser = New-Object System.Security.Principal.NTAccount($Config.WindowsLogonAccount)
                $securityId = $objUser.Translate([System.Security.Principal.SecurityIdentifier])
                $securityId = $securityId.Value

                if (Test-Path "HKU:\\$securityId")
                {
                    if (!(Test-Path "HKU:\\$securityId\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run"))
                    {
                        New-Item -Path "HKU:\\$securityId\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run" -Force
                        Write-Host "Created the registry entry path required to enable autologon."
                    }

                    break
                }
                else
                {
                    $timeout -= 10
                    Start-Sleep(10)
                }
            }

            if ($timeout -lt 0)
            {
                Write-Warning "Failed to find the registry entry for the SId of the user, this is required to enable autologon. Trying to start the agent anyway."
            }
        }

        function Install-Agent
        {
            param(
                $Config
            )

            try
            {
                # Set the current directory to the agent dedicated one previously created.
                Push-Location -Path $Config.AgentInstallPath

                if ($Config.RunAsAutoLogon)
                {
                    Set-MachineForAutologon -Config $Config

                    # Arguements to run agent with autologon enabled
                    $agentConfigArgs = "--unattended", "--url", $Config.ServerUrl, "--auth", "PAT", "--token", $Config.VstsUserPassword, "--pool", $Config.PoolName, "--agent", $Config.AgentName, "--runAsAutoLogon", "--overwriteAutoLogon", "--windowslogonaccount", $Config.WindowsLogonAccount
                }
                else
                {
                    # Arguements to run agent as a service
                    $agentConfigArgs = "--unattended", "--url", $Config.ServerUrl, "--auth", "PAT", "--token", $Config.VstsUserPassword, "--pool", $Config.PoolName, "--agent", $Config.AgentName, "--runasservice", "--windowslogonaccount", $Config.WindowsLogonAccount
                }

                if (-not [string]::IsNullOrWhiteSpace($Config.WindowsLogonPassword))
                {
                    $agentConfigArgs += "--windowslogonpassword", $Config.WindowsLogonPassword
                }
                if (-not [string]::IsNullOrWhiteSpace($Config.WorkDirectory))
                {
                    $agentConfigArgs += "--work", $Config.WorkDirectory
                }
                & $Config.AgentExePath $agentConfigArgs
                if ($LASTEXITCODE -ne 0)
                {
                    Write-Error "Agent configuration failed with exit code: $LASTEXITCODE"
                }
            }
            finally
            {
                Pop-Location
            }
        }

        ###################################################################################################

        #
        # Handle all errors in this script.
        #

        trap
        {
            # NOTE: This trap will handle all errors. There should be no need to use a catch below in this
            #       script, unless you want to ignore a specific error.
            Show-LastError
        }

        ###################################################################################################

        #
        # Main execution block.
        #

        try
        {
            Write-Host 'Validating agent parameters'
            Test-Parameters -VstsAccount $vstsAccount -WorkDirectory $workDirectory

            Write-Host 'Preparing agent installation location'
            $agentInstallPath = New-AgentInstallPath -DriveLetter $driveLetter -AgentName $agentName

            Write-Host 'Checking for previously configured agent'
            Test-AgentExists -InstallPath $agentInstallPath -AgentName $agentName

            Write-Host 'Downloading agent package'
            $agentPackagePath = Get-AgentPackage -VstsAccount $vstsAccount -VstsUserPassword $vstsUserPassword

            Write-Host 'Extracting agent package contents'
            Expand-Archive -LiteralPath $agentPackagePath -DestinationPath $agentInstallPath

            Write-Host 'Getting agent installer path'
            $agentExePath = Get-AgentInstaller -InstallPath $agentInstallPath

            # Call the agent with the configure command and all the options (this creates the settings file)
            # without prompting the user or blocking the cmd execution.
            Write-Host 'Installing agent'
            $config = @{
                AgentExePath = $agentExePath
                AgentInstallPath = $agentInstallPath
                AgentName = $agentName
                PoolName = $poolName
                ServerUrl = "https://$VstsAccount.visualstudio.com"
                VstsUserPassword = $vstsUserPassword
                RunAsAutoLogon = $runAsAutoLogon
                WindowsLogonAccount = $windowsLogonAccount
                WindowsLogonPassword = $windowsLogonPassword
                WorkDirectory = $workDirectory
            }
            Install-Agent -Config $config
            Write-Host 'Done'
        }
        finally
        {
            Pop-Location
        }

    }

    function Get-SystemData {
        # Get available Volume size
        $LogicalDisk = Get-WmiObject -Class win32_logicaldisk -Property *
        $FreeSpace = $LogicalDisk.FreeSpace / 1GB
        $Size = $LogicalDisk.Size / 1GB
        Write-Output "$($FreeSpace.ToString("#.##")) of $($Size.ToString("#.##")) GB disk space available"
    }

    function Watch-VstsAgentService {
        Write-Output "This container will keep running as long as the Azure DevOps agent (vstsagent) service in it is not interrupted for longer than 3 minutes."
        $TryCount = 0
        while ($true)
        {
            if ((Get-Service "vstsagent*").Status -eq "Running")
            {
                Start-Sleep -Seconds 60 | Out-Null
                # Test-Connection -ComputerName localhost -Quiet -Delay 60 | Out-Null
            }
            else
            {
                $TryCount++
            }
            if ($TryCount -gt 3)
            {
                break
            }
        }
    }
#endregion

#region Main

    # Record start time
    $StartDate = Get-Date
    Write-Host "Configuration started at $StartDate"

    # Set SSL version preference
    [Net.ServicePointManager]::SecurityProtocol = "Tls12, Tls11, Tls" # Original: Ssl3, Tls

    # Install Terraform
    Install-Terraform
    $TerraformInstallEnd = Get-Date
    $TerraformInstallDuration = New-TimeSpan -Start $StartDate -End $TerraformInstallEnd
    Write-Host "Terraform installation took $($TerraformInstallDuration.Hours.ToString("00")):$($TerraformInstallDuration.Minutes.ToString("00")):$($TerraformInstallDuration.Seconds.ToString("00")) (HH:mm:ss)"

    # Install Json2HCL
    Install-Json2Hcl
    $Json2HclInstallEnd = Get-Date
    $Json2HclInstallDuration = New-TimeSpan -Start $TerraformInstallEnd -End $Json2HclInstallEnd
    Write-Host "Json2HCL installation took $($Json2HclInstallDuration.Hours.ToString("00")):$($Json2HclInstallDuration.Minutes.ToString("00")):$($Json2HclInstallDuration.Seconds.ToString("00")) (HH:mm:ss)"

    # Install Powershell Modules
    Install-PowerShellModules -RequiredModules $RequiredPowerShellModules
    $PoShModuleInstallEnd = Get-Date
    $PoShModuleInstallDuration = New-TimeSpan -Start $Json2HclInstallEnd -End $PoShModuleInstallEnd
    Write-Host "PowerShell module installation took $($PoShModuleInstallDuration.Hours.ToString("00")):$($PoShModuleInstallDuration.Minutes.ToString("00")):$($PoShModuleInstallDuration.Seconds.ToString("00")) (HH:mm:ss)"

    # Install Azure CLI
    Install-AzureCli
    $AzureCliInstallEnd = Get-Date
    $AzureCliInstallDuration = New-TimeSpan -Start $PoShModuleInstallEnd -End $AzureCliInstallEnd
    Write-Output "Azure CLI installation took $($AzureCliInstallDuration.Hours.ToString("00")):$($AzureCliInstallDuration.Minutes.ToString("00")):$($AzureCliInstallDuration.Seconds.ToString("00")) (HH:mm:ss)"

    # Install PowerShell Core
    Install-PowerShellCore
    $PoShCoreInstallEnd = Get-Date
    $PoShCoreInstallDuration = New-TimeSpan -Start $AzureCliInstallEnd -End $PoShCoreInstallEnd
    Write-Output "PowerShell Core installation took $($PoShCoreInstallDuration.Hours.ToString("00")):$($PoShCoreInstallDuration.Minutes.ToString("00")):$($PoShCoreInstallDuration.Seconds.ToString("00")) (HH:mm:ss)"
    
    # Install VSTS Agent
    $Date = Get-Date -Format yyyyMMdd-HHmmss
    $AgentName = "$AgentNamePrefix-$Date"
    Install-VstsAgent -vstsAccount $VSTSAccountName -vstsUserPassword $PATToken  -agentName $AgentName -poolName $PoolName -windowsLogonAccount "NT AUTHORITY\NetworkService" -driveLetter "C" -runAsAutoLogon:$false
    $AgentInstallEnd = Get-Date
    $AgentInstallDuration = New-TimeSpan -Start $PoShCoreInstallEnd -End $AgentInstallEnd
    Write-Host "Agent installation took $($AgentInstallDuration.Hours.ToString("00")):$($AgentInstallDuration.Minutes.ToString("00")):$($AgentInstallDuration.Seconds.ToString("00")) (HH:mm:ss)"

    # Get available Volume size, RAM
    Get-SystemData

    # Calculate duration
    $OverallDuration = New-TimeSpan -Start $StartDate -End (Get-Date)
    Write-Host "It took $($OverallDuration.Hours.ToString("00")):$($OverallDuration.Minutes.ToString("00")):$($OverallDuration.Seconds.ToString("00")) (HH:mm:ss) to install the required components."
    Write-Host "Installation finished at $(Get-Date)"
    Write-Host "Container successfully configured." # Do NOT change this text, as this is the success criteria for the wrapper script.

    # Keep the container running by checking if the VSTS service is up
    Watch-VstsAgentService

#endregion
