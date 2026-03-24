<#
.SYNOPSIS
    Marketplace registration workflow - apply, admit, revoke, list.
.USAGE
    marketplace-register.ps1 -Action apply -Data '{"entity_id":"ext-acme","type":"external","name":"Acme Corp","description":"Dev agency","capabilities":{"skills":["web-dev"]},"contact":{"repo":"https://github.com/acme/workspace"}}'
    marketplace-register.ps1 -Action admit -EntityId "ext-acme"
    marketplace-register.ps1 -Action revoke -EntityId "ext-acme" -Reason "Violated PR-5"
    marketplace-register.ps1 -Action list
    marketplace-register.ps1 -Action sync-internal     # Sync Universe company profiles into registry
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("apply", "admit", "revoke", "list", "sync-internal")]
    [string]$Action,

    [string]$EntityId = "",
    [string]$Data = "{}",
    [string]$Reason = ""
)

$ErrorActionPreference = "SilentlyContinue"

. "$PSScriptRoot\resolve-market-paths.ps1"

$now = Get-Timestamp

switch ($Action) {
    "apply" {
        $profile = $Data | ConvertFrom-Json

        if (-not $profile.entity_id) { Write-Error "entity_id required"; exit 1 }
        if (-not $profile.name) { Write-Error "name required"; exit 1 }
        if (-not $profile.type) { $profile | Add-Member -NotePropertyName "type" -NotePropertyValue "external" }

        $id = $profile.entity_id

        # Check uniqueness
        $existingActive = Join-Path $script:MarketPaths.Profiles "$id.json"
        $existingPending = Join-Path $script:MarketPaths.Pending "$id.json"
        if (Test-Path $existingActive) { Write-Error "Entity '$id' is already registered"; exit 1 }
        if (Test-Path $existingPending) { Write-Error "Entity '$id' already has a pending application"; exit 1 }

        # Add registration metadata
        $profile | Add-Member -NotePropertyName "registered_at" -NotePropertyValue $now -Force
        $profile | Add-Member -NotePropertyName "admitted_at" -NotePropertyValue $null -Force
        $profile | Add-Member -NotePropertyName "status" -NotePropertyValue "pending" -Force
        $profile | Add-Member -NotePropertyName "origin" -NotePropertyValue "external" -Force

        # Add track record defaults if missing
        if (-not $profile.track_record) {
            $profile | Add-Member -NotePropertyName "track_record" -NotePropertyValue @{
                projects_completed = 0
                avg_quality_score = $null
                reputation_score = 0.0
                total_engagements = 0
            }
        }

        $profile | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $script:MarketPaths.Pending "$id.json") -Encoding UTF8
        Write-AuditEntry -Action "registration.applied" -Entity $id -Detail "Application submitted"
        Write-Host "Application submitted: $id ($($profile.name)). Awaiting admin review." -ForegroundColor Yellow
    }

    "admit" {
        if (-not $EntityId) { Write-Error "-EntityId required"; exit 1 }

        $pendingFile = Join-Path $script:MarketPaths.Pending "$EntityId.json"
        if (-not (Test-Path $pendingFile)) { Write-Error "No pending application for '$EntityId'"; exit 1 }

        $profile = Get-Content $pendingFile -Raw | ConvertFrom-Json
        $profile.status = "active"
        $profile.admitted_at = $now

        # Move from pending to profiles
        $profile | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $script:MarketPaths.Profiles "$EntityId.json") -Encoding UTF8
        Remove-Item $pendingFile -Force

        # Create event outbox for this entity
        $outboxDir = Join-Path $script:MarketPaths.EventsOutbox $EntityId
        if (-not (Test-Path $outboxDir)) { New-Item -ItemType Directory -Path $outboxDir -Force | Out-Null }

        Write-AuditEntry -Action "registration.admitted" -Entity $EntityId -Detail "Admitted to marketplace"
        Write-Host "ADMITTED: $EntityId ($($profile.name))" -ForegroundColor Green
    }

    "revoke" {
        if (-not $EntityId) { Write-Error "-EntityId required"; exit 1 }

        $profileFile = Join-Path $script:MarketPaths.Profiles "$EntityId.json"
        if (-not (Test-Path $profileFile)) { Write-Error "No active profile for '$EntityId'"; exit 1 }

        $profile = Get-Content $profileFile -Raw | ConvertFrom-Json
        $profile.status = "revoked"
        $profile | Add-Member -NotePropertyName "revoked_at" -NotePropertyValue $now -Force
        $profile | Add-Member -NotePropertyName "revocation_reason" -NotePropertyValue $Reason -Force

        # Move from profiles to revoked
        $profile | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $script:MarketPaths.Revoked "$EntityId.json") -Encoding UTF8
        Remove-Item $profileFile -Force

        Write-AuditEntry -Action "registration.revoked" -Entity $EntityId -Detail "Revoked: $Reason"
        Write-Host "REVOKED: $EntityId - $Reason" -ForegroundColor Red
    }

    "list" {
        Write-Host "=== Marketplace Registry ===" -ForegroundColor Cyan

        $active = Get-ChildItem -Path $script:MarketPaths.Profiles -Filter "*.json" -ErrorAction SilentlyContinue
        $pending = Get-ChildItem -Path $script:MarketPaths.Pending -Filter "*.json" -ErrorAction SilentlyContinue
        $revoked = Get-ChildItem -Path $script:MarketPaths.Revoked -Filter "*.json" -ErrorAction SilentlyContinue

        Write-Host "`nActive ($($active.Count)):" -ForegroundColor Green
        foreach ($f in $active) {
            $p = Get-Content $f.FullName -Raw | ConvertFrom-Json
            $origin = if ($p.origin) { $p.origin } else { "unknown" }
            Write-Host "  $($p.entity_id) | $($p.name) | $origin | Skills: $(($p.capabilities.skills -join ', '))" -ForegroundColor White
        }

        if ($pending.Count -gt 0) {
            Write-Host "`nPending ($($pending.Count)):" -ForegroundColor Yellow
            foreach ($f in $pending) {
                $p = Get-Content $f.FullName -Raw | ConvertFrom-Json
                Write-Host "  $($p.entity_id) | $($p.name) | Applied: $($p.registered_at)" -ForegroundColor Yellow
            }
        }

        if ($revoked.Count -gt 0) {
            Write-Host "`nRevoked ($($revoked.Count)):" -ForegroundColor DarkGray
            foreach ($f in $revoked) {
                $p = Get-Content $f.FullName -Raw | ConvertFrom-Json
                Write-Host "  $($p.entity_id) | $($p.name) | Reason: $($p.revocation_reason)" -ForegroundColor DarkGray
            }
        }
    }

    "sync-internal" {
        # Sync Universe company profiles into the marketplace registry
        if (-not $script:IsSubmodule) {
            Write-Host "Not running inside Universe - skipping internal sync" -ForegroundColor Yellow
            return
        }

        $companiesDir = Split-Path $script:MarketRoot -Parent
        $synced = 0

        Get-ChildItem -Path $companiesDir -Directory | ForEach-Object {
            $compName = $_.Name
            if ($compName -eq "market") { return }

            $profilePath = Join-Path (Join-Path $_.FullName "corporate") "profile.json"
            if (-not (Test-Path $profilePath)) { return }

            # Run legality check
            $validateScript = Join-Path (Join-Path $_.FullName "government") "kernel\validate.ps1"
            $isLegal = $false
            if (Test-Path $validateScript) {
                try {
                    & powershell -ExecutionPolicy Bypass -File $validateScript -Quiet 2>&1 | Out-Null
                    $validationReport = Join-Path (Join-Path (Join-Path $_.FullName "corporate") "telemetry") "validation-latest.json"
                    if (Test-Path $validationReport) {
                        $vResult = Get-Content $validationReport -Raw | ConvertFrom-Json
                        if ($vResult.status -eq "pass") { $isLegal = $true }
                    }
                } catch {}
            }

            if (-not $isLegal) {
                Write-Host "  SKIP (illegal): $compName" -ForegroundColor Red
                return
            }

            # Read company profile and write to registry
            $profile = Get-Content $profilePath -Raw | ConvertFrom-Json
            $regEntry = [ordered]@{
                entity_id = $profile.entity_id
                type = "internal"
                origin = "internal"
                name = $profile.name
                description = $profile.description
                ceo = $profile.ceo
                capabilities = $profile.capabilities
                capacity = $profile.capacity
                track_record = $profile.track_record
                pricing = $profile.pricing
                contact = @{
                    owner = $profile.contact.owner
                    workspace_path = "Companies/$compName"
                }
                status = "active"
                registered_at = $now
                admitted_at = $now
                last_updated = $now
            }
            $regEntry | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $script:MarketPaths.Profiles "$compName.json") -Encoding UTF8
            Write-Host "  SYNCED: $compName ($($profile.name))" -ForegroundColor Green
            $synced++
        }

        Write-Host "Internal sync: $synced companies registered" -ForegroundColor Cyan
    }
}
