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
│   ├── LoLApi.ps1       (Riot API integration)
│   └── Helpers.ps1      (Utility functions)
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

## 🔐 Security & CORS

- **Authentication:** Anonymous (configured in Azure Portal)
- **CORS Origins Allowed:**
  - Azure Portal
  - GitHub Pages (your frontend)

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

## 📚 Future Enhancements

The `/modules/` directory contains a helper module template designed for future refactoring:
- `Helpers.ps1` - Planned utilities for logging and error handling

This can be integrated when refactoring GetLoLStats and SnapshotDailyLP for better code organization.

## 📄 License

MIT License - Feel free to use, modify, and redistribute this project as you wish.
