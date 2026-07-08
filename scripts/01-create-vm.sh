#!/usr/bin/env bash
# ============================================================================
# 01-create-vm.sh
# ============================================================================
# Создание виртуальной машины studio-mint в VirtualBox через VBoxManage.
# - 16 ГБ RAM, 4 CPU, 100 ГБ VDI
# - Storage: SATA (VDI) + IDE (ISO)
# - Network: NAT + Host-only
# - Проброс портов: 2222->22, 8080->8080, 9000->9000, 8384->8384,
#                    8082->8080 (hermes), 8081->8081 (webhook)
# - Shared folder: D:\StudioCode -> host_shared
# - Display: VMSVGA, 128 МБ, 3D-ускорение
#
# Usage:
#   sudo ./01-create-vm.sh [VM_NAME] [ISO_PATH]
#   sudo ./01-create-vm.sh studio-mint /path/to/linuxmint-22.iso
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Параметры по умолчанию
# ---------------------------------------------------------------------------
VM_NAME="${1:-studio-mint}"
ISO_PATH="${2:-D:\\VMs\\downloads\\linuxmint-22-cinnamon-64bit.iso}"
SHARED_HOST_DIR="${3:-D:\\StudioCode}"

# Путь к VBoxManage (Windows: C:\Program Files\Oracle\VirtualBox\VBoxManage.exe)
VBOXMANAGE="${VBOXMANAGE:-VBoxManage}"

# Ресурсы VM
VM_MEMORY_MB=16384          # 16 ГБ RAM
VM_CPU_COUNT=4
VM_DISK_MB=102400           # 100 ГБ VDI
VM_VRAM_MB=128              # 128 МБ видео-памяти

# Папка для VM (D:\VMs\studio-mint)
VM_DIR="D:\\VMs\\${VM_NAME}"
VM_DISK="${VM_DIR}\\${VM_NAME}.vdi"

# ---------------------------------------------------------------------------
# Цветной вывод
# ---------------------------------------------------------------------------
ok()    { echo -e "\033[32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[33m[WARN]\033[0m  $*"; }
err()   { echo -e "\033[31m[ERROR]\033[0m $*"; }
info()  { echo -e "\033[36m[INFO]\033[0m  $*"; }

# ---------------------------------------------------------------------------
# Проверка наличия VBoxManage
# ---------------------------------------------------------------------------
if ! command -v "$VBOXMANAGE" >/dev/null 2>&1; then
    err "VBoxManage не найден в PATH. Установите VirtualBox 7.2."
    err "На Windows путь: C:\\Program Files\\Oracle\\VirtualBox\\VBoxManage.exe"
    exit 1
fi
ok "VBoxManage доступен: $(command -v "$VBOXMANAGE")"

# ---------------------------------------------------------------------------
# Проверка ISO-образа
# ---------------------------------------------------------------------------
info "Проверка ISO-образа: $ISO_PATH"
if [ ! -f "$ISO_PATH" ] && [ ! -f "${ISO_PATH//\\\\/\\/}" ]; then
    warn "ISO не найден по пути: $ISO_PATH"
    warn "Скачайте Linux Mint 22 и укажите путь вторым аргументом."
    warn "Продолжаем создание VM, но установку Mint нужно будет запустить вручную."
fi

# ---------------------------------------------------------------------------
# Удаление существующей VM с таким же именем (если есть)
# ---------------------------------------------------------------------------
info "Проверка, существует ли уже VM с именем $VM_NAME..."
if "$VBOXMANAGE" showvminfo "$VM_NAME" >/dev/null 2>&1; then
    warn "VM с именем '$VM_NAME' уже существует."
    read -r -p "Удалить и создать заново? (y/N): " confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        info "Останавливаю и удаляю существующую VM..."
        # sudo: остановка VM может требовать прав на Windows для VBoxManage
        "$VBOXMANAGE" controlvm "$VM_NAME" poweroff >/dev/null 2>&1 || true
        "$VBOXMANAGE" unregistervm "$VM_NAME" --delete >/dev/null 2>&1 || true
        ok "Существующая VM удалена"
    else
        err "Операция прервана пользователем."
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# 1. Создание VM
# ---------------------------------------------------------------------------
info "Создаю VM '$VM_NAME' в папке $VM_DIR..."
"$VBOXMANAGE" createvm \
    --name "$VM_NAME" \
    --basefolder "D:\\VMs" \
    --ostype "Ubuntu_64" \
    --register || { err "Не удалось создать VM"; exit 1; }
ok "VM создана и зарегистрирована"

# ---------------------------------------------------------------------------
# 2. Настройка базовых параметров (RAM, CPU, VRAM, display)
# ---------------------------------------------------------------------------
info "Настраиваю ресурсы: RAM=${VM_MEMORY_MB}MB, CPU=${VM_CPU_COUNT}, VRAM=${VM_VRAM_MB}MB..."
"$VBOXMANAGE" modifyvm "$VM_NAME" \
    --memory "$VM_MEMORY_MB" \
    --cpus "$VM_CPU_COUNT" \
    --vram "$VM_VRAM_MB" \
    --graphicscontroller vmsvga \
    --accelerate3d on \
    --ioapic on \
    --hwvirtex on \
    --vtxvpid on \
    --nestedpaging on \
    --largepages on \
    --boot1 dvd \
    --boot2 disk \
    --boot3 none \
    --boot4 none \
    --nic1 nat \
    --nictype1 82540EM \
    --cableconnected1 on \
    --natdnsproxy1 on \
    --natdnshostresolver1 on \
    --nic2 hostonly \
    --nictype2 82540EM \
    --cableconnected2 on || { err "Не удалось настроить ресурсы VM"; exit 1; }
ok "Ресурсы и сетевые адаптеры настроены"

# ---------------------------------------------------------------------------
# 3. Создание виртуального жёсткого диска (100 ГБ VDI)
# ---------------------------------------------------------------------------
info "Создаю VDI-диск: $VM_DISK (${VM_DISK_MB} МБ)..."
if [ -f "$VM_DISK" ]; then
    warn "VDI уже существует — пропускаю создание"
else
    "$VBOXMANAGE" createmedium \
        --filename "$VM_DISK" \
        --size "$VM_DISK_MB" \
        --variant Standard || { err "Не удалось создать VDI"; exit 1; }
    ok "VDI-диск создан"
fi

# ---------------------------------------------------------------------------
# 4. Подключение SATA-контроллера и VDI-диска
# ---------------------------------------------------------------------------
info "Подключаю SATA-контроллер и VDI..."
"$VBOXMANAGE" storagectl "$VM_NAME" \
    --name "SATA" \
    --add sata \
    --controller IntelAhci \
    --portcount 4 \
    --bootable on || { err "Не удалось создать SATA-контроллер"; exit 1; }

"$VBOXMANAGE" storageattach "$VM_NAME" \
    --storagectl "SATA" \
    --port 0 \
    --device 0 \
    --type hdd \
    --medium "$VM_DISK" || { err "Не удалось подключить VDI к SATA"; exit 1; }
ok "SATA и VDI подключены"

# ---------------------------------------------------------------------------
# 5. Подключение IDE-контроллера и ISO-образа
# ---------------------------------------------------------------------------
info "Подключаю IDE-контроллер и ISO-образ..."
"$VBOXMANAGE" storagectl "$VM_NAME" \
    --name "IDE" \
    --add ide \
    --controller PIIX4 \
    --bootable on || { err "Не удалось создать IDE-контроллер"; exit 1; }

# Подключаем ISO если он существует
if [ -f "$ISO_PATH" ]; then
    "$VBOXMANAGE" storageattach "$VM_NAME" \
        --storagectl "IDE" \
        --port 1 \
        --device 0 \
        --type dvddrive \
        --medium "$ISO_PATH" || { err "Не удалось подключить ISO"; exit 1; }
    ok "ISO подключён к IDE"
else
    warn "ISO не подключён — нет файла. Запустите VM с установочным носителем вручную."
fi
ok "IDE-контроллер создан"

# ---------------------------------------------------------------------------
# 6. Проброс портов через NAT (NAT Network)
# ---------------------------------------------------------------------------
info "Настраиваю проброс портов через NAT..."

# 2222 -> 22 (SSH)
"$VBOXMANAGE" modifyvm "$VM_NAME" \
    --natpf1 "ssh,tcp,127.0.0.1,2222,,22" || { err "Не удалось пробросить порт 2222->22"; exit 1; }

# 8080 -> 8080 (NocoDB)
"$VBOXMANAGE" modifyvm "$VM_NAME" \
    --natpf1 "nocodb,tcp,127.0.0.1,8080,,8080" || { err "Не удалось пробросить порт 8080->8080"; exit 1; }

# 9000 -> 9000 (Portainer)
"$VBOXMANAGE" modifyvm "$VM_NAME" \
    --natpf1 "portainer,tcp,127.0.0.1,9000,,9000" || { err "Не удалось пробросить порт 9000->9000"; exit 1; }

# 8384 -> 8384 (Syncthing)
"$VBOXMANAGE" modifyvm "$VM_NAME" \
    --natpf1 "syncthing,tcp,127.0.0.1,8384,,8384" || { err "Не удалось пробросить порт 8384->8384"; exit 1; }

# 8082 -> 8080 (Hermes — внутри VM Hermes слушает 8080, на хосте открываем 8082)
"$VBOXMANAGE" modifyvm "$VM_NAME" \
    --natpf1 "hermes,tcp,127.0.0.1,8082,,8080" || { err "Не удалось пробросить порт 8082->8080 (hermes)"; exit 1; }

# 8081 -> 8081 (webhook)
"$VBOXMANAGE" modifyvm "$VM_NAME" \
    --natpf1 "webhook,tcp,127.0.0.1,8081,,8081" || { err "Не удалось пробросить порт 8081->8081 (webhook)"; exit 1; }

ok "Проброс портов настроен: 2222->22, 8080->8080, 9000->9000, 8384->8384, 8082->8080 (hermes), 8081->8081 (webhook)"

# ---------------------------------------------------------------------------
# 7. Shared folder: D:\StudioCode -> host_shared
# ---------------------------------------------------------------------------
info "Подключаю shared folder: $SHARED_HOST_DIR -> host_shared..."
# sudo: VBoxManage sharedfolder требует прав на Windows для shared folders
"$VBOXMANAGE" sharedfolder add "$VM_NAME" \
    --name "host_shared" \
    --hostpath "$SHARED_HOST_DIR" \
    --automount \
    --auto-mount-point "/home/mint/host_shared" || { err "Не удалось добавить shared folder"; exit 1; }
ok "Shared folder подключён: $SHARED_HOST_DIR -> host_shared"

# ---------------------------------------------------------------------------
# 8. Дополнительные параметры: clipboard, drag-and-drop, USB
# ---------------------------------------------------------------------------
info "Включаю clipboard и drag-and-drop..."
"$VBOXMANAGE" modifyvm "$VM_NAME" \
    --clipboard bidirectional \
    --draganddrop bidirectional \
    --usb on \
    --usbehci on \
    --usbxhci on || { err "Не удалось включить clipboard/USB"; exit 1; }
ok "Clipboard, drag-and-drop и USB включены"

# ---------------------------------------------------------------------------
# 9. Итоговая сводка
# ---------------------------------------------------------------------------
echo ""
echo "=========================================================="
ok "VM '$VM_NAME' успешно создана"
echo "=========================================================="
info "Ресурсы:"
echo "  RAM:        ${VM_MEMORY_MB} МБ"
echo "  CPU:        ${VM_CPU_COUNT} ядра"
echo "  Disk VDI:   ${VM_DISK_MB} МБ"
echo "  VRAM:       ${VM_VRAM_MB} МБ"
info "Сеть:"
echo "  NIC1: NAT (с пробросом портов)"
echo "  NIC2: Host-only"
info "Пробросы портов:"
echo "  2222 -> 22     (SSH)"
echo "  8080 -> 8080   (NocoDB)"
echo "  9000 -> 9000   (Portainer)"
echo "  8384 -> 8384   (Syncthing)"
echo "  8082 -> 8080   (Hermes)"
echo "  8081 -> 8081   (webhook)"
info "Shared folder: $SHARED_HOST_DIR -> host_shared"
echo ""
info "Следующие шаги:"
echo "  1. Запустите VM:  VBoxManage startvm $VM_NAME --type gui"
echo "  2. Установите Linux Mint 22 через GUI-инсталлятор"
echo "  3. После установки перезагрузите VM и выполните 02-install-linux-mint.sh"
echo ""

ok "Готово."
exit 0
