# ====== Script Control via Arguments ======
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("init", "destroy")]
    [string]$Action
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Load required assemblies
Add-Type -AssemblyName System.IO.Compression.FileSystem

# ====== Configuration ======
$GITHUB_ORG = ""
$GITHUB_URL = "https://github.com/$GITHUB_ORG"                  # Repository URL
$GITHUB_PAT = ""                                                # GitHub Personal Access Token (repo scope required)
$RUNNER_VERSION = ""                                            # Runner version
$NUM_RUNNERS = 10                                               # Number of parallel runners to create
$BASE_DIR = "$env:USERPROFILE\actions-runners"
$RUNNER_ZIP = "actions-runner-win-x64-$RUNNER_VERSION.zip"      # Name of the runner archive
$RUNNER_GROUP = ""

# Service Account Configuration (optional - leave empty to use current user)
$SERVICE_USERNAME = ""                                          # Domain\Username or Username for service account
$SERVICE_PASSWORD = ""                                          # Password for service account (will be prompted if empty but username provided)
# ============================

# Function to get service credentials
function Get-ServiceCredentials {
    if ([string]::IsNullOrEmpty($SERVICE_USERNAME)) {
        Write-Host "No service account specified. Using current user context." -ForegroundColor Cyan
        return $null
    }
    
    if ([string]::IsNullOrEmpty($SERVICE_PASSWORD)) {
        Write-Host "Service username specified: $SERVICE_USERNAME" -ForegroundColor Cyan
        $securePassword = Read-Host "Enter password for $SERVICE_USERNAME" -AsSecureString
        return New-Object System.Management.Automation.PSCredential($SERVICE_USERNAME, $securePassword)
    }
    else {
        $securePassword = ConvertTo-SecureString $SERVICE_PASSWORD -AsPlainText -Force
        return New-Object System.Management.Automation.PSCredential($SERVICE_USERNAME, $securePassword)
    }
}

# Function to generate registration token using PAT
function Get-RegistrationToken {
    param(
        [string]$GITHUB_ORG,
        [string]$GITHUB_PAT
    )
    
    try {
        # GitHub API endpoint for registration token
        $apiUrl = "https://api.github.com/orgs/$GITHUB_ORG/actions/runners/registration-token"
        
        # Prepare headers
        $headers = @{
            Authorization = "token $GITHUB_PAT"
        }

        Write-Host "Generating registration token for $GITHUB_ORG..." -ForegroundColor Cyan

        # Make API call
        $response = Invoke-RestMethod -Uri $apiUrl -Method Post -Headers $headers
        
        if ($response.token) {
            Write-Host "Registration token generated successfully." -ForegroundColor Green
            return $response.token
        }
        else {
            throw "No token received from GitHub API"
        }
    }
    catch {
        Write-Host "Failed to generate registration token: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.Exception.Response) {
            $statusCode = $_.Exception.Response.StatusCode
            Write-Host "HTTP Status Code: $statusCode" -ForegroundColor Red
            
            if ($statusCode -eq 401) {
                Write-Host "Authentication failed. Please check your Personal Access Token." -ForegroundColor Red
            }
            elseif ($statusCode -eq 403) {
                Write-Host "Access forbidden. Ensure your PAT has 'repo' scope and admin access to the repository." -ForegroundColor Red
            }
            elseif ($statusCode -eq 404) {
                Write-Host "Repository not found. Please check the repository URL." -ForegroundColor Red
            }
        }
        throw
    }
}

# Function to generate removal token using PAT
function Get-RemovalToken {
    param(
        [string]$GITHUB_ORG,
        [string]$GITHUB_PAT
    )
    
    try {
        # GitHub API endpoint for removal token
        $apiUrl = "https://api.github.com/orgs/$GITHUB_ORG/actions/runners/remove-token"
        
        # Prepare headers
        $headers = @{
            Authorization = "token $GITHUB_PAT"
        }

        Write-Host "Generating removal token for $GITHUB_ORG..." -ForegroundColor Cyan

        # Make API call
        $response = Invoke-RestMethod -Uri $apiUrl -Method Post -Headers $headers
        
        if ($response.token) {
            Write-Host "Removal token generated successfully." -ForegroundColor Green
            return $response.token
        }
        else {
            throw "No removal token received from GitHub API"
        }
    }
    catch {
        Write-Host "Failed to generate removal token: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

# Function to initialize and start all runners
function Initialize-Runners {
    # Ensure base directory exists
    if (!(Test-Path $BASE_DIR)) {
        New-Item -ItemType Directory -Path $BASE_DIR -Force | Out-Null
    }
    Set-Location $BASE_DIR

    # Download the runner archive, verify it's valid, or re-download if corrupted
    $runnerZipPath = Join-Path $BASE_DIR $RUNNER_ZIP
    $needsDownload = $false
    
    if (!(Test-Path $runnerZipPath)) {
        $needsDownload = $true
        Write-Host "Runner archive not found. Downloading..." -ForegroundColor Cyan
    }
    else {
        # Test if the ZIP file is valid
        try {
            $null = [System.IO.Compression.ZipFile]::OpenRead($runnerZipPath)
            Write-Host "Runner $RUNNER_VERSION already downloaded and verified." -ForegroundColor Green
        }
        catch {
            Write-Host "Existing runner archive is corrupted. Re-downloading..." -ForegroundColor Yellow
            Remove-Item $runnerZipPath -Force -ErrorAction SilentlyContinue
            $needsDownload = $true
        }
    }
    
    if ($needsDownload) {
        Write-Host "Downloading runner version $RUNNER_VERSION ..." -ForegroundColor Cyan
        $downloadUrl = "https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/$RUNNER_ZIP"
        try {
            Invoke-WebRequest -Uri $downloadUrl -OutFile $runnerZipPath -UseBasicParsing
            
            # Verify the downloaded file
            $null = [System.IO.Compression.ZipFile]::OpenRead($runnerZipPath)
            Write-Host "Runner downloaded and verified successfully." -ForegroundColor Green
        }
        catch {
            Write-Host "Failed to download or verify runner: $($_.Exception.Message)" -ForegroundColor Red
            if (Test-Path $runnerZipPath) {
                Remove-Item $runnerZipPath -Force
            }
            exit 1
        }
    }

    # Generate registration token for this batch of runners
    Write-Host "Generating registration token..." -ForegroundColor Cyan
    try {
        $registrationToken = Get-RegistrationToken -GITHUB_ORG $GITHUB_ORG -GITHUB_PAT $GITHUB_PAT
    }
    catch {
        Write-Host "Failed to generate registration token. Exiting." -ForegroundColor Red
        exit 1
    }

    # Create, configure, and start each runner
    for ($i = 1; $i -le $NUM_RUNNERS; $i++) {
        $RUNNER_NAME = "windows-a$i"
        $RUNNER_DIR = Join-Path $BASE_DIR $RUNNER_NAME

        Write-Host "Creating $RUNNER_NAME in $RUNNER_DIR ..." -ForegroundColor Yellow
        
        # Create runner directory
        if (!(Test-Path $RUNNER_DIR)) {
            New-Item -ItemType Directory -Path $RUNNER_DIR -Force | Out-Null
        }
        Set-Location $RUNNER_DIR

        # Copy the runner archive into this runner directory
        Copy-Item $runnerZipPath -Destination $RUNNER_DIR

        # Extract the runner
        Write-Host "Extracting runner ..." -ForegroundColor Yellow
        try {
            Expand-Archive -Path (Join-Path $RUNNER_DIR $RUNNER_ZIP) -DestinationPath $RUNNER_DIR -Force
        }
        catch {
            Write-Host "Failed to extract runner: $($_.Exception.Message)" -ForegroundColor Red
            continue
        }

        # Configure the runner
        Write-Host "Configuring runner $RUNNER_NAME ..." -ForegroundColor Yellow
        try {
            # Get service credentials if specified
            $credentials = Get-ServiceCredentials
            
            if ($credentials) {
                Write-Host "Configuring runner with service account: $($credentials.UserName)" -ForegroundColor Cyan
                # Configure runner with service option and custom credentials
                & ".\config.cmd" --unattended `
                                --url $GITHUB_URL `
                                --token $registrationToken `
                                --name $RUNNER_NAME `
                                --runnergroup $RUNNER_GROUP `
                                --work "_work" `
                                --no-default-labels `
                                --labels "infra-multi-seed-windows-runner" `
                                --replace `
                                --runasservice `
                                --windowslogonaccount $credentials.UserName `
                                --windowslogonpassword $credentials.GetNetworkCredential().Password
            }
            else {
                Write-Host "Configuring runner with current user context" -ForegroundColor Cyan
                # Configure runner with service option using current user
                & ".\config.cmd" --unattended `
                                --url $GITHUB_URL `
                                --token $registrationToken `
                                --name $RUNNER_NAME `
                                --runnergroup $RUNNER_GROUP `
                                --work "_work" `
                                --no-default-labels `
                                --labels "infra-multi-seed-windows-runner" `
                                --replace `
                                --runasservice
            }

            if ($LASTEXITCODE -ne 0) {
                Write-Host "Failed to configure runner $RUNNER_NAME" -ForegroundColor Red
                continue
            }
            
            Write-Host "Runner $RUNNER_NAME configured successfully as a service." -ForegroundColor Green
        }
        catch {
            Write-Host "Failed to configure runner $RUNNER_NAME $($_.Exception.Message)" -ForegroundColor Red
            continue
        }

        # Start the service using PowerShell cmdlets
        Write-Host "Starting $RUNNER_NAME service ..." -ForegroundColor Yellow
        try {
            # Check if running as administrator
            if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
                Write-Host "Administrator privileges required to manage services." -ForegroundColor Yellow
            }

            # Get the service name pattern (GitHub creates services with pattern actions.runner.*)
            $serviceName = "actions.runner.*$RUNNER_NAME*"
            
            # Wait a moment for the service to be registered
            Start-Sleep -Seconds 2
            
            # Start the service
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if ($service) {
                Start-Service -Name $service.Name
                Write-Host "$RUNNER_NAME service started successfully!" -ForegroundColor Green
                
                # Verify service status
                $serviceStatus = Get-Service -Name $service.Name
                Write-Host "Service status: $($serviceStatus.Status)" -ForegroundColor Cyan
            }
            else {
                Write-Host "Warning: Could not find service for $RUNNER_NAME. Service may not have been created properly." -ForegroundColor Yellow
            }
        }
        catch {
            Write-Host "Failed to start service for $RUNNER_NAME`: $($_.Exception.Message)" -ForegroundColor Red
        }

        Set-Location $BASE_DIR
    }

    Write-Host "All $NUM_RUNNERS runners have been processed!" -ForegroundColor Green
}

# Function to stop, uninstall, and remove all runners
function Remove-Runners {
    if (!(Test-Path $BASE_DIR)) {
        Write-Host "Runner base directory ($BASE_DIR) not found. Aborting." -ForegroundColor Red
        exit 1
    }

    Write-Host "Cleaning up all runners in $BASE_DIR ..." -ForegroundColor Yellow

    for ($i = 1; $i -le $NUM_RUNNERS; $i++) {
        $RUNNER_NAME = "windows-a$i"
        $RUNNER_DIR = Join-Path $BASE_DIR $RUNNER_NAME

        if (Test-Path $RUNNER_DIR) {
            Write-Host "Stopping and uninstalling service for $RUNNER_NAME ..." -ForegroundColor Yellow
            Set-Location $RUNNER_DIR
            
            try {
                # Find and stop the service using PowerShell cmdlets
                $serviceName = "actions.runner.*$RUNNER_NAME*"
                $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
                
                if ($service) {
                    Write-Host "Found service: $($service.Name)" -ForegroundColor Cyan
                    
                    # Stop the service if it's running
                    if ($service.Status -eq 'Running') {
                        Write-Host "Stopping service $($service.Name)..." -ForegroundColor Yellow
                        Stop-Service -Name $service.Name -Force
                        Write-Host "Service stopped successfully." -ForegroundColor Green
                    }
                    
                    # Remove the service using sc.exe (Windows Service Control)
                    Write-Host "Removing service $($service.Name)..." -ForegroundColor Yellow
                    $deleteResult = & sc.exe delete $service.Name
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "Service removed successfully." -ForegroundColor Green
                    }
                    else {
                        Write-Host "Warning: Failed to remove service. Exit code: $LASTEXITCODE" -ForegroundColor Yellow
                        Write-Host "Output: $deleteResult" -ForegroundColor Yellow
                    }
                }
                else {
                    Write-Host "No service found for $RUNNER_NAME, skipping service cleanup." -ForegroundColor Yellow
                }
            }
            catch {
                Write-Host "Error managing service for $RUNNER_NAME`: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-Host "Attempting manual cleanup..." -ForegroundColor Yellow
                
                # Generate a removal token for proper cleanup
                try {
                    $removalToken = Get-RemovalToken -GITHUB_ORG $GITHUB_ORG -GITHUB_PAT $GITHUB_PAT
                    & ".\config.cmd" remove --token $removalToken
                    Write-Host "Runner configuration removed manually." -ForegroundColor Green
                }
                catch {
                    Write-Host "Manual cleanup also failed: $($_.Exception.Message)" -ForegroundColor Red
                    Write-Host "Note: Runner may need to be manually removed from GitHub." -ForegroundColor Yellow
                }
            }

            Write-Host "Deleting directory $RUNNER_DIR ..." -ForegroundColor Yellow
            Set-Location $BASE_DIR
            try {
                Remove-Item -Path $RUNNER_DIR -Recurse -Force
            }
            catch {
                Write-Host "Failed to delete $RUNNER_DIR`: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
        else {
            Write-Host "$RUNNER_DIR does not exist, skipping." -ForegroundColor Yellow
        }
    }

    Write-Host "All runners have been removed." -ForegroundColor Green
}

# Function to show script usage
function Show-Usage {
    Write-Host "Invalid parameter. Usage:" -ForegroundColor Yellow
    Write-Host "  .\Setup-MultiRunners.ps1 init     # Creates and starts runners" -ForegroundColor White
    Write-Host "  .\Setup-MultiRunners.ps1 destroy   # Stops, uninstalls and removes all runners" -ForegroundColor White
}

switch ($Action) {
    "init" {
        Write-Host "Initializing GitHub Actions runners..." -ForegroundColor Green
        Initialize-Runners
    }
    "destroy" {
        Write-Host "Removing GitHub Actions runners..." -ForegroundColor Red
        Remove-Runners
    }
    default {
        Show-Usage
        exit 1
    }
}
