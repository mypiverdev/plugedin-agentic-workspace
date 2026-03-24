<#
.SYNOPSIS
    Manage marketplace openings — post, close, list, match.
.USAGE
    marketplace-openings.ps1 -Action post -Company piver -Data '{"title":"Need data analysis","skills":["data-analysis"],"budget":500,"deadline":"2026-04-01"}'
    marketplace-openings.ps1 -Action close -OpeningId "O-piver-001"
    marketplace-openings.ps1 -Action list
    marketplace-openings.ps1 -Action match -Skills "data-analysis,visualization"
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("post", "close", "list", "match")]
    [string]$Action,

    [string]$Company = "",
    [string]$OpeningId = "",
    [string]$Data = "{}",
    [string]$Skills = ""
)

$ErrorActionPreference = "SilentlyContinue"

. "$PSScriptRoot\resolve-market-paths.ps1"

$openingsFile = Join-Path $script:MarketRoot "openings.json"
$marketplaceFile = $script:MarketPaths.Marketplace
$now = Get-Timestamp

# Auto-sync: pull latest before any marketplace operation (MK-15)
Sync-Pull

if (-not (Test-Path $openingsFile)) {
    @{ description="Openings Board"; generated_at=$null; total_open=0; openings=@() } | ConvertTo-Json -Depth 5 | Set-Content -Path $openingsFile -Encoding UTF8
}

$board = Get-Content $openingsFile -Raw | ConvertFrom-Json

switch ($Action) {
    "post" {
        if (-not $Company) { Write-Error "-Company required for post"; exit 1 }
        $parsedData = $Data | ConvertFrom-Json

        # Generate opening ID
        $existingCount = ($board.openings | Where-Object { $_.company -eq $Company }).Count
        $id = "O-$Company-$(($existingCount + 1).ToString('000'))"

        $opening = [ordered]@{
            id = $id
            company = $Company
            title = $parsedData.title
            description = if ($parsedData.description) { $parsedData.description } else { "" }
            skills_required = if ($parsedData.skills) { $parsedData.skills } else { @() }
            budget = if ($parsedData.budget) { $parsedData.budget } else { $null }
            currency = "USD"
            deadline = if ($parsedData.deadline) { $parsedData.deadline } else { $null }
            engagement_type = if ($parsedData.engagement_type) { $parsedData.engagement_type } else { "task" }
            status = "open"
            posted_at = $now
            closed_at = $null
            awarded_to = $null
            applications = @()
        }

        $board.openings += $opening
        $board.total_open = ($board.openings | Where-Object { $_.status -eq "open" }).Count
        $board.generated_at = $now
        $board | ConvertTo-Json -Depth 10 | Set-Content -Path $openingsFile -Encoding UTF8

        # Also write per-entry file (MK-13)
        $openingsDir = $script:MarketPaths.Openings
        if (-not (Test-Path $openingsDir)) { New-Item -ItemType Directory -Path $openingsDir -Force | Out-Null }
        $opening | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $openingsDir "$id.json") -Encoding UTF8

        # Auto-sync: commit and push (MK-15)
        Sync-Push "marketplace: opening $id posted by $Company"

        Write-Host "Opening posted: $id - $($parsedData.title)" -ForegroundColor Green
        Write-Output $id
    }

    "close" {
        if (-not $OpeningId) { Write-Error "-OpeningId required for close"; exit 1 }
        $board.openings | Where-Object { $_.id -eq $OpeningId } | ForEach-Object {
            $_.status = "closed"
            $_.closed_at = $now
        }
        $board.total_open = ($board.openings | Where-Object { $_.status -eq "open" }).Count
        $board.generated_at = $now
        $board | ConvertTo-Json -Depth 10 | Set-Content -Path $openingsFile -Encoding UTF8

        # Update per-entry file (MK-13)
        $openingsDir = $script:MarketPaths.Openings
        $entryFile = Join-Path $openingsDir "$OpeningId.json"
        if (Test-Path $entryFile) {
            $entry = Get-Content $entryFile -Raw | ConvertFrom-Json
            $entry.status = "closed"
            $entry.closed_at = $now
            $entry | ConvertTo-Json -Depth 10 | Set-Content -Path $entryFile -Encoding UTF8
        }

        # Auto-sync: commit and push (MK-15)
        Sync-Push "marketplace: opening $OpeningId closed"

        Write-Host "Opening closed: $OpeningId" -ForegroundColor Green
    }

    "list" {
        $open = $board.openings | Where-Object { $_.status -eq "open" }
        if ($open.Count -eq 0) {
            Write-Host "No open listings" -ForegroundColor Yellow
        } else {
            Write-Host "Open listings ($($open.Count)):" -ForegroundColor Cyan
            foreach ($o in $open) {
                $skillsStr = if ($o.skills_required) { ($o.skills_required -join ", ") } else { "any" }
                $budgetStr = if ($o.budget) { "`$$($o.budget)" } else { "negotiable" }
                Write-Host "  $($o.id) | $($o.company) | $($o.title) | Skills: $skillsStr | Budget: $budgetStr" -ForegroundColor White
            }
        }
    }

    "match" {
        if (-not $Skills) { Write-Error "-Skills required for match"; exit 1 }
        $requestedSkills = ($Skills -split ',').Trim()

        # Find companies with matching skills from marketplace
        if (Test-Path $marketplaceFile) {
            $marketplace = Get-Content $marketplaceFile -Raw | ConvertFrom-Json
            $matches = @()
            foreach ($comp in $marketplace.companies) {
                if (-not $comp.capacity.available) { continue }
                $compSkills = $comp.skills
                $matchCount = ($requestedSkills | Where-Object { $_ -in $compSkills }).Count
                if ($matchCount -gt 0) {
                    $matches += [ordered]@{
                        company = $comp.name
                        id = $comp.id
                        matched_skills = $matchCount
                        total_skills = $requestedSkills.Count
                        quality = $comp.track_record.avg_quality_score
                        projects = $comp.track_record.projects_completed
                    }
                }
            }
            $matches = $matches | Sort-Object { $_.matched_skills } -Descending
            if ($matches.Count -eq 0) {
                Write-Host "No companies match skills: $Skills" -ForegroundColor Yellow
            } else {
                Write-Host "Matches for [$Skills] ($($matches.Count)):" -ForegroundColor Cyan
                foreach ($m in $matches) {
                    Write-Host "  $($m.company) | $($m.matched_skills)/$($m.total_skills) skills | Quality: $($m.quality) | Projects: $($m.projects)" -ForegroundColor White
                }
            }
        }
    }
}
