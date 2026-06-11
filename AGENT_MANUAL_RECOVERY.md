# Agent Manual Recovery

Этот документ нужен для сценария без encrypted bundle.

Предпосылка:

- ты сам даешь агенту доступ к Яндексу
- ты сам даешь агенту этот документ
- агент восстанавливает систему вручную по шагам

## Что должен получить агент

Минимум:

- доступ к `rclone` remote `yadisk:server_backup`
- доступ к инструкции восстановления
- содержимое:
  - `homeserver-backup.env`
  - `homeserver-restore.sh`
  - `homeserver-bootstrap-restore.sh`

Опционально, но полезно:

- `homeserver-backup.exclude`
- `HOMESERVER_BACKUP_RESTORE.md`
- bundled legacy libs:
  - `legacy-libssl.so.1.1`
  - `legacy-libcrypto.so.1.1`

## Где искать данные в Яндексе

- `yadisk:server_backup/LATEST`
- `yadisk:server_backup/snapshots/<SNAPSHOT_ID>/`
- `yadisk:server_backup/objects/<entity>/<fingerprint>.tar.zst`

## Текущее рабочее состояние

По состоянию на `2026-06-11`:

- актуальный snapshot: читать из `yadisk:server_backup/LATEST`
- последний полностью проверенный snapshot: `2026-06-09_20-00-31`
- этот snapshot успешно прошел полный `test restore` на отдельной Ubuntu 22.04 машине
- текущая retention-схема:
  - локально хранится `1` последний snapshot
  - на Яндексе хранятся `30` последних snapshot
- старые snapshot удаляются в конце успешного backup, а не по отдельному таймеру

## Какой режим выбирать

### `disaster`

Использовать, когда старая машина умерла и новая должна подняться как она же:

- старый hostname
- старые bind IP
- старые сервисные адреса

### `test`

Использовать, когда старая машина еще жива, а restore проверяется на другой машине:

- сеть текущей машины сохраняется
- сервисные bind-адреса ремапятся с `PRIMARY_SERVICE_IP` на `RESTORE_TEST_TARGET_IP`

## Пошаговое восстановление агентом

### 1. Установить зависимости

```bash
sudo apt-get update -y
sudo apt-get install -y curl jq zstd tar rclone docker.io python3 gnupg
```

Если `apt update` ломается на `NodeSource`, отключить его и повторить:

```bash
sudo mv /etc/apt/sources.list.d/nodesource.list /etc/apt/sources.list.d/nodesource.list.disabled
sudo apt-get update -y
```

### 2. Положить recovery-файлы

```bash
sudo install -m 600 homeserver-backup.env /etc/homeserver-backup.env
sudo install -m 700 homeserver-restore.sh /usr/local/sbin/homeserver-restore.sh
sudo install -m 700 homeserver-bootstrap-restore.sh /usr/local/sbin/homeserver-bootstrap-restore.sh
```

Если есть:

```bash
sudo install -m 600 homeserver-backup.exclude /etc/homeserver-backup.exclude
sudo install -m 600 HOMESERVER_BACKUP_RESTORE.md /root/HOMESERVER_BACKUP_RESTORE.md
```

Если есть bundled legacy libs:

```bash
sudo install -d -m 755 /opt/homeserver-recovery/lib
sudo install -m 644 legacy-libssl.so.1.1 /opt/homeserver-recovery/lib/legacy-libssl.so.1.1
sudo install -m 644 legacy-libcrypto.so.1.1 /opt/homeserver-recovery/lib/legacy-libcrypto.so.1.1
```

### 3. Проверить доступ к Яндексу

```bash
rclone listremotes
rclone cat yadisk:server_backup/LATEST
```

### 4. Включить restore

```bash
sudo sed -i 's/^ALLOW_RESTORE=.*/ALLOW_RESTORE="YES"/' /etc/homeserver-backup.env
```

### 5. Выбрать режим

#### Disaster

```bash
sudo sed -i 's/^RESTORE_MODE=.*/RESTORE_MODE="disaster"/' /etc/homeserver-backup.env
sudo sed -i 's/^RESTORE_TEST_TARGET_IP=.*/RESTORE_TEST_TARGET_IP=""/' /etc/homeserver-backup.env
```

#### Test

```bash
sudo sed -i 's/^RESTORE_MODE=.*/RESTORE_MODE="test"/' /etc/homeserver-backup.env
sudo sed -i 's/^RESTORE_TEST_TARGET_IP=.*/RESTORE_TEST_TARGET_IP="TEST_MACHINE_IP"/' /etc/homeserver-backup.env
```

### 6. Узнать snapshot

Последний:

```bash
rclone cat yadisk:server_backup/LATEST
```

Или конкретный ID вручную.

### 7. Запустить восстановление

Последний snapshot:

```bash
sudo /usr/local/sbin/homeserver-bootstrap-restore.sh "" disaster
```

Или:

```bash
sudo /usr/local/sbin/homeserver-bootstrap-restore.sh "" test
```

Конкретный snapshot:

```bash
sudo /usr/local/sbin/homeserver-bootstrap-restore.sh <SNAPSHOT_ID> disaster
```

### 8. Проверка после восстановления

```bash
systemctl status x-ui --no-pager
/etc/init.d/bt status
docker ps
ss -ltnp | grep -E '2053|10808|30001|22334|8443'
```

Если Apache не поднимается, сначала проверить:

```bash
/www/server/apache/bin/httpd -t
ls -ld /www/wwwlogs
ldconfig -p | grep -E 'libssl.so.1.1|libcrypto.so.1.1|liblua5.1.so.0'
```

Новая схема recovery уже пытается сделать это сама:

- убрать `CRLF` из `/etc/homeserver-backup.env`
- создать `/www/wwwlogs`
- поставить `liblua5.1-0`
- подложить bundled `libssl.so.1.1` и `libcrypto.so.1.1`, если их нет в системе
- стартовать `x-ui` после restore
- корректно остановить и поднять `Apache`, `pure-ftpd`, `aaPanel`, `mtg`

## Что агент должен знать заранее

### В test mode

Нужно знать:

- `PRIMARY_SERVICE_IP`
- текущий IP тестовой машины, например `192.168.230.132`

### В disaster mode

Нужно понимать:

- старая машина должна быть выключена или мертва
- иначе IP-конфликт

## Ограничения

Агент не сможет автоматически:

- вернуть белый внешний IP провайдера
- перенастроить роутер/DMZ
- угадать секреты без доступа к `rclone`/Yandex

## Рекомендуемый порядок для пользователя

1. Дать агенту доступ к Яндексу
2. Дать агенту этот документ
3. Указать режим: `disaster` или `test`
4. Дать текущий IP тестовой машины, если это `test`
