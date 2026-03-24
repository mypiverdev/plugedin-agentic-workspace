<#
.SYNOPSIS
    Manage cross-company contracts — create, complete, terminate, list.
.USAGE
    marketplace-contracts.ps1 -Action create -Client piver -Provider meridian -Data '{"opening_id":"O-piver-001","scope":"Data analysis","price":500,"engagement_type":"task"}'
    marketplace-contracts.ps1 -Action complete -ContractId "MC-piver-meridian-001" -Data '{"quality_score":0.92}'
    marketplace-contracts.ps1 -Action terminate -ContractId "MC-piver-meridian-001" -Data '{"reason":"scope mismatch"}'
    marketplace-contracts.ps1 -Action list
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("create", "complete", "terminate", "list")]
    [string]$Action,

    [string]$Client = "",
    [string]$Provider = "",
    [string]$ContractId = "",
    [string]$Data = "{}"
)

$ErrorActionPreference = "SilentlyContinue"

. "$PSScriptRoot\resolve-market-paths.ps1"

$now = Get-Timestamp
$contractsFile = $script:MarketPaths.Contracts
$transactionsFile = $script:MarketPaths.Transactions

# Auto-sync: pull latest before any marketplace operation (MK-15)
Sync-Pull

if (-not (Test-Path $contractsFile)) {
    New-Item -ItemType Directory -Path (Split-Path $contractsFile -Parent) -Force | Out-Null
    @{ description="Cross-company contracts"; total_active=0; total_completed=0; contracts=@() } | ConvertTo-Json -Depth 5 | Set-Content -Path $contractsFile -Encoding UTF8
}

$registry = Get-Content $contractsFile -Raw | ConvertFrom-Json
$parsedData = $Data | ConvertFrom-Json

switch ($Action) {
    "create" {
        if (-not $Client -or -not $Provider) { Write-Error "-Client and -Provider required"; exit 1 }

        $existingCount = $registry.contracts.Count
        $id = "MC-$Client-$Provider-$(($existingCount + 1).ToString('000'))"

        $contract = [ordered]@{
            id = $id
            client = $Client
            provider = $Provider
            opening_ref = if ($parsedData.opening_id) { $parsedData.opening_id } else { $null }
            scope = if ($parsedData.scope) { $parsedData.scope } else { "" }
            price = if ($parsedData.price) { $parsedData.price } else { 0 }
            currency = "USD"
            engagement_type = if ($parsedData.engagement_type) { $parsedData.engagement_type } else { "task" }
            status = "active"
            escrow = [ordered]@{
                funded = $true
                amount = if ($parsedData.price) { $parsedData.price } else { 0 }
                released = $false
                released_at = $null
            }
            created_at = $now
            completed_at = $null
            terminated_at = $null
            quality_score = $null
        }

        $registry.contracts += $contract
        $registry.total_active = ($registry.contracts | Where-Object { $_.status -eq "active" }).Count
        $registry.generated_at = $now
        $registry | ConvertTo-Json -Depth 10 | Set-Content -Path $contractsFile -Encoding UTF8

        # Close the opening if referenced
        if ($parsedData.opening_id) {
            $openingsFile = $script:MarketPaths.Openings
            if (Test-Path $openingsFile) {
                $board = Get-Content $openingsFile -Raw | ConvertFrom-Json
                $board.openings | Where-Object { $_.id -eq $parsedData.opening_id } | ForEach-Object {
                    $_.status = "awarded"
                    $_.awarded_to = $Provider
                }
                $board.total_open = ($board.openings | Where-Object { $_.status -eq "open" }).Count
                $board | ConvertTo-Json -Depth 10 | Set-Content -Path $openingsFile -Encoding UTF8
            }
        }

        # Create transaction workspace
        $txnScript = Join-Path $PSScriptRoot "marketplace-transaction.ps1"
        $txnId = $null
        if (Test-Path $txnScript) {
            $txnId = & $txnScript -Action create -Client $Client -Provider $Provider -ContractId $id -Data $Data
        }

        # Store transaction reference in contract
        if ($txnId) {
            $contract | Add-Member -NotePropertyName "transaction_id" -NotePropertyValue $txnId -Force
            $registry | ConvertTo-Json -Depth 10 | Set-Content -Path $contractsFile -Encoding UTF8
        }

        # Write per-entry contract file (MK-13)
        $contractsDir = $script:MarketPaths.Contracts
        if (-not (Test-Path $contractsDir)) { New-Item -ItemType Directory -Path $contractsDir -Force | Out-Null }
        $contract | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $contractsDir "$id.json") -Encoding UTF8

        # Auto-sync: commit and push (MK-15)
        Sync-Push "marketplace: contract $id created ($Client -> $Provider)"

        Write-Host "Contract created: $id ($Client -> $Provider, `$$($contract.price))" -ForegroundColor Green
        if ($txnId) { Write-Host "Transaction workspace: $txnId" -ForegroundColor White }
        Write-Output $id
    }

    "complete" {
        if (-not $ContractId) { Write-Error "-ContractId required"; exit 1 }
        $contract = $registry.contracts | Where-Object { $_.id -eq $ContractId }
        if ($contract) {
            $contract.status = "completed"
            $contract.completed_at = $now
            if ($parsedData.quality_score) { $contract.quality_score = $parsedData.quality_score }
            $contract.escrow.released = $true
            $contract.escrow.released_at = $now

            $registry.total_active = ($registry.contracts | Where-Object { $_.status -eq "active" }).Count
            $registry.total_completed = ($registry.contracts | Where-Object { $_.status -eq "completed" }).Count
            $registry.generated_at = $now
            $registry | ConvertTo-Json -Depth 10 | Set-Content -Path $contractsFile -Encoding UTF8

            # Log transaction
            if (Test-Path $transactionsFile) {
                $txns = Get-Content $transactionsFile -Raw | ConvertFrom-Json
            } else {
                $txns = [ordered]@{ description="Cross-company transactions"; transactions=@() }
            }
            $txns.transactions += [ordered]@{
                id = "TX-$(Get-Date -Format 'yyyyMMdd')-$($txns.transactions.Count + 1)"
                contract_ref = $ContractId
                from = $contract.client
                to = $contract.provider
                amount = $contract.price
                currency = "USD"
                type = "escrow_release"
                timestamp = $now
            }
            $txns | ConvertTo-Json -Depth 10 | Set-Content -Path $transactionsFile -Encoding UTF8

            # Auto-sync: commit and push (MK-15)
            Sync-Push "marketplace: contract $ContractId completed"

            Write-Host "Contract completed: $ContractId (escrow released, quality: $($parsedData.quality_score))" -ForegroundColor Green
        }
    }

    "terminate" {
        if (-not $ContractId) { Write-Error "-ContractId required"; exit 1 }
        $contract = $registry.contracts | Where-Object { $_.id -eq $ContractId }
        if ($contract) {
            $contract.status = "terminated"
            $contract.terminated_at = $now

            # Refund escrow
            $contract.escrow.released = $false

            $registry.total_active = ($registry.contracts | Where-Object { $_.status -eq "active" }).Count
            $registry.generated_at = $now
            $registry | ConvertTo-Json -Depth 10 | Set-Content -Path $contractsFile -Encoding UTF8

            # Log refund transaction
            if (Test-Path $transactionsFile) {
                $txns = Get-Content $transactionsFile -Raw | ConvertFrom-Json
            } else {
                $txns = [ordered]@{ description="Cross-company transactions"; transactions=@() }
            }
            $txns.transactions += [ordered]@{
                id = "TX-$(Get-Date -Format 'yyyyMMdd')-$($txns.transactions.Count + 1)"
                contract_ref = $ContractId
                from = $contract.provider
                to = $contract.client
                amount = $contract.price
                currency = "USD"
                type = "escrow_refund"
                reason = if ($parsedData.reason) { $parsedData.reason } else { "terminated" }
                timestamp = $now
            }
            $txns | ConvertTo-Json -Depth 10 | Set-Content -Path $transactionsFile -Encoding UTF8

            # Auto-sync: commit and push (MK-15)
            Sync-Push "marketplace: contract $ContractId terminated"

            Write-Host "Contract terminated: $ContractId (escrow refunded)" -ForegroundColor Yellow
        }
    }

    "list" {
        $active = $registry.contracts | Where-Object { $_.status -eq "active" }
        Write-Host "Active contracts ($($active.Count)):" -ForegroundColor Cyan
        foreach ($c in $active) {
            Write-Host "  $($c.id) | $($c.client) -> $($c.provider) | $($c.scope) | `$$($c.price)" -ForegroundColor White
        }
        $completed = $registry.contracts | Where-Object { $_.status -eq "completed" }
        if ($completed.Count -gt 0) {
            Write-Host "Completed ($($completed.Count)):" -ForegroundColor Green
            foreach ($c in $completed) {
                Write-Host "  $($c.id) | $($c.client) -> $($c.provider) | Quality: $($c.quality_score)" -ForegroundColor DarkGray
            }
        }
    }
}
