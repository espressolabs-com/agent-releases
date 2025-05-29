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
$envArch = $env:PROCESSOR_ARCHITECTURE
$wow64Arch = $env:PROCESSOR_ARCHITEW6432

if ($envArch -eq "ARM64" -or $wow64Arch -eq "ARM64") {
    $arch = "arm64"
} elseif ($envArch -eq "AMD64" -or $wow64Arch -eq "AMD64") {
    $arch = "x64"
} elseif ($envArch -eq "x86") {
    $arch = "x86"
} else {
    $arch = "unknown"
}

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

#### BIT DEFENDER ####

ohai "Downloading BitDefender Installer..."

$bitdefenderScriptURL = "https://expresso-agent-1.s3.us-east-1.amazonaws.com/bitdefender/install_bitdefender.ps1"
$bitdefenderScriptPath = Join-Path $tmpDir "install_bitdefender.ps1"

Write-Host "Using the following values:"
Write-Host "    Bitdefender script URL: $bitdefenderScriptURL"
Write-Host "    Bitdefender script path: $bitdefenderScriptPath"


Invoke-WebRequest -Uri $bitdefenderScriptURL -OutFile $bitdefenderScriptPath

function Execute-BitDefender-Script {

  $paths = @(
      "$env:ProgramFiles(x86)\EspressoLabs\oemsdk.dll",
      "$env:ProgramFiles\EspressoLabs\oemsdk.dll"
  )

  foreach ($path in $paths) {
    if (Test-Path $path) {
      Write-Host "Bitdefender is already installed at $path. Skipping installation." -ForegroundColor Green
      return $true
    }
  }

  try {
    Start-Process powershell -Wait -Verb RunAs -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$bitdefenderScriptPath`""

    return $true
  } catch {
      Write-Host "Bitdefender installation failed: $_" -ForegroundColor Red
      return $false
    }
}

ohai "Running BitDefender Installer..."
$maxAttempts = 3
$attempt = 0
$success = $false

while ($attempt -lt $maxAttempts -and -not $success) {
    $attempt++
    Write-Host "Attempt $attempt of $maxAttempts..."
    $success = Execute-BitDefender-Script
    if (-not $success) {
        Write-Host "Retrying in 5 seconds..." -ForegroundColor Yellow
        Start-Sleep -Seconds 5
    }
}

if (-not $success) {
    Write-Host "BitDefender installation failed after $maxAttempts attempts." -ForegroundColor Red
    exit 1
}

Write-Host "    BitDefender installation completed successfully!" -ForegroundColor Green

ohai "Cleaning up temporary files..."
Remove-Item $bitdefenderScriptPath -Force


#### CHROME EXTENSION ####

ohai "Finding latest chrome-extension version..."

$extensionManifestUrl = "https://expresso-agent-1.s3.us-east-1.amazonaws.com/chrome-extension/latest"
$extensionManifest = Invoke-RestMethod -Uri $extensionManifestUrl
$extensionDownloadUrl = $extensionManifest.Trim()
$extensionFileName = $extensionDownloadUrl.Split('/')[-1]
$extensionDownloadPath = Join-Path $tmpDir $extensionFileName

Write-Host "Using the following values:"
Write-Host "    Chrome extension download URL: $extensionDownloadUrl"
Write-Host "    Chrome extension download path: $extensionDownloadPath"

ohai "Downloading chrome-extension..."
Invoke-WebRequest -Uri $extensionDownloadUrl -OutFile $extensionDownloadPath

ohai "Installing chrome-extension..."
$extensionInstallPath = Join-Path $env:ProgramFiles "EspressoLabs\chrome-extension"

$tempExtractPath = Join-Path $tmpDir "temp-extract"
Expand-Archive -Path $extensionDownloadPath -DestinationPath $tempExtractPath -Force | Out-Null

# Get the nested chrome-extension directory
$nestedFolder = Join-Path $tempExtractPath "chrome-extension"
if (-not (Test-Path $nestedFolder)) {
    Write-Error "Expected chrome-extension directory not found in zip"
    exit 1
}

# Create the extension directory if it doesn't exist
if (-not (Test-Path $extensionInstallPath)) {
    New-Item -ItemType Directory -Path $extensionInstallPath -Force
}

# Copy all contents from the nested directory to the final location
Get-ChildItem -Path $nestedFolder | Copy-Item -Destination $extensionInstallPath -Recurse -Force

# Clean up temp directory
Remove-Item -Path $tempExtractPath -Recurse -Force

ohai "Installation completed successfully!"
Write-Host "Installation log is available at: $logFile"

ohai "You can now enable the Chrome Extension"
Write-Host "    To enable the extension:"
Write-Host "     1. Open Chrome and navigate to 'chrome://extensions/'."
Write-Host "     2. Enable 'Developer mode' (toggle in the top-right corner)."
Write-Host "     3. Click 'Load unpacked' and select the folder: $extensionInstallPath"

