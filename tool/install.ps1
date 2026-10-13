# Installs `just` and `ju` (just_core_cli) from the newest GitHub release, on
# Windows:
#
#   irm https://raw.githubusercontent.com/just-unknown-dev/just-core-cli/main/tool/install.ps1 | iex
#
# Or, with Dart: dart pub global activate just_core_cli
#
# The folder goes at the END of your user PATH, so a `just` you already have
# (the `just` command runner, say) keeps working: then use `ju`.

$ErrorActionPreference = 'Stop'
# GitHub needs TLS 1.2, which older Windows PowerShell 5.1 setups don't
# offer by default.
[Net.ServicePointManager]::SecurityProtocol =
  [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$repo = 'just-unknown-dev/just-core-cli'
$dir = Join-Path $env:LOCALAPPDATA 'just_core_cli\bin'

$release = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest"
$asset = $release.assets | Where-Object { $_.name -like '*-windows-x64.zip' } | Select-Object -First 1
$sums = $release.assets | Where-Object { $_.name -eq 'SHA256SUMS' } | Select-Object -First 1
if (-not $asset -or -not $sums) { throw "The release $($release.tag_name) has no Windows build." }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("just_core_cli_" + [Guid]::NewGuid())
New-Item -ItemType Directory $tmp | Out-Null
try {
  $zip = Join-Path $tmp $asset.name
  Invoke-WebRequest $asset.browser_download_url -OutFile $zip -UseBasicParsing
  # Read from a file: PowerShell 7 gives a binary download's .Content as
  # bytes, not text.
  $sumsFile = Join-Path $tmp 'SHA256SUMS'
  Invoke-WebRequest $sums.browser_download_url -OutFile $sumsFile -UseBasicParsing
  $line = Get-Content $sumsFile | Where-Object { $_ -match ('^[0-9a-fA-F]{64}\s+\*?' + [regex]::Escape($asset.name) + '$') } |
    Select-Object -First 1
  if (-not $line) { throw "SHA256SUMS has no line for $($asset.name): not installed." }
  $expected = ($line -split '\s+')[0].ToLower()
  $actual = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
  if ($expected -ne $actual) { throw "The download does not match its SHA-256: not installed." }

  Expand-Archive $zip -DestinationPath $tmp -Force
  New-Item -ItemType Directory -Force $dir | Out-Null
  Copy-Item (Join-Path $tmp 'just_core_cli\just.exe') $dir -Force
  Copy-Item (Join-Path $tmp 'just_core_cli\ju.exe') $dir -Force
} finally {
  Remove-Item $tmp -Recurse -Force
}

# The user PATH straight from the registry: unexpanded (%USERPROFILE%\...
# entries stay as they are) and written back with its own type
# (REG_EXPAND_SZ, usually) — or created when the user has none.
$key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
try {
  $path = [string]$key.GetValue('Path', '',
    [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
  $kind = if ($null -ne $key.GetValue('Path')) { $key.GetValueKind('Path') }
    else { [Microsoft.Win32.RegistryValueKind]::ExpandString }
  $entries = @($path -split ';' | Where-Object { $_ })
  if (-not ($entries -contains $dir)) {
    $key.SetValue('Path', (($entries + $dir) -join ';'), $kind)
    # Clearing a variable that isn't set tells running programs (Explorer)
    # that the environment changed, so new terminals see the PATH.
    [Environment]::SetEnvironmentVariable('JUST_CORE_CLI_SETUP', $null, 'User')
    Write-Host "Added $dir to the end of your PATH (open a new terminal)."
  }
} finally {
  $key.Close()
}

$other = Get-Command just -ErrorAction SilentlyContinue |
  Where-Object { $_.Source -and -not $_.Source.StartsWith($dir) } | Select-Object -First 1
Write-Host "Installed just_core_cli $($release.tag_name)."
if ($other) {
  Write-Host "Another ``just`` is on your PATH ($($other.Source)), so use ``ju``: the same tool."
} else {
  Write-Host 'Run: just doctor'
}
