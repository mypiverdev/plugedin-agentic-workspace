<#
.SYNOPSIS
    Lightweight marketplace watcher — pulls market changes and reports new activity.
    No commit, no push, no rebuild. Just keeps your local view fresh.
.USAGE
    government/kernel/marketplace-watch.ps1              # Pull and report
    government/kernel/marketplace-watch.ps1 -Loop 5      # Pull every 5 minutes
    government/kernel/marketplace-watch.ps1 -Quiet       # Pull silently, only report if activity found
#>

param(
    [int]$Loop = 0,
    [switch]$Quiet
)

$ErrorActionPreference = "SilentlyContinue"

. "$PSScriptRoot\resolve-market-paths.ps1"

function Watch-Once {
    # Only run if we're in a submodule
    if (-not $script:IsSubmodule -or -not $script:UniverseRoot) {
        Write-Host "Running standalone — marketplace watcher requires Universe context" -ForegroundColor Yellow
        return
    }

    # Capture current HEAD before pull
    Push-Location $script:UniverseRoot
    $beforeHead = git rev-parse HEAD 2>&1

    # Pull only — no push, no commit
    $pullResult = git pull origin master 2>&1
    $afterHead = git rev-parse HEAD 2>&1

    Pop-Location

    if ($beforeHead -eq $afterHead) {
        if (-not $Quiet) {
            Write-Host "  $(Get-Date -Format 'HH:mm:ss') — no new changes" -ForegroundColor DarkGray
        }
        return
    }

    # Get changed files in market/ since last pull
    Push-Location $script:UniverseRoot
    $changedFiles = git diff --name-only $beforeHead $afterHead -- "Companies/market/" 2>&1
    Pop-Location

    if (-not $changedFiles) {
        if (-not $Quiet) {
            Write-Host "  $(Get-Date -Format 'HH:mm:ss') — changes pulled but none in marketplace" -ForegroundColor DarkGray
        }
        return
    }

    # Parse activity
    $newOpenings = @($changedFiles | Where-Object { $_ -match "openings/" })
    $newContracts = @($changedFiles | Where-Object { $_ -match "contracts/" })
    $txnActivity = @($changedFiles | Where-Object { $_ -match "transactions/" })
    $logUpdates = @($changedFiles | Where-Object { $_ -match "log\.json" })
    $deliveries = @($changedFiles | Where-Object { $_ -match "deliverables/" })
    $escrowChanges = @($changedFiles | Where-Object { $_ -match "escrow\.json" })

    # Report
    Write-Host ""
    Write-Host "  === MARKETPLACE ACTIVITY $(Get-Date -Format 'HH:mm:ss') ===" -ForegroundColor Cyan

    if ($newOpenings.Count -gt 0) {
        Write-Host "    NEW/UPDATED OPENINGS ($($newOpenings.Count)):" -ForegroundColor Yellow
        foreach ($f in $newOpenings) {
            $name = Split-Path $f -Leaf
            Write-Host "      $name" -ForegroundColor White
        }
    }

    if ($newContracts.Count -gt 0) {
        Write-Host "    NEW/UPDATED CONTRACTS ($($newContracts.Count)):" -ForegroundColor Yellow
        foreach ($f in $newContracts) {
            $name = Split-Path $f -Leaf
            Write-Host "      $name" -ForegroundColor White
        }
    }

    if ($deliveries.Count -gt 0) {
        Write-Host "    DELIVERABLES RECEIVED ($($deliveries.Count) files):" -ForegroundColor Green
        foreach ($f in $deliveries) {
            $name = Split-Path $f -Leaf
            Write-Host "      $name" -ForegroundColor White
        }
    }

    if ($escrowChanges.Count -gt 0) {
        Write-Host "    ESCROW CHANGES ($($escrowChanges.Count)):" -ForegroundColor Magenta
        foreach ($f in $escrowChanges) {
            $txn = ($f -split "/") | Where-Object { $_ -match "^TXN-" } | Select-Object -First 1
            Write-Host "      $txn" -ForegroundColor White
        }
    }

    if ($logUpdates.Count -gt 0) {
        Write-Host "    TRANSACTION LOG UPDATES ($($logUpdates.Count)):" -ForegroundColor White
        foreach ($f in $logUpdates) {
            $txn = ($f -split "/") | Where-Object { $_ -match "^TXN-" } | Select-Object -First 1
            if ($txn) { Write-Host "      $txn" -ForegroundColor White }
        }
    }

    $otherChanges = @($changedFiles | Where-Object {
        $_ -notmatch "openings/" -and $_ -notmatch "contracts/" -and
        $_ -notmatch "deliverables/" -and $_ -notmatch "escrow\.json" -and
        $_ -notmatch "log\.json"
    })

    if ($otherChanges.Count -gt 0) {
        Write-Host "    OTHER CHANGES ($($otherChanges.Count)):" -ForegroundColor DarkGray
        foreach ($f in $otherChanges) {
            Write-Host "      $f" -ForegroundColor DarkGray
        }
    }

    Write-Host ""
}

# Run once or loop
if ($Loop -gt 0) {
    Write-Host "Marketplace watcher started — pulling every $Loop minutes" -ForegroundColor Cyan
    Write-Host "Press Ctrl+C to stop" -ForegroundColor DarkGray
    Write-Host ""

    while ($true) {
        Watch-Once
        Start-Sleep -Seconds ($Loop * 60)
    }
} else {
    Watch-Once
}
