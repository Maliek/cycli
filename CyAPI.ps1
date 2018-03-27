﻿<#
.NAME
	Cylance-API

.SYNOPSIS
	A collection of verbs to work with the Cylance Console API v2

.DESCRIPTION
    Allows retrieval and manipulation of configuration objects in the Cylance console using API v2.

    Use:

    Call "Get-CyAPI -SetGlobalScope" to use the same API for subsequent calls
    Get-Devices | Get-DeviceDetails

.LINK
    Blog: http://tietze.io/
    Jan Tietze
#>


<#
    Represents the API handle returned by API after authentication
#>
Class CylanceAPIHandle {
    [string]$AccessToken
    [string]$BaseUri
}

<#
.TODO
    At some point In the future, artifacts for the API will be classes
#>

Class CylanceDevice {
    [string]$Id
}
Class CylanceZone {
    [string]$Id
}
Class CylanceThreat {
    [string]$Id
}

<#
.SYNOPSIS
    Gets an API access token for the authenticated access to the Console API, valid for 30 minutes.

.PARAMETER Id
    Optional. API ID

.PARAMETER Secret
    Optional. API Secret

.PARAMETER TenantId
    Optional. API Tenant ID

.PARAMETER Uri
    Optional. URI to obtain token, e.g. "https://protectapi<-region>.cylance.com/auth/v2/token". Defaults to EUC1 region.

.PARAMETER Scope
    Optional. If you need to access multiple tenants in parallel, use "None" as scope and collect the API object returned.

.PARAMETER Console
    Optional. The console ID in your consoles.json file. See the README for CyCLI module.
#>
function Get-CyAPI {
    Param (
        [parameter(Mandatory=$true, ParameterSetName="Direct")]
        [String]$Id,
        [parameter(Mandatory=$true, ParameterSetName="Direct")]
        [String]$Secret,
        [parameter(Mandatory=$true, ParameterSetName="Direct")]
        [String]$TenantId,
        [parameter(Mandatory=$true, ParameterSetName="Direct")]
        [String]$Uri = "https://protectapi-euc1.cylance.com/auth/v2/token",
        [parameter(Mandatory=$false)]
        [ValidateSet ("Session", "None")]
        [String]$Scope = "Session"
        )
    DynamicParam {
        Get-CyConsoleArgumentAutoCompleter -Mandatory -ParameterName "Console" -ParameterSetName "ByReference"
    }

    Begin {
        switch ($PSCmdlet.ParameterSetName)
        {
            "Direct"
            {
                $claims = @{}

                $jwtBearerToken = Get-JWTToken `
                    -claims $claims `
                    -expirationSeconds 1800 `
                    -secret $Secret `
                    -iss "http://cylance.com" `
                    -tid $TenantId `
                    -APIid $Id

                $payload = @{ "auth_token" = $jwtBearerToken } | ConvertTo-Json

                try {
                   $headers = @{
                        "Accept" = "*/*"
                        }
                    $result = Invoke-RestMethod -Method Post -Uri $Uri -ContentType "application/json; charset=utf-8" -UserAgent "" -Body $payload
                }
                catch {
                    $result = $_.Exception.Response.GetResponseStream()
                    $reader = New-Object System.IO.StreamReader($result)
                    $reader.BaseStream.Position = 0
                    $reader.DiscardBufferedData()
                    $responseBody = $reader.ReadToEnd();
                    Write-Error "Could not get valid API token."
                    if ($Scope -eq "None") {
                        $script:GlobalCyAPIHandle = $null
                    }
                    $_.Exception
                    return
                }

                $baseUri = ([System.Uri]$Uri).Scheme + "://" + ([System.Uri]$Uri).Host

                [CylanceAPIHandle]$r = New-Object CylanceAPIHandle
                $r.AccessToken = $result.access_token
                $r.BaseUri = $baseUri

                if ($Scope -eq "Session") {
                    $script:GlobalCyAPIHandle = $r
                } else {
                    $r
                }
            }
        "ByReference" 
            {
                $ConsoleDetails = (Get-CyConsoleConfig) | Where ConsoleId -eq $PSBoundParameters.Console

                if ($ConsoleDetails.APISecretIsProtected) {
                    # https://social.technet.microsoft.com/wiki/contents/articles/4546.working-with-passwords-secure-strings-and-credentials-in-windows-powershell.aspx
                    $SecureStringPw = $ConsoleDetails.APISecret | ConvertTo-SecureString
                    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureStringPw)
                    $pw = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
                } else {
                    $pw = $ConsoleDetails.APISecret
                }

                if ($ConsoleDetails.APIUrl -ne $null) { $Uri = $ConsoleDetails.APIUrl }
                $args = @{
                    Id = $ConsoleDetails.APIId
                    Secret = $pw
                    TenantId = $ConsoleDetails.APITenantId
                    Scope = $Scope
                    Uri = $Uri
                }
                Get-CyAPI @args
            }
        }
    }

    Process {
    }
}

<#
.SYNOPSIS
    Gets ALL pages for paged query results with maximum page size.

.PARAMETER API
    Optional. API Handle (use only when not using session scope).

.PARAMETER QueryParams
    Optional. If you need to add any query parameters, supply them in a Hashtable.
#>
function Get-CyDataPages {
    Param (
        [parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [CylanceAPIHandle]$API,
        [parameter(Mandatory=$true)]
        [string]$Uri,
        [parameter(Mandatory=$false)]
        [Hashtable]$QueryParams = @{}
        )

    $auth = "Bearer " + $API.AccessToken

    $headers = @{
        "Accept" = "application/json"
        "Authorization" = $auth
    }

    $page = 1
    do {
        $params = @{
            "page" = $page
            "page_size" = 200
        }
        foreach ($key in $QueryParams.Keys) {
            $params.$key = $QueryParams.$key
        }

        foreach ($key in $params.Keys) {
            Write-Verbose "Get-CyDataPages: GET ${Uri} | $($key) = $($params.$key)"
        }
        $resp = Invoke-RestMethod `
            -Method GET `
            -Uri $Uri `
            -Header $headers `
            -UserAgent "" -Body $params `

        $resp.page_items | foreach-object {
            $_ | Convert-CyTypes
        }
        Write-Verbose "Response was page $($resp.page_number) of $($resp.total_pages) pages"

        $page++

    } while ($resp.page_number -lt $resp.total_pages)
}

<#
.SYNOPSIS
    Returns the currently active global CyAPIHandle, if one is set
#>
Function Get-CyAPIHandle {
    $GlobalCyAPIHandle
}


<#
.SYNOPSIS
    Converts a date string as returned from the API to a DateTime object

.PARAMETER Date
    The date string as returned by the API
#>
function Get-CyDateFromString {
    Param (
        [Parameter(Mandatory=$true, Position=1)]
        [String]$Date
    )
    # convert e.g. 2018-03-07T13:21:07 to Date
    # convert e.g. 2018-03-07T13:21:07.123 to Date (date_offline uses fractional seconds)
    return [DateTime]::ParseExact($Date, "yyyy-MM-ddTHH:mm:ss.FFF", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
}

function Convert-CyTypes {
    Param (
        [Parameter(Mandatory=$true, Position=1, ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true)]
        [PSCustomObject]$CyObject
        )
    Begin {
        $fields = @("date_first_registered", "date_offline", "date_last_modified", "date_found", "cert_timestamp", "date_last_login", "date_email_confirmed", "date_created", "date_modified")
    }
    Process {
        foreach ($f in $fields) {
            try {
                if (($CyObject.$f -ne $null) -and ($CyObject.$f -isnot [DateTime])) {
                    $CyObject.$f = Get-CyDateFromString $CyObject.$f
                }
            } catch [FormatException] {
                Write-Error "Problem converting field $($f) to date time (value: $($CyObject.$f))"
            }
        }

        $CyObject
    }
}