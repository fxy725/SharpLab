param (
    [switch] $ServerOnly,
    [switch] $NoCache,
    [switch] $SkipBuild
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$logDirectory = Join-Path $repoRoot '!local'
$ownedProcesses = [Collections.Generic.List[object]]::new()
$savedEnvironment = @{}

function Invoke-Checked([string] $command, [string[]] $arguments) {
    & $command @arguments
    if ($LASTEXITCODE -ne 0) { throw "$command exited with code $LASTEXITCODE." }
}

function Start-LocalService([string] $name, [string] $executable, [string[]] $arguments, [string] $directory) {
    $process = Start-Process -FilePath $executable -ArgumentList $arguments -WorkingDirectory $directory `
        -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $logDirectory "$name.log") `
        -RedirectStandardError (Join-Path $logDirectory "$name.error.log")
    $ownedProcesses.Add([pscustomobject]@{ Name = $name; Process = $process; Started = $process.StartTime })
    Write-Host "Started $name (PID $($process.Id))."
}

Push-Location $repoRoot
try {
    foreach ($key in @('DOTNET_ROLL_FORWARD', 'ASPNETCORE_ENVIRONMENT', 'DOTNET_SYSTEM_NET_HTTP_SOCKETSHTTPHANDLER_HTTP2SUPPORT')) {
        $savedEnvironment[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
    }
    $env:DOTNET_ROLL_FORWARD = 'Major'
    $env:ASPNETCORE_ENVIRONMENT = 'Development'
    $env:DOTNET_SYSTEM_NET_HTTP_SOCKETSHTTPHANDLER_HTTP2SUPPORT = 'false'
    $dotnet = (Get-Command dotnet -ErrorAction Stop).Source
    $node = (Get-Command node -ErrorAction Stop).Source
    $ports = @(44100, 44400)
    if (!$ServerOnly) { $ports += 44200 }
    if (!$NoCache) { $ports += @(10000, 10001, 10002) }
    foreach ($port in $ports) {
        if (Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue) {
            throw "Port $port is already in use. Stop the existing service yourself or reuse the running website."
        }
    }
    foreach ($project in @('WebApp.Server', 'Container.Manager')) {
        $environmentFile = Join-Path $repoRoot "source/$project/.env"
        if (!(Test-Path -LiteralPath $environmentFile)) {
            Copy-Item -LiteralPath "$environmentFile.template" -Destination $environmentFile
        }
    }
    if (!$SkipBuild) {
        Invoke-Checked $dotnet @('build', 'source/WebApp.Server/WebApp.Server.csproj', '-p:NuGetAudit=false', '--verbosity', 'minimal')
        Invoke-Checked $dotnet @('build', 'source/Container.Manager/Container.Manager.csproj', '-p:NuGetAudit=false', '--verbosity', 'minimal')
        if (!$ServerOnly) {
            Push-Location 'source/WebApp'
            try { Invoke-Checked 'npm' @('run', 'build') }
            finally { Pop-Location }
        }
    }
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    # The sandbox must be able to read its own executable and dependencies.
    # This is the same capability-specific permission installed by setup.ps1.
    $containerDirectory = Join-Path $repoRoot 'source/Container.Manager/bin/Debug/net9.0'
    $capability = [Security.Principal.SecurityIdentifier]::new('S-1-15-3-1024-4233803318-1181731508-1220533431-3050556506-2713139869-1168708946-594703785-1824610955')
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
        $capability, [Security.AccessControl.FileSystemRights]::ReadAndExecute,
        ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),
        [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow
    )
    $acl = Get-Acl -LiteralPath $containerDirectory
    $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $containerDirectory -AclObject $acl
    if (!$NoCache) {
        $npmRoot = (& npm root -g | Select-Object -Last 1).Trim()
        $azurite = Join-Path $npmRoot 'azurite/dist/src/azurite.js'
        if (!(Test-Path -LiteralPath $azurite)) { throw 'Azurite is missing. Run npm install -g azurite, or run sl run -NoCache.' }
        $storageDirectory = Join-Path $repoRoot '!azurite'
        New-Item -ItemType Directory -Path $storageDirectory -Force | Out-Null
        Start-LocalService 'azurite' $node @('"' + $azurite + '"', '--location', '"' + $storageDirectory + '"', '--silent') $repoRoot
    }
    if (!$ServerOnly) {
        $assetDirectory = Join-Path $repoRoot 'source/WebApp'
        $httpServer = Join-Path $assetDirectory 'node_modules/http-server/bin/http-server'
        Start-LocalService 'assets' $node @('"' + $httpServer + '"', 'public', '-a', '127.0.0.1', '-p', '44200', '--cors', '-c-1') $assetDirectory
    }
    foreach ($service in @(
        @{ Name = 'containers'; Project = 'Container.Manager'; Assembly = 'SharpLab.Container.Manager'; Port = 44400 },
        @{ Name = 'webapp'; Project = 'WebApp.Server'; Assembly = 'SharpLab.WebApp.Server'; Port = 44100 }
    )) {
        $directory = Join-Path $repoRoot "source/$($service.Project)/bin/Debug/net9.0"
        $assembly = Join-Path $directory "$($service.Assembly).dll"
        Start-LocalService $service.Name $dotnet @('"' + $assembly + '"', '--urls', "http://127.0.0.1:$($service.Port)") $directory
    }
    $ready = $false
    $deadline = [DateTime]::UtcNow.AddMinutes(2)
    while (!$ready -and [DateTime]::UtcNow -lt $deadline) {
        foreach ($service in $ownedProcesses) {
            if ($service.Process.HasExited) { throw "$($service.Name) exited. See $logDirectory/$($service.Name).error.log and .log." }
        }
        try { $ready = (Invoke-WebRequest 'http://localhost:44100/' -TimeoutSec 3).StatusCode -eq 200 }
        catch { Start-Sleep -Milliseconds 500 }
    }
    if (!$ready) { throw "Website did not become ready. See logs in $logDirectory." }
    Write-Host 'SharpLab is ready: http://localhost:44100/' -ForegroundColor Green
    Write-Host "Logs: $logDirectory. Keep this terminal open; Ctrl+C stops these services."
    while ($true) {
        Start-Sleep -Seconds 1
        foreach ($service in $ownedProcesses) {
            if ($service.Process.HasExited) { throw "$($service.Name) exited. See logs in $logDirectory." }
        }
    }
}
finally {
    foreach ($service in $ownedProcesses) {
        $current = Get-Process -Id $service.Process.Id -ErrorAction SilentlyContinue
        if ($current -and $current.StartTime -eq $service.Started) { $current.Kill($true) }
    }
    foreach ($key in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($key, $savedEnvironment[$key], 'Process')
    }
    Pop-Location
}
