param(
  [ValidateSet('Check','Install')]
  [string]$Mode = 'Check',
  [string]$Target = 'C:\Nightwell Music\nightwell-music'
)
$ErrorActionPreference = 'Stop'
try {
  Write-Host ""
  Write-Host "Nightwell Music - latest server fixes" -ForegroundColor Cyan
  Write-Host "Target: $Target"
  $installer = Join-Path -Path $PSScriptRoot -ChildPath 'installer.py'
  if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
    throw "installer.py is missing. Extract the complete ZIP before starting."
  }
  if (-not (Test-Path -LiteralPath (Join-Path $Target 'app.py') -PathType Leaf)) {
    throw "app.py is not found in $Target. Pass the correct server folder as an argument."
  }

  $python = $null
  foreach ($relative in @('.venv\Scripts\python.exe','venv\Scripts\python.exe','python\python.exe','python.exe')) {
    $candidate = Join-Path $Target $relative
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      $python = (Resolve-Path -LiteralPath $candidate).ProviderPath
      break
    }
  }
  $usingLauncher = $false
  if (-not $python) {
    if (Get-Command py.exe -ErrorAction SilentlyContinue) {
      $python = 'py.exe'
      $usingLauncher = $true
    } elseif (Get-Command python.exe -ErrorAction SilentlyContinue) {
      $python = 'python.exe'
    } else {
      throw "Python was not found in the server environment or PATH."
    }
  }

  $pythonArguments = @()
  if ($usingLauncher) { $pythonArguments += '-3' }
  $pythonArguments += $installer
  $pythonArguments += '--check'
  $pythonArguments += '--target'
  $pythonArguments += $Target
  Write-Host "Running compatibility check..." -ForegroundColor Cyan
  & $python @pythonArguments
  if ($LASTEXITCODE -ne 0) {
    throw "Compatibility check failed. Server files were not changed."
  }

  if ($Mode -eq 'Install') {
    Write-Host ""
    $confirmation = Read-Host "Stop the existing server first. Continue with install? (Y/N)"
    if ($confirmation -notmatch '^(?i:y|yes|д|да)$') {
      Write-Host "Installation cancelled."
      exit 0
    }
    $installArguments = @()
    if ($usingLauncher) { $installArguments += '-3' }
    $installArguments += $installer
    $installArguments += '--target'
    $installArguments += $Target
    & $python @installArguments
    if ($LASTEXITCODE -ne 0) {
      throw "Installer failed. Review the error above and the backup folder."
    }
    Write-Host "Restart your server using your ORIGINAL Nightwell start BAT." -ForegroundColor Green
  } else {
    Write-Host "Compatibility check passed. Run Install_Latest_Server.bat after stopping the server." -ForegroundColor Green
  }
  exit 0
}
catch {
  Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}
