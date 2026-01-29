using namespace System.Net

param($Request, $TriggerMetadata)

# --- CONFIGURATION ---
$ApiKey = $env:RiotApiKey
$NbMatchs = 20
$DailyStatsPath = "C:\home\data\daily_stats.json" # Emplacement du snapshot de minuit

# 🚀 LIMITES
$MaxDailyRefreshes = 100000 
$MinIntervalSeconds = 60    

# TA LISTE D'AMIS
$FriendsList = @(
    "BlasterFly#EUW",
    "Megumin Full AP#EUW",
    "Gourdin Puissant#CHIER",
    "Green Goober#GOOB"
)

$Route = "europe"
$Region = "euw1"

# --- NEW: FONCTION DE CALCUL DE SCORE GLOBAL ---
function Get-TotalLP($tier, $rank, $lp) {
    $tierScores = @{"IRON" = 0; "BRONZE" = 400; "SILVER" = 800; "GOLD" = 1200; "PLATINUM" = 1600; "EMERALD" = 2000; "DIAMOND" = 2400; "MASTER" = 2800; "GRANDMASTER" = 2800; "CHALLENGER" = 2800 }
    $rankScores = @{"IV" = 0; "III" = 100; "II" = 200; "I" = 300 }
    $base = $tierScores[$tier]
    if ($null -eq $base) { return 0 }
    if ($base -ge 2800) { return $base + $lp }
    return $base + ($rankScores[$rank] ?? 0) + $lp
}

# --- GESTION DU CACHE ---
$CacheFile = Join-Path $env:TEMP "lol_stats_cache_v10.json"
$CurrentDate = (Get-Date).ToString("yyyyMMdd")

$CachedData = $null
$ShouldRefresh = $true
$Message = "Données fraîches demandées."

if (Test-Path $CacheFile) {
    try {
        $CacheContent = Get-Content $CacheFile -Raw | ConvertFrom-Json
        $CachedData = $CacheContent.Data
        $LastUpdate = [datetime]$CacheContent.LastUpdate
        $SavedDate = $CacheContent.Date
        $DailyCounter = $CacheContent.Counter
        if ($SavedDate -ne $CurrentDate) { $DailyCounter = 0 }
        $SecondsSinceLast = ((Get-Date) - $LastUpdate).TotalSeconds
        if ($SecondsSinceLast -lt $MinIntervalSeconds) {
            $ShouldRefresh = $false; $Message = "Cache utilisé (Délai)."
        }
    }
    catch { $DailyCounter = 0 }
}
else { $DailyCounter = 0 }

if (-not $ShouldRefresh -and $CachedData) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK; 
            Body       = $CachedData | ConvertTo-Json -Depth 10;
            Headers    = @{ "Content-Type" = "application/json" }
        })
    return
}

# --- NEW: CHARGEMENT DU SNAPSHOT ---
$DailyStats = @{}
if (Test-Path $DailyStatsPath) {
    try { $DailyStats = Get-Content $DailyStatsPath | ConvertFrom-Json } catch {}
}

# --- RIOT API HELPER ---
function Invoke-RiotApi {
    param($Url)
    $MaxRetries = 3; $RetryCount = 0; $Success = $false
    while (-not $Success -and $RetryCount -lt $MaxRetries) {
        try { return Invoke-RestMethod -Uri $Url -Headers @{ "X-Riot-Token" = $ApiKey } -Method Get -ErrorAction Stop } 
        catch { 
            if ($_.Exception.Response.StatusCode -eq 429) { Start-Sleep -Seconds 5; $RetryCount++ }
            else { return $null }
        }
    }
}

# --- TRAITEMENT PRINCIPAL ---
Write-Host "Mise à jour via Riot..."
$GlobalData = @{} 

foreach ($Friend in $FriendsList) {
    $Parts = $Friend -split "#"
    if ($Parts.Count -lt 2) { continue }
    $Name = $Parts[0]; $Tag = $Parts[1]
    $EncodedName = [uri]::EscapeDataString($Name)

    $Account = Invoke-RiotApi -Url "https://$Route.api.riotgames.com/riot/account/v1/accounts/by-riot-id/$EncodedName/$Tag"
    
    if ($Account) {
        $Puuid = $Account.puuid
        $Summoner = Invoke-RiotApi -Url "https://$Region.api.riotgames.com/lol/summoner/v4/summoners/by-puuid/$Puuid"
        
        # 3. RANG & TREND
        $RankString = "Unranked"
        $DailyTrend = "0 LP" # Par défaut
        $RankData = Invoke-RiotApi -Url "https://$Region.api.riotgames.com/lol/league/v4/entries/by-puuid/$Puuid"
        
        if ($RankData) {
            $RankObj = $RankData | Where-Object { $_.queueType -eq "RANKED_SOLO_5x5" }
            if (-not $RankObj) { $RankObj = $RankData | Where-Object { $_.queueType -eq "RANKED_FLEX_SR" } }
            
            if ($RankObj) { 
                $RankString = "$($RankObj.tier) $($RankObj.rank) ($($RankObj.leaguePoints) LP)" 
                
                # --- NEW: TREND LOGIC ---
                if ($DailyStats.PSObject.Properties.Match($Name).Count -gt 0) {
                    $snapshot = $DailyStats.$Name
                    $currentScore = Get-TotalLP -tier $RankObj.tier -rank $RankObj.rank -lp $RankObj.leaguePoints
                    $diff = $currentScore - $snapshot.totalScore
                    
                    if ($diff -gt 0) { $DailyTrend = "+$diff LP" }
                    elseif ($diff -lt 0) { $DailyTrend = "$diff LP" }
                    else { $DailyTrend = "Even" }
                }
            }
        }

        # --- 4. MATCHS ---
        $MatchIds = Invoke-RiotApi -Url "https://$Route.api.riotgames.com/lol/match/v5/matches/by-puuid/$Puuid/ids?start=0&count=$NbMatchs&type=ranked"
        $MatchesDetails = @(); $TotalKills = 0; $TotalDeaths = 0; $TotalAssists = 0; $Wins = 0
        $TotalPentas = 0; $TotalQuadras = 0; $TotalPings = 0; $TotalCS = 0

        foreach ($MatchId in $MatchIds) {
            # On vide les variables du match précédent pour éviter les calculs fantômes
            $MatchData = $null; $Me = $null; $TeamParticipants = $null
            $TeamKills = 0; $TeamDmg = 0

            $MatchData = Invoke-RiotApi -Url "https://$Route.api.riotgames.com/lol/match/v5/matches/$MatchId"
    
            if ($MatchData -and $MatchData.info) {
                # 1. IDENTIFIER LE JOUEUR D'ABORD (Crucial pour les calculs suivants)
                $Me = $MatchData.info.participants | Where-Object { $_.puuid -eq $Puuid }
        
                if ($Me) {
                    # 2. IDENTIFIER L'ÉQUIPE ET CALCULER LES TOTALS
                    $MyTeamId = $Me.teamId
                    $TeamParticipants = $MatchData.info.participants | Where-Object { $_.teamId -eq $MyTeamId }

                    # Somme des kills et dégâts de l'équipe
                    foreach ($p in $TeamParticipants) {
                        $TeamKills += $p.kills
                        $TeamDmg += $p.totalDamageDealtToChampions
                    }

                    # Sécurité division par zéro
                    $SafeTeamKills = if ($TeamKills -eq 0) { 1 } else { $TeamKills }
                    $SafeTeamDmg = if ($TeamDmg -eq 0) { 1 } else { $TeamDmg }

                    # 3. CALCULER LES % DE PARTICIPATION (Avec les données fraîches de $Me)
                    $KP = [math]::Round((($Me.kills + $Me.assists) / $SafeTeamKills) * 100, 1)
                    $DmgShare = [math]::Round(($Me.totalDamageDealtToChampions / $SafeTeamDmg) * 100, 1)

                    # 4. INFOS COMPLÉMENTAIRES
                    $MyRole = $Me.teamPosition
                    $Enemy = $MatchData.info.participants | Where-Object { $_.teamPosition -eq $MyRole -and $_.puuid -ne $Puuid }
                    $EnemyChamp = if ($Enemy) { $Enemy.championName } else { "" }

                    # Accumulation des stats globales
                    $TotalKills += $Me.kills; $TotalDeaths += $Me.deaths; $TotalAssists += $Me.assists
                    $TotalPentas += $Me.pentaKills; $TotalQuadras += $Me.quadraKills
                    if ($Me.win) { $Wins++ }

                    $CS = $Me.totalMinionsKilled + $Me.neutralMinionsKilled
                    $TotalCS += $CS
            
                    $DurationSec = $MatchData.info.gameDuration
                    $DurationMinVal = if ($DurationSec -le 0) { 1 } else { $DurationSec / 60 }
                    $TimeStr = "{0}m {1}s" -f [math]::Floor($DurationMinVal), ($DurationSec % 60)
            
                    $CSPerMin = [math]::Round($CS / $DurationMinVal, 1)
                    $GoldMin = [math]::Round($Me.goldEarned / $DurationMinVal, 0)
                    $DPM = [math]::Round($Me.totalDamageDealtToChampions / $DurationMinVal, 0)

                    $ToxScore = ($Me.enemyMissingPings + $Me.pushPings + $Me.baitPings)
                    $TotalPings += $ToxScore

                    $DisplayRole = if ($Me.teamPosition -eq "UTILITY") { "SUPPORT" } else { $Me.teamPosition }
                    $PinksBought = if ($Me.visionWardsBoughtInGame) { $Me.visionWardsBoughtInGame } else { 0 }

                    # 5. AJOUT À L'HISTORIQUE
                    $MatchesDetails += @{
                        Champion    = $Me.championName
                        EnemyChamp  = $EnemyChamp
                        Role        = $DisplayRole
                        KDA         = "$($Me.kills)/$($Me.deaths)/$($Me.assists)"
                        Win         = $Me.win
                        Date        = $MatchData.info.gameEndTimestamp
                        Duration    = $TimeStr
                        CS          = $CS
                        CSMin       = $CSPerMin
                        Vision      = $Me.visionScore
                        Pinks       = $PinksBought
                        Pings       = $ToxScore
                        DamageDealt = $Me.totalDamageDealtToChampions
                        DPM         = $DPM
                        DamageTaken = $Me.totalDamageTaken
                        Heal        = $Me.totalHeal
                        DmgObj      = $Me.damageDealtToObjectives
                        Gold        = $Me.goldEarned
                        GoldMin     = $GoldMin
                        Quadras     = $Me.quadraKills
                        Pentas      = $Me.pentaKills
                        KP          = $KP
                        DmgShare    = $DmgShare
                        TeamKills   = $TeamKills
                    }
                }
            }
        }

        # CALCULS GLOBAUX
        $GamesCount = $MatchesDetails.Count
        $StreakType = "None"; $StreakCount = 0
        if ($GamesCount -gt 0) {
            $Winrate = [math]::Round(($Wins / $GamesCount) * 100, 0)
            $AvgKDA = if ($TotalDeaths -eq 0) { $TotalKills + $TotalAssists } else { [math]::Round(($TotalKills + $TotalAssists) / $TotalDeaths, 2) }
            $IsWinStreak = $MatchesDetails[0].Win
            foreach ($m in $MatchesDetails) {
                if ($m.Win -eq $IsWinStreak) { $StreakCount++ } else { break }
            }
            $StreakType = if ($IsWinStreak) { "Win" } else { "Loss" }
            $AvgPings = [math]::Round($TotalPings / $GamesCount, 1)
        }
        else { $Winrate = 0; $AvgKDA = 0; $AvgPings = 0 }

        $GlobalData[$Name] = @{
            Tag = $Tag; Rank = $RankString; Winrate = $Winrate; AvgKDA = $AvgKDA; 
            DailyLp = $DailyTrend; # --- NEW: TREND AJOUTÉ ICI ---
            StreakType = $StreakType; StreakCount = $StreakCount;
            TotalPentas = $TotalPentas; TotalQuadras = $TotalQuadras;
            AvgPings = $AvgPings; History = $MatchesDetails; ProfileIcon = $Summoner.profileIconId
        }
    }
}

# --- SAUVEGARDE ET RÉPONSE ---
$DailyCounter++ 
$ObjectToCache = @{ LastUpdate = (Get-Date); Date = $CurrentDate; Counter = $DailyCounter; Data = $GlobalData }
$JsonToSave = $ObjectToCache | ConvertTo-Json -Depth 10
$JsonToSave | Set-Content $CacheFile

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK; 
        Body       = $GlobalData | ConvertTo-Json -Depth 10;
        Headers    = @{ "Content-Type" = "application/json" }
    })