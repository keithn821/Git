<#
.SYNOPSIS 
    Creates a number of Azure Environment Resources (in sequence) based on the following input parameters:
        "Project Name", "VM Name", "VM Instance Size" (and optionally "Storage Account Name")

.DESCRIPTION
    This runbook can be used to create the following Azure Environment Resources:
        Azure Affinity Group, Azure Cloud Service, Azure Storage Account,
        Azure Storage Container, Azure VM Image, and Azure VM

    It also requires the Upload of a VHD to a specified storage container mid-process.
    At this point in the process, the runbook will intentionally suspend; after the upload,
    the user simply resumes the runbook and the rest of the creation process continues.
    
    This runbook sample leverages organization id credential based authentication (Azure AD;
    instead of the Connect-Azure Runbook). Before using this runbook, you must create an Azure
    Active Directory user and allow that user to manage the Azure subscription you want to
    work against. You must also place this user's username / password in an Azure Automation
    credential asset. 
    
    You can find more information on configuring Azure so that Azure Automation can manage your 
    Azure subscription(s) here: http://aka.ms/Sspv1l 
 
    It does leverage specific Automation Assets for the required Azure AD Credential and Subscription
    Name. This example uses the following calls to get this information from Asset store:
        
        $Cred = Get-AutomationPSCredential -Name 'Azure AD Automation Account'
        $AzureSubscriptionName = Get-AutomationVariable -Name 'Primary Azure Subscription'

    The entire runbook is heavily checkpointed and can be run multiple times without resource recreation.

    It relies on six additional (6) Automation Assets (to be configured in the Assets tab). These are
    suggested, not required. Replacing the "Get-AutomationVariable" calls within this runbook with static
    or parameter variables is an alternative method. For this example though, the following dependencies exist:
    VARIABLES SET WITH AUTOMATION ASSETS:
        $AGLocation = Get-AutomationVariable -Name 'AGLocation'
        $GenericStorageContainerName = Get-AutomationVariable -Name 'GenericStorageContainer'
        $SourceDiskFileExt = Get-AutomationVariable -Name 'SourceDiskFileExt'
        $VMImageOS = Get-AutomationVariable -Name 'VMImageOS'
        $AdminUsername = Get-AutomationVariable -Name 'AdminUsername'
        $Password = Get-AutomationVariable -Name 'Password'

.PARAMETER ProjectName
    REQUIRED. Name of the Project for the deployment of Azure Environment Resources. This name is leveraged
    throughout the runbook to derive the names of the Azure Environment Resources created.

.PARAMETER VMName
    REQUIRED. Name of the Virtual Machine to be created as part of the Project.

.PARAMETER VMInstanceSize
   REQUIRED. Specifies the size of the instance. Supported values are as below with their (cores, memory) 
   "ExtraSmall" (shared core, 768 MB),
   "Small"      (1 core, 1.75 GB),
   "Medium"     (2 cores, 3.5 GB),
   "Large"      (4 cores, 7 GB),
   "ExtraLarge" (8 cores, 14GB),
   "A5"         (2 cores, 14GB)
   "A6"         (4 cores, 28GB)
   "A7"         (8 cores, 56 GB)

.PARAMETER StorageAccountName
    OPTIONAL. This parameter should only be set if the runbook is being re-executed after an existing
    and unique Storage Account Name has already been created, or if a new and unique Storage Account Name
    is desired. If left blank, a new and unique Storage Account Name will be created for the Project. The
    format of the derived Storage Account Names is:
        $ProjectName (lowercase) + [Random lowercase letters and numbers] up to a total Length of 23

.EXAMPLE
    New-AzureEnvironmentResources -ProjectName "MyProject001" -VMName "MyVM001" `
        -VMInstanceSize "ExtraSmall"
        
.EXAMPLE
    New-AzureEnvironmentResources -ProjectName "MyProject001" -VMName "MyVM001" ` 
        -VMInstanceSize "ExtraSmall" -StorageAccountName "myproject001n3o3m5u0u1l"

.NOTES
    AUTHOR: Charles Joy, EC CAT Team, Microsoft
    BLOG: Building Cloud Blog - http://aka.ms/BuildingClouds
    LAST EDIT: October 17, 2014
#>

workflow New-AzureEnvironmentResourcesFromUploadedVHD
{
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$ProjectName,
        [Parameter(Mandatory=$true)]
        [string]$VMName,
        [Parameter(Mandatory=$true)]
        [string]$VMInstanceSize,
        [Parameter(Mandatory=$false)]
        [string]$StorageAccountName
    )

    ####################################################################################################
    # Set Variables (all non-derived variables are based on Automation Assets)
    
    # Set Azure Affinity Group Variables
    $AGName = $ProjectName
    $AGLocation = Get-AutomationVariable -Name 'AGLocation'
    $AGLocationDesc = "Affinity group for {0} VMs"  -f $ProjectName
    $AGLabel = "{0} {1}" -f $AGLocation,$ProjectName
    
    # Set Azure Cloud Service Variables
    $CloudServiceName = $ProjectName
    $CloudServiceDesc = "Service for {0} VMs" -f $ProjectName
    $CloudServiceLabel = "{0} VMs" -f $ProjectName

    # Set Azure Storage Account Variables
    if (!$StorageAccountName) {
        $StorageAccountName = $ProjectName.ToLower()
        $rand = New-Object System.Random
        $RandomPadCount = 23 - $StorageAccountName.Length
        foreach ($r in 1..$RandomPadCount) { if ($r%2 -eq 1) { $StorageAccountName += [char]$rand.Next(97,122) } else { $StorageAccountName += [char]$rand.Next(48,57) } }
    }
    $StorageAccountDesc = "Storage account for {0} VMs" -f $ProjectName
    $StorageAccountLabel = "{0} Storage" -f $ProjectName

    # Set Azure Storage Container Variables
    $GenericStorageContainerName = Get-AutomationVariable -Name 'GenericStorageContainer'
    $ProjectStorageContainerName = $ProjectName.ToLower()

    # Set Output Message for Manual Task Notification
    $DestinationVHDPath = "https://{0}.blob.core.windows.net/{1}" -f $StorageAccountName,$GenericStorageContainerName
    $ManualTaskOutputNote = "***ACTION REQUIRED***"
    $ManualTaskOutputNote += "`nManual step required. Upload VHD to the {0} container in the {1} storage account." -f $GenericStorageContainerName,$StorageAccountName
    $ManualTaskOutputNote += "`nContainer Path: {0}" -f $DestinationVHDPath
    $ManualTaskOutputNote += "`nOnce the VHD Upload is complete, Resume this Runbook Job."
    $ManualTaskOutputNote += "`n***ACTION REQUIRED***"

    # Set Azure Blob Variables
    $SourceDiskFileExt = Get-AutomationVariable -Name 'SourceDiskFileExt'
    $DestinationVHDName = "{0}.{1}" -f $ProjectName,$SourceDiskFileExt
    $SourceBlobName = $DestinationVHDName
    $SourceContainer = $GenericStorageContainerName
    $DestinationContainer = $ProjectStorageContainerName
    $DestinationBlobName = "{0}_copy.{1}" -f $ProjectName,$SourceDiskFileExt

    # Set Azure VM Image Variables
    $VMImageName = $ProjectName
    $VMImageBlobContainer = $DestinationContainer
    $VMImageBlobName = $DestinationBlobName
    $VMImageOS = Get-AutomationVariable -Name 'VMImageOS'

    #Set Azure VM Variables
    $ServiceName = $ProjectName
    $AdminUsername = Get-AutomationVariable -Name 'AdminUsername'
    $Password = Get-AutomationVariable -Name 'Password'
    $Windows = $true
    $WaitForBoot = $true

    ####################################################################################################

    # Get the credential to use for Authentication to Azure and Azure Subscription Name
    $Cred = Get-AutomationPSCredential -Name 'Azure AD Automation Account'
    $AzureSubscriptionName = Get-AutomationVariable -Name 'Primary Azure Subscription'
    
    # Connect to Azure and Select Azure Subscription
    $AzureAccount = Add-AzureAccount -Credential $Cred
    $AzureSubscription = Select-AzureSubscription -SubscriptionName $AzureSubscriptionName

    ####################################################################################################
    # Create/Verify Azure Affinity Group

    if ($AzureAccount.Id -eq $AzureSubscription.Account) {

        Write-Verbose "Connection to Azure Established - Specified Azure Environment Resource Creation In Progress..."

        $AzureAffinityGroup = Get-AzureAffinityGroup -Name $AGName -ErrorAction SilentlyContinue

        if(!$AzureAffinityGroup) {
            $AzureAffinityGroup = New-AzureAffinityGroup -Location $AGLocation -Name $AGName -Description $AGLocationDesc -Label $AGLabel
            $VerboseMessage = "{0} for {1} {2} (OperationId: {3})" -f $AzureAffinityGroup.OperationDescription,$AGName,$AzureAffinityGroup.OperationStatus,$AzureAffinityGroup.OperationId
        } else { $VerboseMessage = "Azure Affinity Group {0}: Verified" -f $AzureAffinityGroup.Name }

        Write-Verbose $VerboseMessage

    } else {
        $ErrorMessage = "Azure Connection to $AzureSubscriptionName could not be Verified."
        Write-Error $ErrorMessage -Category ResourceUnavailable
        throw $ErrorMessage
     }

    # Checkpoint after Azure Affinity Group Creation
    Checkpoint-Workflow
    
    # (Re)Connect to Azure and (Re)Select Azure Subscription
    $AzureAccount = Add-AzureAccount -Credential $Cred
    $AzureSubscription = Select-AzureSubscription -SubscriptionName $AzureSubscriptionName

    ####################################################################################################

    ####################################################################################################
    # Create/Verify Azure Cloud Service

    if ($AzureAffinityGroup.OperationStatus -eq "Succeeded" -or $AzureAffinityGroup.Name -eq $AGName) {
    
        $AzureCloudService = Get-AzureService -ServiceName $CloudServiceName -ErrorAction SilentlyContinue

        if(!$AzureCloudService) {
            $AzureCloudService = New-AzureService -AffinityGroup $AGName -ServiceName $CloudServiceName -Description $CloudServiceDesc -Label $CloudServiceLabel
            $VerboseMessage = "{0} for {1} {2} (OperationId: {3})" -f $AzureCloudService.OperationDescription,$CloudServiceName,$AzureCloudService.OperationStatus,$AzureCloudService.OperationId
        } else { $VerboseMessage = "Azure Cloud Serivce {0}: Verified" -f $AzureCloudService.ServiceName }

        Write-Verbose $VerboseMessage

    } else {
        $ErrorMessage = "Azure Affinity Group Creation Failed OR Could Not Be Verified for: $AGName"
        Write-Error $ErrorMessage -Category ResourceUnavailable
        throw $ErrorMessage
     }

    # Checkpoint after Azure Cloud Service Creation
    Checkpoint-Workflow
    
    # (Re)Connect to Azure and (Re)Select Azure Subscription
    $AzureAccount = Add-AzureAccount -Credential $Cred
    $AzureSubscription = Select-AzureSubscription -SubscriptionName $AzureSubscriptionName

    ####################################################################################################

    ####################################################################################################
    # Create/Verify Azure Storage Account

    if ($AzureCloudService.OperationStatus -eq "Succeeded" -or $AzureCloudService.ServiceName -eq $CloudServiceName) {
        
        $AzureStorageAccount = Get-AzureStorageAccount -StorageAccountName $StorageAccountName -ErrorAction SilentlyContinue

        if(!$AzureStorageAccount) {
            $AzureStorageAccount = New-AzureStorageAccount -AffinityGroup $AGName -StorageAccountName $StorageAccountName -Description $StorageAccountDesc -Label $StorageAccountLabel
            $VerboseMessage = "{0} for {1} {2} (OperationId: {3})" -f $AzureStorageAccount.OperationDescription,$StorageAccountName,$AzureStorageAccount.OperationStatus,$AzureStorageAccount.OperationId
        } else { $VerboseMessage = "Azure Storage Account {0}: Verified" -f $AzureStorageAccount.StorageAccountName }

        Write-Verbose $VerboseMessage

    } else {
        $ErrorMessage = "Azure Cloud Service Creation Failed OR Could Not Be Verified for: $CloudServiceName"
        Write-Error $ErrorMessage -Category ResourceUnavailable
        throw $ErrorMessage
     }

    # Checkpoint after Azure Storage Account Creation
    Checkpoint-Workflow
    
    # (Re)Connect to Azure and (Re)Select Azure Subscription
    $AzureAccount = Add-AzureAccount -Credential $Cred
    $AzureSubscription = Select-AzureSubscription -SubscriptionName $AzureSubscriptionName

    ####################################################################################################

    ####################################################################################################
    # Create/Verify Azure Storage Containers
    
    if ($AzureStorageAccount.OperationStatus -eq "Succeeded" -or $AzureStorageAccount.StorageAccountName -eq $StorageAccountName) {
        
        # Sleep for 60 seconds to ensure Storage Account is fully created
        Start-Sleep -Seconds 60

        # Set CurrentStorageAccount for the Azure Subscription
        Set-AzureSubscription -SubscriptionName $AzureSubscriptionName -CurrentStorageAccount $StorageAccountName
        
        $GenericStorageContainer = Get-AzureStorageContainer -Name $GenericStorageContainerName -ErrorAction SilentlyContinue

        if(!$GenericStorageContainer) {
            $GenericStorageContainer = New-AzureStorageContainer -Name $GenericStorageContainerName
            $VerboseMessage = "Azure Storage Container {0}: Created" -f $GenericStorageContainer.Name
        } else { $VerboseMessage = "Azure Storage Container {0}: Verified" -f $GenericStorageContainer.Name }

        Write-Verbose $VerboseMessage

        $ProjectStorageContainer = Get-AzureStorageContainer -Name $ProjectStorageContainerName -ErrorAction SilentlyContinue

        if(!$ProjectStorageContainer) {
            $ProjectStorageContainer = New-AzureStorageContainer -Name $ProjectStorageContainerName
            $VerboseMessage = "Azure Storage Container {0}: Created" -f $ProjectStorageContainer.Name
        } else { $VerboseMessage = "Azure Storage Container {0}: Verified" -f $ProjectStorageContainer.Name }

        Write-Verbose $VerboseMessage

    } else {
        $ErrorMessage = "Azure Storage Account Creation Failed OR Could Not Be Verified for: $StorageAccountName"
        Write-Error $ErrorMessage -Category ResourceUnavailable
        throw $ErrorMessage
     }
     
    # Checkpoint after Azure Storage Container Creation
    Checkpoint-Workflow
    
    # (Re)Connect to Azure and (Re)Select Azure Subscription
    $AzureAccount = Add-AzureAccount -Credential $Cred
    $AzureSubscription = Select-AzureSubscription -SubscriptionName $AzureSubscriptionName

    ####################################################################################################

    # Suspend Runbook to wait for Manual Task Execution (VHD Upload)
    $SuspendNote = "Intentionally Suspending Runbook for Manual Task Execution (VHD Upload)." 
    Write-Verbose $SuspendNote
    Write-Output $SuspendNote
    
    # Write Output for Manual Task Notification
    Write-Output $ManualTaskOutputNote
    
    Suspend-Workflow
    
    # Write Output for Resume after Manual Task Execution
    $ResumeNote = "Resuming after Manual Task Execution (VHD Upload)." 
    Write-Output $ResumeNote 
    Write-Verbose $ResumeNote
    
    # (Re)Connect to Azure and (Re)Select Azure Subscription
    Write-Verbose "Re-establishing Connection to Azure (Add-AzureAccount, Select/Set-AzureSubscription)"
    $AzureAccount = Add-AzureAccount -Credential $Cred
    $AzureSubscription = Select-AzureSubscription -SubscriptionName $AzureSubscriptionName
    
    # Set CurrentStorageAccount for the Azure Subscription
    Set-AzureSubscription -SubscriptionName $AzureSubscriptionName -CurrentStorageAccount $StorageAccountName

    ####################################################################################################
    # Verify Azure Blob (from Manual Upload) and Copy (from Generic Container to Project Container)

    $AzureUploadedBlob = Get-AzureStorageBlob -Container $GenericStorageContainerName -Blob $DestinationVHDName -ErrorAction SilentlyContinue

    if ($AzureUploadedBlob) {

        $AzureUploadedBlobMediaLocation = (Get-AzureStorageBlob -Container $GenericStorageContainerName -Blob $DestinationVHDName).ICloudBlob.Uri.AbsoluteUri

        $VerboseMessage = "{0} verified uploaded in container: {1}" -f $AzureUploadedBlob.Name,$AzureUploadedBlobMediaLocation
        Write-Verbose $VerboseMessage

        $CopiedBlobMediaLocation = (Get-AzureStorageBlob -Container $DestinationContainer -Blob $DestinationBlobName -ErrorAction SilentlyContinue).ICloudBlob.Uri.AbsoluteUri
        
        if(!$CopiedBlobMediaLocation) {
            $CopyAzureBlob = Start-AzureStorageBlobCopy -DestContainer $DestinationContainer -SrcBlob $SourceBlobName -SrcContainer $SourceContainer -DestBlob $DestinationBlobName
            $CopiedAzureBlob = $CopyAzureBlob.Name
            $CopiedBlobMediaLocation = (Get-AzureStorageBlob -Container $DestinationContainer -Blob $DestinationBlobName).ICloudBlob.Uri.AbsoluteUri
            $VerboseMessage = "Azure Blob {0}: Copied" -f $CopiedBlobMediaLocation
        } else {
            $CopiedAzureBlob = $CopiedBlobMediaLocation.Split('/')[4]
            $VerboseMessage = "Azure Blob {0}: Verified" -f $CopiedBlobMediaLocation
            }

        Write-Verbose $VerboseMessage

    } else {
        $ErrorMessage = "Azure Blob: $DestinationVHDName in $DestinationVHDPath could not be Verified."
        Write-Error $ErrorMessage -Category ResourceUnavailable
        throw $ErrorMessage
     }

    # Checkpoint after Azure Blob Verification and Copy
    Checkpoint-Workflow
    
    # (Re)Connect to Azure and (Re)Select Azure Subscription
    $AzureAccount = Add-AzureAccount -Credential $Cred
    $AzureSubscription = Select-AzureSubscription -SubscriptionName $AzureSubscriptionName

    ####################################################################################################

    ####################################################################################################
    # Create Azure VM Image

    if ($CopiedAzureBlob -eq $DestinationBlobName) {
        
        $AzureVMImage = Get-AzureVMImage -ImageName $VMImageName -ErrorAction SilentlyContinue

        if(!$AzureVMImage) {
            $AzureBlobMediaLocation = $CopiedBlobMediaLocation
            $AzureVMImage = Add-AzureVMImage -ImageName $VMImageName -MediaLocation $AzureBlobMediaLocation -OS $VMImageOS
            $VerboseMessage = "{0} for {1} {2} (OperationId: {3})" -f $AzureVMImage.OperationDescription,$VMImageName,$AzureVMImage.OperationStatus,$AzureVMImage.OperationId
        } else { $VerboseMessage = "Azure VM Image {0}: Verified" -f $AzureVMImage.ImageName }

        Write-Verbose $VerboseMessage
    
    } else {
        $ErrorMessage = "Azure Blob: $DestinationBlobName in $DestinationContainer could not be Verified."
        Write-Error $ErrorMessage -Category ResourceUnavailable
        throw $ErrorMessage
     }

    # Checkpoint after Azure VM Creation
    Checkpoint-Workflow
    
    # (Re)Connect to Azure and (Re)Select Azure Subscription
    $AzureAccount = Add-AzureAccount -Credential $Cred
    $AzureSubscription = Select-AzureSubscription -SubscriptionName $AzureSubscriptionName

    ####################################################################################################

    ####################################################################################################
    # Create Azure VM
    
    if ($AzureVMImage.OperationStatus -eq "Succeeded" -or $AzureVMImage.ImageName -eq $VMImageName) {

        $AzureVM = Get-AzureVM -Name $VMName -ServiceName $ServiceName -ErrorAction SilentlyContinue
     
        if(!$AzureVM -and $Windows) {
            $AzureVM = New-AzureQuickVM -AdminUsername $AdminUsername -ImageName $VMImageName -Password $Password `
                -ServiceName $ServiceName -Windows:$Windows -InstanceSize $VMInstanceSize -Name $VMName -WaitForBoot:$WaitForBoot
            $VerboseMessage = "{0} for {1} {2} (OperationId: {3})" -f $AzureVM.OperationDescription,$VMName,$AzureVM.OperationStatus,$AzureVM.OperationId
        } else { $VerboseMessage = "Azure VM {0}: Verified" -f $AzureVM.InstanceName }

        Write-Verbose $VerboseMessage

    } else {
        $ErrorMessage = "Azure VM Image Creation Failed OR Could Not Be Verified for: $VMImageName"
        Write-Error $ErrorMessage -Category ResourceUnavailable
        $ErrorMessage = "Azure VM Not Created: $VMName"
        Write-Error $ErrorMessage -Category NotImplemented
        throw $ErrorMessage
     }

    ####################################################################################################

    if ($AzureVM.OperationStatus -eq "Succeeded" -or $AzureVM.InstanceName -eq $VMName) {
        $CompletedNote = "All Steps Completed - All Specified Azure Environment Resources Created."
        Write-Verbose $CompletedNote
        Write-Output $CompletedNote
    } else {
        $ErrorMessage = "Azure VM Creation Failed OR Could Not Be Verified for: $VMName"
        Write-Error $ErrorMessage -Category ResourceUnavailable
        $ErrorMessage = "Not Complete - One or more Specified Azure Environment Resources was NOT Created."
        Write-Error $ErrorMessage -Category NotImplemented
        throw $ErrorMessage
     }
}