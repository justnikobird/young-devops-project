#!/bin/bash

# активируем опцию, которая прерывает выполнение скрипта, если любая команда завершается с ненулевым статусом
set -e

# проверим, запущен ли скрипт от пользователя root
if [[ "${UID}" -ne 0 ]]; then
  echo "You need to run this script as root!"
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

# функция, которая проверяет наличие nat-правила в iptables и в случае отсутствия применяет его
iptables_nat_add() {
  if ! iptables -t nat -C "$@" &>/dev/null; then
    iptables -t nat -A "$@"
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

# выполним настройке OpenVPN
echo -e "\n====================\nOpenVPN server config\n===================="

while true; do
  read -r -n 1 -p "Continue or Skip? (c|s) " cs
  case $cs in
  [Cc]*)

    # установим все необходимые пакеты используя функцию command_check
    systemctl restart systemd-timesyncd.service
    apt-get update
    command_check openvpn "Openvpn" openvpn-lab
    command_check iptables "Iptables" iptables
    command_check netfilter-persistent "Netfilter-persistent" iptables-persistent
    command_check basename "Basename" coreutils

    # проверим наличие файла /etc/sysctl.conf в системе
    if [ ! -f /etc/sysctl.conf ]; then
      echo "File /etc/sysctl.conf not found!"
      exit 1
    fi

    # запросим путь до файла сертификата и перенесем его в рабочую директорию программы
    server_crt=$(path_request certificate)
    cp "$server_crt" /etc/openvpn/server/
    server_crt_file=$(basename "$server_crt")

    # запросим путь до файла ключа и перенесем его в рабочую директорию программы
    server_key=$(path_request key)
    cp "$server_key" /etc/openvpn/server/
    server_key_file=$(basename "$server_key")

    # запросим путь до файла ca-сертификата и перенесем его в рабочую директорию программы
    ca_crt=$(path_request "ca certificate")
    cp "$ca_crt" /etc/openvpn/server/
    cp "$ca_crt" /etc/openvpn/clients_config/keys/
    ca_crt_file=$(basename "$ca_crt")

    cd /etc/openvpn/server/

    # сгенерируем ключ для tls-crypt
    openvpn --genkey --secret ta.key | tee /etc/openvpn/server/ta.key >/dev/null
    cp /etc/openvpn/server/ta.key /etc/openvpn/clients_config/keys/
    echo -e "\n====================\nTls-crypt-key generated /etc/openvpn/server/ta.key\n====================\n"

    # внесем изменения в конфигурационный файл open-vpn
    sed -r -i 's/(^ca\s).*$/\1'"$ca_crt_file"'/' /etc/openvpn/server/server.conf
    sed -r -i 's/(^cert\s).*$/\1'"$server_crt_file"'/' /etc/openvpn/server/server.conf
    sed -r -i 's/(^key\s).*$/\1'"$server_key_file"'/' /etc/openvpn/server/server.conf

    # активируем функцию маршрутизации
    echo -e "\n====================\nIp forward configing\n====================\n"
    sed -i 's/#\?\(net.ipv4.ip_forward=1\s*\).*$/\1/' /etc/sysctl.conf
    sysctl -p
    echo -e "\nDONE\n"

    # cоздадим группу nobody для корректной работы vpn-сервиса
    if ! grep -q "nobody" /etc/group; then
      groupadd nobody
      echo -e "\n====================\nNobody group created\n====================\n"
    fi

    # выполним настройку openvpn
    echo -e "\n====================\nOpenVPN configuration\n====================\n"

    while true; do
      # выведем запрос для выбора транспорта для vpn (udp или tcp)
      read -r -n 3 -p $'\n'"OpenVPN protocol (tcp|udp) (default udp): " proto
      case $proto in
      tcp)
        # в случае выбора tcp внесем настройки в конфигурационные файлы openvpn
        sed -i 's/\(^proto\sudp$\)/\;\1/' /etc/openvpn/server/server.conf
        sed -i 's/^\;\(proto\stcp$\)/\1/' /etc/openvpn/server/server.conf
        sed -i 's/\(^proto\sudp$\)/\;\1/' /etc/openvpn/clients_config/confiles/base.conf
        sed -i 's/^\;\(proto\stcp$\)/\1/' /etc/openvpn/clients_config/confiles/base.conf
        sed -i 's/(^explicit-exit-notify\s1$\)/\;\1/' /etc/openvpn/server/server.conf
        break
        ;;
      udp)
        # в случае выбора udp вносить изменения не нужно, так как udp настроен по умолчанию
        break
        ;;
      *) echo -e "\nPlease answer tcp or udp!\n" ;;
      esac
    done

    # запросим у оператора ввести порт, через который будет работать openvpn
    while true; do
      read -r -n 4 -p $'\n'"OpenVPN port number (default 1194): " port
      re='^[0-9]+$'
      if ! [[ $port =~ $re ]]; then
        echo "error: Not a number" >&2
        exit 1
      else
        if [ "$port" == 1194 ]; then
          break
        else
          # в случае если порт отличается от 1194, внесем изменения в конфигурационный файл
          sed -r -i 's/(^port\s).*$/\1'"$port"'/' /etc/openvpn/server/server.conf
          sed -r -i 's/(^port\s).*$/\1'"$port"'/' /etc/openvpn/clients_config/confiles/base.conf
          break
        fi
      fi
    done

    echo -e "\n"
    ip a
    echo -e "\n"

    # запросим hostname или ip openvpn сервера и занесем в конфигурационный файл
    read -r -p $'\n'"The hostname or IP of the server: " host
    sed -r -i 's/(^remote\s).*$/\1'"$host"' '"$port"'/' /etc/openvpn/clients_config/confiles/base.conf

    echo -e "\n====================\nIptables configuration\n====================\n"

    # запросим имя vpn-интерфейса для настройки iptables
    while true; do
      read -r -p $'\n'"VPN interface name: " eth
      if ! ip a | grep -q "$eth"; then
        echo -e "\nWrong interface name!\n"
      else
        break
      fi
    done

    # выполним настройку iptables
    # OpenVPN
    iptables_add INPUT -i "$eth" -m state --state NEW -p "$proto" --dport "$port" -j ACCEPT -m comment --comment openvpn
    # Allow TUN interfaces connections to OpenVPN server
    iptables_add INPUT -i tun+ -j ACCEPT -m comment --comment openvpn
    # Allow TUN interfaces connections to be forwarded through interfaces
    iptables_add FORWARD -i tun+ -j ACCEPT -m comment --comment openvpn
    iptables_add FORWARD -i tun+ -o "$eth" -m state --state RELATED,ESTABLISHED -j ACCEPT -m comment --comment openvpn
    iptables_add FORWARD -i "$eth" -o tun+ -m state --state RELATED,ESTABLISHED -j ACCEPT -m comment --comment openvpn
    # NAT the VPN client traffic to the interface
    iptables_nat_add POSTROUTING -s 10.8.0.0/24 -o "$eth" -j MASQUERADE -m comment --comment openvpn
    echo -e "\n====================\nSaving iptables config\n====================\n"
    service netfilter-persistent save
    echo -e "\nDONE\n"

    # перезагрузим сервис openvpn
    echo -e "\n====================\nRestarting Open-VPN service...\n====================\n"
    systemctl restart openvpn-server@server.service
    systemctl enable openvpn-server@server.service
    echo -e "\nDONE\n"
    break
    ;;
  [Ss]*)
    echo -e "\n"
    break
    ;;
  *) echo -e "\nPlease answer C or S!\n" ;;
  esac
done

# выполним настройку клиентского конфигурационного файла
echo -e "\n====================\nCreate OpenVPN client config-file\n===================="

while true; do
  read -r -n 1 -p "Continue or Skip? (c|s) " cs
  case $cs in
  [Cc]*)
    # запросим клиентский сертификат и перенесем в рабочую директорию программы
    client_crt=$(path_request "client certificate")
    cp "$client_crt" /etc/openvpn/clients_config/keys/
    client_crt_file=$(basename "$client_crt")

    # запросим клиентский ключ и перенесем в рабочую директорию программы
    client_key=$(path_request "client key")
    cp "$client_key" /etc/openvpn/clients_config/keys/
    client_key_file=$(basename "$client_key")

    # запустим скрипт для генерации клиентского конфигурационного файла
    read -r -p $'\n'"Client name: " client_name
    if /etc/openvpn/clients_config/make_config.sh "$client_crt_file" "$client_key_file" "$client_name"; then
      echo -e "\nDONE!\n\nCheck file /etc/openvpn/clients_config/${client_name}.ovpn"
    fi
    break
    ;;

  [Ss]*)
    echo -e "\n"
    break
    ;;
  *) echo -e "\nPlease answer C or S!\n" ;;
  esac
done

echo -e "\nOK\n"
exit 0
