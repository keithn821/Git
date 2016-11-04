<#
.SYNOPSIS 
    Demonstrates backing up an Azure VM to an Azure storage account by using Azure Automation.  

.DESCRIPTION
    The following script will connect to an Azure VM, stop the VM, back it up to a storage account, and start the VM.
    
    Dependencies
        Connect-Azure runbook:  http://gallery.technet.microsoft.com/scriptcenter/Connect-to-an-Azure-f27a81bb  
        Connect-AzureVM runbook:  http://gallery.technet.microsoft.com/scriptcenter/Connect-to-an-Azure-85f0782c  
        Daniele Grandini's PowerShell Module: http://gallery.technet.microsoft.com/Powershell-module-for-b46c9b62#content
        Automation Certificate Asset containing the management certificate loaded to Azure
        Automation Connection Asset containing the subscription id & name of the certificate asset


.PARAMETER AzureConnectionName
Name of the Azure Subscription defined in the Connect-Azure runbook.  Reference my post for more information: http://blogs.technet.com/b/cbernier/archive/2014/04/08/microsoft-azure-automation.aspx

.PARAMETER ServiceName
Cloud Service the Azure VM is running under.

.PARAMETER VMName
Name of the Virtual Machine in Azure.

.PARAMETER StorageAccountName
Name of the Azure Storage Account to back up the VM to.

.PARAMETER backupContainerName
Name of the Container withing the Storage Account the VM will be backed up to.
#>


workflow BackupAzureVM

{

Param

(

[parameter(Mandatory=$true)]

[String]

$AzureConnectionName,

[parameter(Mandatory=$true)]

[String]

$ServiceName,

[parameter(Mandatory=$true)]

[String]

$VMName,

[parameter(Mandatory=$true)]

[String]

$StorageAccountName,

[parameter(Mandatory=$true)]

[String]

$backupContainerName

)

# Set up Azure connection by calling the Connect-Azure runbook, found in my previous post.

$Uri = Connect-AzureVM -AzureConnectionName $AzureConnectionName -serviceName $ServiceName -VMName $VMName

# Stop Azure VM

Stop-AzureVM -ServiceName $ServiceName -Name $VMName –StayProvisioned

# Backup Azure VM

Backup-AzureVM -serviceName $ServiceName -VMName $VMName -backupContainerName $backupContainerName -backupStorageAccountName $StorageAccountName –includeDataDisks

# Start Azure VM

Start-AzureVM -ServiceName $ServiceName -Name $VMName

}