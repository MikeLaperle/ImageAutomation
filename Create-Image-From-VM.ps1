function CreateImageFromVM {

    Param(
        [Parameter(mandatory = $true)]
        [string] $vmName,
        [Parameter(mandatory = $true)]
        [string] $rgName,
        [Parameter(mandatory = $true)]
        [string] $subName,
        [Parameter(mandatory = $true)]
        [string] $Destination = @("SharedImageGallery", "StorageAccount", "ManagedImage"),
        [Parameter(mandatory = $false, ParameterSetName = "SIG")]
        [object] $imageGalleryDefinition,
        [Parameter(mandatory = $false, ParameterSetName = "SIG")]
        [string] $imageVersion,
        [Parameter(mandatory = $false, ParameterSetName = "SA")]
        [string] $storageAccountName,
        [Parameter(mandatory = $false, ParameterSetName = "SA")]
        [string] $storageContainerName,
        [Parameter(mandatory = $false, ParameterSetName = "SA")]
        [securestring] $storageAccountKey,
        [Parameter(mandatory = $false, ParameterSetName = "SA")]
        [Parameter(mandatory = $false, ParameterSetName = "MI")]
        [string] $imageName
    )

    #code
    $ErrorActionPreference = "Stop"
    Set-AzContext -Subscription $subName
    #Build Variables
    try {
        $vm = Get-AzVM -ResourceGroupName $rgName -Name $vmName
    }
    catch {
        Write-Error -Message "The VM could not be found. Ensure the correct spelling of the RG name and VM Name"
    }
    $uid = (((New-Guid).ToString()).Split("-"))[4]
    $snapName = "Temp" + $vmName + "_" + $uid
    $loc = $vm.Location
    Write-Verbose -Message "Using the following UID for all temp resources: $uid"
    #cleanup the mess
    function cleanUpRes {
        Write-Verbose -Message "Removing Temp snapshot"
        try {
            Remove-AzSnapshot -SnapshotName $snapName -ResourceGroupName $rgName -Force -ErrorAction Continue
        }
        catch {
            Write-Warning -Message "SnapShot $snapName didn't delete please remove manually"
        }
        Write-Verbose -Message "Removing Temp VM"
        try {
            $tempVM | Remove-AzVM -Force -ErrorAction Continue
        }
        catch {
            Write-Warning -Message "VM $tempVMName didn't delete please remove manually"
        }
        Write-Verbose -Message "Removing Temp VM NIC"
        try {
            Remove-AzNetworkInterface -Name "NIC-$uid" -ResourceGroupName $rgName -Force -ErrorAction Continue
        }
        catch {
            Write-Warning -Message "VM NIC NIC-$uid didn't delete please remove manually"
        }
        Write-Verbose -Message "Removing Temp VM OS disk"
        try {
            Remove-AzDisk -DiskName "OSDisk_$uid" -ResourceGroupName $rgName -Force -ErrorAction Continue
        }
        catch {
            Write-Warning -Message "Disk OSDisk_$uid didn't delete please remove manually"
        }
        Write-Verbose -Message "Removing Temp Vnet"
        try {
            Remove-AzVirtualNetwork -Name "vnet-$uid" -ResourceGroupName $rgName -Force
        }
        catch {
            Write-Warning -Message "vNet vNet-$uid didn't delete please remove manually"
        }

        Write-Verbose -Message "Clean up completed"
    }

    #build Snap Shot
    $snapShotConf = New-AzSnapshotConfig -Location $loc -SourceUri $vm.StorageProfile.OsDisk.ManagedDisk.Id -CreateOption copy
    Write-Verbose -Message "Creating SnapShot of source VM"
    try {
        New-AzSnapshot -ResourceGroupName $rgName -SnapshotName $snapName -Snapshot $snapShotConf
    }
    catch {
        Write-Warning -Message "Unable to create SnapShot"
        cleanUpRes
        Write-Error $PSItem.Exception.Message
    }
    #build Temp VM in RG with temp vnet
    Write-Verbose -Message "Creating Vnet and subnet"
    $subnetConf = New-AzVirtualNetworkSubnetConfig -Name "default" -AddressPrefix 192.168.1.0/29
    $vnet = New-AzVirtualNetwork -ResourceGroupName $rgName -Location $loc -Name "vnet-$uid" -AddressPrefix 192.168.1.0/29 -Subnet $subnetConf
    $subnet = Get-AzVirtualNetworkSubnetConfig -Name "default" -VirtualNetwork $vnet
    $snapshot = Get-AzSnapshot -ResourceGroupName $rgName -SnapshotName $snapName
    $diskConf = New-AzDiskConfig -Location $loc -SourceResourceId $snapshot.Id -CreateOption Copy
    Write-Verbose -Message "Creating Disk"
    try {
        $newDisk = New-AzDisk -Disk $diskconf -ResourceGroupName $rgName -DiskName "OSDisk_$uid"
    }
    catch {
        Write-Warning -Message "Unable to create managed Disk from SnapShot"
        cleanUpRes
        Write-Error $PSItem.Exception.Message
    }
    $tempVMName = "VM" + $uid
    $vmConf = New-AzVMConfig -VMName $tempVMName -VMSize Standard_D2s_v3
    $vmConf = Set-AzVMOSDisk -VM $vmConf -ManagedDiskId $newdisk.Id -CreateOption Attach -Windows
    $vmNIC = New-AzNetworkInterface -Name "NIC-$uid" -ResourceGroupName $rgName -Location $loc -SubnetId $subnet.Id
    $vmConf = Add-AzVMNetworkInterface -VM $vmConf -Id $vmNIC.Id
    Write-Verbose -Message "Creating TempVM"
    try {
        New-AzVM -VM $vmConf -ResourceGroupName $rgName -Location $loc
    }
    catch {
        Write-Warning -Message "Temporary VM Creation Failed"
        cleanUpRes
        Write-Error $PSItem.Exception.Message
    }

    #sysprep the machine
    $tempVM = Get-AzVM -ResourceGroupName $rgName -Name $tempVMName
    $scriptContent = @'
    Start-Process -FilePath C:\Windows\System32\Sysprep\Sysprep.exe -ArgumentList '/generalize /oobe /shutdown /quiet'
'@
    $execScriptName = 'Sysprep.ps1'
    $execScriptPath = New-Item -Path $execScriptName -ItemType File -Force -Value $scriptContent | Select-Object -Expand FullName
    $invokeParams = @{
        VM         = $tempVM
        CommandId  = 'RunPowerShellScript'
        ScriptPath = $execScriptPath
    }
    Write-Verbose -Message "Executing Sysprep"
    try {
        Invoke-AzVMRunCommand @invokeParams
    }
    catch {
        Write-Warning -Message "Syprep run failed check logs"
        cleanUpRes
        Write-Error $PSItem.Exception.Message
    }

    #package the VM to an image based on params supplied
    Write-Verbose -Message "Stopping VM if not already stopped"
    Stop-AzVM -ResourceGroupName $rgName -Name $tempVMName -Force -ErrorAction SilentlyContinue
    if ($Destination -eq "SharedImageGallery") {
        $region1 = @{Name = $loc }
        $targetRegions = @($region1)
        $galleryName = ($imageGalleryDefinition.id).split("/")[-3]
        Write-Verbose -Message "Creating Image from $tempVMName in $GalleryName with version number $imageVersion"
        try {
            New-AzGalleryImageVersion -GalleryImageDefinitionName $imageGalleryDefinition.Name `
                -Name $imageVersion `
                -GalleryName $GalleryName `
                -ResourceGroupName $imageGalleryDefinition.ResourceGroupName `
                -Location $imageGalleryDefinition.Location `
                -TargetRegion $targetRegions `
                -StorageAccountType "Premium_LRS" `
                -Source $tempVM.Id `
                -Tag @{UID = "$uid" } `
                -asJob
        }
        catch {
            Write-Warning -Message "Image Creation failed check logs"
            cleanUpRes
            Write-Error $PSItem.Exception.Message
        }
        try {
            do {
                Write-Verbose -Message "Checking Image state..."
                $galleryJob = Get-AzGalleryImageVersion -Name $imageVersion -GalleryName $galleryName -ResourceGroupName $rgName -GalleryImageDefinitionName $imageGalleryDefinition.Name
                if ($galleryJob.ProvisioningState -eq "Succeeded") {
                    Write-Verbose -Message "Image Creation completed"
                    $state = "Completed"
                    cleanUpRes
                }
                else {
                    Start-Sleep -seconds 600
                }
                
            } until ($state -eq "Completed")
        }
        catch {
            Write-Error $PSItem.Exception.Message
        }

    
    }
    if ($Destination -eq "ManagedImage") {
        Set-AzVm -ResourceGroupName $rgName -Name $tempVMName -Generalized
        $image = New-AzImageConfig -Location $loc -SourceVirtualMachineId $tempVM.Id
        New-AzImage -Image $image -ImageName $imageName -ResourceGroupName $rgName
    }
    if ($Destination -eq "StorageAccount") {
        $sas = Grant-AzDiskAccess -ResourceGroupName $rgName -DiskName OSDisk_$uid -DurationInSecond 86400 -Access Read 
        $destinationContext = New-AzStorageContext -StorageAccountName $storageAccountName -StorageAccountKey $storageAccountKey
        $containerSASURI = New-AzStorageContainerSASToken -Context $destinationContext -ExpiryTime(get-date).AddSeconds(86400) -FullUri -Name $storageContainerName -Permission rw
        Write-Verbose -Message "Copying VHD to $storageAccountName"
        try {
            azcopy copy $sas.AccessSAS $containerSASURI
        }
        catch {
            Write-Warning -Message "AzCopy failed check logs"
            cleanUpRes
            Write-Error $PSItem.Exception.Message
        }
    
    }
    
}
