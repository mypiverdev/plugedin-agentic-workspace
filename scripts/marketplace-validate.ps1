<#
.SYNOPSIS
    Validate all marketplace JSON files against schemas and integrity rules.
.USAGE
    marketplace-validate.ps1                    # Validate everything
    marketplace-validate.ps1 -Type profiles     # Validate only profiles
    marketplace-validate.ps1 -Type openings     # Validate only openings
    marketplace-validate.ps1 -File "registry/profiles/ext-acme.json"   # Validate single file
#>

param(
    [ValidateSet("all", "profiles", "openings", "contracts", "events")]
    [string]$Type = "all",

    [string]$File = ""
)

$ErrorActionPreference = "SilentlyContinue"

. "$PSScriptRoot\resolve-market-paths.ps1"

$issues = @()
$warnings = @()
$checked = 0

function Test-JsonFile {
    param([string]$Path, [string]$Label)
    $script:checked++
    try {
        $content = Get-Content $Path -Raw -ErrorAction Stop
        $null = $content | ConvertFrom-Json -ErrorAction Stop
        return $true
    } catch {
        $script:issues += "INVALID JSON: $Label ($Path)"
        return $false
    }
}

function Test-RequiredField {
    param($Object, [string]$Field, [string]$Label)
    $value = $Object.$Field
    if ($null -eq $value -or $value -eq "") {
        $script:issues += "MISSING FIELD: $Field in $Label"
        return $false
    }
    return $true
}

function Test-EntityIdFormat {
    param([string]$Id, [string]$Label)
    if ($Id -notmatch '^[a-z0-9][a-z0-9-]*$') {
        $script:issues += "INVALID entity_id format: '$Id' in $Label (must be lowercase alphanumeric with hyphens)"
        return $false
    }
    return $true
}

# Single file validation
if ($File) {
    $fullPath = Join-Path $script:MarketRoot $File
    if (-not (Test-Path $fullPath)) {
        Write-Error "File not found: $File"
        exit 1
    }
    $valid = Test-JsonFile -Path $fullPath -Label $File
    if ($valid) {
        Write-Host "VALID: $File" -ForegroundColor Green
    } else {
        Write-Host "INVALID: $File" -ForegroundColor Red
        exit 1
    }
    exit 0
}

# Validate profiles
if ($Type -eq "all" -or $Type -eq "profiles") {
    $profileFiles = @()
    $profileFiles += Get-ChildItem -Path $script:MarketPaths.Profiles -Filter "*.json" -ErrorAction SilentlyContinue
    $profileFiles += Get-ChildItem -Path $script:MarketPaths.Pending -Filter "*.json" -ErrorAction SilentlyContinue

    foreach ($f in $profileFiles) {
        $label = "profile/$($f.Name)"
        if (Test-JsonFile -Path $f.FullName -Label $label) {
            $p = Get-Content $f.FullName -Raw | ConvertFrom-Json
            Test-RequiredField $p "entity_id" $label | Out-Null
            Test-RequiredField $p "name" $label | Out-Null
            Test-RequiredField $p "type" $label | Out-Null
            if ($p.entity_id) { Test-EntityIdFormat $p.entity_id $label | Out-Null }

            # Check filename matches entity_id
            $expectedName = "$($p.entity_id).json"
            if ($f.Name -ne $expectedName) {
                $warnings += "MISMATCH: $label - filename '$($f.Name)' does not match entity_id '$($p.entity_id)'"
            }

            # Check skills
            if (-not $p.capabilities -or -not $p.capabilities.skills) {
                $warnings += "NO SKILLS: $label - entity has no declared skills"
            }
        }
    }
}

# Validate openings
if ($Type -eq "all" -or $Type -eq "openings") {
    $openingFiles = Get-ChildItem -Path $script:MarketPaths.Openings -Filter "O-*.json" -ErrorAction SilentlyContinue

    foreach ($f in $openingFiles) {
        $label = "opening/$($f.Name)"
        if (Test-JsonFile -Path $f.FullName -Label $label) {
            $o = Get-Content $f.FullName -Raw | ConvertFrom-Json
            Test-RequiredField $o "id" $label | Out-Null
            Test-RequiredField $o "company" $label | Out-Null
            Test-RequiredField $o "title" $label | Out-Null
            Test-RequiredField $o "status" $label | Out-Null

            # Check ID format matches filename
            $expectedName = "$($o.id).json"
            if ($f.Name -ne $expectedName) {
                $issues += "ID MISMATCH: $label - filename does not match id field"
            }

            # Check sovereignty: opening company must have a profile
            if ($o.company) {
                $profileExists = (Test-Path (Join-Path $script:MarketPaths.Profiles "$($o.company).json"))
                if (-not $profileExists) {
                    $warnings += "ORPHAN: $label - company '$($o.company)' has no active profile"
                }
            }
        }
    }
}

# Validate contracts
if ($Type -eq "all" -or $Type -eq "contracts") {
    $contractFiles = Get-ChildItem -Path $script:MarketPaths.Contracts -Filter "MC-*.json" -ErrorAction SilentlyContinue

    foreach ($f in $contractFiles) {
        $label = "contract/$($f.Name)"
        if (Test-JsonFile -Path $f.FullName -Label $label) {
            $c = Get-Content $f.FullName -Raw | ConvertFrom-Json
            Test-RequiredField $c "id" $label | Out-Null
            Test-RequiredField $c "client" $label | Out-Null
            Test-RequiredField $c "provider" $label | Out-Null
            Test-RequiredField $c "status" $label | Out-Null

            # Check both parties exist
            foreach ($party in @($c.client, $c.provider)) {
                if ($party) {
                    $profileExists = (Test-Path (Join-Path $script:MarketPaths.Profiles "$party.json"))
                    if (-not $profileExists) {
                        $warnings += "ORPHAN: $label - party '$party' has no active profile"
                    }
                }
            }

            # Check transaction workspace exists for active contracts
            if ($c.transaction_id -and $c.status -eq "active") {
                $txnDir = Join-Path $script:MarketPaths.Transactions $c.transaction_id
                if (-not (Test-Path $txnDir)) {
                    $issues += "MISSING TXN: $label - transaction workspace '$($c.transaction_id)' not found"
                }
            }
        }
    }
}

# Validate events
if ($Type -eq "all" -or $Type -eq "events") {
    $outboxDirs = Get-ChildItem -Path $script:MarketPaths.EventsOutbox -Directory -ErrorAction SilentlyContinue

    foreach ($dir in $outboxDirs) {
        $events = Get-ChildItem -Path $dir.FullName -Filter "EVT-*.json" -ErrorAction SilentlyContinue
        foreach ($f in $events) {
            $label = "event/$($dir.Name)/$($f.Name)"
            if (Test-JsonFile -Path $f.FullName -Label $label) {
                $e = Get-Content $f.FullName -Raw | ConvertFrom-Json
                Test-RequiredField $e "id" $label | Out-Null
                Test-RequiredField $e "type" $label | Out-Null
                Test-RequiredField $e "target_entity" $label | Out-Null

                # Check target_entity matches directory
                if ($e.target_entity -ne $dir.Name) {
                    $issues += "SOVEREIGNTY: $label - target_entity '$($e.target_entity)' does not match outbox directory '$($dir.Name)'"
                }
            }
        }
    }
}

# Report
Write-Host "`n=== Marketplace Validation ===" -ForegroundColor Cyan
Write-Host "  Checked: $checked files" -ForegroundColor White

if ($issues.Count -gt 0) {
    Write-Host "`n  ISSUES ($($issues.Count)):" -ForegroundColor Red
    $issues | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
}

if ($warnings.Count -gt 0) {
    Write-Host "`n  WARNINGS ($($warnings.Count)):" -ForegroundColor Yellow
    $warnings | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }
}

if ($issues.Count -eq 0 -and $warnings.Count -eq 0) {
    Write-Host "  Status: ALL VALID" -ForegroundColor Green
} elseif ($issues.Count -eq 0) {
    Write-Host "  Status: VALID (with warnings)" -ForegroundColor Yellow
} else {
    Write-Host "  Status: INVALID" -ForegroundColor Red
    exit 1
}
