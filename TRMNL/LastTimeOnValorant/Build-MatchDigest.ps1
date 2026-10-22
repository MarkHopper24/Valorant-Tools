<#
.SYNOPSIS
    Turns a raw HenrikDev v2/v3 match object into a compact, accurate "story skeleton":
    scoreline, per-squad-member stats, full team rosters, a round-by-round summary and a
    highlights block (aces, multikills, clutches, first bloods, comebacks, sides, economy).

.DESCRIPTION
    All numbers are computed deterministically from the match data so the recap writer never
    has to guess a stat. Clutches are reconstructed from the ordered kill timeline (a player
    is "clutching" when they are the last alive on their team; it counts as a won clutch if
    their team then wins the round).

    "The squad" = the tracked players (the explicit PlayersPath JSON list) present in the match. Their
    majority team is treated as "our team".

    Writes the digest JSON to -OutPath (and prints it to stdout).

.EXAMPLE
    .\Build-MatchDigest.ps1 -MatchPath match.json -PlayersPath players.json -OutPath digest.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MatchPath,
    [Parameter(Mandatory)][string]$PlayersPath,
    [Parameter(Mandatory)][string]$OutPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $MatchPath)) { throw "Match file not found: $MatchPath" }
$m = Get-Content -LiteralPath $MatchPath -Raw | ConvertFrom-Json

$trackedList = @(Get-Content -LiteralPath $PlayersPath -Raw | ConvertFrom-Json | ForEach-Object { $_.ToLowerInvariant() })
if ($trackedList.Count -ne 2) { throw 'Supply exactly two tracked Riot IDs.' }

$meta   = $m.metadata
$allp   = @($m.players.all_players)
$rounds = @()
if ($m.PSObject.Properties.Name -contains 'rounds' -and $m.rounds) { $rounds = @($m.rounds) }
$kills  = @()
if ($m.PSObject.Properties.Name -contains 'kills' -and $m.kills) { $kills = @($m.kills) }

# ---- player index ------------------------------------------------------------
$byPuuid = @{}
foreach ($p in $allp) {
    $byPuuid[$p.puuid] = $p
}
function PName([object]$p) {
    if ($null -eq $p) { return 'Unknown' }
    $n = if ($p.PSObject.Properties.Name -contains 'name') { $p.name } else { 'Unknown' }
    $t = if ($p.PSObject.Properties.Name -contains 'tag') { $p.tag } else { '' }
    return "$n#$t"
}

# Which players are the tracked squad, and what is "our team"?
$squadPuuids = @{}
$teamCount = @{ 'Red' = 0; 'Blue' = 0 }
foreach ($p in $allp) {
    $key = (PName $p).ToLower()
    if ($trackedList -contains $key) {
        $squadPuuids[$p.puuid] = $true
        if ($teamCount.ContainsKey($p.team)) { $teamCount[$p.team]++ }
    }
}
$ourTeam = $null
if ($squadPuuids.Count -gt 0) {
    $ourTeam = if ($teamCount['Blue'] -ge $teamCount['Red']) { 'Blue' } else { 'Red' }
    if ($teamCount['Blue'] -eq 0 -and $teamCount['Red'] -eq 0) { $ourTeam = $null }
}

$roundsPlayed = [int]$meta.rounds_played
if ($roundsPlayed -le 0) { $roundsPlayed = [math]::Max($rounds.Count, 1) }

# ---- teams / score -----------------------------------------------------------
$blue = $m.teams.blue; $red = $m.teams.red
$blueRounds = if ($blue) { [int]$blue.rounds_won } else { 0 }
$redRounds  = if ($red)  { [int]$red.rounds_won }  else { 0 }
$winner =
    if ($blue -and $blue.has_won) { 'Blue' }
    elseif ($red -and $red.has_won) { 'Red' }
    elseif ($blueRounds -gt $redRounds) { 'Blue' }
    elseif ($redRounds -gt $blueRounds) { 'Red' }
    else { 'Draw' }

$ourResult = 'N/A'
if ($ourTeam) {
    $ourResult = if ($winner -eq 'Draw') { 'Draw' } elseif ($winner -eq $ourTeam) { 'Win' } else { 'Loss' }
}

# ---- attack/defense inference ------------------------------------------------
# Attackers plant the spike. Find the first-half attacker from the first plant in rounds 0-11.
$firstHalfAttacker = $null
for ($i = 0; $i -lt [math]::Min(12, $rounds.Count); $i++) {
    $pe = $rounds[$i].plant_events
    if ($pe -and $pe.planted_by -and $pe.planted_by.team) { $firstHalfAttacker = $pe.planted_by.team; break }
}
function Get-RoundSide([int]$idx) {
    if (-not $ourTeam -or -not $firstHalfAttacker) { return 'unknown' }
    $otherTeam = if ($firstHalfAttacker -eq 'Red') { 'Blue' } else { 'Red' }
    $attacker =
        if ($idx -lt 12) { $firstHalfAttacker }
        elseif ($idx -lt 24) { $otherTeam }
        else { $null }  # overtime: unknown without more data
    if (-not $attacker) {
        # try plant evidence for OT rounds
        $pe = $rounds[$idx].plant_events
        if ($pe -and $pe.planted_by -and $pe.planted_by.team) { $attacker = $pe.planted_by.team }
    }
    if (-not $attacker) { return 'unknown' }
    return $(if ($ourTeam -eq $attacker) { 'attack' } else { 'defense' })
}

function Buy-Type([int]$loadout) {
    if ($loadout -lt 1000) { return 'eco' }
    elseif ($loadout -lt 2500) { return 'force' }
    elseif ($loadout -lt 4000) { return 'half' }
    else { return 'full' }
}

$endTypeMap = @{
    'Eliminated'       = 'elimination'
    'Bomb detonated'   = 'spike detonated'
    'Bomb defused'     = 'spike defused'
    'Round timer expired' = 'time expired'
}

# ---- per-round pass ----------------------------------------------------------
$roundDigest = @()
$blueCum = 0; $redCum = 0
$squadTotalsByPuuid = @{}   # puuid -> per-match rollups computed from rounds/kills
$weaponTallyByPuuid = @{}   # puuid -> @{ weapon -> count }
$aces = @(); $clutchList = @(); $multiRounds = @()

for ($r = 0; $r -lt $rounds.Count; $r++) {
    $rd = $rounds[$r]
    $rWinner = $rd.winning_team
    if ($rWinner -eq 'Blue') { $blueCum++ } elseif ($rWinner -eq 'Red') { $redCum++ }
    $weWon = if ($ourTeam) { [bool]($rWinner -eq $ourTeam) } else { $null }

    $rk = @($kills | Where-Object { [int]$_.round -eq $r } | Sort-Object { [int]$_.kill_time_in_round })

    # first blood / first death
    $fb = $null
    if ($rk.Count -gt 0) {
        $k0 = $rk[0]
        $fb = [ordered]@{
            killer     = $k0.killer_display_name
            killerTeam = $k0.killer_team
            victim     = $k0.victim_display_name
            victimTeam = $k0.victim_team
            weapon     = $k0.damage_weapon_name
            ours       = [bool]($squadPuuids.ContainsKey($k0.killer_puuid))
            oursDied   = [bool]($squadPuuids.ContainsKey($k0.victim_puuid))
        }
    }

    # per-killer counts this round + weapon tally
    $killCount = @{}
    foreach ($k in $rk) {
        if (-not $killCount.ContainsKey($k.killer_puuid)) { $killCount[$k.killer_puuid] = 0 }
        $killCount[$k.killer_puuid]++
        if ($squadPuuids.ContainsKey($k.killer_puuid)) {
            if (-not $weaponTallyByPuuid.ContainsKey($k.killer_puuid)) { $weaponTallyByPuuid[$k.killer_puuid] = @{} }
            $w = $k.damage_weapon_name; if (-not $w) { $w = 'Unknown' }
            if (-not $weaponTallyByPuuid[$k.killer_puuid].ContainsKey($w)) { $weaponTallyByPuuid[$k.killer_puuid][$w] = 0 }
            $weaponTallyByPuuid[$k.killer_puuid][$w]++
        }
    }
    # multikills (>=3) and aces (>=5) by anyone
    foreach ($kp in $killCount.Keys) {
        $c = $killCount[$kp]
        $pl = $byPuuid[$kp]
        if ($null -eq $pl) { continue } # environmental/unattributed kill (e.g. spike detonation), not a real player
        $entry = [ordered]@{ round = $r + 1; player = (PName $pl); team = $pl.team; kills = $c; ours = [bool]($squadPuuids.ContainsKey($kp)) }
        if ($c -ge 5) { $aces += $entry }
        if ($c -ge 3) { $multiRounds += $entry }
    }

    # clutch reconstruction from kill timeline
    $aliveRed = New-Object System.Collections.Generic.HashSet[string]
    $aliveBlue = New-Object System.Collections.Generic.HashSet[string]
    foreach ($p in $allp) {
        if ($p.team -eq 'Red') { [void]$aliveRed.Add($p.puuid) } elseif ($p.team -eq 'Blue') { [void]$aliveBlue.Add($p.puuid) }
    }
    $clutch = $null
    foreach ($k in $rk) {
        $vt = $k.victim_team
        if ($vt -eq 'Red') { [void]$aliveRed.Remove($k.victim_puuid) } elseif ($vt -eq 'Blue') { [void]$aliveBlue.Remove($k.victim_puuid) }
        foreach ($side in @('Red', 'Blue')) {
            if ($side -eq 'Red') { $mineCount = $aliveRed.Count; $enemyCount = $aliveBlue.Count }
            else { $mineCount = $aliveBlue.Count; $enemyCount = $aliveRed.Count }
            if ($mineCount -eq 1 -and $null -eq $clutch -and $enemyCount -ge 1) {
                $survivor = $null
                if ($side -eq 'Red') { foreach ($x in $aliveRed) { $survivor = $x; break } }
                else { foreach ($x in $aliveBlue) { $survivor = $x; break } }
                $clutch = [ordered]@{ puuid = $survivor; team = $side; vs = $enemyCount }
            }
        }
    }
    $clutchOut = $null
    if ($clutch) {
        $won = ($rWinner -eq $clutch.team)
        $pl = $byPuuid[$clutch.puuid]
        $clutchOut = [ordered]@{
            round     = $r + 1
            player    = (PName $pl)
            team      = $clutch.team
            situation = "1v$($clutch.vs)"
            won       = [bool]$won
            ours      = [bool]($squadPuuids.ContainsKey($clutch.puuid))
        }
        if ($won) { $clutchList += $clutchOut }
    }

    # squad-centric round detail
    $squadRoundKills = @()
    foreach ($ps in @($rd.player_stats)) {
        if (-not $squadPuuids.ContainsKey($ps.player_puuid)) { continue }
        $pl = $byPuuid[$ps.player_puuid]
        $died = $null
        $dk = $rk | Where-Object { $_.victim_puuid -eq $ps.player_puuid } | Select-Object -First 1
        if ($dk) { $died = [ordered]@{ by = $dk.killer_display_name; weapon = $dk.damage_weapon_name } }
        $loadout = 0
        if ($ps.economy -and $ps.economy.loadout_value) { $loadout = [int]$ps.economy.loadout_value }
        $squadRoundKills += [ordered]@{
            name     = (PName $pl)
            kills    = [int]$ps.kills
            died     = $died
            survived = [bool]($null -eq $dk)
            buy      = (Buy-Type $loadout)
            loadout  = $loadout
        }
        # rollups
        if (-not $squadTotalsByPuuid.ContainsKey($ps.player_puuid)) {
            $squadTotalsByPuuid[$ps.player_puuid] = [ordered]@{ fb = 0; fd = 0; multi2 = 0; multi3 = 0; multi4 = 0; multi5 = 0; clutchWon = 0 }
        }
        $c = 0; if ($killCount.ContainsKey($ps.player_puuid)) { $c = $killCount[$ps.player_puuid] }
        if ($c -eq 2) { $squadTotalsByPuuid[$ps.player_puuid].multi2++ }
        elseif ($c -eq 3) { $squadTotalsByPuuid[$ps.player_puuid].multi3++ }
        elseif ($c -eq 4) { $squadTotalsByPuuid[$ps.player_puuid].multi4++ }
        elseif ($c -ge 5) { $squadTotalsByPuuid[$ps.player_puuid].multi5++ }
    }
    if ($fb -and $fb.ours) { $squadTotalsByPuuid[($rk[0].killer_puuid)].fb++ }
    if ($fb -and $fb.oursDied) {
        $vp = $rk[0].victim_puuid
        if ($squadTotalsByPuuid.ContainsKey($vp)) { $squadTotalsByPuuid[$vp].fd++ }
    }
    if ($clutchOut -and $clutchOut.ours -and $clutchOut.won) {
        if ($squadTotalsByPuuid.ContainsKey($clutch.puuid)) { $squadTotalsByPuuid[$clutch.puuid].clutchWon++ }
    }

    $notable = @()
    foreach ($a in ($aces | Where-Object { $_.round -eq ($r + 1) })) { $notable += "ACE by $($a.player)$(if($a.ours){' (squad)'})" }
    foreach ($mk in ($multiRounds | Where-Object { $_.round -eq ($r + 1) -and $_.kills -lt 5 })) { $notable += "$($mk.kills)K by $($mk.player)$(if($mk.ours){' (squad)'})" }
    if ($clutchOut -and $clutchOut.won -and [int]($clutchOut.situation -replace '1v', '') -ge 2) {
        $notable += "$($clutchOut.situation) clutch by $($clutchOut.player)$(if($clutchOut.ours){' (squad)'})"
    }

    $pe = $rd.plant_events
    $roundDigest += [ordered]@{
        n           = $r + 1
        winner      = $rWinner
        weWon       = $weWon
        side        = (Get-RoundSide $r)
        endType     = $(if ($endTypeMap.ContainsKey($rd.end_type)) { $endTypeMap[$rd.end_type] } else { $rd.end_type })
        bombPlanted = [bool]$rd.bomb_planted
        plantSite   = $(if ($pe) { $pe.plant_site } else { $null })
        bombDefused = [bool]$rd.bomb_defused
        scoreAfter  = [ordered]@{ blue = $blueCum; red = $redCum }
        firstBlood  = $fb
        clutch      = $clutchOut
        squad       = $squadRoundKills
        notable     = $notable
    }
}

# ---- squad member season/match stats ----------------------------------------
function HsPct($p) {
    $h = [int]$p.stats.headshots; $b = [int]$p.stats.bodyshots; $l = [int]$p.stats.legshots
    $t = $h + $b + $l
    if ($t -le 0) { return 0 }
    return [math]::Round(100.0 * $h / $t, 1)
}
function TopWeapon($puuid) {
    if (-not $weaponTallyByPuuid.ContainsKey($puuid)) { return $null }
    $best = $null; $bestC = -1
    foreach ($w in $weaponTallyByPuuid[$puuid].Keys) {
        if ($weaponTallyByPuuid[$puuid][$w] -gt $bestC) { $bestC = $weaponTallyByPuuid[$puuid][$w]; $best = $w }
    }
    if ($best) { return "$best ($bestC)" } else { return $null }
}

# overall combat-score ranking (for MVP)
$scored = @($allp | Sort-Object { -[int]$_.stats.score })
$overallRank = @{}
for ($i = 0; $i -lt $scored.Count; $i++) { $overallRank[$scored[$i].puuid] = $i + 1 }

function Build-PlayerLine($p, [bool]$squad) {
    $roll = if ($squadTotalsByPuuid.ContainsKey($p.puuid)) { $squadTotalsByPuuid[$p.puuid] } else { $null }
    $k = [int]$p.stats.kills; $d = [int]$p.stats.deaths; $a = [int]$p.stats.assists
    $line = [ordered]@{
        name    = (PName $p)
        agent   = $p.character
        rank    = $p.currenttier_patched
        team    = $p.team
        kills   = $k; deaths = $d; assists = $a
        kd      = if ($d -gt 0) { [math]::Round($k / [double]$d, 2) } else { [double]$k }
        acs     = [math]::Round([int]$p.stats.score / [double]$roundsPlayed, 0)
        hsPct   = (HsPct $p)
        adr     = [math]::Round([int]$p.damage_made / [double]$roundsPlayed, 0)
        scoreRankOverall = $overallRank[$p.puuid]
        isSquad = $squad
    }
    if ($squad) {
        $line.firstBloods = if ($roll) { $roll.fb } else { 0 }
        $line.firstDeaths = if ($roll) { $roll.fd } else { 0 }
        $line.multikills  = [ordered]@{
            '2k' = if ($roll) { $roll.multi2 } else { 0 }
            '3k' = if ($roll) { $roll.multi3 } else { 0 }
            '4k' = if ($roll) { $roll.multi4 } else { 0 }
            '5k' = if ($roll) { $roll.multi5 } else { 0 }
        }
        $line.clutchesWon = if ($roll) { $roll.clutchWon } else { 0 }
        $line.topWeapon   = (TopWeapon $p.puuid)
        $icon = $null
        try { if ($p.assets -and $p.assets.agent -and $p.assets.agent.small) { $icon = $p.assets.agent.small } } catch { }
        $line.agentIcon = $icon
    }
    return $line
}

$teamsOut = [ordered]@{ Blue = @(); Red = @() }
foreach ($p in ($allp | Sort-Object { -[int]$_.stats.score })) {
    $isSquad = $squadPuuids.ContainsKey($p.puuid)
    $line = Build-PlayerLine $p $isSquad
    if ($p.team -eq 'Blue') { $teamsOut.Blue += $line } else { $teamsOut.Red += $line }
}

$squadOut = @()
foreach ($p in ($allp | Where-Object { $squadPuuids.ContainsKey($_.puuid) } | Sort-Object { -[int]$_.stats.score })) {
    $squadOut += (Build-PlayerLine $p $true)
}

# ---- highlights --------------------------------------------------------------
$topFragger = $scored[0]
# longest round-win streak for our team + biggest deficit overcome
$streak = 0; $bestStreak = 0; $maxDeficit = 0; $curDiff = 0
if ($ourTeam) {
    foreach ($rdg in $roundDigest) {
        if ($rdg.weWon) { $streak++; if ($streak -gt $bestStreak) { $bestStreak = $streak } } else { $streak = 0 }
    }
    # deficit tracking
    $ourCum = 0; $oppCum = 0
    foreach ($rdg in $roundDigest) {
        $ourCum = if ($ourTeam -eq 'Blue') { $rdg.scoreAfter.blue } else { $rdg.scoreAfter.red }
        $oppCum = if ($ourTeam -eq 'Blue') { $rdg.scoreAfter.red } else { $rdg.scoreAfter.blue }
        $deficit = $oppCum - $ourCum
        if ($deficit -gt $maxDeficit) { $maxDeficit = $deficit }
    }
}

$squadClutchesWon = @($clutchList | Where-Object { $_.ours })
$squadAces        = @($aces | Where-Object { $_.ours })

$highlights = [ordered]@{
    topFragger      = [ordered]@{ name = (PName $topFragger); team = $topFragger.team; kills = [int]$topFragger.stats.kills; ours = [bool]($squadPuuids.ContainsKey($topFragger.puuid)) }
    aces            = $aces
    squadAces       = $squadAces
    clutchesWon     = $clutchList
    squadClutchesWon = $squadClutchesWon
    multikillRounds = $multiRounds
    bestSquadStreak = $bestStreak
    maxDeficitFaced = $maxDeficit
    comeback        = $(if ($ourTeam -and $ourResult -eq 'Win' -and $maxDeficit -ge 4) { "Overcame a $maxDeficit-round deficit to win" } else { $null })
    heartbreak      = $(if ($ourTeam -and $ourResult -eq 'Loss' -and $bestStreak -ge 4) { "Won $bestStreak rounds in a row but still lost" } else { $null })
    wentTheDistance = [bool]([math]::Abs($blueRounds - $redRounds) -le 2)
    overtime        = [bool]($roundsPlayed -gt 24)
}

# ---- assemble ----------------------------------------------------------------
$durMin = [math]::Round([int]$meta.game_length / 60.0, 1)
$digest = [ordered]@{
    match = [ordered]@{
        matchId    = $meta.matchid
        map        = $meta.map
        mode       = $meta.mode
        queue      = $meta.queue
        region     = $meta.region
        startedAt  = $meta.game_start_patched
        durationMin = $durMin
        roundsPlayed = $roundsPlayed
    }
    result = [ordered]@{
        ourTeam    = $ourTeam
        ourResult  = $ourResult
        winner     = $winner
        score      = [ordered]@{ blue = $blueRounds; red = $redRounds }
        ourScore   = $(if ($ourTeam -eq 'Blue') { $blueRounds } elseif ($ourTeam -eq 'Red') { $redRounds } else { $null })
        theirScore = $(if ($ourTeam -eq 'Blue') { $redRounds } elseif ($ourTeam -eq 'Red') { $blueRounds } else { $null })
        overtime   = [bool]($roundsPlayed -gt 24)
    }
    squad      = $squadOut
    teams      = $teamsOut
    rounds     = $roundDigest
    highlights = $highlights
}


($digest | ConvertTo-Json -Depth 30) | Set-Content -LiteralPath $OutPath -Encoding UTF8
Write-Output "DIGEST_PATH=$OutPath"
Get-Content -LiteralPath $OutPath -Raw
