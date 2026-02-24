param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$GitArgs
)

if (-not $GitArgs -or $GitArgs.Count -eq 0) {
    Write-Error "Usage: .\\scripts\\git-all.ps1 <git args>"
    exit 1
}

$modulePaths = @()
$raw = git config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>$null

if ($LASTEXITCODE -ne 0 -or -not $raw) {
    Write-Error "No submodules found. Ensure .gitmodules exists in the current directory."
    exit 1
}

foreach ($line in $raw) {
    $parts = $line -split '\s+', 2
    if ($parts.Count -eq 2) {
        $modulePaths += $parts[1]
    }
}

foreach ($path in $modulePaths) {
    Write-Host "=== $path ==="
    git -C $path @GitArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Command failed in $path"
        exit $LASTEXITCODE
    }
    Write-Host ""
}
