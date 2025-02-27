
param(
    [string]$backendHost,
    [string]$token
)
# Disable StrictMode in this script
Set-StrictMode -Off

# Check for --help flag and display usage information
if ($args -contains '--help') {
    Write-Host "Usage: .\install.ps1 [-backendHost <backendHost>] [-token <token>]"
    Write-Host ""
    Write-Host "Parameters:"
    Write-Host "  -backendHost <backendHost>  The backend host to pass to the installer"
    Write-Host "  -token <token>              The installation token required by the installer"
    Write-Host ""
    Write-Host "This script downloads the latest release from the espressolabs-com/agent-releases GitHub repo,"
    Write-Host "installs the agent using the provided parameters, and verifies the installed version."
    exit 0
}

function ohai {
    param(
        [string]$message
    )
    Write-Host "==>" -ForegroundColor Blue -NoNewline
    Write-Host " $message"
}
function Test-IsAdmin {
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

ohai "Checking for required privileges..."
# Check if the script is running with administrator privileges
if (-not (Test-IsAdmin)) {
    Write-Host "This script requires administrator privileges!" -ForegroundColor Red
    exit 1
} else {
    Write-Host "    Administrator privileges confirmed!" -ForegroundColor Green
}

ohai "Installing the EspressoLabs Agent..."

# If arguments are not provided, prompt the user
if (-not $backendHost) {
    $backendHost = Read-Host "Enter the backend host"
}

if (-not $token) {
    $token = Read-Host "Enter the token"
}

Write-Host "Using the following values:"
Write-Host "    Backend host: $backendHost"
Write-Host "           Token: $token"

# Define GitHub API URL
$repo = "espressolabs-com/agent-releases"
$apiUrl = "https://api.github.com/repos/$repo/releases/latest"

ohai "Downloading the latest release from GitHub..."
# Get the latest release data from GitHub
$response = Invoke-RestMethod -Uri $apiUrl

# Extract version and remove 'v' prefix if it exists
$version = $response.tag_name -replace '^v', ''

# Extract version and asset name based on architecture
$arch = if ([System.Environment]::Is64BitOperatingSystem) { "x64" } else { "x86" }

# Find the correct MSI asset from the release
$asset = $response.assets | Where-Object { $_.name -match "-$arch\.msi$" }

if (-not $asset) {
    Write-Error "No asset found for architecture $arch"
    exit 1
}

Write-Host "Found latest release:"
Write-Host "         Name: $($response.name)"
Write-Host "      Version: $version"
Write-Host "    Installer: $($asset.name)"

# Create a temporary directory to store the MSI
$tmpDir = New-Item -ItemType Directory -Force -Path (Join-Path $env:TEMP "agent-install")
$tmpMsiPath = Join-Path $tmpDir $asset.name

# Download the MSI asset
ohai "Downloading the MSI asset..."
$ProgressPreference = 'Continue'
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmpMsiPath

Unblock-File -Path $tmpMsiPath

function Uninstall-ExistingVersion {
    ohai "Checking for previous installation..."
    $installedApp = Get-WmiObject -Query "SELECT * FROM Win32_Product WHERE Name LIKE 'espresso-agent%'" | Select-Object -First 1

    if ($installedApp) {
        ohai "Uninstalling existing version: $($installedApp.Version)"
        
        Start-Process -FilePath "msiexec.exe" -ArgumentList "/x $($installedApp.IdentifyingNumber) /quiet /norestart" -Wait -NoNewWindow
        
        # Verify uninstallation
        $checkApp = Get-WmiObject -Query "SELECT * FROM Win32_Product WHERE Name LIKE 'espresso-agent%'" | Select-Object -First 1
        if ($checkApp) {
            Write-Error "Failed to uninstall existing version!"
            exit 1
        }

        Write-Host "Previous version uninstalled successfully."
    } else {
        Write-Host "No previous version found."
    }
}
# Run uninstallation before installing the new version
Uninstall-ExistingVersion

$logFile = "$env:TEMP\espresso-agent-install.log"
$msiArgs = "/i `"$tmpMsiPath`" /quiet /norestart /L*V `"$logFile`" BACKEND_HOST=`"$backendHost`" TOKEN=`"$token`""

# Ensure the command is properly formatted
ohai "Installing the agent..."

# Run the installation with cmd /c to properly handle msiexec arguments
cmd /c "msiexec.exe $msiArgs"

$exitCode = $LASTEXITCODE
# Check exit code properly
if ($exitCode -ne 0) {
    Write-Error "MSI installation failed with exit code $exitCode. Check the log: $logFile"
    exit 1
}

ohai "Installation completed successfully!"

# Define possible installation paths
$installPaths = @(
    "${env:ProgramFiles}\EspressoLabs\espresso-agent.exe",
    "${env:ProgramFiles(x86)}\EspressoLabs\espresso-agent.exe"
)

# Find the correct path where espresso-agent.exe exists
$agentPath = $installPaths | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $agentPath) {
    Write-Error "Could not find espresso-agent.exe in any known install locations."
    exit 1
}
# Verify the installed agent version
ohai "Verifying the installed agent version"
$installedVersion = & $agentPath --version

# Check if the installed version contains the expected version as a substring
if ($installedVersion -match "\b$expectedVersion\b") {
    ohai "Version match: Installed version $installedVersion is correct."
} else {
    Write-Error "Version mismatch: Installed version is $installedVersion, expected $expectedVersion."
    exit 1
}

ohai "Installation completed successfully!"
Write-Host "Installation log is available at: $logFile"
