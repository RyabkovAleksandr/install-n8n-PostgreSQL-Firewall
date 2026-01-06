wget https://raw.githubusercontent.com/RyabkovAleksandr/install-n8n-PostgreSQL-Firewall/main/install-n8n.sh

sed -i 's/\r$//g' install-n8n.sh

bash install-n8n.sh

sudo bash install-n8n.sh --update


#Защита от подбора паролей (Fail2Ban)

sudo apt install fail2ban -y
#автозапуск

sudo systemctl enable fail2ban
sudo systemctl start fail2ban

#проверка В поле Active должно появиться зеленое active (running).

sudo systemctl status fail2ban

#В строке Banned IP list вы увидите список тех, кто заблокирован прямо сейчас.

fail2ban-client status sshd

sudo apt update && sudo apt upgrade -y

#Очистка: После обновления Docker часто оставляет старые «подвешенные» образы, которые занимают место. Их можно удалить командой:

sudo docker image prune -f

#На Ubuntu часто остаются скачанные пакеты, которые больше не нужны. Это освободит около 200-500 МБ:

sudo apt-get clean

sudo apt-get autoremove -y
