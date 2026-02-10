# LoL Dashboard Backend

Azure Functions application for tracking League of Legends player statistics and daily LP snapshots using PowerShell.

## 📋 Project Structure

```
lol-dashboard-backend/
├── GetLoLStats/
│   ├── function.json     (HTTP Trigger - GET/POST)
│   └── run.ps1          (Fetch player stats on demand)
├── SnapshotDailyLP/
│   ├── function.json     (Timer Trigger - Daily at 00:05)
│   └── run.ps1          (Daily LP snapshot capture)
├── modules/
│   └── Helpers.ps1      (For future refactoring)
├── .gitignore
└── README.md
```

## 🎮 Functions

### GetLoLStats
**Type:** HTTP Trigger (GET/POST)  
**Auth Level:** Anonymous  
**Purpose:** Fetch League of Legends player statistics on demand

**Features:**
- Retrieves summoner info and ranked stats
- Returns tier, rank, LP, and win rate
- Calculates global LP score across tiers
- Supports multiple regions

### SnapshotDailyLP
**Type:** Timer Trigger  
**Schedule:** `0 5 0 * * *` (Daily at 00:05 UTC)  
**Purpose:** Capture daily LP snapshots for all tracked players

**Features:**
- Collects LP data for each player in `Players` list
- Stores snapshot in JSON file
- Tracks tier, rank, LP, and calculated score
- Includes timestamp for historical tracking

**Players Tracked:**
- Gourdin Puissant (CHIER)
- Megumin Full AP (EUW)
- BlasterFly (EUW)
- Green Goober (GOOB)
- Macon Capule (CHIER)

## 🔐 Security & CORS

- **Authentication:** Anonymous (configured in Azure Portal)
- **CORS Origins Allowed:**
  - Azure Portal
  - GitHub Pages (your frontend)
## 📋 Prerequisites

Before deploying, configure the following in your Azure Function App:

### 1. Riot API Key (App Settings)
```
Setting Name: RiotApiKey
Value: <your-riot-api-key>
```

**Better Practice: Use Azure Key Vault**
1. Create an Azure Key Vault
2. Store the API key in the vault
3. Reference it in App Settings:
```
Setting Name: RiotApiKey
Value: @Microsoft.KeyVault(SecretUri=https://<vault-name>.vault.azure.net/secrets/<secret-name>/version)
```

### 2. Storage Account (For Timer Trigger)
The `SnapshotDailyLP` timer trigger requires persistent storage:

1. Create or use an existing Azure Storage Account
2. Get the connection string from **Access Keys**
3. Add to App Settings:
```
Setting Name: AzureWebJobsStorage
Value: <your-storage-account-connection-string>
```

This allows the timer job to maintain state and schedule reliability.

### 3. Data Storage Location
Configure the snapshot file path in `SnapshotDailyLP/run.ps1`:
```powershell
$FilePath = "C:\home\data\daily_stats.json"  # Azure Functions file system
```
## � Related Projects

- **Frontend Dashboard:** [lol-dashboard](https://github.com/dejavu-sandbox/lol-dashboard)
  - Main UI for displaying player statistics
  - Hosted on GitHub Pages

## 🚀 Deployment

Deploy to Azure Functions using:
```powershell
func azure functionapp publish <FunctionAppName>
```

## 📝 API Reference

### GetLoLStats Endpoint
```
GET/POST /api/GetLoLStats
Response: { tier, rank, lp, totalLP, winRate, summonerId, ... }
```

### SnapshotDailyLP
Runs automatically on schedule. Stores snapshots in configured data path.

## 🏆 Badge System

14 achievement badges calculated over the last 20 matches:

**Performance Badges:**
- **ON FIRE:** ≥4 win streak
- **SAD:** ≥4 loss streak
- **CARRY:** >26% team damage share
- **UNKILLABLE:** <15% team deaths
- **DEATH MAGNET:** >20% team deaths
- **FARMER:** ≥8.5 CS/min average

**Champion Mastery:**
- **OTP (One-Trick Pony):** ≥13/20 games on same champion
- **VERSATILE:** ≥7 different champions played

**Special Achievements:**
- **PENTA KILL:** Achieved pentakill in recent matches
- **QUADRA KILL:** Achieved quadrakill in recent matches
- **SMURF:** Rank tier changed during tracked period
- **TOXIC:** ≥3 average deaths in won games
- **LOWWR:** <45% win rate with ≥10 games played
- **BLIND:** <20% average vision score

## ⚙️ Technical Implementation

**Match Processing:**
- **Filtering:** Remakes (games <5 minutes) are excluded from calculations
- **Sample Size:** Statistics calculated over last 20 ranked matches
- **Caching:** Per-match cache system (`lol_stats_cache.json`) to minimize Riot API calls

**Data Storage:**
- Match statistics cache: `lol_stats_cache.json`
- Daily LP snapshots: `daily_stats.json`

## 📚 Future Enhancements

The `/modules/` directory contains a helper module template designed for future refactoring:
- `Helpers.ps1` - Planned utilities for logging and error handling

This can be integrated when refactoring GetLoLStats and SnapshotDailyLP for better code organization.

## 📄 License

MIT License - Feel free to use, modify, and redistribute this project as you wish.
