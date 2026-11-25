# Builds the vendored PCRE2 (16-bit library only) into build\lib\pcre2d.lib with MSVC (cl/lib).
# Run from a Developer PowerShell / after vcvars64. Compiled with /MT to match LDC's static CRT.
# Options (env, part of the rebuild stamp): PCRE2_JIT=auto|on|off, PCRE2_NEWLINE=LF|CR|CRLF|ANY|ANYCRLF|NUL,
# PCRE2_MATCH_LIMIT=N, PCRE2_EXTRA_CFLAGS, CFLAGS. Second argument "nojit" forces JIT off.
param([string]$Mode = "static", [string]$Variant = "")
$ErrorActionPreference = "Stop"
if ($Mode -ne "static") { throw "only 'static' is implemented" }

$Root = Split-Path -Parent $PSScriptRoot
$Src  = Join-Path $Root "vendor\pcre2\src"
$Out  = Join-Path $Root "build\lib"
$Obj  = Join-Path $Root "build\obj-$Mode"
New-Item -ItemType Directory -Force $Out, $Obj | Out-Null

if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
    throw "cl.exe not found: run from a Visual Studio developer environment (vcvars64.bat)"
}

$Jit = if ($env:PCRE2_JIT) { $env:PCRE2_JIT } else { "auto" }
if ($Variant -eq "nojit") { $Jit = "off" }
if ($Jit -eq "auto") { $Jit = "on" }   # x86_64 / arm64 Windows are supported by sljit
$NlMap = @{ CR = 1; LF = 2; CRLF = 3; ANY = 4; ANYCRLF = 5; NUL = 6 }
$NlName = if ($env:PCRE2_NEWLINE) { $env:PCRE2_NEWLINE } else { "LF" }
if (-not $NlMap.ContainsKey($NlName)) { throw "PCRE2_NEWLINE must be LF|CR|CRLF|ANY|ANYCRLF|NUL" }

$Flags = @("/nologo", "/O2", "/std:c11", "/MT", "/wd4244", "/wd4267", "/wd4146", "/wd4996",
           "/DHAVE_CONFIG_H", "/DPCRE2_CODE_UNIT_WIDTH=16", "/DPCRE2_STATIC", "/DNEWLINE_DEFAULT=$($NlMap[$NlName])",
           "/I$Root\config", "/I$Src")
if ($Jit -eq "on") { $Flags += "/DPCRE2D_JIT" }
if ($env:PCRE2_MATCH_LIMIT) { $Flags += "/DMATCH_LIMIT=$($env:PCRE2_MATCH_LIMIT)" }
if ($env:PCRE2_EXTRA_CFLAGS) { $Flags += $env:PCRE2_EXTRA_CFLAGS -split " " }
if ($env:CFLAGS) { $Flags += $env:CFLAGS -split " " }

$Sources = Get-ChildItem "$Src\pcre2_*.c" | ForEach-Object FullName
$Target  = Join-Path $Out "pcre2d.lib"
$Stamp   = Join-Path $Obj "flags.stamp"
$ClVersion = (& cmd.exe /c "cl.exe 2>&1" | Select-Object -First 1)
$NewStamp = "$ClVersion" + "|" + ($Flags -join " ")
if (-not (Test-Path $Stamp) -or (Get-Content $Stamp -Raw) -ne $NewStamp) {
    Remove-Item "$Obj\*.obj", $Target -ErrorAction SilentlyContinue
    Set-Content $Stamp $NewStamp -NoNewline
}

$Headers = @(Get-ChildItem "$Src\*.h", "$Root\config\config.h") + @(Get-ChildItem "$Root\vendor\pcre2\deps\sljit\sljit_src" -Recurse -Include *.c, *.h)
$NeedLink = -not (Test-Path $Target)
foreach ($s in $Sources) {
    $o = Join-Path $Obj ([IO.Path]::GetFileNameWithoutExtension($s) + ".obj")
    $rebuild = -not (Test-Path $o)
    if (-not $rebuild) {
        $t = (Get-Item $o).LastWriteTime
        $rebuild = ((Get-Item $s).LastWriteTime -gt $t) -or ($Headers | Where-Object { $_.LastWriteTime -gt $t })
    }
    if ($rebuild) {
        Write-Host "CC  $(Split-Path -Leaf $s)"
        & cl.exe @Flags /c $s "/Fo$o"
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        $NeedLink = $true
    }
}
if ($NeedLink) {
    Write-Host "LIB pcre2d.lib (JIT=$Jit)"
    Remove-Item $Target -ErrorAction SilentlyContinue
    & lib.exe /nologo "/OUT:$Target" (Get-ChildItem "$Obj\*.obj" | ForEach-Object FullName)
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
