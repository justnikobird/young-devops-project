#!/bin/bash

# активируем опцию, которая прерывает выполнение скрипта, если любая команда завершается с ненулевым статусом
set -e

# проверим, запущен ли скрипт от пользователя root
if [[ "${UID}" -ne 0 ]]; then
  echo -e "You need to run this script as root!\nPlease apply 'sudo su root' and add your host-key to /root/.ssh/authorized_keys before run this script!"
  exit 1
fi

# проверим, загружены ли открытые ssh-ключи у пользователя root
if [ ! -f /root/.ssh/authorized_keys ]; then
  echo -e "\n====================\nFile /root/.ssh/authorized_keys not found!\n====================\n"
  exit 1
else
  if [ ! -s /root/.ssh/authorized_keys ]; then
    echo -e "\n====================\nFile /root/.ssh/authorized_keys is empty!\n====================\n"
    exit 1
  fi
fi

# функция, которая проверяет наличие пакета в системе и в случае его отсутствия выполняет установку
command_check() {
  if ! command -v "$1" &>/dev/null; then
    echo -e "\n====================\n$2 could not be found!\nInstalling...\n====================\n"
    apt-get install -y "$3"
    echo -e "\nDONE\n"
  fi
}

# функция, которая запрашивает имя нового пользователя и проверяет его на наличие в системе
username_request() {
  while true; do
    read -r -p $'\n'"new username: " username
    if id "$username" >/dev/null 2>&1; then
      echo -e "\nUser $username exists!\n"
    else
      break
    fi
  done
}

# функция, которая проверяет наличие правила в iptables и в случае отсутствия применяет его
iptables_add() {
  if ! iptables -C "$@" &>/dev/null; then
    iptables -A "$@"
  fi
}

# функция, которая выполняет backup файла путем копирования его и модификации названия
bkp() {
  if [ -f "$1" ]; then
    cp "$1" "$1".bkp
  fi
}

# функция, которая восстанавливает файл из backup
restore_bkp() {
  if [ -f "$1".bkp ]; then
    if [ -f "$1" ]; then
      rm "$1" && mv "$1".bkp "$1"
    else
      mv "$1".bkp "$1"
    fi
  else
    echo -e "\nCan't find backup file!\n"
  fi
}

# настроим часовой пояс
echo -e "\n====================\nSetting timezone\n===================="
timedatectl set-timezone Europe/Moscow
systemctl restart systemd-timesyncd.service
timedatectl
echo -e "\nDONE\n"

# установим все необходимые пакеты используя функцию command_check
apt-get update
command_check wget "Wget" wget
command_check iptables "Iptables" iptables
command_check netfilter-persistent "Netfilter-persistent" iptables-persistent
command_check openssl "Openssl" openssl
command_check update-ca-certificates "Ca-certificates" ca-certificates

# проверим наличие конфигурационного файла ssh
if [ ! -f /etc/ssh/sshd_config ]; then
  echo -e "\n====================\nFile /etc/ssh/sshd_config not found!\n====================\n"
  exit 1
fi

# проверим наличие конфигурационного файла grub
if [ ! -f /etc/default/grub ]; then
  echo -e "\n====================\nFile /etc/default/grub not found!\n====================\n"
  exit 1
fi

# создадим нового пользователя
echo -e "\n====================\nNew user config\n===================="

while true; do
  read -r -n 1 -p "Continue or Skip? (c|s) " cs
  case $cs in
  [Cc]*)
    # запросим имя пользователя используя функцию username_request (функция создаст глобальную переменную "username")
    username_request

    # запросим пароль для нового пользователя
    read -r -p "new password: " -s password

    # создадим нового пользователя и перенесем ssh-ключи
    useradd -p "$(openssl passwd -1 "$password")" "$username" -s /bin/bash -m -G sudo
    cp -r /root/.ssh/ /home/"$username"/ && chown -R "$username":"$username" /home/"$username"/.ssh/
    echo -e "\n\nDONE\n"

    # выполним корректировку prompt statement
    echo -e "\n====================\nEdit prompt statement for this user?\n===================="

    while true; do
      read -r -n 1 -p "Continue or Skip? (c|s) " cs
      case $cs in
      [Cc]*)
        # запросим имя vm
        read -r -p $'\n'"vm name: " vm_name

        # выполним корректировку prompt statement
        echo "PS1='\${debian_chroot:+(\$debian_chroot)}\\u@$vm_name:\\w\\\$ '" >>/home/"$username"/.bashrc

        echo -e "\n\nDONE\n"
        break
        ;;
      [Ss]*)
        echo -e "\n"
        break
        ;;
      *) echo -e "\nPlease answer C or S!\n" ;;
      esac
    done

    break
    ;;
  [Ss]*)
    echo -e "\n"
    break
    ;;
  *) echo -e "\nPlease answer C or S!\n" ;;
  esac
done

# настроим ssh
echo -e "\n====================\nEdit sshd_config file\n===================="

while true; do
  read -r -n 1 -p "Continue or Skip? (c|s) " cs
  case $cs in
  [Cc]*)
    sed -i 's/#\?\(Port\s*\).*$/\1 1870/' /etc/ssh/sshd_config
    sed -i 's/#\?\(PermitRootLogin\s*\).*$/\1 no/' /etc/ssh/sshd_config
    sed -i 's/#\?\(PubkeyAuthentication\s*\).*$/\1 yes/' /etc/ssh/sshd_config
    sed -i 's/#\?\(PermitEmptyPasswords\s*\).*$/\1 no/' /etc/ssh/sshd_config
    sed -i 's/#\?\(PasswordAuthentication\s*\).*$/\1 no/' /etc/ssh/sshd_config
    echo -e "\n\n"
    /etc/init.d/ssh restart
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

# выключим ipv6
echo -e "\n====================\nDisabling ipv6\n===================="

while true; do
  read -r -n 1 -p "Continue or Skip? (c|s) " cs
  case $cs in
  [Cc]*)
    echo -e "\n\n"
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="/&ipv6.disable=1 /' /etc/default/grub
    sed -i 's/^GRUB_CMDLINE_LINUX="/&ipv6.disable=1 /' /etc/default/grub
    update-grub
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

# подключим репозиторий
echo -e "\n====================\nRepo config\n===================="

while true; do
  read -r -n 1 -p "Continue or Skip? (c|s) " cs
  echo -e "\n"
  case $cs in
  [Cc]*)
    # выполним backup файлов с помощью функции bkp
    bkp /etc/apt/sources.list.d/own_repo.list
    bkp /etc/apt/auth.conf

    # запросим логин и пароль для подключения к репозиторию
    read -r -p $'\n\n'"login for repo.justnikobird.ru (default nikolay): " repo_login
    read -r -p "password for repo.justnikobird.ru (default password): " -s repo_pass

    # проверим файл /etc/apt/sources.list.d/own_repo.list на наличие записи о репозитории, и в случае ее отсутствия добавим
    if ! grep -Fxq "deb https://repo.justnikobird.ru:1111/lab focal main" /etc/apt/sources.list.d/own_repo.list &>/dev/null; then
      echo "deb https://repo.justnikobird.ru:1111/lab focal main" >>/etc/apt/sources.list.d/own_repo.list
    fi

    # проверим файл /etc/apt/auth.conf на наличие записей о репозитории, и в случае их отсутствия добавим
    if ! grep -Fxq "machine repo.justnikobird.ru:1111" /etc/apt/auth.conf &>/dev/null; then
      echo -e "machine repo.justnikobird.ru:1111\nlogin $repo_login\npassword $repo_pass" >>/etc/apt/auth.conf
    else
      # если в файле /etc/apt/auth.conf записи обнаружены, то попросим пользователя удалить их
      echo -e "\n\nrepo.justnikobird.ru has been configured in /etc/apt/auth.conf!\nPlease manually clean configuration or skip this stage."
      restore_bkp /etc/apt/sources.list.d/own_repo.list
      restore_bkp /etc/apt/auth.conf
      exit 1
    fi

    # скачаем и установим gpg-ключ от репозитория
    if ! wget --no-check-certificate -P ~/ https://"$repo_login":"$repo_pass"@repo.justnikobird.ru:1111/lab/labtest.asc; then
      restore_bkp /etc/apt/sources.list.d/own_repo.list
      restore_bkp /etc/apt/auth.conf
      exit 1
    else
      apt-key add ~/labtest.asc
    fi

    # скачаем и установим открытый ключ ca-сертификата от репозитория
    if ! wget --no-check-certificate -P /usr/local/share/ca-certificates/ https://"$repo_login":"$repo_pass"@repo.justnikobird.ru:1111/lab/ca.crt; then
      restore_bkp /etc/apt/sources.list.d/own_repo.list
      restore_bkp /etc/apt/auth.conf
      exit 1
    else
      update-ca-certificates
    fi

    # выполним синхронизацию списков пакетов в системе
    if ! apt update; then
      restore_bkp /etc/apt/sources.list.d/own_repo.list
      restore_bkp /etc/apt/auth.conf
      exit 1
    fi
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

# настроим iptables
echo -e "\n====================\nIptables config\n===================="
while true; do
  read -r -n 1 -p "Current ssh session may drop! To continue you have to relogin to this host via 1870 ssh-port and run this script again. Are you ready? (y|n) " yn
  case $yn in
  [Yy]*) #---DNS---
    iptables_add OUTPUT -p tcp --dport 53 -j ACCEPT -m comment --comment dns
    iptables_add OUTPUT -p udp --dport 53 -j ACCEPT -m comment --comment dns
    #---NTP---
    iptables_add OUTPUT -p udp --dport 123 -j ACCEPT -m comment --comment ntp
    #---REPO---
    iptables_add OUTPUT -p tcp --dport 1111 -j ACCEPT -m comment --comment repo.justnikobird.ru
    #---ICMP---
    iptables_add OUTPUT -p icmp -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT
    iptables_add INPUT -p icmp -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT
    #---loopback---
    iptables_add OUTPUT -o lo -j ACCEPT
    iptables_add INPUT -i lo -j ACCEPT
    #---Input-SSH---
    iptables_add INPUT -p tcp --dport 1870 -j ACCEPT -m comment --comment ssh
    #---Output-HTTP---
    iptables_add OUTPUT -p tcp -m multiport --dports 443,80 -j ACCEPT
    #---ESTABLISHED---
    iptables_add INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables_add OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    #---INVALID---
    iptables_add OUTPUT -m state --state INVALID -j DROP
    iptables_add INPUT -m state --state INVALID -j DROP
    #---Defaul-Drop---
    iptables -P OUTPUT DROP
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    # save iptables config
    echo -e "\n====================\nSaving iptables config\n====================\n"
    service netfilter-persistent save
    echo -e "DONE\n"
    break
    ;;
  [Nn]*)
    echo -e "\n"
    exit
    ;;
  *) echo -e "\nPlease answer Y or N!\n" ;;
  esac
done

echo -e "\nOK\n"
exit 0
