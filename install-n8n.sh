#!/bin/bash

# Скрипт для развертывания n8n с PostgreSQL, защитой Fail2Ban и UFW
# Автор: Модифицировано для комплексной безопасности
# Поддерживает Ubuntu 20.04, 22.04, 24.04 LTS

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Глобальные переменные
PROJECT_DIR="n8n-compose"
DOMAIN=""
MAIN_DOMAIN=""
SUBDOMAIN=""
SSL_EMAIL=""
ORIGINAL_DIR=$(pwd)
DB_PASSWORD=$(openssl rand -base64 15)

print_header() { echo -e "${BLUE}================================\n$1\n================================${NC}"; }
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ $1${NC}"; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "Этот скрипт должен быть запущен от имени root (sudo)"
        exit 1
    fi
}

setup_security() {
    print_header "Настройка сетевой безопасности (UFW & SSH)"

    # Изменение порта SSH
    print_info "Перенастройка SSH на порт 2222..."
    sed -i 's/^#Port 22/Port 2222/' /etc/ssh/sshd_config
    sed -i 's/^Port 22/Port 2222/' /etc/ssh/sshd_config
    
    # Настройка UFW
    print_info "Настройка фаервола UFW..."
    apt update && apt install -y ufw
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 2222/tcp comment 'SSH Custom Port'
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    ufw allow 5432/tcp comment 'PostgreSQL Internal'
    
    # Включаем UFW (force исключает запрос на подтверждение)
    echo "y" | ufw enable
    print_success "UFW активен: порты 2222, 80, 443, 5432 открыты."

    # Установка и настройка Fail2Ban
    print_header "Настройка Fail2Ban"
    apt install -y fail2ban
    
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port    = 2222

[n8n-auth]
enabled = true
port    = 80,443,5670
filter  = sshd
logpath = /var/log/auth.log
EOF
    
    systemctl restart fail2ban
    systemctl enable fail2ban
    print_success "Fail2Ban настроен для мониторинга портов 2222, 80, 443, 5670"
}

install_docker() {
    print_header "Установка Docker"
    if ! command -v docker &> /dev/null; then
        apt install -y apt-transport-https ca-certificates curl gnupg lsb-release
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt update && apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        systemctl start docker && systemctl enable docker
        print_success "Docker установлен"
    else
        print_success "Docker уже на борту"
    fi
}

setup_domain_ssl() {
    print_header "Настройка домена"
    read -p "Введите домен (n8n.example.com): " DOMAIN
    read -p "Введите email для SSL: " SSL_EMAIL

    if [[ $DOMAIN =~ ^([^.]+)\.(.*)$ ]]; then
        SUBDOMAIN="${BASH_REMATCH[1]}"
        MAIN_DOMAIN="${BASH_REMATCH[2]}"
    else
        print_error "Ошибка формата домена"; exit 1
    fi
}

create_config_files() {
    print_header "Создание конфигурации n8n + PostgreSQL"
    mkdir -p "$PROJECT_DIR/local-files"
    cd "$PROJECT_DIR"

    # Создание .env
    cat > .env << EOF
DOMAIN_NAME=$MAIN_DOMAIN
SUBDOMAIN=$SUBDOMAIN
SSL_EMAIL=$SSL_EMAIL
GENERIC_TIMEZONE=Europe/Moscow

# DB Config
DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=postgres
DB_POSTGRESDB_PORT=5432
DB_POSTGRESDB_DATABASE=n8n
DB_POSTGRESDB_USER=n8n_user
DB_POSTGRESDB_PASSWORD=$DB_PASSWORD
EOF

    # Создание docker-compose.yml
    cat > docker-compose.yml << 'EOF'
name: n8n-stack
services:
  traefik:
    image: traefik:v3.0
    restart: always
    command:
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

  postgres:
    image: postgres:15-alpine
    restart: always
    environment:
      - POSTGRES_DB=${DB_POSTGRESDB_DATABASE}
      - POSTGRES_USER=${DB_POSTGRESDB_USER}
      - POSTGRES_PASSWORD=${DB_POSTGRESDB_PASSWORD}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_POSTGRESDB_USER} -d ${DB_POSTGRESDB_DATABASE}"]
      interval: 5s
      timeout: 5s
      retries: 5

  n8n:
    image: docker.n8n.io/n8nio/n8n:latest
    restart: always
    depends_on:
      postgres:
        condition: service_healthy
    ports:
      - "127.0.0.1:5670:5670"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(`${SUBDOMAIN}.${DOMAIN_NAME}`)"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls.certresolver=mytlschallenge"
      - "traefik.http.services.n8n.loadbalancer.server.port=5670"
    environment:
      - N8N_HOST=${SUBDOMAIN}.${DOMAIN_NAME}
      - N8N_PORT=5670
      - N8N_PROTOCOL=https
      - NODE_ENV=production
      - WEBHOOK_URL=https://${SUBDOMAIN}.${DOMAIN_NAME}/
      - DB_TYPE=${DB_TYPE}
      - DB_POSTGRESDB_HOST=${DB_POSTGRESDB_HOST}
      - DB_POSTGRESDB_PORT=${DB_POSTGRESDB_PORT}
      - DB_POSTGRESDB_DATABASE=${DB_POSTGRESDB_DATABASE}
      - DB_POSTGRESDB_USER=${DB_POSTGRESDB_USER}
      - DB_POSTGRESDB_PASSWORD=${DB_POSTGRESDB_PASSWORD}
    volumes:
      - n8n_data:/home/node/.n8n
      - ./local-files:/files

volumes:
  traefik_data:
  n8n_data:
  postgres_data:
EOF
}

start_services() {
    print_header "Запуск n8n"
    docker compose up -d
    print_success "Система запущена на порту 5670 (внутренний) и доступна через 443 (внешний)"
    print_info "Пароль БД сохранен в .env файле"
}

main() {
    check_root
    setup_security
    install_docker
    setup_domain_ssl
    create_config_files
    start_services
    
    print_header "Установка завершена!"
    echo -e "${YELLOW}ВАЖНО:${NC}"
    echo -e "1. SSH теперь работает на порту ${GREEN}2222${NC}"
    echo -e "2. Доступ к n8n: ${GREEN}https://$SUBDOMAIN.$MAIN_DOMAIN${NC}"
    echo -e "3. Fail2Ban и UFW активны."
    print_warning "Перезапустите SSH сервис или сервер, чтобы убедиться в применении настроек порта 2222."
}

# Обработка команд
case "${1:-}" in
    --stop)
        cd "$PROJECT_DIR" && docker compose down
        ;;
    --update)
        cd "$PROJECT_DIR" && docker compose pull && docker compose up -d
        ;;
    *)
        main
        ;;
esac
