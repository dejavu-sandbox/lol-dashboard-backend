using namespace System.Net
param($Timer)

# 1. CONFIGURATION (Utilise ta variable fonctionnelle)
$ApiKey = $env:RiotApiKey
$FilePath = "C:\home\data\daily_stats.json"

$Players = @(
    @{ Name = "Gourdin Puissant"; Tag = "CHIER" },
    @{ Name = "Megumin Full AP"; Tag = "EUW" },
    @{ Name = "BlasterFly"; Tag = "EUW" },
    @{ Name = "Green Goober"; Tag = "GOOB" }
)

# --- TA FONCTION API ---
function Invoke-RiotApi {
    param($Url)
    try { 
        return Invoke-RestMethod -Uri $Url -Headers @{ "X-Riot-Token" = $ApiKey } -Method Get -ErrorAction Stop 
    } catch { 
        Write-Host "❌ Erreur API sur $Url : $($_.Exception.Message)"
        return $null 
    }
}

function Get-TotalLP($tier, $rank, $lp) {
    $tierScores = @{"IRON"=0;"BRONZE"=400;"SILVER"=800;"GOLD"=1200;"PLATINUM"=1600;"EMERALD"=2000;"DIAMOND"=2400;"MASTER"=2800}
    $rankScores = @{"IV"=0;"III"=100;"II"=200;"I"=300}
    $base = $tierScores[$tier]
    if ($null -eq $base) { return 0 }
    if ($base -ge 2800) { return $base + $lp }
    return $base + $rankScores[$rank] + $lp
}

Write-Host "📸 DÉBUT DU SNAPSHOT..."
$DailyData = @{}

foreach ($player in $Players) {
    $EncodedName = [uri]::EscapeDataString($player.Name)
    Write-Host "🔍 Recherche : $($player.Name)..."

    # 1. RÉCUPÉRER LE PUUID (Via Account-v1)
    $Account = Invoke-RiotApi -Url "https://europe.api.riotgames.com/riot/account/v1/accounts/by-riot-id/$EncodedName/$($player.Tag)"
    
    if ($Account -and $Account.puuid) {
        $puuid = $Account.puuid
        
        # 2. RÉCUPÉRER LE RANG DIRECTEMENT VIA LE PUUID (Méthode de ton script principal)
        # On utilise le nouveau endpoint : /league/v4/entries/by-puuid/
        $RankData = Invoke-RiotApi -Url "https://euw1.api.riotgames.com/lol/league/v4/entries/by-puuid/$puuid"
        
        if ($RankData) {
            $SoloQ = $RankData | Where-Object { $_.queueType -eq "RANKED_SOLO_5x5" }
            if ($SoloQ) {
                $TotalScore = Get-TotalLP -tier $SoloQ.tier -rank $SoloQ.rank -lp $SoloQ.leaguePoints
                $DailyData[$player.Name] = @{
                    "totalScore" = $TotalScore
                    "tier" = $SoloQ.tier
                    "rank" = $SoloQ.rank
                    "lp" = $SoloQ.leaguePoints
                    "timestamp" = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                }
                Write-Host "✅ Sauvegardé : $($player.Name) ($TotalScore pts)"
            }
        }
    }
}

# 3. ÉCRITURE DU FICHIER SI NON VIDE
if ($DailyData.Count -gt 0) {
    $DataDir = "C:\home\data"
    if (!(Test-Path $DataDir)) { New-Item -ItemType Directory -Force -Path $DataDir }
    $DailyData | ConvertTo-Json -Depth 5 | Out-File $FilePath -Encoding utf8
    Write-Host "💾 Snapshot terminé ! Fichier écrit dans $FilePath"
} else {
    Write-Host "⚠️ Aucune donnée n'a pu être récupérée."
}