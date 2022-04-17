<#
    .DESCRIPTION
        A runbook which starts the secondary WLS cluster for disaster recovery

    .NOTES
        AUTHOR: Jianguo Ma
        LASTEDIT: Apr 17, 2022
#>

Param (
	[Parameter(Mandatory = $false)]
    [Object] $webhookData,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()]
    [String] $secondaryPostgreSQLServerRG,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()]
    [String] $secondaryPostgreSQLServerName,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()]
    [String] $secondaryWLSClusterRG,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()]
    [String] $secondaryAdminVMName,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()]
    [String] $secondaryAdminConsoleURI,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()]
    [String] $secondaryManagedVMsNameList,
	[Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()]
    [String] $trafficMgrRG,
	[Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()]
    [String] $profileName,
	[Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()]
    [String] $endpointName
)

# Connect to Azure with system-assigned managed identity (automation account)
Connect-AzAccount -Identity

$startTime = $(get-date)
Write-Output("${startTime}: Starting to boot the secondary cluster...")

# Start the admin VM in the secondary cluster
Write-Output("$(get-date): Starting admin VM in the secondary cluster asynchronouslly...")
Start-AzVM -ResourceGroupName $secondaryWLSClusterRG -Name $secondaryAdminVMName -NoWait
Write-Output("$(get-date): Started admin VM in the secondary cluster asynchronouslly.")

# Promote the replica to a standalone PostgreSQL server
Write-Output("$(get-date): Starting to promote the replica to a standalone PostgreSQL server...")
Update-AzPostgreSqlServer -ResourceGroupName $secondaryPostgreSQLServerRG -Name $secondaryPostgreSQLServerName -ReplicationRole None
Write-Output("$(get-date): Completed to promote the replica to a standalone PostgreSQL server.")

# Wait until admin console is accessible
while ($true)
{
    try {
        $statusCode = (Invoke-WebRequest -URI $secondaryAdminConsoleURI -UseBasicParsing).StatusCode
        if ($statusCode -eq 200) {
            Write-Output("$(get-date): Successfully connect to ${secondaryAdminConsoleURI}.")
            break
        } else {
            Write-Output("$(get-date): Unexpected response status code ${statusCode} received from ${secondaryAdminConsoleURI}.")
            Start-Sleep -s 5
        }
    } catch {
        Write-Output("$(get-date): Unable to connect to ${secondaryAdminConsoleURI}.")
        Start-Sleep -s 5
    }
}

# Start managed servers of the cluster in parallel
$vmList = $secondaryManagedVMsNameList.Split(",")
foreach ($vm in $vmList)
{
	Write-Output("$(get-date): Starting ${vm} in the secondary cluster asynchronouslly...")
	Start-AzVM -ResourceGroupName $secondaryWLSClusterRG -Name $vm -NoWait
	Write-Output("$(get-date): Started ${vm} in the secondary cluster asynchronouslly.")
}

# Wait until the endpoint of the Azure Traffic Manager is online
while ($true)
{
	$endpointState = (Get-AzTrafficManagerEndpoint -Name $endpointName -ProfileName $profileName -ResourceGroupName $trafficMgrRG -Type AzureEndpoints).EndpointMonitorStatus
	Write-Output("$(get-date): ${endpointName} is in '${endpointState}' state.")
	if ($endpointState -eq "Online") {
		break
	} else {
		Start-Sleep -s 5
	}
}

$endTime = $(get-date)
Write-Output("${endTime}: Completed to boot the secondary cluster.")
$elapsedTime = $endTime - $StartTime
$totalTime = "{0:HH:mm:ss}" -f ([datetime]$elapsedTime.Ticks)
Write-Output("The RTO is about ${totalTime} (the time for triggering the DR alert by Azure Traffic Manager is not counted).")
