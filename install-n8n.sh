```bash
#!/bin/bash

# Скрипт для развертывания n8n на Ubuntu 24.04 VPS c PostgreSQL, Traefik, UFW и Fail2Ban
# Автор: Viacheslav Lykov (модифицировано)
# Telegram: https://t.me/JumbleAI
# Youtube: https://www.youtube.com/@ViacheslavLykov

set -e

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

PROJECT_DIR="n8n-compose"
DOMAIN=""
MAIN_DOMAIN=""
SUBDOMAIN=""
SSL_EMAIL=""
ORIGINAL_DIR=""

print_header() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}================================${NC}"
}
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_error()   { echo -e "${RED}✗ $1${NC}"; }
print_info()    { echo -e "${BLUE}ℹ $1${NC}"; }

# Проверка версии Ubuntu (только 24.04)
check_ubuntu_version() {
    print_header "Проверка версии Ubuntu"
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [ "$VERSION_ID" = "24.04" ]; then
            print_success "Обнаружена поддерживаемая версия Ubuntu $VERSION_ID LTS"
        else
            print_error "Поддерживается только Ubuntu 24.04 LTS. Обнаружено: $VERSION_ID"
            exit 1
        fi
    else
        print_error "Не удалось определить версию Ubuntu"
        exit 1
    fi
}

# Установка и проверка Docker
install_docker_engine() {
    print_info "Обновление пакетов..."
    apt update && apt upgrade -y
    print_info "Установка необходимых пакетов..."
    apt install -y apt-transport-https ca-certificates curl gnupg lsb-release
    print_info "Добавление ключа Docker..."
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    print_info "Добавление репозитория Docker..."
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    print_info "Установка Docker Engine..."
    apt update
    apt install -y docker-ce docker-ce-cli containerd.io
    print_info "Запуск Docker..."
    systemctl start docker
    systemctl enable docker
    print_success "Docker успешно установлен"
}

install_docker_compose() {
    print_info "Установка Docker Compose v2..."
    apt install -y docker-compose-plugin
    print_success "Docker Compose успешно установлен"
}

install_docker() {
    print_header "Проверка и установка Docker"
    if command -v docker &>/dev/null; then
        DOCKER_VERSION=$(docker --version | cut -d' ' -f3 | cut -d',' -f1)
        print_success "Docker уже установлен: $DOCKER_VERSION"
        if docker compose version &>/dev/null || docker-compose version &>/dev/null; then
            if docker compose version &>/dev/null; then
                COMPOSE_VERSION=$(docker compose version | cut -d' ' -f4)
                print_success "Docker Compose v2 уже установлен: $COMPOSE_VERSION"
            else
                COMPOSE_VERSION=$(docker-compose version | cut -d' ' -f3)
                print_warning "Обнаружена Docker Compose v1: $COMPOSE_VERSION"
                print_info "Рекомендуется обновить до Docker Compose v2"
            fi
        else
            print_warning "Docker Compose не найден, устанавливаем..."
            install_docker_compose
        fi
    else
        print_warning "Docker не найден, устанавливаем..."
        install_docker_engine
        install_docker_compose
    fi
}

# Настройка SSH порта на 2222
configure_ssh_port() {
    print_header "Настройка SSH порта (2222)"
    if ! grep -qE "^Port 2222" /etc/ssh/sshd_config; then
        sed -i 's/^#\?Port .*/Port 2222/' /etc/ssh/sshd_config
        print_info "Порт SSH изменен на 2222"
    else
        print_info "Порт SSH уже установлен на 2222"
    fi
    # Перезагрузка службы SSH (учет имен ssh/sshd)
    if systemctl reload ssh 2>/dev/null; then
        print_success "SSH перезагружен (ssh)"
    elif systemctl reload sshd 2>/dev/null; then
        print_success "SSH перезагружен (sshd)"
    elif systemctl restart ssh 2>/dev/null; then
        print_success "SSH перезапущен (ssh)"
    elif systemctl restart sshd 2>/dev/null; then
        print_success "SSH перезапущен (sshd)"
    else
        print_warning "Не удалось автоматически перезапустить ssh/sshd. Сделайте это вручную: systemctl restart ssh"
    fi
    print_warning "Не закрывайте текущую сессию, пока не убедитесь, что вход по порту 2222 работает."
}

# Настройка UFW
setup_firewall() {
    print_header "Настройка UFW"
    apt install -y ufw
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 2222/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 5670/tcp
    ufw --force enable
    print_success "UFW настроен и включен (22 закрыт, открыт 2222/80/443/5670)"
}

# Настройка Fail2Ban (порты 2222, 5670)
setup_fail2ban() {
    print_header "Установка и настройка Fail2Ban"
    apt install -y fail2ban
    cat >/etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 10m
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled  = true
port     = 2222
logpath  = %(sshd_log)s
maxretry = 5

[postgresql]
enabled  = true
port     = 5670
filter   = postgresql
logpath  = /var/log/postgresql/postgresql-*.log
maxretry = 5
EOF
    systemctl enable fail2ban
    systemctl restart fail2ban
    print_success "Fail2Ban настроен (порты 2222 и 5670)"
}

# Проверка существующих контейнеров
check_existing_containers() {
    print_header "Проверка существующих контейнеров n8n"
    if docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" | grep -q n8n; then
        print_warning "Обнаружены существующие контейнеры n8n:"
        docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" | grep n8n
        read -p "Хотите остановить и удалить существующие контейнеры? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            docker stop $(docker ps -aq --filter "name=n8n") 2>/dev/null || true
            docker rm $(docker ps -aq --filter "name=n8n") 2>/dev/null || true
            print_success "Существующие контейнеры удалены"
        fi
    else
        print_success "Существующие контейнеры n8n не найдены"
    fi

    if docker volume ls | grep -q n8n; then
        print_warning "Обнаружены существующие volumes n8n:"
        docker volume ls | grep n8n
        read -p "Хотите сохранить существующие volumes? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            docker volume rm $(docker volume ls -q | grep n8n) 2>/dev/null || true
            print_success "Volumes удалены"
        fi
    else
        print_success "Volumes n8n не найдены"
    fi

    if [ -d "$PROJECT_DIR" ] && [ -f "$PROJECT_DIR/letsencrypt/acme.json" ]; then
        print_warning "Обнаружены SSL сертификаты в $PROJECT_DIR/letsencrypt/"
        read -p "Хотите сохранить существующие сертификаты? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$PROJECT_DIR/letsencrypt"
            print_success "Существующие сертификаты удалены"
        else
            print_info "Сертификаты будут сохранены"
        fi
    fi
}

# Настройка домена и SSL
setup_domain_ssl() {
    print_header "Настройка домена и SSL"
    read -p "Введите ваш домен (например: n8n.example.com): " DOMAIN
    if [ -z "$DOMAIN" ]; then
        print_error "Домен не может быть пустым"
        exit 1
    fi
    if [[ ! $DOMAIN =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        print_error "Неверный формат домена: $DOMAIN"
        exit 1
    fi
    read -p "Введите email для Let's Encrypt сертификата: " SSL_EMAIL
    if [ -z "$SSL_EMAIL" ]; then
        print_error "Email не может быть пустым"
        exit 1
    fi
    if [[ ! $SSL_EMAIL =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        print_error "Неверный формат email: $SSL_EMAIL"
        exit 1
    fi
    print_success "Домен: $DOMAIN"
    print_success "Email: $SSL_EMAIL"
    if [[ $DOMAIN =~ ^([^.]+)\.(.*)$ ]]; then
        SUBDOMAIN="${BASH_REMATCH[1]}"
        MAIN_DOMAIN="${BASH_REMATCH[2]}"
    else
        SUBDOMAIN="n8n"
        MAIN_DOMAIN="$DOMAIN"
    fi
    print_info "Субдомен: $SUBDOMAIN"
    print_info "Основной домен: $MAIN_DOMAIN"
}

# Создание конфигурационных файлов
create_config_files() {
    print_header "Создание конфигурационных файлов"
    if [ -d "$PROJECT_DIR" ]; then
        print_warning "Директория $PROJECT_DIR уже существует"
        read -p "Хотите перезаписать файлы? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Пропускаем создание файлов"
            return
        fi
    else
        mkdir -p "$PROJECT_DIR"
    fi

    cd "$PROJECT_DIR"

    # .env
    cat > .env <<EOF
# Домены
DOMAIN_NAME=$MAIN_DOMAIN
SUBDOMAIN=$SUBDOMAIN
SSL_EMAIL=$SSL_EMAIL

# Часовой пояс
GENERIC_TIMEZONE=Europe/Moscow

# PostgreSQL настройки
DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=postgres
DB_POSTGRESDB_PORT=5670
DB_POSTGRESDB_DATABASE=n8n
DB_POSTGRESDB_USER=n8n
DB_POSTGRESDB_PASSWORD=$(openssl rand -hex 16)
EOF
    print_success ".env создан"

    # docker-compose.yml
    cat > docker-compose.yml <<'EOF'
name: n8n
services:
  traefik:
    image: "traefik"
    restart: always
    command:
      - "--api.insecure=true"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.web.http.redirections.entryPoint.to=websecure"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesresolvers.mytlschallenge.acme.tlschallenge=true"
      - "--certificatesresolvers.mytlschallenge.acme.email=${SSL_EMAIL}"
      - "--certificatesresolvers.mytlschallenge.acme.storage=/letsencrypt/acme.json"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - traefik_data:/letsencrypt
      - /var/run/docker.sock:/var/run/docker.sock:ro
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.traefik.rule=Host(`traefik.${DOMAIN_NAME}`)"
      - "traefik.http.routers.traefik.entrypoints=websecure"
      - "traefik.http.routers.traefik.tls.certresolver=mytlschallenge"
      - "traefik.http.routers.traefik.service=api@internal"
      - "traefik.http.middlewares.traefik.headers.SSLRedirect=true"

  n8n:
    image: docker.n8n.io/n8nio/n8n:latest
    restart: always
    ports:
      - "127.0.0.1:5678:5678"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(`${SUBDOMAIN}.${DOMAIN_NAME}`)"
      - "traefik.http.routers.n8n.tls=true"
      - "traefik.http.routers.n8n.entrypoints=web,websecure"
      - "traefik.http.routers.n8n.tls.certresolver=mytlschallenge"
      - "traefik.http.middlewares.n8n.headers.SSLRedirect=true"
      - "traefik.http.middlewares.n8n.headers.STSSeconds=315360000"
      - "traefik.http.middlewares.n8n.headers.browserXSSFilter=true"
      - "traefik.http.middlewares.n8n.headers.contentTypeNosniff=true"
      - "traefik.http.middlewares.n8n.headers.forceSTSHeader=true"
      - "traefik.http.middlewares.n8n.headers.SSLHost=${DOMAIN_NAME}"
      - "traefik.http.middlewares.n8n.headers.STSIncludeSubdomains=true"
      - "traefik.http.middlewares.n8n.headers.STSPreload=true"
      - "traefik.http.routers.n8n.middlewares=n8n@docker"
    environment:
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
      - N8N_HOST=${SUBDOMAIN}.${DOMAIN_NAME}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - N8N_RUNNERS_ENABLED=true
      - NODE_ENV=production
      - WEBHOOK_URL=https://${SUBDOMAIN}.${DOMAIN_NAME}/
      - GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
      - TZ=${GENERIC_TIMEZONE}
      - DB_TYPE=${DB_TYPE}
      - DB_POSTGRESDB_HOST=${DB_POSTGRESDB_HOST}
      - DB_POSTGRESDB_PORT=${DB_POSTGRESDB_PORT}
      - DB_POSTGRESDB_DATABASE=${DB_POSTGRESDB_DATABASE}
      - DB_POSTGRESDB_USER=${DB_POSTGRESDB_USER}
      - DB_POSTGRESDB_PASSWORD=${DB_POSTGRESDB_PASSWORD}
    volumes:
      - n8n_data:/home/node/.n8n
      - ./local-files:/files
    depends_on:
      - postgres

  postgres:
    image: postgres:15
    restart: always
    command: -p 5670
    environment:
      - POSTGRES_DB=${DB_POSTGRESDB_DATABASE}
      - POSTGRES_USER=${DB_POSTGRESDB_USER}
      - POSTGRES_PASSWORD=${DB_POSTGRESDB_PASSWORD}
    ports:
      - "5670:5670"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    labels:
      - "traefik.enable=false"

volumes:
  n8n_data:
  traefik_data:
  postgres_data:
EOF

    mkdir -p local-files

    if docker compose config --quiet 2>/dev/null; then
        print_success "Синтаксис docker-compose.yml корректен"
    else
        print_warning "Проверьте docker-compose.yml на ошибки"
    fi

    cd "$ORIGINAL_DIR" || print_warning "Не удалось вернуться в исходную директорию"
}

check_config_files() {
    print_info "Проверка конфигурационных файлов..."
    if [ ! -f "docker-compose.yml" ]; then
        print_error "Файл docker-compose.yml не найден"
        return 1
    fi
    if ! docker compose config --quiet 2>/dev/null; then
        print_error "Ошибка в синтаксисе docker-compose.yml"
        return 1
    else
        print_success "docker-compose.yml корректен"
    fi
    if [ ! -f ".env" ]; then
        print_error "Файл .env не найден"
        return 1
    fi
    print_success "Все конфигурационные файлы корректны"
    return 0
}

start_services() {
    print_header "Запуск сервисов n8n"
    if [ ! -d "$PROJECT_DIR" ]; then
        print_error "Директория $PROJECT_DIR не найдена"
        exit 1
    fi
    cd "$PROJECT_DIR"
    if ! check_config_files; then
        exit 1
    fi
    print_info "Запуск Docker Compose..."
    docker compose up -d
    print_info "Ожидание запуска сервисов..."
    sleep 12
    if docker compose ps | grep -q "Up"; then
        print_success "Сервисы успешно запущены!"
        EXTERNAL_IP=$(curl -s ifconfig.me 2>/dev/null || echo "не удалось определить")
        print_header "Информация о развертывании"
        echo -e "${GREEN}✓ n8n: https://${SUBDOMAIN}.${MAIN_DOMAIN}${NC}"
        echo -e "${GREEN}✓ Traefik dashboard: https://traefik.${MAIN_DOMAIN}${NC}"
        echo -e "${BLUE}ℹ Внешний IP: $EXTERNAL_IP${NC}"
        echo -e "${YELLOW}⚠ Убедитесь, что DNS записи указывают на этот IP${NC}"
    else
        print_error "Ошибка запуска сервисов"
        docker compose logs
        exit 1
    fi
    cd "$ORIGINAL_DIR" || true
}

setup_autostart() {
    print_header "Настройка автозапуска"
    cat > /etc/systemd/system/n8n.service <<EOF
[Unit]
Description=n8n Workflow Automation
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$ORIGINAL_DIR/$PROJECT_DIR
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable n8n
    if systemctl start n8n 2>/dev/null; then
        print_success "Сервис n8n запущен"
    else
        print_warning "Не удалось запустить сервис n8n. Проверьте: journalctl -u n8n -e"
    fi
    print_success "Автозапуск настроен"
}

main() {
    if [ "$EUID" -ne 0 ]; then
        print_error "Запустите скрипт с правами root (sudo)"
        exit 1
    fi

    print_header "Установка n8n на Ubuntu 24.04 (PostgreSQL, Traefik, UFW, Fail2Ban)"
    ORIGINAL_DIR=$(pwd)

    check_ubuntu_version
    configure_ssh_port
    setup_firewall
    setup_fail2ban
    install_docker
    check_existing_containers
    setup_domain_ssl
    create_config_files
    start_services
    setup_autostart

    print_header "Установка завершена!"
    print_success "n8n успешно развернут на вашем сервере"
    print_info "Не забудьте настроить DNS записи для домена"
    print_info "Логи: 'docker compose logs -f' в директории $PROJECT_DIR"
}

case "${1:-}" in
    --help|-h)
        echo "Скрипт для развертывания n8n на Ubuntu 24.04 LTS"
        echo "Опции:"
        echo "  --help, -h      Показать помощь"
        echo "  --version, -v   Показать версию"
        echo "  --update        Обновить n8n"
        echo "  --stop          Остановить n8n"
        echo "  --restart       Перезапустить n8n"
        echo "  --check         Проверить конфигурацию"
        exit 0
        ;;
    --version|-v)
        echo "n8n Installation Script v1.1.1 (Ubuntu 24.04 only, PostgreSQL)"
        exit 0
        ;;
    --update)
        print_header "Обновление n8n"
        ORIGINAL_DIR=$(pwd)
        if [ -d "n8n-compose" ]; then
            cd n8n-compose
            if [ ! -f "docker-compose.yml" ]; then
                print_error "docker-compose.yml не найден в n8n-compose"
                exit 1
            fi
            docker compose pull
            docker compose up -d
            print_success "n8n обновлен"
        else
            print_error "Директория n8n-compose не найдена"
            exit 1
        fi
        cd "$ORIGINAL_DIR" 2>/dev/null || true
        exit 0
        ;;
    --stop)
        print_header "Остановка n8n"
        ORIGINAL_DIR=$(pwd)
        if [ -d "n8n-compose" ]; then
            cd n8n-compose
            if [ ! -f "docker-compose.yml" ]; then
                print_error "docker-compose.yml не найден в n8n-compose"
                exit 1
            fi
            docker compose down
            print_success "n8n остановлен"
        else
            print_error "Директория n8n-compose не найдена"
            exit 1
        fi
        cd "$ORIGINAL_DIR" 2>/dev/null || true
        exit 0
        ;;
    --restart)
        print_header "Перезапуск n8n"
        ORIGINAL_DIR=$(pwd)
        if [ -d "n8n-compose" ]; then
            cd n8n-compose
            if [ ! -f "docker-compose.yml" ]; then
                print_error "docker-compose.yml не найден в n8n-compose"
                exit 1
            fi
            docker compose restart
            print_success "n8n перезапущен"
        else
            print_error "Директория n8n-compose не найдена"
            exit 1
        fi
        cd "$ORIGINAL_DIR" 2>/dev/null || true
        exit 0
        ;;
    --check)
        print_header "Проверка конфигурации"
        ORIGINAL_DIR=$(pwd)
        if [ -d "n8n-compose" ]; then
            cd n8n-compose
            if check_config_files; then
                print_success "Конфигурация корректна"
            else
                print_error "Найдены ошибки"
                exit 1
            fi
        else
            print_error "Директория n8n-compose не найдена"
            exit 1
        fi
        cd "$ORIGINAL_DIR" 2>/dev/null || true
        exit 0
        ;;
    *)
        main
        ;;
esac
```
