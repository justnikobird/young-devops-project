#!/bin/bash

# активируем опцию, которая прерывает выполнение скрипта, если любая команда завершается с ненулевым статусом
set -e

# проверим, запущен ли скрипт от пользователя root
if [[ "${UID}" -ne 0 ]]; then
  echo -e "You need to run this script as root!"
  exit 1
fi

# проверим подключен ли репозиторий
if [[ ! $(grep -rhE ^deb /etc/apt/sources.list*) == *"deb https://repo.justnikobird.ru:1111/lab focal main"* ]]; then
  echo -e "Lab repo not connected!\nPlease run vm_start.sh script!\n"
  exit 1
fi

# функция, которая проверяет наличие пакета в системе и в случае его отсутствия выполняет установку
command_check() {
  if ! command -v "$1" &>/dev/null; then
    echo -e "\n====================\n$2 could not be found!\nInstalling...\n====================\n"
    apt-get install -y "$3"
    echo -e "\nDONE\n"
  fi
}

# функция, которая проверяет наличие правила в iptables и в случае отсутствия применяет его
iptables_add() {
  if ! iptables -C "$@" &>/dev/null; then
    iptables -A "$@"
  fi
}

# функция, которая проверяет валидность пути в linux-системе
path_request() {
  while true; do
    read -r -e -p $'\n'"Please input valid path to ${1}: " path
    if [ -f "$path" ]; then
      echo "$path"
      break
    fi
  done
}

# настроим часовой пояс
echo -e "\n====================\nSetting timezone\n===================="
timedatectl set-timezone Europe/Moscow
systemctl restart systemd-timesyncd.service
timedatectl
echo -e "\nDONE\n"

# установим все необходимые пакеты используя функцию command_check
apt-get update
command_check iptables "Iptables" iptables
command_check netfilter-persistent "Netfilter-persistent" iptables-persistent
command_check prometheus "Prometheus" just-prometheus
command_check basename "Basename" coreutils
command_check htpasswd "Htpasswd" apache2-utils

# запросим адрес приватной сети и проверим его на корректность
while true; do
  read -r -p $'\n'"Privat network (format 10.0.0.0/24): " private_net
  if [[ ! $private_net =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\/[0-9]{1,2}$ ]]; then
    echo -e "\nPrefix not valid!\n"
  else
    break
  fi
done

# выполним настройку iptables
echo -e "\n====================\nIptables configuration\n====================\n"
iptables_add INPUT -p tcp --dport 9090 -j ACCEPT -m comment --comment prometheus
iptables_add INPUT -p tcp --dport 9093 -j ACCEPT -m comment --comment prometheus_alertmanager
iptables_add OUTPUT -p tcp --dport 587 -j ACCEPT -m comment --comment smtp
iptables_add OUTPUT -p tcp -d "$private_net" --dport 9100 -j ACCEPT -m comment --comment prometheus_node_exporter
iptables_add OUTPUT -p tcp -d "$private_net" --dport 9176 -j ACCEPT -m comment --comment prometheus_openvpn_exporter
iptables_add OUTPUT -p tcp -d "$private_net" --dport 9113 -j ACCEPT -m comment --comment prometheus_nginx_exporter
echo -e "\n====================\nSaving iptables config\n====================\n"
service netfilter-persistent save
echo -e "\nDONE\n"

# выполним настройку HTTPS
echo -e "\n====================\nHTTPS configuration\n====================\n"

# запросим путь до файла ca-сертификата, перенесем его в рабочую директорию программы и поменяем владельца
ca_cert_path=$(path_request "ca certificate")
cp "$ca_cert_path" /etc/prometheus/ca.crt
chmod 744 /etc/prometheus/ca.crt
chown prometheus:prometheus /etc/prometheus/ca.crt

# запросим путь до файла сертификата, перенесем его в рабочую директорию программы и поменяем владельца
cert_path=$(path_request certificate)
cp "$cert_path" /etc/prometheus/
cert_file=$(basename "$cert_path")
chmod 744 /etc/prometheus/"$cert_file"
chown prometheus:prometheus /etc/prometheus/"$cert_file"

# запросим путь до файла ключа, перенесем его в рабочую директорию программы и поменяем владельца
key_path=$(path_request key)
cp "$key_path" /etc/prometheus/
key_file=$(basename "$key_path")
chmod 744 /etc/prometheus/"$key_file"
chown prometheus:prometheus /etc/prometheus/"$key_file"

# запросим username и password для авторизации в программе
read -r -p $'\n'"Prometheus username: " username
read -r -p $'\n'"Prometheus password: " -s password

# запишем настройки в конфигурационный файл
echo -e "tls_server_config:\n  cert_file: $cert_file\n  key_file: $key_file\n\nbasic_auth_users:\n  $username: '$(htpasswd -nbB -C 10 admin "$password" | grep -o "\$.*")'" >/etc/prometheus/web.yml

# перезагрузим сервисы prometheus и alertmanager
echo -e "\nDONE\n"
systemctl daemon-reload
systemctl restart prometheus.service
systemctl enable prometheus.service
systemctl restart prometheus-alertmanager.service
systemctl enable prometheus-alertmanager.service
echo -e "\nOK\n"
