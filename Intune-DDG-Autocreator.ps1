<#
.Author 
    Ali Alame - CYBERSYSTEM
.SYNOPSIS
    Automates the creation of Intune dynamic device groups from a text file of Active Directory OUs.

.DESCRIPTION
    Reads a list of Active Directory Organizational Units (OUs) from a text file,
    connects to Microsoft Graph, and creates one Azure AD dynamic device group
    per OU. The group name follows the format "AZ-OU-Autopilot-DDG", where "OU"
    is the simple name of the OU. The Intune GroupTag for each created group
    is set to the same simple OU name.

.PARAMETER InputFilePath
    The path to the text file containing a list of Active Directory OUs (one per line).

.NOTES
    Requires the RSAT ActiveDirectory module and the Microsoft.Graph.Authentication
    and Microsoft.Graph.Groups PowerShell modules.
#>
param([Parameter(Mandatory=$true)][string]$InputFilePath)

# ---------- 1. Ensure required modules are present -------------------
$graphSub = @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Groups')
foreach ($m in $graphSub) {
    if (-not (Get-Module -ListAvailable -Name $m)) {
        Write-Host "Installing $m..."
        Install-Module $m -Scope CurrentUser -Force -ErrorAction Stop
    }
}
Import-Module Microsoft.Graph.Authentication, Microsoft.Graph.Groups -Force

# ---------- 2. Read OUs from the input file --------------------------
try {
    $OUsFromFile = Get-Content -Path $InputFilePath -ErrorAction Stop
    if (-not $OUsFromFile) {
        Write-Warning "The input file is empty."
        exit
    }
}
catch {
    Write-Error "Error reading file: $($_.Exception.Message)"
    exit
}

# ---------- 3. Connect to Graph ---------------------------------
try {
    Connect-MgGraph -Scopes 'Group.ReadWrite.All' -ErrorAction Stop
}
catch {
    Write-Error "Error connecting to Microsoft Graph: $($_.Exception.Message)"
    exit
}

# ---------- 4. Process each OU and create Dynamic Device Group -----
foreach ($OU in $OUsFromFile) {
    # Extract the simple OU name (assuming canonical path format)
    $SimpleOUName = ($OU -split '/')[-1]

    # Construct the dynamic group name
    $GroupName = "AZ-$SimpleOUName-Autopilot-DDG"

    # Sanitize the group name for MailNickname
    $MailNickname = $GroupName -replace '[^0-9A-Za-z]', ''

    # Build the dynamic membership rule
    $rule = '(device.devicePhysicalIds -any _ -eq "[OrderID]:' + $SimpleOUName + '")'

    $params = @{
        DisplayName                 = $GroupName
        Description                 = "Dynamic device group for OU: $SimpleOUName"
        MailEnabled                 = $false
        MailNickname                = $MailNickname
        SecurityEnabled             = $true
        GroupTypes                  = @('DynamicMembership')
        MembershipRule              = $rule
        MembershipRuleProcessingState = 'On'
    }

    try {
        New-MgGroup @params -ErrorAction Stop
        Write-Host "[+] Group created: $GroupName"
    }
    catch {
        Write-Warning "[-] Could not create group ${GroupName}: $($_.Exception.Message)"
    }
}

Write-Host 'Completed. Dynamic device group creation process finished.'