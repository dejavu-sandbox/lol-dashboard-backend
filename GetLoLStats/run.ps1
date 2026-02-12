using namespace System.Net

param($Request, $TriggerMetadata)

# --- CONFIGURATION ---
$ApiKey = $env:RiotApiKey
$NbMatchs = 20
$DailyStatsPath = "C:\home\data\daily_stats.json"

# CACHE
$CacheFile = "C:\home\data\lol_stats_cache.json"
$CurrentDate = (Get-Date).ToString("yyyyMMdd")

$FriendsList = @("BlasterFly#EUW", "Megumin Full AP#EUW", "Gourdin Puissant#CHIER", "Green Goober#GOOB", "Macon Capule#CHIER")
$Route = "europe"
$Region = "euw1"

# --- TOTAL LP CALCULATION FUNCTION ---
function Get-TotalLP($tier, $rank, $lp) {
    $tierScores = @{"IRON"=0;"BRONZE"=400;"SILVER"=800;"GOLD"=1200;"PLATINUM"=1600;"EMERALD"=2000;"DIAMOND"=2400;"MASTER"=2800}
    $rankScores = @{"IV"=0;"III"=100;"II"=200;"I"=300}
    $base = $tierScores[$tier]
    if ($null -eq $base) { return 0 }
    if ($base -ge 2800) { return $base + $lp }
    return $base + ($rankScores[$rank] ?? 0) + $lp
}

# --- CHAMPION NAME NORMALIZATION ---
function Normalize-ChampionName($championName) {
    # Fix champion names that don't match DDragon file names
    $nameMap = @{
        "FiddleSticks" = "Fiddlesticks"
    }
    if ($nameMap.ContainsKey($championName)) {
        return $nameMap[$championName]
    }
    return $championName
}

# --- CACHE MANAGEMENT ---
$ForceRefresh = $Request.Query.refresh -eq 'true'
$CacheContent = $null

# Load existing cache if it exists
if (Test-Path $CacheFile) {
    try {
        $CacheContent = Get-Content $CacheFile -Raw | ConvertFrom-Json
        
        # If not forcing refresh and cache is from today, return it immediately
        if (!$ForceRefresh -and $CacheContent.Date -eq $CurrentDate) {
            Write-Host "[CACHE] F5 detected - Returning cached data (no API calls)" -ForegroundColor Cyan
            $ResponseData = @{ 
                LastUpdate = $CacheContent.LastUpdate
                Data = $CacheContent.Data 
            }
            Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::OK; Body = $ResponseData | ConvertTo-Json -Depth 10; Headers = @{"Content-Type"="application/json"}
            }); return
        }
    } catch { 
        $CacheContent = $null
    }
}

# --- LOAD DAILY SNAPSHOT ---
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

# --- MAIN PROCESSING ---
$GlobalData = @{} 

foreach ($Friend in $FriendsList) {
    $Parts = $Friend -split "#"; $Name = $Parts[0]; $Tag = $Parts[1]; $EncodedName = [uri]::EscapeDataString($Name)
    Write-Host "[INFO] Processing player: $Name#$Tag" -ForegroundColor Cyan
    
    $Account = Invoke-RiotApi -Url "https://$Route.api.riotgames.com/riot/account/v1/accounts/by-riot-id/$EncodedName/$Tag"
    
    if ($Account) {
        $Puuid = $Account.puuid
        $Summoner = Invoke-RiotApi -Url "https://$Region.api.riotgames.com/lol/summoner/v4/summoners/by-puuid/$Puuid"
        
        # Rank, trend and season winrate
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

        # --- LAST 20 MATCHES ANALYSIS (excluding remakes) ---
        $CachedMatches = @{}
        if ($CacheContent -and $CacheContent.Data.$Name -and $CacheContent.Data.$Name.CachedMatches) {
            foreach ($prop in $CacheContent.Data.$Name.CachedMatches.PSObject.Properties) {
                $CachedMatches[$prop.Name] = $prop.Value
            }
            Write-Host "  [CACHE] Loaded: $($CachedMatches.Count) matches" -ForegroundColor Green
        } else {
            Write-Host "  [CACHE] No cache found, starting fresh" -ForegroundColor Yellow
        }
        
        # Fetch more matches to ensure we have 20 valid ones after filtering remakes
        $MatchIds = Invoke-RiotApi -Url "https://$Route.api.riotgames.com/lol/match/v5/matches/by-puuid/$Puuid/ids?start=0&count=30&type=ranked"
        Write-Host "  [API] Fetched $($MatchIds.Count) match IDs" -ForegroundColor Gray
        
        $MatchesDetails = @(); $Wins = 0; $TotalKills = 0; $TotalDeaths = 0; $TotalAssists = 0; $TotalPings = 0
        $NewCachedMatches = @{}
        $CacheHits = 0; $ApiCalls = 0; $RemakesSkipped = 0

        foreach ($MatchId in $MatchIds) {
            if ($MatchesDetails.Count -ge $NbMatchs) { break }
            
            if ($CachedMatches.ContainsKey($MatchId)) {
                $CachedMatchDetails = $CachedMatches[$MatchId]
                
                if ($CachedMatchDetails.IsRemake) {
                    $NewCachedMatches[$MatchId] = $CachedMatchDetails
                    $RemakesSkipped++
                    continue
                }
                
                $MatchesDetails += $CachedMatchDetails
                $NewCachedMatches[$MatchId] = $CachedMatchDetails
                $CacheHits++
                
                $TotalKills += [int]($CachedMatchDetails.KDA -split '/')[0]
                $TotalDeaths += [int]($CachedMatchDetails.KDA -split '/')[1]
                $TotalAssists += [int]($CachedMatchDetails.KDA -split '/')[2]
                if ($CachedMatchDetails.Win) { $Wins++ }
                $TotalPings += $CachedMatchDetails.Pings
                continue
            }
            
            $MatchData = $null; $Me = $null; $TeamParticipants = $null
            $TK = 0; $TDmg = 0; $TDeaths = 0

            $MatchData = Invoke-RiotApi -Url "https://$Route.api.riotgames.com/lol/match/v5/matches/$MatchId"
            $ApiCalls++
            
            if ($MatchData -and $MatchData.info) {
                # Skip remakes (games under 5 minutes)
                $GameDurationMinutes = $MatchData.info.gameDuration / 60
                if ($GameDurationMinutes -lt 5) {
                    $NewCachedMatches[$MatchId] = @{ IsRemake = $true }
                    $RemakesSkipped++
                    continue 
                }
                
                $Me = $MatchData.info.participants | Where-Object { $_.puuid -eq $Puuid }
                if ($Me) {
                    $TeamParticipants = $MatchData.info.participants | Where-Object { $_.teamId -eq $Me.teamId }
                    foreach ($p in $TeamParticipants) {
                        $TK += $p.kills; $TDmg += $p.totalDamageDealtToChampions; $TDeaths += $p.deaths
                    }

                    # Individual percentages
                    $KP = [math]::Round((($Me.kills + $Me.assists) / [math]::Max(1, $TK)) * 100, 1)
                    $DmgShare = [math]::Round(($Me.totalDamageDealtToChampions / [math]::Max(1, $TDmg)) * 100, 1)
                    $DeathShare = [math]::Round(($Me.deaths / [math]::Max(1, $TDeaths)) * 100, 1)

                    $DurMin = [math]::Max(1, $MatchData.info.gameDuration / 60)
                    $ToxicPingsMatch = ($Me.enemyMissingPings ?? 0) + ($Me.pushPings ?? 0) + ($Me.baitPings ?? 0)
                    
                    $MatchDetails = @{
                        Champion = Normalize-ChampionName $Me.championName; Win = $Me.win; KDA = "$($Me.kills)/$($Me.deaths)/$($Me.assists)"
                        KP = $KP; DmgShare = $DmgShare; DeathShare = $DeathShare
                        TeamKills = $TK; TeamDeaths = $TDeaths
                        Pings = $ToxicPingsMatch
                        # Detailed ping breakdown (for visual stats charts)
                        AllInPings = ($Me.allInPings ?? 0)
                        AssistMePings = ($Me.assistMePings ?? 0)
                        BaitPings = ($Me.baitPings ?? 0)
                        BasicPings = ($Me.basicPings ?? 0)
                        CommandPings = ($Me.commandPings ?? 0)
                        DangerPings = ($Me.dangerPings ?? 0)
                        EnemyMissingPings = ($Me.enemyMissingPings ?? 0)
                        EnemyVisionPings = ($Me.enemyVisionPings ?? 0)
                        GetBackPings = ($Me.getBackPings ?? 0)
                        HoldPings = ($Me.holdPings ?? 0)
                        NeedVisionPings = ($Me.needVisionPings ?? 0)
                        OnMyWayPings = ($Me.onMyWayPings ?? 0)
                        PushPings = ($Me.pushPings ?? 0)
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
                    
                    $MatchesDetails += $MatchDetails
                    $NewCachedMatches[$MatchId] = $MatchDetails
                    
                    $TotalKills += $Me.kills; $TotalDeaths += $Me.deaths; $TotalAssists += $Me.assists; if ($Me.win) { $Wins++ }
                    $TotalPings += $ToxicPingsMatch
                }
            }
        }
        
        Write-Host "  [STATS] $($MatchesDetails.Count) valid matches | Cache hits: $CacheHits | API calls: $ApiCalls | ⚠️ Remakes: $RemakesSkipped" -ForegroundColor Green

        # --- GLOBAL STATS CALCULATION ---
        $GamesCount = $MatchesDetails.Count
        if ($GamesCount -gt 0) {
            # Impact averages
            $AvgKP = [math]::Round(($MatchesDetails.KP | Measure-Object -Average).Average, 1)
            $AvgDeathShare = [math]::Round(($MatchesDetails.DeathShare | Measure-Object -Average).Average, 1)
            
            # Most played champion
            $MainChamp = ($MatchesDetails.Champion | Group-Object | Sort-Object Count -Descending | Select-Object -First 1).Name

            # Streak
            $StreakCount = 0; $IsWinStreak = $MatchesDetails[0].Win
            foreach ($m in $MatchesDetails) { if ($m.Win -eq $IsWinStreak) { $StreakCount++ } else { break } }
            
            # --- BADGES LOGIC ---
            $Badges = @()
            $AvgPingsCalc = [math]::Round($TotalPings / $GamesCount, 1)
            $KDA = if ($TotalDeaths -eq 0) { $TotalKills + $TotalAssists } else { [math]::Round(($TotalKills + $TotalAssists) / $TotalDeaths, 2) }
            $WinrateCalc = [math]::Round(($Wins / $GamesCount) * 100, 0)
            $TotalPentasSum = ($MatchesDetails.Pentas | Measure-Object -Sum).Sum
            $TotalQuadrasSum = ($MatchesDetails.Quadras | Measure-Object -Sum).Sum
            
            # Additional calculations for badges
            $ChampCounts = $MatchesDetails.Champion | Group-Object | Sort-Object Count -Descending
            $TopChampCount = ($ChampCounts | Select-Object -First 1).Count
            
            # CS/min, damage share, and pinks excluding support games
            $NonSupportMatches = $MatchesDetails | Where-Object { $_.Role -ne "SUPPORT" }
            $NonSupportCount = $NonSupportMatches.Count
            $AvgCSMin = if ($NonSupportCount -gt 0) { [math]::Round(($NonSupportMatches.CSMin | Measure-Object -Average).Average, 1) } else { 0 }
            $AvgDmgShare = if ($NonSupportCount -gt 0) { [math]::Round(($NonSupportMatches.DmgShare | Measure-Object -Average).Average, 1) } else { 0 }
            $AvgPinks = if ($NonSupportCount -gt 0) { [math]::Round(($NonSupportMatches.Pinks | Measure-Object -Average).Average, 1) } else { 0 }
                        
            if ($AvgPingsCalc -gt 6) {
                $Badges += @{ Type = "toxic"; Spell = "TeemoR"; Title = "🍄 TOXIC: Mad Pinger! (Averaging 6+ 'Missing' or 'Push Forward' pings per game)" }
            }
            if ($IsWinStreak -and $StreakCount -ge 4) {
                $Badges += @{ Type = "fire"; Spell = "SummonerDot"; Title = "🔥 ON FIRE: Unstoppable! (>=4 Win Streak)" }
            }
            if (-not $IsWinStreak -and $StreakCount -ge 4) {
                $Badges += @{ Type = "sad"; Spell = "AuraofDespair"; Title = "😢 SAD: Tough day? (>=4 Loss Streak)" }
            }
            if ($WinrateCalc -ge 60) {
                $Badges += @{ Type = "smurf"; Spell = "UndyingRage"; Title = "👑 SMURF: Built Different! (Winrate >= 60% on last 20 games)" }
            }
            if ($TotalPentasSum -gt 0) {
                $Badges += @{ Type = "penta"; Icon = "666"; Title = "🤘 PENTAKILL! ($TotalPentasSum)" }
            }
            if ($TotalQuadrasSum -gt 0) {
                $Badges += @{ Type = "quadra"; Champion = "Jhin"; Title = "🎭 PERFECTION! ($TotalQuadrasSum Quadras)" }
            }
            if ($TopChampCount -ge 13) {
                $TopChampName = ($ChampCounts | Select-Object -First 1).Name
                $Badges += @{ Type = "otp"; LocalIcon = "img/oneTrickPony.png"; Champion = $TopChampName; Title = "🎯 OTP: $TopChampName Specialist! (Played same champ >=13/20 games, Current: $TopChampCount/20)" }
            }
            if ($TopChampCount -le 5 -and $GamesCount -ge 20) {
                $Badges += @{ Type = "versatile"; Icon = "4409"; Title = "🎭 VERSATILE: Jack of All Champs! (No dominant pick)" }
            }
            if ($AvgDeathShare -gt 20) {
                $Badges += @{ Type = "death_magnet"; Spell = "Revive"; Title = "💀 DEATH MAGNET: Professional Respawn Speedrunner! (Rule: >20%, Current: ${AvgDeathShare}% of team deaths)" }
            }
            if ($AvgDeathShare -lt 15 -and $GamesCount -ge 10) {
                $Badges += @{ Type = "unkillable"; Spell = "SummonerBarrier"; Title = "🛡️ UNKILLABLE: Invincible! (<15% of team deaths)" }
            }
            if ($AvgDmgShare -gt 25 -and $NonSupportCount -ge 3) {
                $Badges += @{ Type = "carry"; LocalIcon = "img/FakerShh.png"; Title = "⚔️ CARRY: Team's Damage Dealer! (>25% team damage, Current: ${AvgDmgShare}%)" }
            }
            if ($AvgCSMin -gt 8 -and $NonSupportCount -ge 3) {
                $Badges += @{ Type = "farmer"; Spell = "NasusQ"; Title = "🌾 FARM MACHINE: Minion Slayer! (${AvgCSMin} CS/min avg)" }
            }
            if ($WinrateCalc -le 30) {
                $Badges += @{ Type = "lowwr"; LocalIcon = "img/emoteBeeCry.png"; Title = "🐝 CURSED: Elo Hell Resident! Winrate( Last 20) <= 30%" }
            }
            if ($AvgPinks -lt 2 -and $NonSupportCount -ge 3) {
                $Badges += @{ Type = "blind"; Icon = "6058"; Title = "👁️ BLIND: Ward Allergic! Average Pinks < 2/game (current: ${AvgPinks} pinks/game on non-support roles)" }
            }

            # --- PRE-CALCULATE FRONT-END DATA ---
            # 1. RankScore for sorting
            $RankScore = 0
            if ($RankObj) {
                $RankScore = Get-TotalLP -tier $RankObj.tier -rank $RankObj.rank -lp $RankObj.leaguePoints
            } else {
                $RankScore = -10000  # Unranked
            }

            # 2. TopChampions stats (Top 5 + Others)
            $ChampStatsDict = @{}
            foreach ($m in $MatchesDetails) {
                $champ = $m.Champion
                if (-not $ChampStatsDict.ContainsKey($champ)) {
                    $ChampStatsDict[$champ] = @{ Count = 0; Wins = 0; Losses = 0 }
                }
                $ChampStatsDict[$champ].Count++
                if ($m.Win) { $ChampStatsDict[$champ].Wins++ } else { $ChampStatsDict[$champ].Losses++ }
            }
            
            $TopChampions = @()
            $SortedChamps = $ChampStatsDict.GetEnumerator() | Sort-Object { $_.Value.Count } -Descending
            $Top5Champs = $SortedChamps | Select-Object -First 5
            $Top5Total = 0
            foreach ($c in $Top5Champs) {
                $TopChampions += @{ 
                    Name = $c.Key
                    Count = $c.Value.Count
                    Wins = $c.Value.Wins
                    Losses = $c.Value.Losses
                }
                $Top5Total += $c.Value.Count
            }
            
            # Add "Others" if necessary
            if ($Top5Total -lt $GamesCount) {
                $OthersWins = 0
                $OthersLosses = 0
                foreach ($m in $MatchesDetails) {
                    $isInTop5 = $false
                    foreach ($tc in $Top5Champs) {
                        if ($tc.Key -eq $m.Champion) { $isInTop5 = $true; break }
                    }
                    if (-not $isInTop5) {
                        if ($m.Win) { $OthersWins++ } else { $OthersLosses++ }
                    }
                }
                $TopChampions += @{
                    Name = "Autres"
                    Count = $GamesCount - $Top5Total
                    Wins = $OthersWins
                    Losses = $OthersLosses
                }
            }

            # 3. RoleStats
            $RoleStatsDict = @{}
            foreach ($m in $MatchesDetails) {
                $role = $m.Role
                if (-not $RoleStatsDict.ContainsKey($role)) {
                    $RoleStatsDict[$role] = @{ Count = 0; Wins = 0; Losses = 0 }
                }
                $RoleStatsDict[$role].Count++
                if ($m.Win) { $RoleStatsDict[$role].Wins++ } else { $RoleStatsDict[$role].Losses++ }
            }
            
            $RoleStats = @()
            foreach ($r in $RoleStatsDict.GetEnumerator()) {
                $RoleStats += @{
                    Name = $r.Key
                    Count = $r.Value.Count
                    Wins = $r.Value.Wins
                    Losses = $r.Value.Losses
                }
            }

            # 4. WorstPingGame (match with most pings)
            $WorstPingGame = $null
            $MaxPingsInGame = 0
            foreach ($m in $MatchesDetails) {
                $totalPings = $m.Pings
                if ($totalPings -gt $MaxPingsInGame) {
                    $MaxPingsInGame = $totalPings
                    $WorstPingGame = @{
                        Champion = $m.Champion
                        TotalPings = $totalPings
                        Win = $m.Win
                        KDA = $m.KDA
                        Date = $m.Date
                        AllInPings = $m.AllInPings
                        AssistMePings = $m.AssistMePings
                        BaitPings = $m.BaitPings
                        BasicPings = $m.BasicPings
                        CommandPings = $m.CommandPings
                        DangerPings = $m.DangerPings
                        EnemyMissingPings = $m.EnemyMissingPings
                        EnemyVisionPings = $m.EnemyVisionPings
                        GetBackPings = $m.GetBackPings
                        HoldPings = $m.HoldPings
                        NeedVisionPings = $m.NeedVisionPings
                        OnMyWayPings = $m.OnMyWayPings
                        PushPings = $m.PushPings
                    }
                }
            }

            $GlobalData[$Name] = @{
                Tag = $Tag; Rank = $RankString; DailyLp = $DailyTrend; 
                GlobalWinrate = $GlobalWR; GlobalGames = $GlobalGames; # Season
                Winrate = $WinrateCalc; # Last 20
                AvgKDA = $KDA;
                AvgKP = $AvgKP; AvgDeathShare = $AvgDeathShare; MainChamp = $MainChamp;
                StreakType = if ($IsWinStreak) { "Win" } else { "Loss" }; StreakCount = $StreakCount;
                AvgPings = $AvgPingsCalc;
                History = $MatchesDetails; ProfileIcon = $Summoner.profileIconId;
                TotalPentas = $TotalPentasSum; TotalQuadras = $TotalQuadrasSum;
                Badges = $Badges;
                CachedMatches = $NewCachedMatches;  # Store match cache for next refresh
                # Pre-calculated front-end data
                RankScore = $RankScore;
                TopChampions = $TopChampions;
                RoleStats = $RoleStats;
                WorstPingGame = $WorstPingGame;
            }
        }
    }
}

# --- SAVE AND RESPONSE ---
Write-Host "✅ Processing complete! Saving cache..." -ForegroundColor Green
$ObjectToCache = @{ LastUpdate = (Get-Date); Date = $CurrentDate; Data = $GlobalData }
$ObjectToCache | ConvertTo-Json -Depth 10 | Set-Content $CacheFile

# Include LastUpdate timestamp in response
$ResponseData = @{ 
    LastUpdate = $ObjectToCache.LastUpdate.ToString("o")  # ISO 8601 format
    Data = $GlobalData 
}

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK; Body = $ResponseData | ConvertTo-Json -Depth 10; Headers = @{ "Content-Type" = "application/json" }
})