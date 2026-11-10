#!/usr/bin/env bash
# Собирает и подписывает модули ядра VMware Workstation (vmmon/vmnet) на Ubuntu
# при включённом Secure Boot. Запускать от обычного пользователя (sudo спросит сам):
#   bash vmware-modules.sh
# После обновления ядра просто запусти скрипт ещё раз.
set -euo pipefail

REPO="https://github.com/philipl/vmware-host-modules.git"
SRC="$HOME/vmware-host-modules"
KEYDIR="$HOME/.vmware-mok"
KVER="$(uname -r)"

if [ "$(id -u)" -eq 0 ]; then
  echo "Запусти от обычного пользователя, не от root (sudo вызывается внутри)." >&2
  exit 1
fi

echo "== 1/6 Пакеты =="
sudo apt-get update -qq
sudo apt-get install -y build-essential "linux-headers-$KVER" git mokutil openssl

echo "== 2/6 Исходники модулей =="
if [ -d "$SRC/.git" ]; then
  git -C "$SRC" fetch --all --prune
else
  git clone "$REPO" "$SRC"
fi
cd "$SRC"
echo "origin: $(git remote get-url origin)"
BRANCH="$(git --no-pager branch -r | sed 's#^ *origin/##' | grep -i '26h1' | head -1 || true)"
if [ -n "$BRANCH" ]; then
  echo "Ветка из форка: $BRANCH"
  git checkout "$BRANCH"
  git pull --ff-only || true
else
  echo "Ветки 26h1 в origin нет, беру код из PR #335 основного репозитория."
  git remote add upstream https://github.com/mkubecek/vmware-host-modules.git 2>/dev/null || true
  git fetch upstream pull/335/head
  git checkout -B pr-335-26h1 FETCH_HEAD
fi
git log --oneline -3

echo "== 3/6 Сборка и установка =="
make clean || true
make
sudo make install

echo "== 4/6 Secure Boot =="
SB_STATE="$(mokutil --sb-state 2>&1 || true)"
echo "$SB_STATE"
if echo "$SB_STATE" | grep -qi "enabled"; then
  mkdir -p "$KEYDIR"; chmod 700 "$KEYDIR"
  if [ ! -f "$KEYDIR/MOK.priv" ]; then
    openssl req -new -x509 -newkey rsa:2048 -keyout "$KEYDIR/MOK.priv" \
      -outform DER -out "$KEYDIR/MOK.der" -nodes -days 36500 \
      -subj "/CN=VMware modules $(hostname)/"
    chmod 600 "$KEYDIR/MOK.priv"
  fi
  if ! mokutil --test-key "$KEYDIR/MOK.der" 2>&1 | grep -qi "already enrolled"; then
    echo
    echo "Ключ ещё не добавлен в MOK. Задай ОДНОРАЗОВЫЙ пароль (цифры и латиница)."
    echo "После перезагрузки на синем экране: Enroll MOK -> Continue -> Yes -> пароль -> Reboot."
    sudo mokutil --import "$KEYDIR/MOK.der"
    echo "Перезагрузись, пройди синий экран и запусти этот скрипт ещё раз."
    exit 0
  fi

  echo "== 5/6 Подпись модулей =="
  SIGN="/usr/src/linux-headers-$KVER/scripts/sign-file"
  [ -x "$SIGN" ] || SIGN="$(find /usr/src -name sign-file -type f 2>/dev/null | head -1)"
  [ -x "$SIGN" ] || { echo "sign-file не найден" >&2; exit 1; }
  for m in vmmon vmnet; do
    f="$(modinfo -n "$m")"
    case "$f" in
      *.zst|*.xz|*.gz) echo "Модуль сжат ($f), подпись автоматом не поддержана" >&2; exit 1 ;;
    esac
    sudo "$SIGN" sha256 "$KEYDIR/MOK.priv" "$KEYDIR/MOK.der" "$f"
    echo "Подписан: $f"
  done
else
  echo "Secure Boot выключен, подпись не нужна."
  echo "== 5/6 Подпись пропущена =="
fi

echo "== 6/6 Загрузка модулей и запуск VMware =="
sudo modprobe vmmon
sudo modprobe vmnet
sudo systemctl restart vmware.service || sudo systemctl restart vmware
lsmod | grep -E '^vm(mon|net)' || true
echo "Готово."
