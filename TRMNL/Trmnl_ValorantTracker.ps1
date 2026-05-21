#Set script parameters
param(
    [Parameter(Mandatory = $true)]
    [string]$TrmnlPluginId,
    [Parameter(Mandatory = $true)]
    [string]$APIKey,
    [Parameter(Mandatory = $true)]
    [string]$username,
    [Parameter(Mandatory = $true)]
    [string]$tagline,
    [Parameter(Mandatory = $false)]
    [string]$region
)

if (-not $region) {
    $region = "na"
}

$headers = @{}
$headers.Add("Authorization", "$APIKey")

Function Get-AccountData {
    param(
        [string]$username,
        [string]$tagline
    )

    $uri = "https://api.henrikdev.xyz/valorant/v1/account/$username/$tagline"
    $AccountResponse = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
    Start-Sleep -Seconds 30

    if ($AccountResponse.status -ne 200) {
        Write-Host "Account does not exist"
        return
    }
    else {
        return $AccountResponse.data
    }
}

Function Get-MatchHistory {
    param(
        [string]$username,
        [string]$tagline,
        [string]$region,
        [int]$size = 10
    )

    $uri = "https://api.henrikdev.xyz/valorant/v3/matches/$region/$username/$tagline`?size=$size"
    $MatchHistoryResponse = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
    Start-Sleep -Seconds 30

    if ($MatchHistoryResponse.status -ne 200) {
        return $MatchHistoryResponse
    }
    else {
        return $MatchHistoryResponse.data
    }
}

Function Get-MatchDetails {
    param(
        [string]$matchId,
        [string]$region
    )

    if (-not $region) { $region = "na" }

    $uri = "https://api.henrikdev.xyz/valorant/v4/match/$region/$matchId"
    $MatchDetailsResponse = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
    Start-Sleep -Seconds 30

    if ($MatchDetailsResponse.status -ne 200) {
        Write-Host "Match does not exist"
        return
    }
    else {
        return $MatchDetailsResponse.data
    }
}

Function Get-MMRR {
    param(
        [string]$username,
        [string]$tagline,
        [string]$region
    )

    $uri = "https://api.henrikdev.xyz/valorant/v3/mmr/na/pc/$username/$tagline"
    $MMRRResponse = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
    Start-Sleep -Seconds 30

    if ($MMRRResponse.status -ne 200) {
        Write-Host "MMRR does not exist"
        return
    }
    else {
        return $MMRRResponse.data
    }
}

Function Get-CareerStats {
    param(
        [string]$username,
        [string]$tagline,
        [string]$region
    )

    if (-not $region) { $region = "na" }

    $MMRR = Get-MMRR -username $username -tagline $tagline -region $region

    $TotalGames = 0
    $TotalWins = 0

    $MMRR.seasonal | ForEach-Object {
        $TotalGames += $_.games
        $TotalWins += $_.wins
    }

    $WinRate = [math]::Round(($TotalWins / $TotalGames), 2) * 100
    $WinRate = "$WinRate%"

    $CareerStats = @{
        N  = "$username#$tagline"
        CR = $MMRR.current.tier.name
        PR = $MMRR.peak.tier.name
        TG = $TotalGames
        TW = $TotalWins
        WR = $WinRate
    }

    return $CareerStats
}

Function Get-LastMatches {
    param(
        [string]$username,
        [string]$tagline,
        [string]$region
    )

    if (-not $region) { $region = "na" }

    $MatchesOutput = @()
    $MatchHistory = Get-MatchHistory -username $username -tagline $tagline -region $region -size 10

    foreach ($match in $MatchHistory) {
        $match.players.all_players |
            Where-Object { $_.name -eq $username -and $_.tag -eq $tagline } |
            ForEach-Object {

                $thisMatch = $_
                $date = (Get-Date -Date ([datetime]'1970-01-01' + [timespan]::FromSeconds($match.metadata.game_start))).AddHours(-6)
                $GameStart = $date.ToString("MM/dd hh:mm tt")

                $Details = Get-MatchDetails -matchId $match.metadata.matchid
                $WinningTeam = $Details.teams | Where-Object { $_.won -eq $true }

                $Outcome = if ($WinningTeam.team_id -eq $thisMatch.team) { "Win" } else { "Loss" }

                $MatchesOutput += @{
                    Id = $match.metadata.matchid
                    O  = $Outcome
                    GS = $GameStart
                    Mp = $match.metadata.map
                    Md = $match.metadata.mode
                    Ag = $thisMatch.character
                    K  = $thisMatch.stats.kills
                    D  = $thisMatch.stats.deaths
                    A  = $thisMatch.stats.assists
                    S  = $thisMatch.stats.score
                    BS = $thisMatch.stats.bodyshots
                    HS = $thisMatch.stats.headshots
                    LS = $thisMatch.stats.legshots
                }
        }
    }

    return $MatchesOutput
}

Function New-TrmnlRequestBody {
    param(
        [string]$username,
        [string]$tag
    )

    $Output = @{}
    $LastMatches = Get-LastMatches -username $username -tagline $tag
    $CareerStats = Get-CareerStats -username $username -tagline $tag

    for ($i = 0; $i -lt $LastMatches.Count; $i++) {
        $Match = $LastMatches[$i]
        $Output += @{
            "O_$i"  = $Match.O
            "GS_$i" = $Match.GS
            "Mp_$i" = $Match.Mp
            "Md_$i" = $Match.Md
            "Ag_$i" = $Match.Ag
            "K_$i"  = $Match.K
            "D_$i"  = $Match.D
            "A_$i"  = $Match.A
            "S_$i"  = $Match.S
            "BS_$i" = $Match.BS
            "HS_$i" = $Match.HS
            "LS_$i" = $Match.LS
        }
    }

    $Output += $CareerStats
    return $Output
}

Function Invoke-TrmnlPostRequest {
    param(
        [hashtable]$Body
    )

    $uri = "https://usetrmnl.com/api/custom_plugins/$TrmnlPluginId"
    $TrmnlHeaders = @{ "Content-Type" = "application/json" }

    $TrmnlBody = @{ "merge_variables" = $Body }

    Invoke-RestMethod -Uri $uri -Headers $TrmnlHeaders -Method Post -Body ($TrmnlBody | ConvertTo-Json)
}

$Body = New-TrmnlRequestBody -username $username -tag $tagline
Invoke-TrmnlPostRequest -Body $Body
