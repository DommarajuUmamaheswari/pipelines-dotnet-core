<#
.SYNOPSIS
  Builds the project and runs the tests, optionally publishing zip packages for later deployment.
.DESCRIPTION
  Builds the project and runs the tests, optionally publishing zip packages for later deployment.
.PARAMETER $PublishZipToPath
  If specified, the artifacts are zipped and placed into this folder.
.PARAMETER $BuildVerbosity
  The dotnet --verbosity= value: q[uiet], m[inimal], n[ormal], d[etailed], and diag[nostic].
.PARAMETER $SrcBranchName
  The source branch name e.g. "local" or "3123-issue", usually $env:BUILD_SOURCEBRANCHNAME from VSTS.
.PARAMETER $BuildId
  The build ID e.g. 12345, defaults to $env:BUILD_BUILDID from VSTS.
.PARAMETER $BuildDatabasePrefix
  Create and tear down a PostgreSQL database when running the tests. The prefix is combined with $BuildId to generate the actual database name.
.PARAMETER $BuildApimConsumptionDatabase
    Create PostgreSQL database for APIM Consumption.

.INPUTS
  none
.OUTPUTS
  none
.NOTES
  Version:        1.0
  Author:         Adam Chester
  Creation Date:  12/08/2018
  Purpose/Change: Created

.EXAMPLE build.ps1
.EXAMPLE build.ps1 -publish ./artifacts
.EXAMPLE build.ps1 -BuildVerbosity normal -PublishZipToPath C:\temp\publishlocation
.EXAMPLE build.ps1 -BuildVerbosity normal -PublishZipToPath C:\temp\publishlocation -BuildDatabasePrefix testdbprefix
.EXAMPLE build.ps1 -BuildVerbosity normal -PublishZipToPath C:\temp\publishlocation -BuildDatabasePrefix testdbprefix -BuildApimConsumptionDatabase apimdbprefix
#>
Param(
    # If specified, the artifacts are zipped and placed into this folder.
    [Parameter(Mandatory = $false, Position = 1)]
    [System.IO.FileInfo]
    [Alias("publish")]
    $PublishZipToPath = $NULL,

    # The dotnet --verbosity= value: q[uiet], m[inimal], n[ormal], d[etailed], and diag[nostic].
    [Parameter(Mandatory = $false, Position = 2)]
    [string]
    [ValidateSet("quiet", "q", "minimal", "m", "normal", "n", "detailed", "d", "diagnostic", "diag")]
    $BuildVerbosity = "minimal",

    # The source branch name e.g. "local" or "3123-issue", usually $env:BUILD_SOURCEBRANCHNAME from VSTS
    [Parameter(Mandatory = $false, Position = 3)]
    [string]
    $SrcBranchName = $env:BUILD_SOURCEBRANCHNAME,

    # The build ID e.g. 12345, defaults to $env:BUILD_BUILDID from VSTS
    [Parameter(Mandatory = $false, Position = 4)]
    [string]
    $BuildId = $env:BUILD_BUILDID,

    # A prefix combined with $BuildId to generate the PostgreSQL database name.
    [Parameter(Mandatory = $false, Position = 5)]
    [string]
    $BuildDatabasePrefix = $NULL,

    # A prefix combined with $BuildId to generate the PostgreSQL database name for apim consumption.
    [Parameter(Mandatory = $false, Position = 6)]
    [string]
    $BuildApimConsumptionDatabase = $NULL
)

function Compress-File {
    param (
        [string]$name,
        [string]$publishArtifactsPath
    )
    $fileName = [System.IO.Path]::GetFileName("$name.zip")
    $publishedZipFile = [System.IO.Path]::Combine("$ZipAndPublishDestination", "$fileName")
    Write-Host "build: zipping '$publishArtifactsPath' to '$publishedZipFile'"
    Push-Location $publishArtifactsPath
    Compress-Archive -Path "./*" -DestinationPath "$publishedZipFile" -Force
    Pop-Location
    Write-Host "##vso[artifact.upload artifactname=FilesToPublish;]$publishedZipFile"
}

Write-Host "build: Build started"

if ($VerbosePreference) {
    & dotnet --info
}

Push-Location $PSScriptRoot
Write-Host "build: Starting in folder '$PSScriptRoot'"

if (Test-Path ./artifacts) {
    Write-Host "build: Cleaning ./artifacts"
    Remove-Item ./artifacts -Force -Recurse
}

if ($PublishZipToPath) {
    $ZipAndPublishDestination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PublishZipToPath)
    Write-Host "build: Publishing to '$ZipAndPublishDestination'"
}

$branch = @{ $true = $SrcBranchName; $false = $(git symbolic-ref --short -q HEAD) }[$SrcBranchName -ne $NULL];
$revision = @{ $true = "{0:00000}" -f [convert]::ToInt32("0" + $BuildId, 10); $false = "lo" }[$BuildId -ne $NULL];
$suffix = @{ $true = ""; $false = "$($branch.Substring(0, [math]::Min(10,$branch.Length)))-$revision" }[$branch -eq "master" -and $revision -ne "lo"]
$commitHash = $(git rev-parse --short HEAD)
$buildSuffix = @{ $true = "$($suffix)-$($commitHash)"; $false = "$($branch)-$($commitHash)" }[$suffix -ne ""]
$BuildDatabases = ""

Write-Host "build: Package version suffix is $suffix"
Write-Host "build: Build version suffix is $buildSuffix"
if ($BuildDatabasePrefix) {
    $now = Get-Date
    $nowStr = $now.ToUniversalTime().ToString("yyyyMMddHHmmss")

    $BuildDatabaseName = "$nowStr-$BuildDatabasePrefix-$buildSuffix"
  
    Write-Host "build: Managed database $BuildDatabaseName"
    Push-Location -Path "../database/Kmd.Logic.DbAdmin"

    & dotnet run -- create -s kmd-logic-api-build-db -d $BuildDatabaseName -u $BuildDatabaseName -p oQTX2jPgOWwe
    if($LASTEXITCODE -ne 0) { exit 1 }

    # Running database migrations
    & dotnet run -- migrate -s kmd-logic-api-build-db -d $BuildDatabaseName -u $BuildDatabaseName -p oQTX2jPgOWwe -f ../../logic/MigrationScripts
    if($LASTEXITCODE -ne 0) { exit 1 }

    Pop-Location

    # Set the environment variable used by the tests to access the database
    $connString = "Server=kmd-logic-api-build-db.postgres.database.azure.com;Database=$BuildDatabaseName;Port=5432;User Id=$BuildDatabaseName@kmd-logic-api-build-db;Password=oQTX2jPgOWwe;Ssl Mode=Require;"
    
    $Env:KMD_LOGIC_API_ConnectionStrings:LogicDatabase = $connString

    $BuildDatabases = $BuildDatabaseName

}

if($BuildApimConsumptionDatabase){
    $now = Get-Date
    $nowStr = $now.ToUniversalTime().ToString("yyyyMMddHHmmss")

    $ConsumptionDatabase = "$nowStr-$BuildApimConsumptionDatabase-$buildSuffix"
  
    Write-Host "build: Managed database $ConsumptionDatabase"
    Push-Location -Path "../database/Kmd.Logic.DbAdmin"

    & dotnet run -- create -s kmd-logic-api-build-db -d $ConsumptionDatabase -u $ConsumptionDatabase -p oQTX2jPgOWwe
    if($LASTEXITCODE -ne 0) { exit 1 }

    # Running database migrations
    & dotnet run -- migrate -s kmd-logic-api-build-db -d $ConsumptionDatabase -u $ConsumptionDatabase -p oQTX2jPgOWwe -f ../../logic/APIMMigrationScripts
    if($LASTEXITCODE -ne 0) { exit 1 }
    
    Pop-Location

    # Set the environment variable used by the tests to access the database
    $connString = "Server=kmd-logic-api-build-db.postgres.database.azure.com;Database=$ConsumptionDatabase;Port=5432;User Id=$ConsumptionDatabase@kmd-logic-api-build-db;Password=oQTX2jPgOWwe;Ssl Mode=Require;"
    
    $Env:KMD_LOGIC_APIM_ConsumptionDb_ConnectionStrings:ApimConsumptionDatabase = $connString

    $BuildDatabases = $BuildDatabases + "," + $ConsumptionDatabase
}

# Ensure the database name is passed to cleanupdatabase.ps1
if($BuildDatabases)
{
    Write-Host "##vso[task.setvariable variable=BUILD_DATABASE_NAME;]$BuildDatabases"
}

& dotnet build Kmd.Logic.Api.sln -c Release --verbosity="$BuildVerbosity" --version-suffix=$buildSuffix
if($LASTEXITCODE -ne 0) { exit 1 }

foreach ($src in $("Kmd.Logic.Api",
                    "DataServices/Kmd.Logic.DataServices.ExtractProcessor",
                    "CitizenDocuments/Kmd.Logic.CitizenDocuments.Processor",
                    "Sms/Kmd.Logic.Sms.DeliveryProcessor",
                    "Gateway/Kmd.Logic.Gateway.ApimPublishProcessor",
                    "Kmd.Logic.Api.EndToEnd.Tests",
                    "Sms/Kmd.Logic.Sms.TestSender",
                    "Kmd.Logic.NotificationProcessor",
                    "Kmd.Logic.DigitalPost.FakeProvider",
                    "Cpr/Kmd.Logic.Cpr.FakeProvider",
                    "Kmd.Logic.WorkflowNotificationProcessor",
                    "DocumentGeneration/Kmd.Logic.DocumentGeneration.Job")) {
    Push-Location $src

	$publishArtifactsPath = @{ $true = "../artifacts/$src"; $false = "../artifacts/$src" }[$suffix -ne ""]
    Write-Host "build: building output of '$src' into '$publishArtifactsPath'"
    & dotnet publish -c Release --verbosity="$BuildVerbosity" --no-restore --no-build -o $publishArtifactsPath --version-suffix=$suffix
    if($LASTEXITCODE -ne 0) { exit 1 }

    if ($src -eq "Kmd.Logic.Api") {
        Write-Host "build: Copy OpenAPI Spec to `Kmd.Logic.Api` APIM Publish files"
        foreach ($spec in $("sms")) {
            Copy-Item "../Kmd.Logic.Api.Integration.Tests/OpenApiSpec/OpenApiSpecTests.SwaggerJson-$spec.approved.json" -Destination "$publishArtifactsPath\ApimPublish\apis\$spec\$spec-v1.json"
        }
        Move-Item "$publishArtifactsPath\ApimPublish" -Destination "..\artifacts\ApimPublish"
    }

  # Compress (zip) the published output into the $publish folder
	if($ZipAndPublishDestination)
	{
        If(!(test-path $ZipAndPublishDestination))
        {
            Write-Warning "The -ZipAndPublishDestination does not exist, creating '$ZipAndPublishDestination'"
            New-Item -ItemType Directory -Force -Path $ZipAndPublishDestination
        }
        Compress-File $src $publishArtifactsPath
    }

    Pop-Location
}

if ($ZipAndPublishDestination) {
    Write-Host "##vso[artifact.upload containerfolder=DeployScript;artifactname=DeploymentScript;]$PSScriptRoot/deploy.ps1"
    Write-Host "##vso[artifact.upload containerfolder=DeployScript;artifactname=DeploymentScript;]$PSScriptRoot/deploy-webjobs.ps1"
    Write-Host "##vso[artifact.upload containerfolder=DeployScript;artifactname=DeploymentScript;]$PSScriptRoot/deploy-function.ps1"
    Write-Host "##vso[artifact.upload containerfolder=DeployScript;artifactname=DeploymentScript;]$PSScriptRoot/WebJobsStatusCheck.ps1"

    $resGrpSrc = "Kmd.Logic.Api.ResourceGroup"
    $artifactsOutputPath = "../artifacts/$resGrpSrc"

    Push-Location "$resGrpSrc"

    Write-Host "build: Packaging project in '$resGrpSrc'"
    & dotnet build -c Release --verbosity="$BuildVerbosity" --output "$artifactsOutputPath"    
    if($LASTEXITCODE -ne 0) { exit 1 }
    Pop-Location

    $resolvedArtifactsOutputPath = Resolve-Path -Path "$PSScriptRoot/$resGrpSrc/$artifactsOutputPath"

    Push-Location "$PSScriptRoot/../database/Kmd.Logic.DbAdmin"
    Write-Host "build: Packaging project in 'Kmd.Logic.DbAdmin'"
    & dotnet publish -c Release --verbosity="$BuildVerbosity" --output "$resolvedArtifactsOutputPath"
    if($LASTEXITCODE -ne 0) { exit 1 }
    Pop-Location

    Write-Host "build: Copy Lab Migration scripts"
    Copy-Item  "$PSScriptRoot/MigrationScripts" -Destination "$resolvedArtifactsOutputPath/MigrationScripts" -Recurse  
    Copy-Item  "$PSScriptRoot/APIMMigrationScripts" -Destination "$resolvedArtifactsOutputPath/APIMMigrationScripts" -Recurse
    
    Write-Host "build: publishing file '$resolvedArtifactsOutputPath'"
    Write-Host "##vso[artifact.upload containerfolder=ResourceGroupScripts;artifactname=ResourceGroupScripts;]$resolvedArtifactsOutputPath"

    Compress-File "ApimPublish" "artifacts/ApimPublish"
}

foreach ($test in $("Kmd.Logic.Api.Tests",
        "Kmd.Logic.Api.Integration.Tests",
        "Gateway/Kmd.Logic.Gateway.ApimPublishProcessor.Tests",
        "Gateway/Kmd.Logic.Gateway.ApimPublishProcessor.IntegrationTests",
        "Kmd.Logic.DigitalPost.Api.IntegrationTests",
        "Kmd.Logic.DigitalPost.Api.Tests",
        "Cpr/Kmd.Logic.Cpr.Api.IntegrationTests",
        "Cpr/Kmd.Logic.Cpr.Api.Tests")) {

    Push-Location $test

    Write-Host "build: Testing project in '$test'"

    & dotnet test -c Release --no-restore --no-build --logger trx --verbosity="$BuildVerbosity"
    if($LASTEXITCODE -ne 0) { exit 3 }

    Pop-Location
}