# The change engine: detect -> preview -> record originals -> apply -> verify -> (rollback | keep) -> undo later.
# Nothing here prompts; callers must pass -Approved after the user agreed. Results are objects, never thrown errors.

$script:CpReasonCodes = @(
    'approval-required', 'unknown-operation', 'busy', 'already-applied', 'windows-build-too-old',
    'windows-build-unknown', 'access-denied', 'registry-error', 'unsupported-value', 'capture-failed',
    'verify-failed', 'revert-verify-failed', 'no-original-state', 'captured-state-mismatch',
    'store-unavailable', 'unexpected', 'interrupted',
    'unsafe-needs-confirmation', 'app-not-installed', 'app-protected', 'app-remove-failed', 'app-list-failed'
)
$script:CpSupportedKinds = @('DWord', 'String')
$script:CpRevertableStates = @('Verified', 'Applying', 'Reverting', 'RecoveryNeeded')
$script:CpKeepOriginalStates = @('Applying', 'Reverting', 'RecoveryNeeded')

function New-CpResult {
    param(
        [string]$FeatureId,
        [string]$Action,
        [bool]$Success,
        [string]$Status,
        [string]$Reason = '',
        [string]$Detail = ''
    )
    if ($Reason -and $script:CpReasonCodes -cnotcontains $Reason) { throw "Unknown reason code '$Reason'." }
    return [pscustomobject]@{
        FeatureId = $FeatureId
        Action    = $Action
        Success   = $Success
        Status    = $Status
        Reason    = $Reason
        Detail    = $Detail
    }
}

function Get-CpFailureReason {
    param($ErrorRecord)
    $exception = $ErrorRecord.Exception
    while ($null -ne $exception.InnerException) { $exception = $exception.InnerException }
    if ($exception -is [System.UnauthorizedAccessException] -or $exception -is [System.Security.SecurityException]) { return 'access-denied' }
    return 'registry-error'
}

function Test-CpValueEqual {
    param([string]$Kind, $Left, $Right)
    if ($Kind -eq 'DWord') {
        try { return ([int64]$Left -eq [int64]$Right) } catch { return $false }
    }
    return ([string]$Left -ceq [string]$Right)
}

function Test-CpMatchesChange {
    param($Current, $Change)
    if (-not $Current.Exists) { return $false }
    if ($Current.Kind -ne $Change.type) { return $false }
    return (Test-CpValueEqual -Kind $Change.type -Left $Current.Value -Right $Change.value)
}

# Returns a reason code when the feature cannot run on this Windows, otherwise $null.
function Test-CpBuildProblem {
    param($Feature)
    $build = [int](Get-CpWindowsBuild)
    if ($build -le 0) { return 'windows-build-unknown' }
    if ($build -lt [int]$Feature.minBuild) { return 'windows-build-too-old' }
    return $null
}

# Reads the current state of every change in a feature. Never writes.
function Get-CpFeatureStatus {
    param([Parameter(Mandatory)]$Feature)

    $buildProblem = Test-CpBuildProblem -Feature $Feature
    if ($buildProblem) {
        return [pscustomobject]@{ FeatureId = $Feature.id; Status = 'Unsupported'; Reason = $buildProblem; Items = @() }
    }
    $items = New-Object System.Collections.ArrayList
    $matching = 0
    foreach ($change in @($Feature.changes)) {
        try { $current = Read-CpRegistry -Path $change.path -Name $change.name }
        catch {
            return [pscustomobject]@{ FeatureId = $Feature.id; Status = 'Unknown'; Reason = (Get-CpFailureReason $_); Items = @() }
        }
        $isMatch = Test-CpMatchesChange -Current $current -Change $change
        if ($isMatch) { $matching++ }
        [void]$items.Add([pscustomobject]@{
                Path    = $change.path
                Name    = $change.name
                Kind    = $change.type
                Exists  = [bool]$current.Exists
                Current = $current.Value
                Target  = $change.value
                Matches = $isMatch
            })
    }
    $total = $items.Count
    $status = 'Partial'
    if ($matching -eq $total) { $status = 'Applied' }
    elseif ($matching -eq 0) { $status = 'NotApplied' }
    return [pscustomobject]@{ FeatureId = $Feature.id; Status = $status; Reason = ''; Items = $items.ToArray() }
}

function Enter-CpLock {
    $mutex = New-Object System.Threading.Mutex($false, 'Local\CorePilot.Engine')
    $acquired = $false
    try { $acquired = $mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) { $mutex.Dispose(); return $null }
    return $mutex
}

function Exit-CpLock {
    param($Mutex)
    if ($null -eq $Mutex) { return }
    try { $Mutex.ReleaseMutex() } catch { }
    $Mutex.Dispose()
}

# Puts the recorded original values back, then re-reads everything. Returns $true only when all of it is confirmed.
function Restore-CpOriginals {
    param([Parameter(Mandatory)][object[]]$Originals)
    $ok = $true
    foreach ($original in $Originals) {
        try {
            if ($original.exists) {
                Write-CpRegistry -Path $original.path -Name $original.name -Kind $original.kind -Value $original.value
            }
            else {
                Remove-CpRegistry -Path $original.path -Name $original.name
            }
        }
        catch { $ok = $false }
    }
    foreach ($original in $Originals) {
        try {
            $current = Read-CpRegistry -Path $original.path -Name $original.name
            if ($original.exists) {
                if (-not $current.Exists -or $current.Kind -ne $original.kind -or -not (Test-CpValueEqual -Kind $original.kind -Left $current.Value -Right $original.value)) { $ok = $false }
            }
            elseif ($current.Exists) { $ok = $false }
        }
        catch { $ok = $false }
    }
    return $ok
}

# A recorded original is only trusted when it describes exactly this feature's catalog targets.
function Test-CpRecordMatchesFeature {
    param($Record, $Feature)
    try {
        if ($Record.featureId -cne $Feature.id) { return $false }
        $originals = @($Record.originals)
        $changes = @($Feature.changes)
        if ($originals.Count -ne $changes.Count) { return $false }
        $seen = @{}
        foreach ($original in $originals) {
            $key = Get-CpTargetKey -Path ([string]$original.path) -Name ([string]$original.name)
            if ($seen.ContainsKey($key)) { return $false }
            $seen[$key] = $true
            $belongs = $false
            foreach ($change in $changes) {
                if ((Get-CpTargetKey -Path $change.path -Name $change.name) -ceq $key) { $belongs = $true }
            }
            if (-not $belongs) { return $false }
            if ($original.exists -isnot [bool]) { return $false }
            if ($original.exists) {
                if ($script:CpSupportedKinds -cnotcontains [string]$original.kind) { return $false }
                if ($original.kind -eq 'DWord') {
                    if (-not ($original.value -is [int] -or $original.value -is [long])) { return $false }
                    if ($original.value -lt -2147483648 -or $original.value -gt 2147483647) { return $false }
                }
                elseif ($original.value -isnot [string]) { return $false }
            }
        }
        return $true
    }
    catch { return $false }
}

function Invoke-CpApply {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FeatureId,
        [switch]$Approved
    )
    $feature = Get-CpFeature -Id $FeatureId
    if ($null -eq $feature) { return New-CpResult $FeatureId 'Apply' $false 'Refused' 'unknown-operation' }
    if (-not $Approved) { return New-CpResult $FeatureId 'Apply' $false 'Refused' 'approval-required' }
    $buildProblem = Test-CpBuildProblem -Feature $feature
    if ($buildProblem) { return New-CpResult $FeatureId 'Apply' $false 'Refused' $buildProblem }

    $lock = Enter-CpLock
    if ($null -eq $lock) { return New-CpResult $FeatureId 'Apply' $false 'Refused' 'busy' }
    try { $result = Invoke-CpApplyLocked -Feature $feature }
    catch { $result = New-CpResult $FeatureId 'Apply' $false 'Failed' 'unexpected' $_.Exception.Message }
    finally { Exit-CpLock $lock }
    if ($result.Status -in @('Verified', 'Failed', 'RecoveryNeeded')) {
        Add-CpHistory -FeatureId $FeatureId -Action 'Apply' -Status $result.Status -Reason $result.Reason
    }
    return $result
}

function Invoke-CpApplyLocked {
    param($Feature)
    $id = $Feature.id

    try { $record = Read-CpRecord -Id $id }
    catch { return New-CpResult $id 'Apply' $false 'Refused' 'store-unavailable' $_.Exception.Message }

    $status = Get-CpFeatureStatus -Feature $Feature
    if ($status.Status -eq 'Unknown') { return New-CpResult $id 'Apply' $false 'Refused' $status.Reason }
    if ($status.Status -eq 'Applied') { return New-CpResult $id 'Apply' $true 'NoChange' 'already-applied' }

    $originals = $null
    if ($null -ne $record -and $script:CpKeepOriginalStates -contains $record.state) {
        # An earlier run was interrupted: its recorded values are the true originals, never overwrite them.
        if (-not (Test-CpRecordMatchesFeature -Record $record -Feature $Feature)) {
            return New-CpResult $id 'Apply' $false 'Refused' 'captured-state-mismatch'
        }
        $originals = @($record.originals)
    }
    else {
        $captured = New-Object System.Collections.ArrayList
        foreach ($change in @($Feature.changes)) {
            try { $current = Read-CpRegistry -Path $change.path -Name $change.name }
            catch { return New-CpResult $id 'Apply' $false 'Refused' (Get-CpFailureReason $_) $_.Exception.Message }
            if ($current.Exists -and $script:CpSupportedKinds -cnotcontains $current.Kind) {
                return New-CpResult $id 'Apply' $false 'Refused' 'unsupported-value' "$($change.path)\$($change.name) is $($current.Kind)"
            }
            [void]$captured.Add([ordered]@{
                    path   = $change.path
                    name   = $change.name
                    exists = [bool]$current.Exists
                    kind   = $current.Kind
                    value  = $current.Value
                })
        }
        $originals = $captured.ToArray()
    }

    $newRecord = New-CpRecord -FeatureId $id -State 'Applying' -Originals $originals -Build ([int](Get-CpWindowsBuild))
    try { Save-CpRecord -Record $newRecord }
    catch { return New-CpResult $id 'Apply' $false 'Refused' 'store-unavailable' $_.Exception.Message }

    $writeError = $null
    try {
        foreach ($change in @($Feature.changes)) {
            Write-CpRegistry -Path $change.path -Name $change.name -Kind $change.type -Value $change.value
        }
    }
    catch { $writeError = $_ }

    $verified = $false
    if ($null -eq $writeError) {
        $after = Get-CpFeatureStatus -Feature $Feature
        $verified = ($after.Status -eq 'Applied')
    }

    if (-not $verified) {
        $reason = 'verify-failed'
        $detail = ''
        if ($null -ne $writeError) { $reason = Get-CpFailureReason $writeError; $detail = $writeError.Exception.Message }
        if (Restore-CpOriginals -Originals $originals) {
            $newRecord.state = 'Failed'
            try { Save-CpRecord -Record $newRecord } catch { }
            return New-CpResult $id 'Apply' $false 'Failed' $reason $detail
        }
        $newRecord.state = 'RecoveryNeeded'
        try { Save-CpRecord -Record $newRecord } catch { }
        return New-CpResult $id 'Apply' $false 'RecoveryNeeded' $reason $detail
    }

    $newRecord.state = 'Verified'
    try { Save-CpRecord -Record $newRecord } catch { }
    return New-CpResult $id 'Apply' $true 'Verified'
}

function Invoke-CpRevert {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FeatureId,
        [switch]$Approved
    )
    $feature = Get-CpFeature -Id $FeatureId
    if ($null -eq $feature) { return New-CpResult $FeatureId 'Undo' $false 'Refused' 'unknown-operation' }
    if (-not $Approved) { return New-CpResult $FeatureId 'Undo' $false 'Refused' 'approval-required' }

    $lock = Enter-CpLock
    if ($null -eq $lock) { return New-CpResult $FeatureId 'Undo' $false 'Refused' 'busy' }
    try { $result = Invoke-CpRevertLocked -Feature $feature }
    catch { $result = New-CpResult $FeatureId 'Undo' $false 'Failed' 'unexpected' $_.Exception.Message }
    finally { Exit-CpLock $lock }
    if ($result.Status -in @('Reverted', 'Failed', 'RecoveryNeeded')) {
        Add-CpHistory -FeatureId $FeatureId -Action 'Undo' -Status $result.Status -Reason $result.Reason
    }
    return $result
}

function Invoke-CpRevertLocked {
    param($Feature)
    $id = $Feature.id

    try { $record = Read-CpRecord -Id $id }
    catch { return New-CpResult $id 'Undo' $false 'Refused' 'captured-state-mismatch' $_.Exception.Message }
    if ($null -eq $record -or $script:CpRevertableStates -cnotcontains $record.state) {
        return New-CpResult $id 'Undo' $false 'Refused' 'no-original-state'
    }
    if (-not (Test-CpRecordMatchesFeature -Record $record -Feature $Feature)) {
        return New-CpResult $id 'Undo' $false 'Refused' 'captured-state-mismatch'
    }

    $record.state = 'Reverting'
    try { Save-CpRecord -Record $record }
    catch { return New-CpResult $id 'Undo' $false 'Refused' 'store-unavailable' $_.Exception.Message }

    if (Restore-CpOriginals -Originals @($record.originals)) {
        $record.state = 'Reverted'
        try { Save-CpRecord -Record $record } catch { }
        return New-CpResult $id 'Undo' $true 'Reverted'
    }
    $record.state = 'RecoveryNeeded'
    try { Save-CpRecord -Record $record } catch { }
    return New-CpResult $id 'Undo' $false 'RecoveryNeeded' 'revert-verify-failed'
}
