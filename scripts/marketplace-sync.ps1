<#
.SYNOPSIS
    Marketplace sync — pull, validate, rebuild generated files, push.
    Ensures data integrity across multiple machines sharing the same repo.
    Per MK-15 (Marketplace Sync Protocol).
.USAGE
    government/kernel/marketplace-sync.ps1              # Full sync cycle
    government/kernel/marketplace-sync.ps1 -ValidateOnly # Just validate, no git
    government/kernel/marketplace-sync.ps1 -Rebuild      # Rebuild generated files only
#>

param(
    [switch]$ValidateOnly,
    [switch]$Rebuild
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\resolve-market-paths.ps1"

$auditFile = $script:MarketPaths.Audit
$timestamp = Get-Timestamp
$hostname = Get-MarketHostname

function Write-Audit {
    param([string]$Action, [string]$Detail, [string]$Status)
    $entry = @{
        timestamp = $timestamp
        machine   = $hostname
        action    = $Action
        detail    = $Detail
        status    = $Status
    } | ConvertTo-Json -Compress
    Add-Content -Path $auditFile -Value $entry -Encoding UTF8
}

function Validate-JsonFile {
    param([string]$Path)
    try {
        Get-Content $Path -Raw | ConvertFrom-Json | Out-Null
        return $true
    } catch {
        return $false
    }
}

Write-Host "`n=== MARKETPLACE SYNC ===" -ForegroundColor Cyan
Write-Host "Machine: $hostname | Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor White

# --- Step 1: Git Pull ---
if (-not $ValidateOnly -and -not $Rebuild) {
    Write-Host "`n[1/5] Pulling latest from remote..." -ForegroundColor Yellow
    if ($script:IsSubmodule -and $script:UniverseRoot) {
        Push-Location $script:UniverseRoot
        try {
            $pullResult = git pull --rebase 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  Git pull failed: $pullResult" -ForegroundColor Red
                Write-Audit "sync.pull" "Git pull failed: $pullResult" "fail"
                Pop-Location
                exit 1
            }
            Write-Host "  $pullResult" -ForegroundColor White
            Write-Audit "sync.pull" "Pull successful" "ok"
        } finally {
            Pop-Location
        }
    } else {
        Write-Host "  Running standalone — skipping git pull" -ForegroundColor DarkGray
    }
} else {
    Write-Host "`n[1/5] Skipping git pull ($( if ($ValidateOnly) {'validate-only'} else {'rebuild'} ))" -ForegroundColor DarkGray
}

# --- Step 2: Validate marketplace files (MK-16) ---
Write-Host "`n[2/5] Validating marketplace integrity..." -ForegroundColor Yellow
$errors = @()
$warnings = @()

# Validate per-entry directories exist
$openingsDir = $script:MarketPaths.Openings
$contractsDir = $script:MarketPaths.Contracts
$txnDir = $script:MarketPaths.Transactions

foreach ($dir in @($openingsDir, $contractsDir, $txnDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $warnings += "Created missing directory: $(Split-Path $dir -Leaf)/"
    }
}

# Validate all JSON files in openings/
$openingCount = 0
if (Test-Path $openingsDir) {
    Get-ChildItem -Path $openingsDir -Filter "*.json" -ErrorAction SilentlyContinue | ForEach-Object {
        if (-not (Validate-JsonFile $_.FullName)) {
            $errors += "Malformed JSON: openings/$($_.Name)"
        } else {
            $openingCount++
        }
    }
}

# Validate all JSON files in contracts/
$contractCount = 0
$activeContracts = @()
if (Test-Path $contractsDir) {
    Get-ChildItem -Path $contractsDir -Filter "*.json" -ErrorAction SilentlyContinue | ForEach-Object {
        if (-not (Validate-JsonFile $_.FullName)) {
            $errors += "Malformed JSON: contracts/$($_.Name)"
        } else {
            $contractCount++
            $contract = Get-Content $_.FullName -Raw | ConvertFrom-Json
            if ($contract.status -eq "active" -or $contract.status -eq "completed") {
                $activeContracts += $contract
            }
        }
    }
}

# Validate transaction workspaces
$txnCount = 0
if (Test-Path $txnDir) {
    Get-ChildItem -Path $txnDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $txnCount++
        $contractFile = Join-Path $_.FullName "contract.json"
        $escrowFile = Join-Path $_.FullName "escrow.json"
        $logFile = Join-Path $_.FullName "log.json"

        if (-not (Test-Path $contractFile)) { $warnings += "TXN $($_.Name): missing contract.json" }
        if (-not (Test-Path $escrowFile)) { $warnings += "TXN $($_.Name): missing escrow.json" }
        if (-not (Test-Path $logFile)) { $warnings += "TXN $($_.Name): missing log.json" }

        foreach ($f in @($contractFile, $escrowFile, $logFile)) {
            if ((Test-Path $f) -and -not (Validate-JsonFile $f)) {
                $errors += "Malformed JSON: $($_.Name)/$(Split-Path $f -Leaf)"
            }
        }
    }
}

# Check for duplicate IDs
$openingIds = @()
if (Test-Path $openingsDir) {
    Get-ChildItem -Path $openingsDir -Filter "*.json" -ErrorAction SilentlyContinue | ForEach-Object {
        $id = $_.BaseName
        if ($openingIds -contains $id) { $errors += "Duplicate opening ID: $id" }
        $openingIds += $id
    }
}

$contractIds = @()
if (Test-Path $contractsDir) {
    Get-ChildItem -Path $contractsDir -Filter "*.json" -ErrorAction SilentlyContinue | ForEach-Object {
        $id = $_.BaseName
        if ($contractIds -contains $id) { $errors += "Duplicate contract ID: $id" }
        $contractIds += $id
    }
}

# Report validation
if ($errors.Count -gt 0) {
    Write-Host "  ERRORS ($($errors.Count)):" -ForegroundColor Red
    foreach ($e in $errors) { Write-Host "    $e" -ForegroundColor Red }
    Write-Audit "sync.validate" "$($errors.Count) errors found" "fail"
} else {
    Write-Host "  No errors" -ForegroundColor Green
}

if ($warnings.Count -gt 0) {
    Write-Host "  WARNINGS ($($warnings.Count)):" -ForegroundColor Yellow
    foreach ($w in $warnings) { Write-Host "    $w" -ForegroundColor Yellow }
}

Write-Host "  Openings: $openingCount | Contracts: $contractCount | Transactions: $txnCount" -ForegroundColor White

if ($ValidateOnly) {
    Write-Host "`n=== VALIDATION COMPLETE ===" -ForegroundColor Cyan
    exit $(if ($errors.Count -gt 0) { 1 } else { 0 })
}

# --- Step 3: Rebuild generated files ---
Write-Host "`n[3/5] Rebuilding generated files..." -ForegroundColor Yellow

# Rebuild marketplace.json from company profiles
$syncScript = Join-Path $PSScriptRoot "sync-marketplace.ps1"
if (Test-Path $syncScript) {
    try {
        & $syncScript 2>&1 | Out-Null
        Write-Host "  marketplace.json rebuilt from company profiles" -ForegroundColor White
    } catch {
        $warnings += "Failed to rebuild marketplace.json: $_"
        Write-Host "  WARN: marketplace.json rebuild failed" -ForegroundColor Yellow
    }
}

# Rebuild reputation.json from completed contracts
$repScript = Join-Path $PSScriptRoot "marketplace-reputation.ps1"
if (Test-Path $repScript) {
    try {
        & $repScript 2>&1 | Out-Null
        Write-Host "  reputation.json rebuilt from contract outcomes" -ForegroundColor White
    } catch {
        $warnings += "Failed to rebuild reputation.json: $_"
        Write-Host "  WARN: reputation.json rebuild failed" -ForegroundColor Yellow
    }
}

Write-Audit "sync.rebuild" "Generated files rebuilt" "ok"

if ($Rebuild) {
    Write-Host "`n=== REBUILD COMPLETE ===" -ForegroundColor Cyan
    exit 0
}

# --- Step 4: Stage and commit ---
Write-Host "`n[4/5] Staging changes..." -ForegroundColor Yellow
if ($script:IsSubmodule -and $script:UniverseRoot) {
    Push-Location $script:UniverseRoot
    try {
        git add "Companies/market/" 2>&1 | Out-Null

        $status = git diff --cached --stat 2>&1
        if ($status) {
            Write-Host "  Changes detected:" -ForegroundColor White
            Write-Host "  $status" -ForegroundColor White

            git commit -m "marketplace sync: $hostname $(Get-Date -Format 'yyyy-MM-dd HH:mm')" 2>&1 | Out-Null
            Write-Host "  Committed" -ForegroundColor Green
            Write-Audit "sync.commit" "Changes committed" "ok"
        } else {
            Write-Host "  No changes to commit" -ForegroundColor DarkGray
        }
    } finally {
        Pop-Location
    }
} else {
    Write-Host "  Running standalone — skipping git operations" -ForegroundColor DarkGray
}

# --- Step 5: Push ---
Write-Host "`n[5/5] Pushing to remote..." -ForegroundColor Yellow
if ($script:IsSubmodule -and $script:UniverseRoot) {
    Push-Location $script:UniverseRoot
    try {
        $pushResult = git push 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  Push failed: $pushResult" -ForegroundColor Red
            Write-Host "  Retrying with pull --rebase..." -ForegroundColor Yellow
            git pull --rebase 2>&1 | Out-Null
            $pushResult = git push 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  Push still failed. Manual intervention needed." -ForegroundColor Red
                Write-Audit "sync.push" "Push failed after retry" "fail"
                Pop-Location
                exit 1
            }
        }
        Write-Host "  Pushed successfully" -ForegroundColor Green
        Write-Audit "sync.push" "Push successful" "ok"
    } finally {
        Pop-Location
    }
} else {
    Write-Host "  Running standalone — skipping git push" -ForegroundColor DarkGray
}

Write-Host "`n=== MARKETPLACE SYNC COMPLETE ===" -ForegroundColor Cyan
Write-Host ""
