param(
    [string]$PackageRoot = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
    $root = Split-Path -Parent $PSCommandPath
} else {
    $root = [IO.Path]::GetFullPath($PackageRoot)
}

if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    Write-Host "PACKAGE_VERIFY_FAILED: package root does not exist: $root" -ForegroundColor Red
    exit 1
}

$manifestPath = Join-Path $root 'checksums.sha256'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    Write-Host 'PACKAGE_VERIFY_FAILED: checksums.sha256 is missing.' -ForegroundColor Red
    exit 1
}

$failures = New-Object System.Collections.Generic.List[string]
$manifestEntries = @{}
$baseFull = [IO.Path]::GetFullPath($root).TrimEnd(
    [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
) + [IO.Path]::DirectorySeparatorChar

foreach ($line in @(Get-Content -LiteralPath $manifestPath -ErrorAction Stop)) {
    if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
    $parts = $line -split '\s{2,}', 2
    if ($parts.Count -ne 2) {
        $failures.Add("Invalid checksum line: $line")
        continue
    }

    $expected = $parts[0].Trim().ToUpperInvariant()
    $relative = $parts[1].Trim()
    if ([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)') {
        $failures.Add("Unsafe manifest path: $relative")
        continue
    }
    if ($manifestEntries.ContainsKey($relative.ToLowerInvariant())) {
        $failures.Add("Duplicate manifest path: $relative")
        continue
    }
    $manifestEntries[$relative.ToLowerInvariant()] = $relative

    $path = [IO.Path]::GetFullPath((Join-Path $root $relative))
    if (-not $path.StartsWith($baseFull, [StringComparison]::OrdinalIgnoreCase)) {
        $failures.Add("Manifest path escapes package root: $relative")
        continue
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $failures.Add("Missing file: $relative")
        continue
    }

    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($actual -ne $expected) {
        $failures.Add("SHA-256 mismatch: $relative")
    }
}

$actualFiles = @(
    Get-ChildItem -LiteralPath $root -File -Recurse -ErrorAction Stop |
        Where-Object { $_.FullName -ne $manifestPath } |
        ForEach-Object {
            $_.FullName.Substring($root.Length).TrimStart(
                [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
            )
        }
)

foreach ($relative in $actualFiles) {
    if (-not $manifestEntries.ContainsKey($relative.ToLowerInvariant())) {
        $failures.Add("File is not listed in checksums.sha256: $relative")
    }
}
foreach ($relative in $manifestEntries.Values) {
    if ($actualFiles -notcontains $relative) {
        $failures.Add("Manifest entry has no matching package file: $relative")
    }
}

if ($failures.Count -gt 0) {
    Write-Host 'PACKAGE_VERIFY_FAILED' -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host ('- ' + $failure) -ForegroundColor Red
    }
    exit 1
}

Write-Host 'PACKAGE_SHA256_OK. This release is not Authenticode-signed.' -ForegroundColor Green
exit 0
