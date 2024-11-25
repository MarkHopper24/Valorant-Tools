#Set script parameters
param(
    #API Key
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

## valorant header
$headers = @{}
$headers.Add("Authorization", "$APIKey")

Function Get-AccountData {
    param(
        [Parameter(Mandatory = $true)]
        [string]$username,
        [Parameter(Mandatory = $true)]
        [string]$tagline
    )

    $uri = "https://api.henrikdev.xyz/valorant/v1/account/$username/$tagline"

    $AccountResponse = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get

    #If status == 200, then the account exists
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
        [Parameter(Mandatory = $true)]
        [string]$username,
        [Parameter(Mandatory = $true)]
        [string]$tagline,
        [Parameter(Mandatory = $true)]
        [string]$region
    )

    $uri = "https://api.henrikdev.xyz/valorant/v3/matches/$region/$username/$tagline"

    $MatchHistoryResponse = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get

    if ($MatchHistoryResponse.status -ne 200) {
        Write-Host "Match history does not exist"
        return
    }
    else {
        return $MatchHistoryResponse.data
    }
}

Function Get-MatchDetails {
    param(
        [Parameter(Mandatory = $true)]
        [string]$matchId,
        [Parameter(Mandatory = $false)]
        [string]$region
    )
    if (-not $region) {
        $region = "na"
    }

    $uri = "https://api.henrikdev.xyz/valorant/v4/match/$region/$matchId"

    $MatchDetailsResponse = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get

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
        [Parameter(Mandatory = $true)]
        [string]$username,
        [Parameter(Mandatory = $true)]
        [string]$tagline,
        [Parameter(Mandatory = $false)]
        [string]$region
    )

    $uri = "https://api.henrikdev.xyz/valorant/v3/mmr/na/pc/$username/$tagline"

    $MMRRResponse = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get

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
        [Parameter(Mandatory = $true)]
        [string]$username,
        [Parameter(Mandatory = $true)]
        [string]$tagline,
        [Parameter(Mandatory = $false)]
        [string]$region
    )

    $Name = $username + "#" + $tagline

    if (-not $region) {
        $region = "na"
    }

    $MMRR = Get-MMRR -username $username -tagline $tagline -region $region

    $TotalGames = 0
    $TotalWins = 0

    $MMRR.seasonal | ForEach-Object {
        $Season = $_
        $TotalGames += $Season.games
        $TotalWins += $Season.wins
    } 

    $WinRate = $TotalWins / $TotalGames
    $WinRate = [math]::Round($WinRate, 2)
    $WinRate = $WinRate * 100
    $WinRate = $WinRate.ToString() + "%"

    $PeakRating = $MMRR.peak.tier.name
    $CurrentRating = $MMRR.current.tier.name

    $CareerStats = @{
        Name                  = $Name
        CurrentRating         = $CurrentRating
        PeakRating            = $PeakRating
        TotalCompetitiveGames = $TotalGames
        TotalWins             = $TotalWins
        WinRate               = $WinRate
    }

    return $CareerStats
}

function Get-LastMatches {
    param(
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

    $MatchesOutput = @()

    $MatchHistory = Get-MatchHistory -username $username -tagline $tagline -region $region
    foreach ($match in $MatchHistory) {
        $match.players.all_players | Where-Object { $_.name -eq $username -and $_.tag -eq $tagline } | ForEach-Object {
            $thisMatch = $_

            $date = (Get-Date -Date ([datetime]'1970-01-01' + [timespan]::FromSeconds($match.metadata.game_star))).AddHours(-6)
            $GameStart = $date.ToString("MM/dd hh:mm tt")

            $TeamColor = $thisMatch.team
            $Details = Get-MatchDetails -matchId $match.metadata.matchid
            $WinningTeam = $Details.teams | Where-Object { $_.won -eq $true }
            if ($WinningTeam.team_id -eq $TeamColor) {
                $Outcome = "Win"
            }
            else {
                $Outcome = "Loss"
            }

            $Agent = $thisMatch.character

            $Stats = $thisMatch.stats

            $MatchInformation = @{
                Id        = $match.metadata.matchid;
                Outcome   = $Outcome;
                GameStart = $GameStart;
                Map       = $match.metadata.map;
                Mode      = $match.metadata.mode;
                Agent     = $Agent;
                Kills     = $Stats.kills;
                Deaths    = $Stats.deaths;
                Assists   = $Stats.assists;
                Score     = $Stats.score;
                BodyShots = $Stats.bodyshots;
                HeadShots = $Stats.headshots;
                LegShots  = $Stats.legshots;
            };

            $MatchesOutput += $MatchInformation
        }
    }
    return $MatchesOutput
}

Function New-TrmnlRequestBody {
    param(
        [Parameter(Mandatory = $true)]
        [string]$username,
        [Parameter(Mandatory = $true)]
        [string]$tag
    )

    $Output = @{}

    $LastMatches = Get-LastMatches -username $username -tagline $tag
    $CareerStats = Get-CareerStats -username $username -tagline $tag

    for ($i = 0; $i -lt $LastMatches.Count; $i++) {
        $iteratorString = $i.ToString()

        $Match = $LastMatches[$i]
        $MatchBodyDetails = @{
            "Match_ID_$iteratorString"   = $Match.Id
            "Outcome_$iteratorString"    = $Match.Outcome
            "Game_Start_$iteratorString" = $Match.GameStart
            "Map_$iteratorString"        = $Match.Map
            "Mode_$iteratorString"       = $Match.Mode
            "Agent_$iteratorString"      = $Match.Agent
            "Kills_$iteratorString"      = $Match.Kills
            "Deaths_$iteratorString"     = $Match.Deaths
            "Assists_$iteratorString"    = $Match.Assists
            "Score_$iteratorString"      = $Match.Score
            "Body_Shots_$iteratorString" = $Match.BodyShots
            "Head_Shots_$iteratorString" = $Match.HeadShots
            "Leg_Shots_$iteratorString"  = $Match.LegShots
        }
        $Output += $MatchBodyDetails
    }

    $Output += $CareerStats

    return $Output
}

Function Invoke-Trmnl-PostRequest {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Body
    )

    $uri = "https://usetrmnl.com/api/custom_plugins/$TrmnlPluginId"

    $TrmnlHeaders = @{
        "Content-Type" = "application/json"
    }

    $TrmnlBody = @{
        "merge_variables" = $Body
    }

    $TrmnlBody | ConvertTo-Json

    Invoke-RestMethod -Uri $uri -Headers $TrmnlHeaders -Method Post -Body ($TrmnlBody | ConvertTo-Json)
}

$Body = New-TrmnlRequestBody -username $username -tag $tagline
Invoke-Trmnl-PostRequest -Body $Body
