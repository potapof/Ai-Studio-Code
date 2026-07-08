# ============================================================================
# 00-prepare-host.ps1
# ============================================================================
# Подготовка Windows-хоста для проекта "Студия программирования" v2.0
# - Создание папок D:\StudioCode, D:\VMs
# - Скачивание VirtualBox 7.2 + Extension Pack
# - Скачивание Linux Mint 22 ISO
# - Установка Syncthing для Windows
# - Создание задачи в Task Scheduler для автозапуска VM
# - Проверка виртуализации в BIOS
#
# Usage:
#   powershell.exe -ExecutionPolicy Bypass -File .\00-prepare-host.ps1
# ============================================================================

#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$StudioCodeDir = "D:\StudioCode",
    [string]$VMsDir        = "D:\VMs",
    [string]$DownloadDir   = "D:\VMs\downloads",
    [string]$VirtualBoxVersion = "7.2.4",
    [string]$MintIsoUrl    = "https://mirrors.kernel.org/linuxmint/stable/22/linuxmint-22-cinnamon-64bit.iso"
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Хелперы для цветного вывода
# ---------------------------------------------------------------------------
function Write-Ok    { param($msg) Write-Host "[OK]   $msg" -ForegroundColor Green }
function Write-Warn  { param($msg) Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-Err   { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red }
function Write-Info  { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Cyan }

# ---------------------------------------------------------------------------
# 0. Проверка виртуализации в BIOS
# ---------------------------------------------------------------------------
Write-Info "Проверка поддержки виртуализации в BIOS..."

$cpuInfo = Get-CimInstance -ClassName Win32_Processor
if ($cpuInfo.VirtualizationFirmwareEnabled) {
    Write-Ok "Виртуализация включена в BIOS (VT-x/AMD-V)"
} else {
    Write-Warn "Виртуализация НЕ включена в BIOS."
    Write-Warn "Войдите в BIOS и включите Intel VT-x / AMD-V перед установкой VM."
    $continue = Read-Host "Продолжить установку? (y/N)"
    if ($continue -ne "y") {
        Write-Err "Установка прервана пользователем."
        exit 1
    }
}

# Дополнительная проверка через Hyper-V WMI
try {
    $hv = (Get-CimInstance -ClassName Win32_ComputerSystem).HypervisorLaunchInfo
    Write-Info "Hyper-V launch info: $hv"
} catch {
    Write-Info "Hyper-V WMI недоступен — пропускаем проверку."
}

# ---------------------------------------------------------------------------
# 1. Создание папок
# ---------------------------------------------------------------------------
Write-Info "Создание папок $StudioCodeDir и $VMsDir..."

# Создание D:\StudioCode (требуются права администратора для корня диска)
if (-not (Test-Path $StudioCodeDir)) {
    try {
        New-Item -ItemType Directory -Path $StudioCodeDir -Force | Out-Null
        Write-Ok "Создана папка: $StudioCodeDir"
    } catch {
        Write-Err "Не удалось создать $StudioCodeDir"
        Write-Err $_.Exception.Message
        exit 1
    }
} else {
    Write-Info "Папка $StudioCodeDir уже существует — пропуск"
}

# Создание D:\VMs
if (-not (Test-Path $VMsDir)) {
    try {
        New-Item -ItemType Directory -Path $VMsDir -Force | Out-Null
        Write-Ok "Создана папка: $VMsDir"
    } catch {
        Write-Err "Не удалось создать $VMsDir"
        Write-Err $_.Exception.Message
        exit 1
    }
} else {
    Write-Info "Папка $VMsDir уже существует — пропуск"
}

# Создание подпапки для загрузок
if (-not (Test-Path $DownloadDir)) {
    New-Item -ItemType Directory -Path $DownloadDir -Force | Out-Null
    Write-Ok "Создана папка: $DownloadDir"
}

# ---------------------------------------------------------------------------
# 2. Скачивание VirtualBox 7.2 + Extension Pack
# ---------------------------------------------------------------------------
Write-Info "Скачивание VirtualBox $VirtualBoxVersion..."

$vboxInstaller = Join-Path $DownloadDir "VirtualBox-$VirtualBoxVersion-Win.exe"
$vboxUrl = "https://download.virtualbox.org/virtualbox/$VirtualBoxVersion/VirtualBox-$VirtualBoxVersion-164428-Win.exe"

if (-not (Test-Path $vboxInstaller)) {
    try {
        Invoke-WebRequest -Uri $vboxUrl -OutFile $vboxInstaller -UseBasicParsing
        Write-Ok "VirtualBox скачан: $vboxInstaller"
    } catch {
        Write-Err "Не удалось скачать VirtualBox с $vboxUrl"
        Write-Err $_.Exception.Message
        exit 1
    }
} else {
    Write-Info "VirtualBox уже скачан: $vboxInstaller — пропуск"
}

# Extension Pack
Write-Info "Скачивание VirtualBox Extension Pack..."
$extPack = Join-Path $DownloadDir "Oracle_VirtualBox_Extension_Pack-$VirtualBoxVersion.vbox-extpack"
$extPackUrl = "https://download.virtualbox.org/virtualbox/$VirtualBoxVersion/Oracle_VirtualBox_Extension_Pack-$VirtualBoxVersion.vbox-extpack"

if (-not (Test-Path $extPack)) {
    try {
        Invoke-WebRequest -Uri $extPackUrl -OutFile $extPack -UseBasicParsing
        Write-Ok "Extension Pack скачан: $extPack"
    } catch {
        Write-Err "Не удалось скачать Extension Pack с $extPackUrl"
        Write-Err $_.Exception.Message
        exit 1
    }
} else {
    Write-Info "Extension Pack уже скачан: $extPack — пропуск"
}

# ---------------------------------------------------------------------------
# 3. Скачивание Linux Mint 22 ISO
# ---------------------------------------------------------------------------
Write-Info "Скачивание Linux Mint 22 ISO (это может занять до 30 минут)..."

$mintIso = Join-Path $DownloadDir "linuxmint-22-cinnamon-64bit.iso"

if (-not (Test-Path $mintIso)) {
    try {
        # Показываем прогресс загрузки
        $ProgressPreference = 'Continue'
        Invoke-WebRequest -Uri $MintIsoUrl -OutFile $mintIso -UseBasicParsing
        Write-Ok "Linux Mint 22 ISO скачан: $mintIso"
    } catch {
        Write-Err "Не удалось скачать ISO с $MintIsoUrl"
        Write-Err "Попробуйте зеркало: https://linuxmint.com/download.php"
        Write-Err $_.Exception.Message
        exit 1
    }
} else {
    Write-Info "ISO Linux Mint уже скачан: $mintIso — пропуск"
}

# Проверка размера ISO (обычно ~3 ГБ)
$isoSize = (Get-Item $mintIso).Length / 1GB
if ($isoSize -lt 2.0) {
    Write-Warn "Размер ISO ($([math]::Round($isoSize, 2)) ГБ) меньше ожидаемого. Возможно, файл повреждён."
} else {
    Write-Ok "Размер ISO: $([math]::Round($isoSize, 2)) ГБ"
}

# ---------------------------------------------------------------------------
# 4. Установка Syncthing для Windows
# ---------------------------------------------------------------------------
Write-Info "Проверка установки Syncthing..."

$chocoAvailable = $false
try {
    $chocoVersion = & choco --version 2>$null
    if ($LASTEXITCODE -eq 0) { $chocoAvailable = $true }
} catch {
    $chocoAvailable = $false
}

if ($chocoAvailable) {
    Write-Info "Chocolatey доступен ($chocoVersion). Установка Syncthing через choco..."
    # sudo-аналог в Windows — запуск от администратора
    # Требуется запуск PowerShell от имени администратора
    try {
        Start-Process -FilePath "choco" -ArgumentList "install syncthing -y --no-progress" -Wait -NoNewWindow
        Write-Ok "Syncthing установлен через Chocolatey"
    } catch {
        Write-Warn "Установка через choco не удалась. Скачиваем вручную."
        $chocoAvailable = $false
    }
}

if (-not $chocoAvailable) {
    # Ручная установка Syncthing
    $syncthingDir = Join-Path $StudioCodeDir "syncthing"
    if (-not (Test-Path $syncthingDir)) {
        New-Item -ItemType Directory -Path $syncthingDir -Force | Out-Null
    }

    # Определяем последнюю версию Syncthing через GitHub API
    try {
        $latestRelease = Invoke-RestMethod -Uri "https://api.github.com/repos/syncthing/syncthing/releases/latest" -UseBasicParsing
        $syncthingVersion = $latestRelease.tag_name.TrimStart('v')
        Write-Info "Последняя версия Syncthing: $syncthingVersion"
    } catch {
        Write-Warn "Не удалось получить версию Syncthing через GitHub API. Используем 1.27.10"
        $syncthingVersion = "1.27.10"
    }

    $syncthingZip = Join-Path $DownloadDir "syncthing-windows-amd64-v$syncthingVersion.zip"
    $syncthingUrl = "https://github.com/syncthing/syncthing/releases/download/v$syncthingVersion/syncthing-windows-amd64-v$syncthingVersion.zip"

    if (-not (Test-Path $syncthingZip)) {
        try {
            Invoke-WebRequest -Uri $syncthingUrl -OutFile $syncthingZip -UseBasicParsing
            Write-Ok "Syncthing архив скачан: $syncthingZip"
        } catch {
            Write-Err "Не удалось скачать Syncthing с $syncthingUrl"
            Write-Err $_.Exception.Message
            exit 1
        }
    }

    # Распаковка
    try {
        Expand-Archive -Path $syncthingZip -DestinationPath $syncthingDir -Force
        Write-Ok "Syncthing распакован в $syncthingDir"
    } catch {
        Write-Err "Не удалось распаковать архив Syncthing"
        Write-Err $_.Exception.Message
        exit 1
    }

    # Поиск исполняемого файла syncthing.exe
    $syncthingExe = Get-ChildItem -Path $syncthingDir -Recurse -Filter "syncthing.exe" | Select-Object -First 1
    if ($syncthingExe) {
        Write-Ok "Syncthing executable: $($syncthingExe.FullName)"
        # Добавляем в PATH для текущего пользователя
        $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
        $syncthingBinDir = Split-Path $syncthingExe.FullName
        if ($userPath -notlike "*$syncthingBinDir*") {
            [Environment]::SetEnvironmentVariable("PATH", "$userPath;$syncthingBinDir", "User")
            Write-Ok "Syncthing добавлен в PATH пользователя"
        }
    } else {
        Write-Err "syncthing.exe не найден после распаковки"
        exit 1
    }
}

# ---------------------------------------------------------------------------
# 5. Создание задачи в Task Scheduler для автозапуска VM
# ---------------------------------------------------------------------------
Write-Info "Создание задачи в Task Scheduler для автозапуска VM studio-mint..."

$taskName = "StudioAutostartVM"
$taskExists = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

# VBoxManage путь — обычно C:\Program Files\Oracle\VirtualBox\VBoxManage.exe
$vboxManagePath = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
if (-not (Test-Path $vboxManagePath)) {
    # Альтернативный путь в x86
    $vboxManagePath = "C:\Program Files (x86)\Oracle\VirtualBox\VBoxManage.exe"
}

if (-not (Test-Path $vboxManagePath)) {
    Write-Warn "VBoxManage не найден в стандартных путях. Пропускаем создание задачи."
    Write-Warn "Установите VirtualBox вручную и повторно запустите этот скрипт."
} else {
    $startVmAction = New-ScheduledTaskAction `
        -Execute $vboxManagePath `
        -Argument "startvm studio-mint --type headless"

    # Запускать при входе пользователя в систему
    $trigger = New-ScheduledTaskTrigger -AtLogOn

    # Запуск от имени текущего пользователя без пароля (только интерактивно)
    $principal = New-ScheduledTaskPrincipal `
        -UserId $env:USERNAME `
        -LogonType Interactive `
        -RunLevel Highest

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable

    try {
        if ($taskExists) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            Write-Info "Старая задача $taskName удалена"
        }
        Register-ScheduledTask `
            -TaskName $taskName `
            -Action $startVmAction `
            -Trigger $trigger `
            -Principal $principal `
            -Settings $settings `
            -Description "Автозапуск VM studio-mint при входе пользователя" | Out-Null
        Write-Ok "Задача '$taskName' создана в Task Scheduler"
    } catch {
        Write-Err "Не удалось создать задачу в Task Scheduler"
        Write-Err $_.Exception.Message
        # Не выходим — это некритично
    }
}

# ---------------------------------------------------------------------------
# 6. Итоговая сводка
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Ok "Подготовка Windows-хоста завершена"
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Папки:"
Write-Host "  StudioCode: $StudioCodeDir"
Write-Host "  VMs:        $VMsDir"
Write-Host "  Downloads:  $DownloadDir"
Write-Host ""
Write-Host "Файлы:"
Write-Host "  VirtualBox:        $vboxInstaller"
Write-Host "  Extension Pack:    $extPack"
Write-Host "  Mint ISO:          $mintIso"
Write-Host ""
Write-Host "Следующие шаги:"
Write-Host "  1. Установите VirtualBox 7.2 ($vboxInstaller)"
Write-Host "  2. Дважды кликните по Extension Pack ($extPack) для установки"
Write-Host "  3. Запустите 01-create-vm.sh на Linux-хосте или вручную через VBoxManage"
Write-Host "  4. После создания VM запустите установку Linux Mint 22 из ISO"
Write-Host ""

exit 0
