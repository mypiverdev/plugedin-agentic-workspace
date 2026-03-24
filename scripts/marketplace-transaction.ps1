<#
.SYNOPSIS
    Manage marketplace transaction workspaces -the neutral zone where companies transact.
.DESCRIPTION
    When a contract is created between client and provider, a transaction folder is
    created in Companies/market/transactions/. The vendor works there, deliverables
    land there, escrow lives there, and every event is logged there.
.USAGE
    marketplace-transaction.ps1 -Action create -Client piver -Provider meridian -ContractId "MC-piver-meridian-001" -Data '{"scope":"Market research","price":300,"engagement_type":"task","deliverables":["research-report.md"],"deadline":"2026-04-01","evaluation_criteria":["completeness","accuracy"]}'
    marketplace-transaction.ps1 -Action log -TxnId "TXN-piver-meridian-001" -Event "work.started" -By meridian -Detail "Research phase begun"
    marketplace-transaction.ps1 -Action deliver -TxnId "TXN-piver-meridian-001" -By meridian -Files "research-report.md"
    marketplace-transaction.ps1 -Action accept -TxnId "TXN-piver-meridian-001" -By piver -Data '{"quality_score":0.92}'
    marketplace-transaction.ps1 -Action reject -TxnId "TXN-piver-meridian-001" -By piver -Data '{"reason":"Missing competitor analysis section"}'
    marketplace-transaction.ps1 -Action terminate -TxnId "TXN-piver-meridian-001" -By piver -Data '{"reason":"Scope changed, no longer needed"}'
    marketplace-transaction.ps1 -Action status -TxnId "TXN-piver-meridian-001"
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("create", "log", "deliver", "accept", "reject", "terminate", "status")]
    [string]$Action,

    [string]$Client = "",
    [string]$Provider = "",
    [string]$ContractId = "",
    [string]$TxnId = "",
    [string]$Event = "",
    [string]$By = "",
    [string]$Detail = "",
    [string]$Files = "",
    [string]$Data = "{}"
)

$ErrorActionPreference = "SilentlyContinue"

. "$PSScriptRoot\resolve-market-paths.ps1"

# Auto-sync: pull latest before any marketplace operation (MK-15)
Sync-Pull
$txnRoot = $script:MarketPaths.Transactions
$now = Get-Timestamp

# Ensure transactions directory exists
if (-not (Test-Path $txnRoot)) { New-Item -ItemType Directory -Path $txnRoot -Force | Out-Null }

# --- Helper: read/write JSON ---
function Read-Json($path) {
    if (Test-Path $path) { return (Get-Content $path -Raw | ConvertFrom-Json) }
    return $null
}
function Write-Json($path, $obj) {
    $dir = Split-Path $path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $obj | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8
}

# --- Helper: get company workspace paths ---
function Get-CompanyPaths($companyId) {
    $companiesDir = if ($script:UniverseRoot) { Join-Path $script:UniverseRoot "Companies" } else { Split-Path $script:MarketRoot -Parent }
    $compDir = Join-Path $companiesDir $companyId
    $corp = Join-Path $compDir "corporate"
    $off = Join-Path $compDir "office"
    $depts = Join-Path $corp "departments"
    return @{
        Root        = $compDir
        Corporate   = $corp
        StateJson   = Join-Path $corp "state.json"
        ProjectReg  = Join-Path $corp "project-registry.json"
        Treasury    = Join-Path (Join-Path $depts "treasury") "workspace"
        Sales       = Join-Path (Join-Path $depts "sales") "workspace"
        Reputation  = Join-Path (Join-Path $depts "reputation") "workspace"
        Admin       = Join-Path (Join-Path $depts "administration") "workspace"
        Records     = Join-Path $off "records"
        Telemetry   = Join-Path $corp "telemetry"
    }
}

# --- Helper: update company financials for external transaction ---
function Update-CompanyFinancials($companyId, $role, $counterparty, $amount, $project, $qualityScore) {
    $p = Get-CompanyPaths $companyId
    $financesFile = Join-Path $p.Treasury "finances.json"
    $finances = Read-Json $financesFile
    if (-not $finances) { return }

    if ($role -eq "client") {
        # Client PAYS: cash decreases, record expense
        $finances.accounts.cash.balance -= $amount
        $finances.accounts.cash.last_updated = $now
        $finances.costs.total_this_month += $amount
        $finances.costs.by_project += [ordered]@{
            project = $project
            external_provider = $counterparty
            total = $amount
            type = "external_engagement"
            recorded_at = $now
        }
        # Close payable if exists, otherwise add one and close it
        $payable = $finances.accounts.receivables | Where-Object { $_.project -eq $project -and $_.status -eq "pending" }
        if ($payable) { $payable | ForEach-Object { $_.status = "paid" } }
        Write-Json $financesFile $finances
        Write-Host "  [treasury] ${companyId}: -$amount (expense to $counterparty)" -ForegroundColor DarkCyan
    }
    elseif ($role -eq "provider") {
        # Provider RECEIVES: cash increases, record revenue
        $finances.accounts.cash.balance += $amount
        $finances.accounts.cash.last_updated = $now
        $finances.revenue.total_this_month += $amount
        $finances.revenue.total_all_time += $amount
        # Close receivable
        $receivable = $finances.accounts.receivables | Where-Object { $_.project -eq $project -and $_.status -eq "pending" }
        if ($receivable) { $receivable | ForEach-Object { $_.status = "paid" } }
        Write-Json $financesFile $finances
        Write-Host "  [treasury] ${companyId}: +$amount (revenue from $counterparty)" -ForegroundColor DarkCyan
    }

    # Update state.json
    $state = Read-Json $p.StateJson
    if ($state) {
        if ($role -eq "provider") {
            $state.performance_snapshot.revenue_this_month += $amount
        }
        $state.lastModifiedBy = "marketplace@$([Environment]::MachineName)"
        $state.updatedAt = $now
        Write-Json $p.StateJson $state
    }

    # Update quality in reputation department (provider only)
    if ($role -eq "provider" -and $qualityScore) {
        $qualityFile = Join-Path $p.Reputation "quality-tracker.json"
        $quality = Read-Json $qualityFile
        if ($quality) {
            $quality.scores += [ordered]@{ project=$project; score=$qualityScore; scored_at=$now; external=$true; client=$counterparty }
            $allScores = $quality.scores | ForEach-Object { $_.score }
            $quality.trends.current_average = [math]::Round(($allScores | Measure-Object -Average).Average, 3)
            Write-Json $qualityFile $quality
            Write-Host "  [reputation] ${companyId}: quality $qualityScore logged" -ForegroundColor DarkCyan
        }
    }

    # Create record in administration
    $registryFile = Join-Path $p.Records "registry.json"
    $registry = Read-Json $registryFile
    if ($registry) {
        $recordType = if ($role -eq "client") { "expense-record" } else { "revenue-record" }
        $recordId = "R-$(Get-Date -Format 'yyyyMMdd')-$($registry.total_records + 1)"
        $registry.index += [ordered]@{
            record_id = $recordId
            object_type = $recordType
            object_id = $project
            label = "$recordType/confidential/financial/$(Get-Date -Format 'yyyy')"
            authority = "administration"
            counterparty = $counterparty
            amount = $amount
            status = "active"
            created_at = $now
        }
        $registry.total_records += 1
        $registry.last_updated = $now
        Write-Json $registryFile $registry
        Write-Host "  [admin] ${companyId}: $recordType created ($recordId)" -ForegroundColor DarkCyan
    }

    # Update project registry
    $projReg = Read-Json $p.ProjectReg
    if ($projReg) {
        $existing = $projReg.projects | Where-Object { $_.project_id -eq $project }
        if (-not $existing) {
            $projReg.projects += [ordered]@{
                project_id = $project
                client = @{ entity_id = if ($role -eq "client") { $companyId } else { $counterparty }; type = "external" }
                engagement_type = "external"
                role = $role
                counterparty = $counterparty
                objective = ""
                status = "active"
                started_at = $now
                completed_at = $null
                quality_score = $qualityScore
            }
        }
        Write-Json $p.ProjectReg $projReg
    }

    # Log telemetry
    $eventsFile = Join-Path $p.Telemetry "events.jsonl"
    if (-not (Test-Path $p.Telemetry)) { New-Item -ItemType Directory -Path $p.Telemetry -Force | Out-Null }
    $telEvent = [ordered]@{
        timestamp = $now
        type = "external.$role.payment"
        entity = $companyId
        counterparty = $counterparty
        amount = $amount
        project = $project
        machine = [Environment]::MachineName
    } | ConvertTo-Json -Compress
    Add-Content -Path $eventsFile -Value $telEvent -Encoding UTF8
}

# --- Helper: fire event into a company's workspace ---
function Fire-CompanyEvent($companyId, $event, $project, $data) {
    $companyDir = Get-CompanyDir $companyId
    if ($companyDir) {
        $fireScript = Join-Path (Join-Path (Join-Path $companyDir "government") "lib") "fire-event.ps1"
        if (Test-Path $fireScript) {
            Push-Location $companyDir
            & $fireScript -Event $event -Project $project -Data $data 2>&1 | Out-Null
            Pop-Location
            Write-Host "  [event] $event fired in $companyId" -ForegroundColor DarkCyan
        } else {
            Write-Host "  [event] SKIP: fire-event.ps1 not found for $companyId" -ForegroundColor Yellow
        }
    }
}

# --- Helper: append to log ---
function Append-Log($txnDir, $event, $by, $detail, $files) {
    $logFile = Join-Path $txnDir "log.json"
    $log = @()
    if (Test-Path $logFile) {
        try { $log = @(Get-Content $logFile -Raw | ConvertFrom-Json) } catch { $log = @() }
    }
    $entry = [ordered]@{
        timestamp = $now
        event     = $event
        by        = $by
        detail    = $detail
    }
    if ($files) { $entry.files = $files -split ',' | ForEach-Object { $_.Trim() } }
    $log += $entry
    $log | ConvertTo-Json -Depth 10 | Set-Content -Path $logFile -Encoding UTF8
}

switch ($Action) {
    # ================================================================
    # CREATE -set up the transaction workspace
    # ================================================================
    "create" {
        if (-not $Client -or -not $Provider -or -not $ContractId) {
            Write-Error "-Client, -Provider, and -ContractId required"
            exit 1
        }
        $parsedData = $Data | ConvertFrom-Json

        # Generate transaction ID
        $existingTxns = Get-ChildItem -Path $txnRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "^TXN-$Client-$Provider" }
        $seq = ($existingTxns.Count + 1).ToString('000')
        $txnId = "TXN-$Client-$Provider-$seq"
        $txnDir = Join-Path $txnRoot $txnId

        # Create directory structure
        $workDir = Join-Path (Join-Path $txnDir "workspace") "work"
        $delDir = Join-Path $txnDir "deliverables"
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
        New-Item -ItemType Directory -Path $delDir -Force | Out-Null

        # contract.json
        $contract = [ordered]@{
            id               = $ContractId
            transaction_id   = $txnId
            type             = "external"
            client           = $Client
            provider         = $Provider
            scope            = if ($parsedData.scope) { $parsedData.scope } else { "" }
            price            = if ($parsedData.price) { $parsedData.price } else { 0 }
            currency         = "USD"
            engagement_type  = if ($parsedData.engagement_type) { $parsedData.engagement_type } else { "task" }
            deliverables     = if ($parsedData.deliverables) { $parsedData.deliverables } else { @() }
            deadline         = if ($parsedData.deadline) { $parsedData.deadline } else { $null }
            status           = "active"
            created_at       = $now
        }
        $contract | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $txnDir "contract.json") -Encoding UTF8

        # escrow.json
        $escrow = [ordered]@{
            amount            = if ($parsedData.price) { $parsedData.price } else { 0 }
            currency          = "USD"
            funded_by         = $Client
            funded_at         = $now
            status            = "locked"
            release_conditions = @("client_acceptance")
            released_at       = $null
            released_to       = $null
            refunded_at       = $null
        }
        $escrow | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $txnDir "escrow.json") -Encoding UTF8

        # rules.json
        $rules = [ordered]@{
            deliverables         = if ($parsedData.deliverables) { $parsedData.deliverables } else { @() }
            evaluation_criteria  = if ($parsedData.evaluation_criteria) { $parsedData.evaluation_criteria } else { @() }
            deadline             = if ($parsedData.deadline) { $parsedData.deadline } else { $null }
            revision_limit       = 2
            workspace_rules      = @(
                "Provider works in workspace/work/"
                "Final deliverables go in deliverables/"
                "Client can read workspace/ at any time"
                "Neither party modifies escrow.json directly"
                "All actions are logged to log.json"
            )
        }
        $rules | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $txnDir "rules.json") -Encoding UTF8

        # Initialize log
        Append-Log $txnDir "contract.created" "system" "Contract $ContractId between $Client (client) and $Provider (provider). Escrow: $($escrow.amount)" ""
        Append-Log $txnDir "escrow.funded" $Client "Escrow locked: $($escrow.amount)" ""

        # Register engagement in both companies' project registries + create financial entries
        # Client: records a payable (money owed to provider)
        $clientPaths = Get-CompanyPaths $Client
        $clientFinances = Read-Json (Join-Path $clientPaths.Treasury "finances.json")
        if ($clientFinances) {
            $clientFinances.accounts.receivables += [ordered]@{
                project = $txnId; client = $Provider; amount = $contract.price
                status = "pending"; type = "external_payable"; created = $now
            }
            Write-Json (Join-Path $clientPaths.Treasury "finances.json") $clientFinances
            Write-Host "  [treasury] ${Client}: payable of $($contract.price) to $Provider" -ForegroundColor DarkCyan
        }
        # Client project registry
        $clientProjReg = Read-Json $clientPaths.ProjectReg
        if ($clientProjReg) {
            $clientProjReg.projects += [ordered]@{
                project_id = $txnId; client = @{ entity_id = $Client; type = "external" }
                engagement_type = "external"; role = "client"; counterparty = $Provider
                objective = $contract.scope; status = "active"; started_at = $now
                completed_at = $null; quality_score = $null
            }
            Write-Json $clientPaths.ProjectReg $clientProjReg
        }
        # Client admin record
        $clientRecords = Read-Json (Join-Path $clientPaths.Records "registry.json")
        if ($clientRecords) {
            $clientRecords.index += [ordered]@{
                record_id = "R-$(Get-Date -Format 'yyyyMMdd')-$($clientRecords.total_records + 1)"
                object_type = "contract-record"; object_id = $txnId
                label = "contract-record/confidential/financial/$(Get-Date -Format 'yyyy')"
                authority = "administration"; counterparty = $Provider; status = "active"; created_at = $now
            }
            $clientRecords.total_records += 1
            Write-Json (Join-Path $clientPaths.Records "registry.json") $clientRecords
        }

        # Provider: records a receivable (money owed from client)
        $providerPaths = Get-CompanyPaths $Provider
        $providerFinances = Read-Json (Join-Path $providerPaths.Treasury "finances.json")
        if ($providerFinances) {
            $providerFinances.accounts.receivables += [ordered]@{
                project = $txnId; client = $Client; amount = $contract.price
                status = "pending"; type = "external_receivable"; created = $now
            }
            $providerFinances.revenue.total_this_month += $contract.price
            Write-Json (Join-Path $providerPaths.Treasury "finances.json") $providerFinances
            Write-Host "  [treasury] ${Provider}: receivable of $($contract.price) from $Client" -ForegroundColor DarkCyan
        }
        # Provider project registry
        $providerProjReg = Read-Json $providerPaths.ProjectReg
        if ($providerProjReg) {
            $providerProjReg.projects += [ordered]@{
                project_id = $txnId; client = @{ entity_id = $Client; type = "external" }
                engagement_type = "external"; role = "provider"; counterparty = $Client
                objective = $contract.scope; status = "active"; started_at = $now
                completed_at = $null; quality_score = $null
            }
            Write-Json $providerPaths.ProjectReg $providerProjReg
        }
        # Provider admin record
        $providerRecords = Read-Json (Join-Path $providerPaths.Records "registry.json")
        if ($providerRecords) {
            $providerRecords.index += [ordered]@{
                record_id = "R-$(Get-Date -Format 'yyyyMMdd')-$($providerRecords.total_records + 1)"
                object_type = "contract-record"; object_id = $txnId
                label = "contract-record/confidential/financial/$(Get-Date -Format 'yyyy')"
                authority = "administration"; counterparty = $Client; status = "active"; created_at = $now
            }
            $providerRecords.total_records += 1
            Write-Json (Join-Path $providerPaths.Records "registry.json") $providerRecords
        }

        Write-Host "Transaction workspace created: $txnId" -ForegroundColor Green
        Write-Host "  Path: $txnDir" -ForegroundColor White
        Write-Host "  Contract: $ContractId | $Client -> $Provider | $($contract.price)" -ForegroundColor White
        Write-Host "  Provider workspace: $txnDir\workspace\work\" -ForegroundColor White
        Write-Output $txnId
    }

    # ================================================================
    # LOG -append an event to the transaction log
    # ================================================================
    "log" {
        if (-not $TxnId -or -not $Event -or -not $By) {
            Write-Error "-TxnId, -Event, and -By required"
            exit 1
        }
        $txnDir = Join-Path $txnRoot $TxnId
        if (-not (Test-Path $txnDir)) { Write-Error "Transaction not found: $TxnId"; exit 1 }

        Append-Log $txnDir $Event $By $Detail $Files
        Sync-Push "marketplace: $Event by $By in $TxnId"
        Write-Host "Logged: $Event by $By in $TxnId" -ForegroundColor Green
    }

    # ================================================================
    # DELIVER -provider declares work done, stages deliverables
    # ================================================================
    "deliver" {
        if (-not $TxnId -or -not $By) {
            Write-Error "-TxnId and -By required"
            exit 1
        }
        $txnDir = Join-Path $txnRoot $TxnId
        if (-not (Test-Path $txnDir)) { Write-Error "Transaction not found: $TxnId"; exit 1 }

        $workDir = Join-Path (Join-Path $txnDir "workspace") "work"
        $delDir = Join-Path $txnDir "deliverables"

        # Copy all files from work/ to deliverables/
        $copiedFiles = @()
        if (Test-Path $workDir) {
            Get-ChildItem -Path $workDir -File -Recurse | ForEach-Object {
                $relativePath = $_.FullName.Substring($workDir.Length + 1)
                $destPath = Join-Path $delDir $relativePath
                $destDir = Split-Path $destPath -Parent
                if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
                Copy-Item -Path $_.FullName -Destination $destPath -Force
                $copiedFiles += $relativePath
            }
        }

        # If specific files specified, only log those
        if ($Files) {
            $copiedFiles = ($Files -split ',') | ForEach-Object { $_.Trim() }
        }

        Append-Log $txnDir "work.delivered" $By "Provider declares work complete. $($copiedFiles.Count) files staged for review." ($copiedFiles -join ',')

        # Update contract status
        $contractFile = Join-Path $txnDir "contract.json"
        if (Test-Path $contractFile) {
            $contract = Get-Content $contractFile -Raw | ConvertFrom-Json
            $contract.status = "delivered"
            $contract | ConvertTo-Json -Depth 10 | Set-Content -Path $contractFile -Encoding UTF8
        }

        Sync-Push "marketplace: work delivered in $TxnId"
        Write-Host "Delivered: $($copiedFiles.Count) files staged in $TxnId/deliverables/" -ForegroundColor Green
        $copiedFiles | ForEach-Object { Write-Host "  $_" -ForegroundColor White }
    }

    # ================================================================
    # ACCEPT -client accepts deliverables, releases escrow
    # ================================================================
    "accept" {
        if (-not $TxnId -or -not $By) {
            Write-Error "-TxnId and -By required"
            exit 1
        }
        $txnDir = Join-Path $txnRoot $TxnId
        if (-not (Test-Path $txnDir)) { Write-Error "Transaction not found: $TxnId"; exit 1 }

        $parsedData = $Data | ConvertFrom-Json
        $qualityScore = if ($parsedData.quality_score) { $parsedData.quality_score } else { $null }

        # Release escrow
        $escrowFile = Join-Path $txnDir "escrow.json"
        $escrow = Get-Content $escrowFile -Raw | ConvertFrom-Json
        $provider = (Get-Content (Join-Path $txnDir "contract.json") -Raw | ConvertFrom-Json).provider
        $escrow.status = "released"
        $escrow.released_at = $now
        $escrow.released_to = $provider
        $escrow | ConvertTo-Json -Depth 5 | Set-Content -Path $escrowFile -Encoding UTF8

        # Update contract
        $contractFile = Join-Path $txnDir "contract.json"
        $contract = Get-Content $contractFile -Raw | ConvertFrom-Json
        $contract.status = "completed"
        $contract | ConvertTo-Json -Depth 10 | Set-Content -Path $contractFile -Encoding UTF8

        # Log
        $detail = "Client accepted deliverables. Escrow $($escrow.amount) released to $provider."
        if ($qualityScore) { $detail += " Quality score: $qualityScore" }
        Append-Log $txnDir "work.accepted" $By $detail ""
        Append-Log $txnDir "escrow.released" "system" "Escrow $($escrow.amount) released to $provider" ""
        Append-Log $txnDir "engagement.closed" "system" "Transaction complete" ""

        # Update both companies' financials
        $client = $contract.client
        Update-CompanyFinancials $client "client" $provider $escrow.amount $TxnId $null
        Update-CompanyFinancials $provider "provider" $client $escrow.amount $TxnId $qualityScore

        # Mark projects as completed in both registries
        foreach ($compId in @($client, $provider)) {
            $cp = Get-CompanyPaths $compId
            $projReg = Read-Json $cp.ProjectReg
            if ($projReg) {
                $projReg.projects | Where-Object { $_.project_id -eq $TxnId } | ForEach-Object {
                    $_.status = "completed"
                    $_.completed_at = $now
                    $_.quality_score = $qualityScore
                }
                Write-Json $cp.ProjectReg $projReg
            }
        }

        # Update marketplace contracts.json
        $contractsScript = Join-Path $PSScriptRoot "marketplace-contracts.ps1"
        if (Test-Path $contractsScript) {
            $completeData = @{ quality_score = $qualityScore } | ConvertTo-Json -Compress
            & $contractsScript -Action complete -ContractId $contract.id -Data $completeData
        }

        # Update reputation
        $reputationScript = Join-Path $PSScriptRoot "marketplace-reputation.ps1"
        if (Test-Path $reputationScript) {
            & $reputationScript 2>&1 | Out-Null
        }

        Sync-Push "marketplace: $TxnId accepted, escrow released"
        Write-Host "Accepted: $TxnId - escrow $($escrow.amount) released to $provider" -ForegroundColor Green
        if ($qualityScore) { Write-Host "  Quality: $qualityScore" -ForegroundColor White }
    }

    # ================================================================
    # REJECT -client rejects deliverables, provider can revise
    # ================================================================
    "reject" {
        if (-not $TxnId -or -not $By) {
            Write-Error "-TxnId and -By required"
            exit 1
        }
        $txnDir = Join-Path $txnRoot $TxnId
        if (-not (Test-Path $txnDir)) { Write-Error "Transaction not found: $TxnId"; exit 1 }

        $parsedData = $Data | ConvertFrom-Json
        $reason = if ($parsedData.reason) { $parsedData.reason } else { "Does not meet requirements" }

        # Check revision limit
        $logFile = Join-Path $txnDir "log.json"
        $log = @(Get-Content $logFile -Raw | ConvertFrom-Json)
        $rejections = ($log | Where-Object { $_.event -eq "work.rejected" }).Count
        $rulesFile = Join-Path $txnDir "rules.json"
        $rules = Get-Content $rulesFile -Raw | ConvertFrom-Json
        $limit = if ($rules.revision_limit) { $rules.revision_limit } else { 2 }

        if ($rejections -ge $limit) {
            Write-Host "Revision limit ($limit) reached. Consider terminating the contract." -ForegroundColor Yellow
        }

        # Update contract status back to active (provider can revise)
        $contractFile = Join-Path $txnDir "contract.json"
        $contract = Get-Content $contractFile -Raw | ConvertFrom-Json
        $contract.status = "revision_requested"
        $contract | ConvertTo-Json -Depth 10 | Set-Content -Path $contractFile -Encoding UTF8

        # Clear deliverables/ for re-delivery
        $delDir = Join-Path $txnDir "deliverables"
        Get-ChildItem -Path $delDir -File -Recurse | Remove-Item -Force

        Append-Log $txnDir "work.rejected" $By "Rejection #$($rejections + 1): $reason" ""
        Append-Log $txnDir "revision.requested" "system" "Deliverables cleared. Provider may revise and re-deliver. ($($rejections + 1)/$limit revisions used)" ""

        Sync-Push "marketplace: $TxnId rejected, revision requested"
        Write-Host "Rejected: $TxnId -revision requested ($($rejections + 1)/$limit)" -ForegroundColor Yellow
        Write-Host "  Reason: $reason" -ForegroundColor White
    }

    # ================================================================
    # TERMINATE -end the engagement early
    # ================================================================
    "terminate" {
        if (-not $TxnId -or -not $By) {
            Write-Error "-TxnId and -By required"
            exit 1
        }
        $txnDir = Join-Path $txnRoot $TxnId
        if (-not (Test-Path $txnDir)) { Write-Error "Transaction not found: $TxnId"; exit 1 }

        $parsedData = $Data | ConvertFrom-Json
        $reason = if ($parsedData.reason) { $parsedData.reason } else { "Terminated by $By" }

        # Refund escrow to client
        $escrowFile = Join-Path $txnDir "escrow.json"
        $escrow = Get-Content $escrowFile -Raw | ConvertFrom-Json
        $contractFile = Join-Path $txnDir "contract.json"
        $contract = Get-Content $contractFile -Raw | ConvertFrom-Json

        $escrow.status = "refunded"
        $escrow.refunded_at = $now
        $escrow | ConvertTo-Json -Depth 5 | Set-Content -Path $escrowFile -Encoding UTF8

        $contract.status = "terminated"
        $contract | ConvertTo-Json -Depth 10 | Set-Content -Path $contractFile -Encoding UTF8

        Append-Log $txnDir "engagement.terminated" $By "Reason: $reason" ""
        Append-Log $txnDir "escrow.refunded" "system" "Escrow $($escrow.amount) refunded to $($contract.client)" ""

        # Update marketplace contracts.json
        $contractsScript = Join-Path $PSScriptRoot "marketplace-contracts.ps1"
        if (Test-Path $contractsScript) {
            & $contractsScript -Action terminate -ContractId $contract.id -Data (@{ reason = $reason } | ConvertTo-Json -Compress)
        }

        # Update reputation
        $reputationScript = Join-Path $PSScriptRoot "marketplace-reputation.ps1"
        if (Test-Path $reputationScript) {
            & $reputationScript 2>&1 | Out-Null
        }

        Sync-Push "marketplace: $TxnId terminated, escrow refunded"
        Write-Host "Terminated: $TxnId -escrow refunded to $($contract.client)" -ForegroundColor Yellow
        Write-Host "  Reason: $reason" -ForegroundColor White
    }

    # ================================================================
    # STATUS -show current state of a transaction
    # ================================================================
    "status" {
        if (-not $TxnId) {
            # List all transactions
            $txnDirs = Get-ChildItem -Path $txnRoot -Directory -ErrorAction SilentlyContinue
            if ($txnDirs.Count -eq 0) {
                Write-Host "No transactions" -ForegroundColor Yellow
            } else {
                Write-Host "Transactions ($($txnDirs.Count)):" -ForegroundColor Cyan
                foreach ($d in $txnDirs) {
                    $cf = Join-Path $d.FullName "contract.json"
                    if (Test-Path $cf) {
                        $c = Get-Content $cf -Raw | ConvertFrom-Json
                        $ef = Join-Path $d.FullName "escrow.json"
                        $e = Get-Content $ef -Raw | ConvertFrom-Json
                        Write-Host "  $($d.Name) | $($c.client) -> $($c.provider) | $($c.status) | Escrow: $($e.status) $($e.amount)" -ForegroundColor White
                    }
                }
            }
            return
        }

        $txnDir = Join-Path $txnRoot $TxnId
        if (-not (Test-Path $txnDir)) { Write-Error "Transaction not found: $TxnId"; exit 1 }

        $contract = Get-Content (Join-Path $txnDir "contract.json") -Raw | ConvertFrom-Json
        $escrow = Get-Content (Join-Path $txnDir "escrow.json") -Raw | ConvertFrom-Json
        $log = @(Get-Content (Join-Path $txnDir "log.json") -Raw | ConvertFrom-Json)

        # Count deliverable files
        $delDir = Join-Path $txnDir "deliverables"
        $delFiles = Get-ChildItem -Path $delDir -File -Recurse -ErrorAction SilentlyContinue
        $workDir = Join-Path (Join-Path $txnDir "workspace") "work"
        $workFiles = Get-ChildItem -Path $workDir -File -Recurse -ErrorAction SilentlyContinue

        Write-Host "=== Transaction: $TxnId ===" -ForegroundColor Cyan
        Write-Host "  Client:       $($contract.client)" -ForegroundColor White
        Write-Host "  Provider:     $($contract.provider)" -ForegroundColor White
        Write-Host "  Scope:        $($contract.scope)" -ForegroundColor White
        Write-Host "  Status:       $($contract.status)" -ForegroundColor $(if ($contract.status -eq "completed") { "Green" } elseif ($contract.status -eq "terminated") { "Red" } else { "Yellow" })
        Write-Host "  Escrow:       $($escrow.status) $($escrow.amount)" -ForegroundColor White
        Write-Host "  Work files:   $($workFiles.Count)" -ForegroundColor White
        Write-Host "  Deliverables: $($delFiles.Count)" -ForegroundColor White
        Write-Host "  Log entries:  $($log.Count)" -ForegroundColor White
        Write-Host "  Latest event: $($log[-1].event) by $($log[-1].by) at $($log[-1].timestamp)" -ForegroundColor DarkGray
    }
}
