<#
.SYNOPSIS
    Event queue for marketplace notifications to external entities.
.USAGE
    marketplace-events.ps1 -Action post -TargetEntity "ext-acme" -Type "work.delivered" -TxnId "TXN-xxx" -Role "client" -Data '{"files":["report.pdf"]}'
    marketplace-events.ps1 -Action list -TargetEntity "ext-acme"
    marketplace-events.ps1 -Action consume -EventId "EVT-001" -TargetEntity "ext-acme"
    marketplace-events.ps1 -Action check-stale
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("post", "list", "consume", "check-stale")]
    [string]$Action,

    [string]$TargetEntity = "",
    [string]$Type = "",
    [string]$TxnId = "",
    [string]$ContractId = "",
    [string]$Role = "",
    [string]$EventId = "",
    [string]$Data = "{}"
)

$ErrorActionPreference = "SilentlyContinue"

. "$PSScriptRoot\resolve-market-paths.ps1"

$now = Get-Timestamp

function Get-NextEventId {
    $consumed = Get-ChildItem -Path $script:MarketPaths.EventsConsumed -Filter "EVT-*.json" -ErrorAction SilentlyContinue
    $outboxDirs = Get-ChildItem -Path $script:MarketPaths.EventsOutbox -Directory -ErrorAction SilentlyContinue
    $allEvents = @()
    $allEvents += $consumed
    foreach ($dir in $outboxDirs) {
        $allEvents += Get-ChildItem -Path $dir.FullName -Filter "EVT-*.json" -ErrorAction SilentlyContinue
    }
    $maxNum = 0
    foreach ($f in $allEvents) {
        if ($f.BaseName -match 'EVT-(\d+)') {
            $num = [int]$Matches[1]
            if ($num -gt $maxNum) { $maxNum = $num }
        }
    }
    return "EVT-$(($maxNum + 1).ToString('000'))"
}

switch ($Action) {
    "post" {
        if (-not $TargetEntity) { Write-Error "-TargetEntity required"; exit 1 }
        if (-not $Type) { Write-Error "-Type required"; exit 1 }
        if (-not $TxnId) { Write-Error "-TxnId required"; exit 1 }
        if (-not $Role) { Write-Error "-Role required"; exit 1 }

        $eventId = Get-NextEventId
        $parsedData = $Data | ConvertFrom-Json

        $event = [ordered]@{
            id = $eventId
            timestamp = $now
            type = $Type
            transaction_id = $TxnId
            contract_id = $ContractId
            target_entity = $TargetEntity
            role = $Role
            data = $parsedData
            consumed = $false
            consumed_at = $null
            consumed_by = $null
        }

        # Ensure entity outbox directory exists
        $entityOutbox = Join-Path $script:MarketPaths.EventsOutbox $TargetEntity
        if (-not (Test-Path $entityOutbox)) { New-Item -ItemType Directory -Path $entityOutbox -Force | Out-Null }

        $event | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $entityOutbox "$eventId.json") -Encoding UTF8

        Write-AuditEntry -Action "event.posted" -Entity $TargetEntity -Detail "$Type for $TxnId"
        Write-Host "Event posted: $eventId -> $TargetEntity ($Type)" -ForegroundColor Green
        Write-Output $eventId
    }

    "list" {
        if (-not $TargetEntity) { Write-Error "-TargetEntity required"; exit 1 }

        $entityOutbox = Join-Path $script:MarketPaths.EventsOutbox $TargetEntity
        if (-not (Test-Path $entityOutbox)) {
            Write-Host "No pending events for $TargetEntity" -ForegroundColor Yellow
            return
        }

        $events = Get-ChildItem -Path $entityOutbox -Filter "EVT-*.json" -ErrorAction SilentlyContinue
        if ($events.Count -eq 0) {
            Write-Host "No pending events for $TargetEntity" -ForegroundColor Yellow
            return
        }

        Write-Host "Pending events for $TargetEntity ($($events.Count)):" -ForegroundColor Cyan
        foreach ($f in $events) {
            $evt = Get-Content $f.FullName -Raw | ConvertFrom-Json
            $age = ([datetime]::UtcNow - [datetime]::Parse($evt.timestamp)).TotalHours
            $ageStr = if ($age -gt 24) { "$([math]::Round($age / 24, 1))d" } else { "$([math]::Round($age, 1))h" }
            $color = if ($age -gt 168) { "Red" } elseif ($age -gt 72) { "Yellow" } else { "White" }
            Write-Host "  $($evt.id) | $($evt.type) | TXN: $($evt.transaction_id) | Age: $ageStr" -ForegroundColor $color
        }
    }

    "consume" {
        if (-not $EventId) { Write-Error "-EventId required"; exit 1 }
        if (-not $TargetEntity) { Write-Error "-TargetEntity required"; exit 1 }

        $entityOutbox = Join-Path $script:MarketPaths.EventsOutbox $TargetEntity
        $eventFile = Join-Path $entityOutbox "$EventId.json"
        if (-not (Test-Path $eventFile)) { Write-Error "Event $EventId not found in $TargetEntity outbox"; exit 1 }

        $evt = Get-Content $eventFile -Raw | ConvertFrom-Json
        $evt.consumed = $true
        $evt.consumed_at = $now
        $evt.consumed_by = $TargetEntity

        # Move to consumed
        $evt | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $script:MarketPaths.EventsConsumed "$EventId.json") -Encoding UTF8
        Remove-Item $eventFile -Force

        Write-AuditEntry -Action "event.consumed" -Entity $TargetEntity -Detail "$EventId consumed"
        Write-Host "Event consumed: $EventId" -ForegroundColor Green
    }

    "check-stale" {
        $warnings = @()
        $outboxDirs = Get-ChildItem -Path $script:MarketPaths.EventsOutbox -Directory -ErrorAction SilentlyContinue

        foreach ($dir in $outboxDirs) {
            $entity = $dir.Name
            $events = Get-ChildItem -Path $dir.FullName -Filter "EVT-*.json" -ErrorAction SilentlyContinue

            foreach ($f in $events) {
                $evt = Get-Content $f.FullName -Raw | ConvertFrom-Json
                $age = ([datetime]::UtcNow - [datetime]::Parse($evt.timestamp)).TotalHours

                if ($age -gt 168) {
                    $warnings += [ordered]@{
                        entity = $entity
                        event = $evt.id
                        type = $evt.type
                        age_hours = [math]::Round($age, 1)
                        severity = "suspension"
                    }
                } elseif ($age -gt 72) {
                    $warnings += [ordered]@{
                        entity = $entity
                        event = $evt.id
                        type = $evt.type
                        age_hours = [math]::Round($age, 1)
                        severity = "warning"
                    }
                }
            }
        }

        if ($warnings.Count -eq 0) {
            Write-Host "No stale events" -ForegroundColor Green
        } else {
            Write-Host "Stale events ($($warnings.Count)):" -ForegroundColor Yellow
            foreach ($w in $warnings) {
                $color = if ($w.severity -eq "suspension") { "Red" } else { "Yellow" }
                $ageStr = "$([math]::Round($w.age_hours / 24, 1))d"
                Write-Host "  [$($w.severity.ToUpper())] $($w.entity) | $($w.event) | $($w.type) | Age: $ageStr" -ForegroundColor $color
            }
        }
    }
}
