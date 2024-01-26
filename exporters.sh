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

# функция, которая проверяет корректность введения ip-адреса
ip_request() {
  while true; do
    read -r -p $'\n'"Enter monitov vm ip (format 10.0.0.6): " ip
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
      echo "$ip"
      break
    fi
  done
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

# установим все необходимые пакеты используя функцию command_check
systemctl restart systemd-timesyncd.service
apt-get update
command_check iptables "Iptables" iptables
command_check netfilter-persistent "Netfilter-persistent" iptables-persistent
command_check basename "Basename" coreutils
command_check htpasswd "Htpasswd" apache2-utils

# выведем в shell меню с предложением выбрать экспортер для установки
while true; do
  echo -e "\n--------------------------\n"
  echo -e "[1] node exporter\n"
  echo -e "[2] openvpn exporter\n"
  echo -e "[3] nginx exporter\n"
  echo -e "[4] exit\n"
  echo -e "--------------------------\n"
  read -r -n 1 -p "Select exporter for install: " exporter

  case $exporter in

  # установим node-exporter
  1)
    echo -e "\n====================\nNode Exporter Installing...\n====================\n"

    # установим ранее собранный пакет node-exporter-lab
    apt-get install -y node-exporter-lab

    # запросим пути до файлов сертификата и ключа
    cert_path=$(path_request certificate)
    key_path=$(path_request key)

    # отделим названия файлов от путей
    cert_file=$(basename "$cert_path")
    key_file=$(basename "$key_path")

    # переместим файлы ключа и сертификата в рабочую директорию программы и поменяем права на владение
    cp "$cert_path" /opt/node_exporter/
    cp "$key_path" /opt/node_exporter/
    chmod 744 /opt/node_exporter/"$cert_file"
    chmod 744 /opt/node_exporter/"$key_file"
    chown node_exporter:node_exporter /opt/node_exporter/"$cert_file"
    chown node_exporter:node_exporter /opt/node_exporter/"$key_file"

    # запросим данные для авторизации и запишим их в конфигурационный файл
    read -r -p $'\n'"Node Exporter username: " username
    read -r -p $'\n'"Node Exporter password: " -s password
    echo -e "tls_server_config:\n  cert_file: $cert_file\n  key_file: $key_file\n\nbasic_auth_users:\n  $username: '$(htpasswd -nbB -C 10 admin "$password" | grep -o "\$.*")'" >/opt/node_exporter/web.yml

    # настроим iptables
    echo -e "\n====================\nIptables configuration\n====================\n"
    monitor_vm_ip=$(ip_request)
    iptables_add INPUT -p tcp -s "$monitor_vm_ip" --dport 9100 -j ACCEPT -m comment --comment prometheus_node_exporter
    echo -e "\n====================\nSaving iptables config\n====================\n"
    service netfilter-persistent save
    echo -e "\nDONE\n"

    # перезагрузим node-exporter-сервис
    systemctl daemon-reload
    systemctl restart node_exporter.service
    systemctl enable node_exporter.service

    echo -e "\n====================\nNode Exporter listening on port 9100\n====================\n"
    echo -e "\nOK\n"
    ;;

  2)
    echo -e "\n====================\nOpenvpn Exporter Installing...\n====================\n"

    # установим ранее собранный пакет openvpn-exporter-lab
    apt-get install -y openvpn-exporter-lab

    # настроим iptables
    echo -e "\n====================\nIptables configuration\n====================\n"
    monitor_vm_ip=$(ip_request)
    iptables_add INPUT -p tcp -s "$monitor_vm_ip" --dport 9176 -j ACCEPT -m comment --comment prometheus_openvpn_exporter
    echo -e "\n====================\nSaving iptables config\n====================\n"
    service netfilter-persistent save
    echo -e "\nDONE\n"

    # перезагрузим openvpn-exporter-сервис
    systemctl daemon-reload
    systemctl restart openvpn_exporter.service
    systemctl enable openvpn_exporter.service

    echo -e "\n====================\nOpenvpn Exporter listening on port 9176\n====================\n"
    echo -e "\nOK\n"
    ;;

  3)
    echo -e "\n====================\nConfigure Nginx /stub_status location on 8080 port before install \n====================\n"
    echo -e "\n====================\nNginx Exporter Installing...\n====================\n"

    # установим ранее собранный пакет nginx-exporter-lab
    apt-get install -y nginx-exporter-lab

    # запросим пути до файлов сертификата и ключа
    cert_path=$(path_request certificate)
    key_path=$(path_request key)

    # отделим названия файлов от путей
    cert_file=$(basename "$cert_path")
    key_file=$(basename "$key_path")

    # переместим файлы ключа и сертификата в рабочую директорию программы и поменяем права на владение
    cp "$cert_path" /opt/nginx_exporter/
    cp "$key_path" /opt/nginx_exporter/
    new_cert_path="/opt/nginx_exporter/$cert_file"
    new_key_path="/opt/nginx_exporter/$key_file"
    chmod 744 "$new_cert_path"
    chmod 744 "$new_key_path"
    chown prometheus:prometheus "$new_cert_path"
    chown prometheus:prometheus "$new_key_path"

    # запишим данные о сертификате и ключе в конфигурационный файл
    echo 'ARGS="-web.secured-metrics -web.ssl-server-cert '"$new_cert_path"' -web.ssl-server-key '"$new_key_path"'' >/opt/nginx_exporter/prometheus-nginx-exporter

    # настроим iptables
    echo -e "\n====================\nIptables configuration\n====================\n"
    monitor_vm_ip=$(ip_request)
    iptables_add INPUT -p tcp -s "$monitor_vm_ip" --dport 9113 -j ACCEPT -m comment --comment prometheus_nginx_exporter
    echo -e "\n====================\nSaving iptables config\n====================\n"
    service netfilter-persistent save
    echo -e "\nDONE\n"

    # перезагрузим nginx-exporter-сервис
    systemctl daemon-reload
    systemctl restart prometheus-nginx-exporter.service
    systemctl enable prometheus-nginx-exporter.service

    echo -e "\n====================\nNginx Exporter listening on port 9113\n====================\n"
    echo -e "\nOK\n"
    ;;

  4)
    echo -e "\n\nOK\n"
    exit 0
    ;;

  *)
    echo -e "\n\nUnknown\n"
    ;;
  esac
done
