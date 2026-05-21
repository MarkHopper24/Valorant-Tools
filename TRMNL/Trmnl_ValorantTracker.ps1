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
        Name                  = "$username#$tagline"
        CurrentRating         = $MMRR.current.tier.name
        PeakRating            = $MMRR.peak.tier.name
        TotalCompetitiveGames = $TotalGames
        TotalWins             = $TotalWins
        WinRate               = $WinRate
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
                    Id        = $match.metadata.matchid
                    Outcome   = $Outcome
                    GameStart = $GameStart
                    Map       = $match.metadata.map
                    Mode      = $match.metadata.mode
                    Agent     = $thisMatch.character
                    Kills     = $thisMatch.stats.kills
                    Deaths    = $thisMatch.stats.deaths
                    Assists   = $thisMatch.stats.assists
                    Score     = $thisMatch.stats.score
                    BodyShots = $thisMatch.stats.bodyshots
                    HeadShots = $thisMatch.stats.headshots
                    LegShots  = $thisMatch.stats.legshots
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
            "Outcome_$i"    = $Match.Outcome
            "Game_Start_$i" = $Match.GameStart
            "Map_$i"        = $Match.Map
            "Mode_$i"       = $Match.Mode
            "Agent_$i"      = $Match.Agent
            "Kills_$i"      = $Match.Kills
            "Deaths_$i"     = $Match.Deaths
            "Assists_$i"    = $Match.Assists
            "Score_$i"      = $Match.Score
            "Body_Shots_$i" = $Match.BodyShots
            "Head_Shots_$i" = $Match.HeadShots
            "Leg_Shots_$i"  = $Match.LegShots
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
