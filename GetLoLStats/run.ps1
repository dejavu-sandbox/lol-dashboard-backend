using namespace System.Net

param($Request, $TriggerMetadata)

# --- CONFIGURATION ---
$ApiKey = $env:RiotApiKey
$NbMatchs = 20
$DailyStatsPath = "C:\home\data\daily_stats.json"

# 🚀 LIMITES & CACHE
$MinIntervalSeconds = 60    
$CacheFile = Join-Path $env:TEMP "lol_stats_cache_v12.json"
$CurrentDate = (Get-Date).ToString("yyyyMMdd")

$FriendsList = @("BlasterFly#EUW", "Megumin Full AP#EUW", "Gourdin Puissant#CHIER", "Green Goober#GOOB")
$Route = "europe"
$Region = "euw1"

# --- FONCTION DE CALCUL DE SCORE GLOBAL (POUR LE TREND) ---
function Get-TotalLP($tier, $rank, $lp) {
    $tierScores = @{"IRON"=0;"BRONZE"=400;"SILVER"=800;"GOLD"=1200;"PLATINUM"=1600;"EMERALD"=2000;"DIAMOND"=2400;"MASTER"=2800}
    $rankScores = @{"IV"=0;"III"=100;"II"=200;"I"=300}
    $base = $tierScores[$tier]
    if ($null -eq $base) { return 0 }
    if ($base -ge 2800) { return $base + $lp }
    return $base + ($rankScores[$rank] ?? 0) + $lp
}

# --- GESTION DU CACHE ---
if (Test-Path $CacheFile) {
    try {
        $CacheContent = Get-Content $CacheFile -Raw | ConvertFrom-Json
        $SecondsSinceLast = ((Get-Date) - [datetime]$CacheContent.LastUpdate).TotalSeconds
        if ($SecondsSinceLast -lt $MinIntervalSeconds -and $CacheContent.Date -eq $CurrentDate) {
            Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::OK; Body = $CacheContent.Data | ConvertTo-Json -Depth 10; Headers = @{"Content-Type"="application/json"}
            }); return
        }
    } catch { }
}

# --- CHARGEMENT DU SNAPSHOT DE MINUIT ---
$DailyStats = @{}
if (Test-Path $DailyStatsPath) { try { $DailyStats = Get-Content $DailyStatsPath | ConvertFrom-Json } catch {} }

# --- RIOT API HELPER ---
function Invoke-RiotApi {
    param($Url)
    $MaxRetries = 3; $RetryCount = 0
    while ($RetryCount -lt $MaxRetries) {
        try { return Invoke-RestMethod -Uri $Url -Headers @{ "X-Riot-Token" = $ApiKey } -Method Get -ErrorAction Stop } 
        catch { if ($_.Exception.Response.StatusCode -eq 429) { Start-Sleep -Seconds 5; $RetryCount++ } else { return $null } }
    }
}

# --- TRAITEMENT PRINCIPAL ---
$GlobalData = @{} 

foreach ($Friend in $FriendsList) {
    $Parts = $Friend -split "#"; $Name = $Parts[0]; $Tag = $Parts[1]; $EncodedName = [uri]::EscapeDataString($Name)
    $Account = Invoke-RiotApi -Url "https://$Route.api.riotgames.com/riot/account/v1/accounts/by-riot-id/$EncodedName/$Tag"
    
    if ($Account) {
        $Puuid = $Account.puuid
        $Summoner = Invoke-RiotApi -Url "https://$Region.api.riotgames.com/lol/summoner/v4/summoners/by-puuid/$Puuid"
        
        # 3. RANG, TREND & GLOBAL WINRATE (SEASON)
        $RankString = "Unranked"; $DailyTrend = "0 LP"; $GlobalWR = 0; $GlobalGames = 0
        $RankData = Invoke-RiotApi -Url "https://$Region.api.riotgames.com/lol/league/v4/entries/by-puuid/$Puuid"
        
        if ($RankData) {
            $RankObj = $RankData | Where-Object { $_.queueType -eq "RANKED_SOLO_5x5" }
            if (-not $RankObj) { $RankObj = $RankData | Where-Object { $_.queueType -eq "RANKED_FLEX_SR" } }
            
            if ($RankObj) { 
                $RankString = "$($RankObj.tier) $($RankObj.rank) ($($RankObj.leaguePoints) LP)" 
                $GlobalGames = $RankObj.wins + $RankObj.losses
                $GlobalWR = if ($GlobalGames -gt 0) { [math]::Round(($RankObj.wins / $GlobalGames) * 100, 1) } else { 0 }

                if ($DailyStats.PSObject.Properties.Match($Name).Count -gt 0) {
                    $snapshot = $DailyStats.$Name
                    $currentScore = Get-TotalLP -tier $RankObj.tier -rank $RankObj.rank -lp $RankObj.leaguePoints
                    $diff = $currentScore - $snapshot.totalScore
                    $DailyTrend = if ($diff -gt 0) { "+$diff LP" } elseif ($diff -lt 0) { "$diff LP" } else { "Even" }
                }
            }
        }

        # --- 4. ANALYSE DES 20 DERNIERS MATCHS ---
        $MatchIds = Invoke-RiotApi -Url "https://$Route.api.riotgames.com/lol/match/v5/matches/by-puuid/$Puuid/ids?start=0&count=$NbMatchs&type=ranked"
        $MatchesDetails = @(); $Wins = 0; $TotalKills = 0; $TotalDeaths = 0; $TotalAssists = 0; $TotalPings = 0

        foreach ($MatchId in $MatchIds) {
            $MatchData = $null; $Me = $null; $TeamParticipants = $null
            $TK = 0; $TDmg = 0; $TDeaths = 0

            $MatchData = Invoke-RiotApi -Url "https://$Route.api.riotgames.com/lol/match/v5/matches/$MatchId"
            if ($MatchData -and $MatchData.info) {
                $Me = $MatchData.info.participants | Where-Object { $_.puuid -eq $Puuid }
                if ($Me) {
                    $TeamParticipants = $MatchData.info.participants | Where-Object { $_.teamId -eq $Me.teamId }
                    foreach ($p in $TeamParticipants) {
                        $TK += $p.kills; $TDmg += $p.totalDamageDealtToChampions; $TDeaths += $p.deaths
                    }

                    # Calculs % individuels
                    $KP = [math]::Round((($Me.kills + $Me.assists) / [math]::Max(1, $TK)) * 100, 1)
                    $DmgShare = [math]::Round(($Me.totalDamageDealtToChampions / [math]::Max(1, $TDmg)) * 100, 1)
                    $DeathShare = [math]::Round(($Me.deaths / [math]::Max(1, $TDeaths)) * 100, 1)

                    $DurMin = [math]::Max(1, $MatchData.info.gameDuration / 60)
                    
                    $MatchesDetails += @{
                        Champion = $Me.championName; Win = $Me.win; KDA = "$($Me.kills)/$($Me.deaths)/$($Me.assists)"
                        KP = $KP; DmgShare = $DmgShare; DeathShare = $DeathShare
                        TeamKills = $TK; TeamDeaths = $TDeaths
                        Pings = ($Me.enemyMissingPings + $Me.pushPings + $Me.baitPings)
                        Date = $MatchData.info.gameEndTimestamp
                        DamageDealt = $Me.totalDamageDealtToChampions; DPM = [math]::Round($Me.totalDamageDealtToChampions / $DurMin, 0)
                        CS = ($Me.totalMinionsKilled + $Me.neutralMinionsKilled)
                        CSMin = [math]::Round(($Me.totalMinionsKilled + $Me.neutralMinionsKilled) / $DurMin, 1)
                        Gold = $Me.goldEarned; GoldMin = [math]::Round($Me.goldEarned / $DurMin, 0)
                        Vision = $Me.visionScore; Pinks = ($Me.visionWardsBoughtInGame ?? 0)
                        Heal = $Me.totalHeal; DamageTaken = $Me.totalDamageTaken; DmgObj = $Me.damageDealtToObjectives
                        Role = if ($Me.teamPosition -eq "UTILITY") { "SUPPORT" } else { $Me.teamPosition }
                        Duration = ("{0}m {1}s" -f [math]::Floor($DurMin), ($MatchData.info.gameDuration % 60))
                        EnemyChamp = ($MatchData.info.participants | Where-Object { $_.teamPosition -eq $Me.teamPosition -and $_.teamId -ne $Me.teamId }).championName
                        Pentas = $Me.pentaKills; Quadras = $Me.quadraKills
                    }
                    $TotalKills += $Me.kills; $TotalDeaths += $Me.deaths; $TotalAssists += $Me.assists; if ($Me.win) { $Wins++ }
                    $TotalPings += ($Me.enemyMissingPings + $Me.pushPings + $Me.baitPings)
                }
            }
        }

        # --- 5. CALCULS GLOBAUX POUR LE DASHBOARD ---
        $GamesCount = $MatchesDetails.Count
        if ($GamesCount -gt 0) {
            # Moyennes d'Impact
            $AvgKP = [math]::Round(($MatchesDetails.KP | Measure-Object -Average).Average, 1)
            $AvgDeathShare = [math]::Round(($MatchesDetails.DeathShare | Measure-Object -Average).Average, 1)
            
            # Champion le plus joué (Main Champ)
            $MainChamp = ($MatchesDetails.Champion | Group-Object | Sort-Object Count -Descending | Select-Object -First 1).Name

            # Streak
            $StreakCount = 0; $IsWinStreak = $MatchesDetails[0].Win
            foreach ($m in $MatchesDetails) { if ($m.Win -eq $IsWinStreak) { $StreakCount++ } else { break } }
            
            $GlobalData[$Name] = @{
                Tag = $Tag; Rank = $RankString; DailyLp = $DailyTrend; 
                GlobalWinrate = $GlobalWR; GlobalGames = $GlobalGames; # Saison
                Winrate = [math]::Round(($Wins / $GamesCount) * 100, 0); # Last 20
                AvgKDA = if ($TotalDeaths -eq 0) { $TotalKills + $TotalAssists } else { [math]::Round(($TotalKills + $TotalAssists) / $TotalDeaths, 2) };
                AvgKP = $AvgKP; AvgDeathShare = $AvgDeathShare; MainChamp = $MainChamp;
                StreakType = if ($IsWinStreak) { "Win" } else { "Loss" }; StreakCount = $StreakCount;
                AvgPings = [math]::Round($TotalPings / $GamesCount, 1);
                History = $MatchesDetails; ProfileIcon = $Summoner.profileIconId;
                TotalPentas = ($MatchesDetails.Pentas | Measure-Object -Sum).Sum; 
                TotalQuadras = ($MatchesDetails.Quadras | Measure-Object -Sum).Sum
            }
        }
    }
}

# --- SAUVEGARDE ET RÉPONSE ---
$ObjectToCache = @{ LastUpdate = (Get-Date); Date = $CurrentDate; Data = $GlobalData }
$ObjectToCache | ConvertTo-Json -Depth 10 | Set-Content $CacheFile
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK; Body = $GlobalData | ConvertTo-Json -Depth 10; Headers = @{ "Content-Type" = "application/json" }
})