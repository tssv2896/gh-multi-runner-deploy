# gh-multi-runner-deploy

This project provides a PowerShell script to automate the deployment and removal of multiple self-hosted GitHub Actions runners on Windows.

## Features
- Deploys multiple runners in parallel as Windows services
- Supports both initialization and cleanup (destroy) of runners
- Handles service account credentials and GitHub API tokens

## Prerequisites
- Windows OS
- PowerShell 5.1 or later
- GitHub Personal Access Token (PAT) with `repo` and `admin:org` scope

## Configuration
Edit the following variables at the top of `Setup-MultiRunners.ps1` before running:

- `$GITHUB_ORG` - Your GitHub organization name
- `$GITHUB_PAT` - Your GitHub Personal Access Token
- `$RUNNER_VERSION` - The version of the GitHub Actions runner to install (e.g., `2.316.0`)
- `$NUM_RUNNERS` - Number of runners to deploy (default: 10)
- `$RUNNER_GROUP` - (Optional) Runner group name
- `$SERVICE_USERNAME` and `$SERVICE_PASSWORD` - (Optional) Service account credentials

## Usage
Open PowerShell as Administrator and run:

### To initialize (deploy) runners:
```powershell
./Setup-MultiRunners.ps1 -Action init
```

### To destroy (remove) all deployed runners:
```powershell
./Setup-MultiRunners.ps1 -Action destroy
```

## Notes
- The script will prompt for a password if a service username is provided but no password is set.
- Each runner is installed as a Windows service and labeled for easy identification.
- Ensure your PAT and organization name are correct to avoid API errors.

---
For more details, see comments in `Setup-MultiRunners.ps1`.
