﻿
Function New-StandardVM {
    [CmdletBinding(DefaultParameterSetName="Name")]
    Param(
        [Parameter(Mandatory = $True,Position = 0,ValueFromPipeline=$True)]
        [String[]]$Name,
        [Parameter(Mandatory = $True,Position = 1)]
        [String[]]$Folder,
        [Parameter(Mandatory = $True,Position = 2)]
        [String[]]$DataStore,
        [Parameter(Mandatory = $True,Position = 3)]
        [String[]]$Site,
        [Parameter(Mandatory = $True,Position = 4)]
        [String]$ConfigDataBaseDirectory,
        [Parameter(Mandatory = $True,Position = 5)]
        [String]$ConfigDataFileName,
        [Parameter(Position=6)]
        [String]$Template,
        [Parameter(Position=7)]
        [String]$Customization
        
    )

    Begin{}

    Process{
        Try{
            # Import Configuration Data File
            $ConfigData = Import-LocalizedData -BaseDirectory $ConfigDataBaseDirectory -FileName $ConfigDataFileName

            # Add Snapins for PowerCLI        
            $Snapins = Get-PSSnapin

            Foreach($snap in $Snapins){
                if($snap.Name -eq "VMWare.VimAutomation.Core"){
                    Write-Host "Snap in already loaded"
                }
                else{
                    Add-PSSnapin "VMWare.VimAutomation.Core"
                    
                    Connect-VIServer ($ConfigData.Nodes.Where{($_.Role -eq "VSphere") -and ($_.ADSite -eq [System.DirectoryServices.ActiveDirectory.ActiveDirectorySite]::GetComputerSite().Name)}).NodeName -AllLinked 
                }
            
            }

            # Get Cluster Resource Pool
            If($Site[0] -like "*South*"){
                $Resource = Get-ResourcePool
                if($Resource.Count -gt 1){
                    $Resource = $Resource | Where {$_.Parent -like "*South*"}
                }
                else{
                    if($Resource.Parent -like "*South*"){
                    }
                    else{
                        Write-Host "There is currently an issue with the VSphere service." -ForegroundColor Red
                        break;
                    }
                }
            }
            elseIf($Site[0] -like "*North*"){
                $Resource = Get-ResourcePool
                if($Resource.Count -gt 1){
                    $Resource = $Resource | Where {$_.Parent -like "*North*"}
                }
                else{
                    if($Resource.Parent -like "*North*"){
                    }
                    else{
                        Write-Host "There is currently an issue with the VSphere service." -ForegroundColor Red
                        break;
                    }
                }
            }
            else{
                Write-Host "Invalid Site location" -ForegroundColor Red
                break;
            }
            
            # Get Customization File                         
            if($Customization){
                $OSCustom = Get-OSCustomizationSpec | where {$_.Name -like "*$($Customization[0])*"}
            }
            else{
                $OSCustom = Get-OSCustomizationSpec | where {$_.Name -eq $ConfigData.Common.BaselineOSCustomization}
            }

            # Check to ensure only one resource pool is specified
            If($Resource.Count -gt 1){
                Write-Host "The resource pools are: "
                Foreach($r in $Resource){
                    $r.Name
                }
                break;
            }

            # Get Template
            $usedTemplate = if($Template){$Template}else{$ConfigData.Common.BaselineOSTemplateName}

            # Build VM
            $VMS = new-vm -Name $Name[0] `
                          -Location $Folder[0] `
                          -Datastore $Datastore[0] `
                          -ResourcePool $Resource `
                          -OSCustomizationSpec $OSCustom[0].Name `
                          -Template $usedTemplate
    
            $VMS = $VMS | Start-VM

            
            # Start of Customization Monitoring
            $timeoutSeconds = 600

            # Constants for status
            $STATUS_VM_NOT_STARTED = "VmNotStarted"
            $STATUS_CUSTOMIZATION_NOT_STARTED = "CustomizationNotStarted"
            $STATUS_STARTED = "CustomizationStarted"
            $STATUS_SUCCEEDED = "CustomizationSucceeded"
            $STATUS_FAILED = "CustomizationFailed"
            $STATUS_NOT_COMPLETED_LIST = @($STATUS_CUSTOMIZATION_NOT_STARTED, $STATUS_STARTED)
    
            # Constants for Event types
            $evt_type_custom_started = "VMware.Vim.CustomizationStartedEvent"
            $evt_type_custom_Succeeded = "VMWare.Vim.CustomizationSucceeded"
            $evt_type_custom_failed = "VMWare.Vim.CustomizationFailed"
            $evt_type_custom_Start = "VMware.Vim.VmStartingEvent"

            $WaitInterval = 15

            
            $time = Get-Date
            $timeevntFilter = $time.AddMinutes(-5)
            $vmDescriptors = New-Object System.Collections.ArrayList
            # Determines for each VM in the list if the VM is started
            foreach ($vm in $VMs){
                Write-Host "Start monitoring customization for vm '$vm'"
                $obj = "" | select VM,CustomizationStatus,StartVMEvent
                $obj.VM = $vm
                $obj.StartVMEvent = Get-VIEvent $vm -Start $timeevntFilter | where {$_ -is $evt_type_custom_Start} | Sort CreatedTime | Select -Last 1
                if(!($obj.StartVMEvent)){
                    $obj.CustomizationStatus = $STATUS_VM_NOT_STARTED
                }
                else{
                    $obj.CustomizationStatus = $STATUS_CUSTOMIZATION_NOT_STARTED
                }
                ($vmDescriptors.Add($obj))
            }

            # Determins whether the timeout has occured or the Status is finished to continue the loop
            $shouldContinue = {
                $notCompleteVMs = $vmDescriptors | where {$STATUS_NOT_COMPLETED_LIST -contains $_.CustomizationStatus}
                $currentTime = Get-Date
                $timeoutElapsed = $currentTime - $time
                $timeoutNotElasped = ($timeoutElapsed.TotalSeconds -lt $timeoutSeconds)

                return (($notCompleteVMs -ne $null) -and ($timeoutNotElasped))
            }

            # Begins looping through the event to determine VM Status
            while(& $shouldContinue){
                foreach($vmItem in $vmDescriptors){
                    $vmName = $vmItem.VM.Name
                    switch($vmItem.CustomizationStatus){
                        $STATUS_CUSTOMIZATION_NOT_STARTED {
                            $vmEvents = Get-VIEvent -Entity $vmItem.VM -Start $vmItem.StartVMEvent.CreatedTime
                            $startEvent = $vmEvents | where {$_ -is $evt_type_custom_started}
                            if ($startEvent){
                                $vmItem.CustomizationStatus = $STATUS_STARTED
                                Write-Host "Customization for VM '$vmName' has started" -ForegroundColor Green
                            }
                            break;
                        }
                        $STATUS_STARTED {
                            $vmEvents = Get-VIEvent -Entity $vmItem.VM -Start $vmItem.StartVMEvent.CreatedTime
                            $succeedEvent = $vmEvents | where {$_ -is $evt_type_custom_Succeeded}
                            $failedEvent = $vmEvents | where {$_ -is $evt_type_custom_failed}
                            if($succeedEvent){
                                $vmItem.CustomizationStatus = $STATUS_SUCCEEDED
                                Write-Host "Customization for VM '$vmName' has successfully completed" -ForegroundColor Green
                            }
                            if($failedEvent){
                                $vmItem.CustomizationStatus = $STATUS_FAILED
                                Write-Host "Customization for VM '$vmName' has Failed" -ForegroundColor Red
                            }
                            break;
                        }
                        default {
                            break;
                        }
                    }
                }

                #Write-Host "Sleeping for $WaitInterval seconds"
                Sleep $WaitInterval
            }

            # Outputs the results of the Customization
            $result = $vmDescriptors
            return $result
        }
        Catch{
            Write-Error error$_
        }
    }
    end{}


<#
.Synopsis
   Creates a new Windows 2012 R2 SP1 Standard Virtual Machine 
   on the North or South Cluster.

.Description
   The New-StandardVM Function creates a new Windows 2012 R2 SP1 
   Standard Virtual Machine on the VMware Environment. It can be 
   on the North Cluster or the South Cluster.

.Parameter Name
   The name of the Server
 
.Parameter Folder
   The VSphere the VM will be put in

.Parameter DataStore
   The DataStore of the storage for the VM. This needs to 
   already be a valide DataStore in VSphere environment.

.Parameter Site
   The cluster site the VM will be on example North or South

.Parameter ConfigDataBaseDirectory
   The Folder location where the network specific Configuration 
   Data file lives.

.Parameter ConfigDataFileName
   The name of the Configuration Data File

.Parameter Template
   [Optional] This allows you to change the default template 
     that is being used to to build the server. The default 
     template is identified in the Configuration Data file.

.Parameter Customization
   [Optional] This allows you to change the default Customization 
     file that is being used to build the server. The default 
     template is identifed in the Configuration Data file

.Example
     New-StandardVM `
      -Name "Testing" `
      -Folder "Testing" `
      -DataStore "TestDataStore_1" `
      -Site "South" `
      -ConfigDataBaseDirectory "\\contoso\share\ConfigData" `
      -ConfigDataFileName "ConfigData.psd1"

.Example
     New-StandardVM ` 
      -Name "Testing" `
      -Folder "Testing" `
      -DataStore "TestDataStore_1" `
      -Site "South" `
      -ConfigDataBaseDirectory "\\contoso\share\ConfigData" `
      -ConfigDataFileName "ConfigData.psd1" `
      -Template "Windows Server 2008 R2" `
      -Customization "Windows 2008 R2 Customization"
.Inputs
   You can supply the Server Name to be built

.Outputs
   Returns the status of the VM customization

.Notes
    Version: 1.0.1072016
    Date Created: 1/7/2016
    Creator: John Snow TLS
    Required Software: PowerCLI v5.8 
                       VSphere 5.1 or greater 
                       VMWare Template
                       VMWare Customization File
    PowerShell Version: v3.0 or greater

.Component
    PowerCLI 5.8
    VMWare 5.1
    VSphere 5.1

.Role
    Virtualization Administrator

.Functionality
    Build Company Standard Virtual Machine on VMWare and 
    monitor the completion of the customization file
#>
}