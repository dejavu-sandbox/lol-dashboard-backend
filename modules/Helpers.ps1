# Helper Functions Module
# Utility functions for common operations

function Format-Date {
    param(
        [Parameter(Mandatory = $true)]
        [DateTime]$Date,
        
        [string]$Format = "o"
    )
    
    return $Date.ToString($Format)
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [ValidateSet("Info", "Warning", "Error")]
        [string]$Level = "Info"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message"
}

function Invoke-SafeAPI {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ApiCall,
        
        [int]$MaxRetries = 3,
        [int]$RetryDelaySeconds = 2
    )
    
    $attempt = 1
    
    while ($attempt -le $MaxRetries) {
        try {
            return & $ApiCall
        }
        catch {
            Write-Log "API call failed (attempt $attempt/$MaxRetries): $_" -Level "Warning"
            
            if ($attempt -lt $MaxRetries) {
                Start-Sleep -Seconds $RetryDelaySeconds
            }
            
            $attempt++
        }
    }
    
    throw "API call failed after $MaxRetries attempts"
}
