<#
.SYNOPSIS
    Calculate and publish public reputation scores from contract history.
.DESCRIPTION
    Reads contracts.json for completed engagements, calculates reputation per
    company using the constitution's TL-7 formula, writes to reputation.json.
.USAGE
    marketplace-reputation.ps1
#>

$ErrorActionPreference = "SilentlyContinue"

. "$PSScriptRoot\resolve-market-paths.ps1"

$contractsFile = $script:MarketPaths.Contracts
$reputationFile = $script:MarketPaths.Reputation
$now = Get-Timestamp

# Load contracts
$contracts = @()
$contractsRegistry = Join-Path (Split-Path $script:MarketPaths.Contracts -Parent) "contracts.json"
if (Test-Path $contractsRegistry) {
    $reg = Get-Content $contractsRegistry -Raw | ConvertFrom-Json
    $contracts = $reg.contracts
}

# Find all companies that have been providers
$providerIds = ($contracts | Where-Object { $_.provider } | Select-Object -ExpandProperty provider -Unique)

# Also find all companies that have been clients
$clientIds = ($contracts | Where-Object { $_.client } | Select-Object -ExpandProperty client -Unique)
$allIds = ($providerIds + $clientIds) | Select-Object -Unique

$companyScores = @()

foreach ($compId in $allIds) {
    # Provider reputation (when this company did work for others)
    $asProvider = $contracts | Where-Object { $_.provider -eq $compId -and $_.status -eq "completed" }
    $asProviderFailed = $contracts | Where-Object { $_.provider -eq $compId -and $_.status -eq "terminated" }

    $providerEngagements = $asProvider.Count + $asProviderFailed.Count
    $providerSuccessRate = if ($providerEngagements -gt 0) { [math]::Round($asProvider.Count / $providerEngagements, 3) } else { $null }
    $providerAvgQuality = if ($asProvider.Count -gt 0) {
        $scores = $asProvider | Where-Object { $_.quality_score } | Select-Object -ExpandProperty quality_score
        if ($scores.Count -gt 0) { [math]::Round(($scores | Measure-Object -Average).Average, 3) } else { $null }
    } else { $null }

    # Client reputation (when this company hired others — did they pay fairly?)
    $asClient = $contracts | Where-Object { $_.client -eq $compId -and $_.status -eq "completed" }
    $asClientTerminated = $contracts | Where-Object { $_.client -eq $compId -and $_.status -eq "terminated" }
    $clientEngagements = $asClient.Count + $asClientTerminated.Count
    $paymentReliability = if ($clientEngagements -gt 0) {
        $released = ($asClient | Where-Object { $_.escrow.released }).Count
        [math]::Round($released / $clientEngagements, 3)
    } else { $null }

    # Overall reputation score (TL-7 formula simplified)
    # Success rate 30%, Quality 25%, Volume 10% (log), rest from available data
    $score = $null
    if ($providerEngagements -gt 0) {
        $successComponent = if ($providerSuccessRate) { $providerSuccessRate * 0.30 } else { 0 }
        $qualityComponent = if ($providerAvgQuality) { $providerAvgQuality * 0.25 } else { 0 }
        $volumeComponent = [math]::Min([math]::Log10([math]::Max($providerEngagements, 1)) / 2, 1) * 0.10
        # Simplified: fill remaining 35% with average of what we have
        $knownTotal = $successComponent + $qualityComponent + $volumeComponent
        $knownWeight = 0.65
        $score = [math]::Round($knownTotal / $knownWeight, 3)
        $score = [math]::Min($score, 1.0)
    }

    # Determine tier
    $tier = "unrated"
    if ($score -ne $null) {
        if ($score -ge 0.9) { $tier = "elite" }
        elseif ($score -ge 0.7) { $tier = "proven" }
        elseif ($score -ge 0.5) { $tier = "established" }
        elseif ($score -ge 0.3) { $tier = "developing" }
        else { $tier = "untested" }
    }

    $companyScores += [ordered]@{
        company_id = $compId
        reputation_score = $score
        tier = $tier
        as_provider = [ordered]@{
            engagements = $providerEngagements
            completed = $asProvider.Count
            terminated = $asProviderFailed.Count
            success_rate = $providerSuccessRate
            avg_quality = $providerAvgQuality
        }
        as_client = [ordered]@{
            engagements = $clientEngagements
            payment_reliability = $paymentReliability
        }
        last_engagement = if ($asProvider.Count -gt 0) {
            ($asProvider | Sort-Object { $_.completed_at } -Descending | Select-Object -First 1).completed_at
        } else { $null }
    }
}

$reputation = [ordered]@{
    description = "Public reputation scores computed from cross-company contract history"
    generated_at = $now
    total_rated = ($companyScores | Where-Object { $_.reputation_score -ne $null }).Count
    companies = $companyScores
}

$reputation | ConvertTo-Json -Depth 10 | Set-Content -Path $reputationFile -Encoding UTF8

Write-Host "Reputation: $($companyScores.Count) companies scored" -ForegroundColor Green
foreach ($c in $companyScores) {
    $scoreStr = if ($c.reputation_score) { "$($c.reputation_score) ($($c.tier))" } else { "unrated" }
    Write-Host "  $($c.company_id): $scoreStr | Provider: $($c.as_provider.completed)/$($c.as_provider.engagements) | Client: $($c.as_client.engagements) deals" -ForegroundColor White
}
