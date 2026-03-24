<#
.SYNOPSIS
    Shared path resolution for marketplace scripts.
    Detects whether running inside a Universe submodule or standalone.
#>

# Marketplace root is parent of scripts/ directory
$script:MarketRoot = Split-Path $PSScriptRoot -Parent

# Detect if we're inside a Universe repo (submodule context)
$script:UniverseRoot = $null
$script:IsSubmodule = $false

# Check if marketplace is a top-level directory inside a Universe repo
# Universe structure: marketplace/ is a peer of congress/, Companies/, executive/
$potentialUniverse = Split-Path $script:MarketRoot -Parent
$congressDir = Join-Path $potentialUniverse "congress"
$companiesDir = Join-Path $potentialUniverse "Companies"
if ((Test-Path $congressDir) -and (Test-Path $companiesDir)) {
    $script:UniverseRoot = $potentialUniverse
    $script:IsSubmodule = $true
}

# Marketplace paths (always available)
$script:MarketPaths = @{
    Root           = $script:MarketRoot
    Openings       = Join-Path $script:MarketRoot "openings"
    Contracts      = Join-Path $script:MarketRoot "contracts"
    Transactions   = Join-Path $script:MarketRoot "transactions"
    Registry       = Join-Path $script:MarketRoot "registry"
    Profiles       = Join-Path (Join-Path $script:MarketRoot "registry") "profiles"
    Pending        = Join-Path (Join-Path $script:MarketRoot "registry") "pending"
    Revoked        = Join-Path (Join-Path $script:MarketRoot "registry") "revoked"
    EventsOutbox   = Join-Path (Join-Path $script:MarketRoot "events") "outbox"
    EventsConsumed = Join-Path (Join-Path $script:MarketRoot "events") "consumed"
    Marketplace    = Join-Path $script:MarketRoot "marketplace.json"
    Reputation     = Join-Path $script:MarketRoot "reputation.json"
    Audit          = Join-Path $script:MarketRoot "audit.jsonl"
}

function Get-Timestamp { [datetime]::UtcNow.ToString("o") }
function Get-MarketHostname { if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { hostname } }

function Test-EntityIsInternal {
    param([string]$EntityId)
    if (-not $script:IsSubmodule) { return $false }
    $companyDir = Join-Path (Join-Path $script:UniverseRoot "Companies") $EntityId
    return (Test-Path $companyDir)
}

function Get-CompanyDir {
    param([string]$EntityId)
    if (-not $script:IsSubmodule) { return $null }
    $dir = Join-Path (Join-Path $script:UniverseRoot "Companies") $EntityId
    if (Test-Path $dir) { return $dir }
    return $null
}

function Write-AuditEntry {
    param([string]$Action, [string]$Entity, [string]$Detail)
    $entry = @{
        timestamp = Get-Timestamp
        action = $Action
        entity = $Entity
        detail = $Detail
        machine = Get-MarketHostname
    } | ConvertTo-Json -Compress
    Add-Content -Path $script:MarketPaths.Audit -Value $entry -Encoding UTF8
}

function Sync-Pull {
    Push-Location $script:MarketRoot
    git pull origin main --quiet 2>&1 | Out-Null
    Pop-Location
}

function Sync-Push {
    param([string]$Message)
    Push-Location $script:MarketRoot
    git add -A 2>&1 | Out-Null
    git commit -m $Message --quiet 2>&1 | Out-Null
    git push origin main --quiet 2>&1 | Out-Null
    Pop-Location
}
