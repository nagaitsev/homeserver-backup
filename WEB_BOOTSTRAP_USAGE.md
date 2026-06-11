# Web Bootstrap Usage

Теперь есть два варианта запуска.

## Вариант 1. Публичный bootstrap + encrypted bundle на Яндексе

Это основной рекомендуемый вариант.

На вебсервере лежит только:

- `bootstrap.sh`

На Яндексе лежит:

- `recovery-bundle.tar.gz.gpg`

Внутри encrypted bundle:

- `homeserver-backup.env`
- `homeserver-restore.sh`
- `homeserver-bootstrap-restore.sh`
- `homeserver-backup.exclude`
- `HOMESERVER_BACKUP_RESTORE.md`
- bundled legacy libs for Apache compatibility when available:
  - `legacy-libssl.so.1.1`
  - `legacy-libcrypto.so.1.1`
- опционально `rclone.conf`

## Вариант 2. Публичный bootstrap + открытый/закрытый набор файлов по URL

Это старый поддерживаемый вариант.

На вебсервере или в закрытой директории лежат:

- `bootstrap.sh`
- `homeserver-backup.env`
- `homeserver-restore.sh`
- `homeserver-bootstrap-restore.sh`

Опционально:

- `homeserver-backup.exclude`
- `HOMESERVER_BACKUP_RESTORE.md`
- `rclone.conf`

## Безопасность

`homeserver-backup.env` и особенно `rclone.conf` содержат чувствительные данные.

Если используешь вариант без encrypted bundle:

- не держи эти файлы в публично индексируемом месте
- лучше закрытая директория / basic auth / непредсказуемый URL / VPN

Если используешь encrypted bundle:

- даже если URL утечет, без passphrase архив бесполезен

## Текущее рабочее состояние

По состоянию на `2026-06-11`:

- backup-схема рабочая и проверена полным `test restore`
- последний полностью проверенный snapshot: `2026-06-09_20-00-31`
- текущая retention-схема:
  - локально `1` snapshot
  - remote `30` snapshot
- старые snapshot удаляются в конце успешного backup

## Сборка encrypted bundle

Используй:

- [`build-encrypted-recovery-bundle.sh`](./build-encrypted-recovery-bundle.sh)
- [`publish-recovery-bundle.sh`](./publish-recovery-bundle.sh)

### Вариант “одной командой”

Если запускаешь на боевом сервере и хочешь:

- взять текущие live recovery-файлы
- запросить пароль
- собрать bundle
- проверить его
- залить `.gpg` на Яндекс
- получить готовую команду восстановления

используй:

```bash
sudo bash publish-recovery-bundle.sh \
  --public-bootstrap-url https://raw.githubusercontent.com/<owner>/<repo>/<ref>/bootstrap.sh
```

По умолчанию он:

- берет recovery-файлы из `/etc` и `/usr/local/sbin`
- берет `rclone.conf` из `/root/.config/rclone/rclone.conf`
- грузит bundle в `yadisk:server_backup/recovery`
- обновляет стабильный alias `recovery-bundle-latest.*`
- печатает готовую команду `curl | bash` через публичную ссылку на папку

Пример:

```bash
bash build-encrypted-recovery-bundle.sh \
  --source-dir ./oldserver \
  --output-dir ./dist \
  --bundle-name recovery-bundle \
  --rclone-conf /path/to/rclone.conf
```

На выходе будут:

- `recovery-bundle.tar.gz`
- `recovery-bundle.tar.gz.gpg`
- `recovery-bundle.manifest.txt`
- `recovery-bundle.verify.txt`

Что делает `verify.txt`:

- подтверждает, что `.gpg` реально расшифровывается
- подтверждает, что архив реально распаковывается
- сверяет содержимое с `bundle.manifest.txt`
- проверяет, что обязательные recovery-файлы присутствуют
- проверяет, что внутри архива скрипты лежат как исполнимые, а секретные файлы как неисполняемые

Заливать на Яндекс нужно:

- `recovery-bundle.tar.gz.gpg`

И что обновляется автоматически в remote:

- `recovery-bundle-latest.tar.gz.gpg`
- `recovery-bundle-latest.manifest.txt`
- `recovery-bundle-latest.verify.txt`

Идея:

- timestamped bundle остается как исторический артефакт
- stable alias перезаписывается
- restore-команда может оставаться одной и той же

Проверить результат можно так:

```bash
cat ./dist/recovery-bundle.verify.txt
```

## Запуск на новой машине

### 1. Encrypted bundle на Яндексе

Аварийное восстановление через стабильную ссылку на папку:

```bash
curl -fsSL https://your-domain.example/recovery/bootstrap.sh | sudo bash -s -- \
  --encrypted-bundle-url "https://your-yandex-public-folder-link.example/" \
  --encrypted-bundle-path "/recovery-bundle-latest.tar.gz.gpg" \
  --mode disaster
```

Тот же запуск, если `bootstrap.sh` лежит на GitHub:

```bash
curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/<ref>/bootstrap.sh | sudo bash -s -- \
  --encrypted-bundle-url "https://your-yandex-public-folder-link.example/" \
  --encrypted-bundle-path "/recovery-bundle-latest.tar.gz.gpg" \
  --mode disaster
```

Тестовое восстановление:

```bash
curl -fsSL https://your-domain.example/recovery/bootstrap.sh | sudo bash -s -- \
  --encrypted-bundle-url "https://your-yandex-public-folder-link.example/" \
  --encrypted-bundle-path "/recovery-bundle-latest.tar.gz.gpg" \
  --mode test \
  --test-ip TEST_MACHINE_IP
```

Если не хочешь вводить passphrase руками:

```bash
curl -fsSL https://your-domain.example/recovery/bootstrap.sh | sudo bash -s -- \
  --encrypted-bundle-url "https://your-yandex-public-folder-link.example/" \
  --encrypted-bundle-path "/recovery-bundle-latest.tar.gz.gpg" \
  --mode disaster \
  --bundle-passphrase-file /root/recovery-passphrase.txt
```

### 2. Обычный набор файлов по URL

Аварийное восстановление:

```bash
curl -fsSL https://your-domain.example/recovery/bootstrap.sh | sudo bash -s -- \
  --bundle-url https://your-domain.example/recovery \
  --mode disaster \
  --rclone-conf-url https://your-domain.example/recovery/rclone.conf
```

Тестовое восстановление:

```bash
curl -fsSL https://your-domain.example/recovery/bootstrap.sh | sudo bash -s -- \
  --bundle-url https://your-domain.example/recovery \
  --mode test \
  --test-ip TEST_MACHINE_IP \
  --rclone-conf-url https://your-domain.example/recovery/rclone.conf
```

## Что делает bootstrap.sh

1. Ставит зависимости
2. При необходимости отключает сломанный `NodeSource`, если он мешает `apt update`
3. Либо скачивает recovery-файлы по URL, либо скачивает encrypted bundle
4. Для encrypted bundle:
   - спрашивает passphrase
   - умеет брать файл как по прямой public-ссылке, так и по public-ссылке на папку Яндекса + пути к файлу
   - расшифровывает архив
   - раскладывает recovery-файлы по местам
   - раскладывает bundled legacy libs в `/opt/homeserver-recovery/lib`, если они есть
5. Проверяет `rclone.conf`
6. Записывает `RESTORE_MODE`
7. Для `test` записывает `RESTORE_TEST_TARGET_IP`
8. Запускает `homeserver-bootstrap-restore.sh`

После старта restore-скрипты дополнительно умеют:

- нормализовать `CRLF` в `/etc/homeserver-backup.env`
- отключать сломанный `NodeSource`, если он ломает `apt update`
- создавать `/www/wwwlogs`
- ставить `liblua5.1-0`
- подложить `libssl.so.1.1` и `libcrypto.so.1.1`, если они приехали в bundle
- корректно останавливать и поднимать `x-ui`, `Apache`, `pure-ftpd`, `aaPanel`, `mtg`

## Что bootstrap.sh не делает магически

- не чинит роутер/DMZ
- не возвращает внешний белый IP провайдера
- не угадывает секреты, если у него нет `env`, `rclone.conf` или encrypted bundle

## Что можно держать на GitHub

Можно:

- `bootstrap.sh`
- `build-encrypted-recovery-bundle.sh`
- `WEB_BOOTSTRAP_USAGE.md`
- `AGENT_MANUAL_RECOVERY.md`
- шаблоны и sanitized-примеры без секретов

Нельзя класть в публичный GitHub:

- боевой `homeserver-backup.env`
- боевой `rclone.conf`
- passphrase от encrypted bundle
- любые токены Telegram / SMTP / Yandex OAuth

Сам `recovery-bundle.tar.gz.gpg` технически можно держать публично, если passphrase сильный и хранится отдельно, но для твоего сценария лучше оставлять его на Яндексе.

## Ручной вариант для агента

Если не хочешь использовать encrypted bundle, но готов сам дать агенту доступ к Яндексу и к инструкции, используй:

- [`AGENT_MANUAL_RECOVERY.md`](./AGENT_MANUAL_RECOVERY.md)

Это запасной сценарий:

- без encrypted bundle
- с ручным доступом к Яндексу
- с пошаговой инструкцией для агента
