#!/bin/bash

set -e

if [[ "${UID}" -ne 0 ]]; then
  echo -e "You need to run this script as root!\nPlease apply 'sudo su root' and add your host-key to /root/.ssh/authorized_keys before run this script!"
  exit 1
fi

if [ ! -f /root/.ssh/authorized_keys ]; then
  echo -e "\n====================\nFile /root/.ssh/authorized_keys not found!\n====================\n"
  exit 1
else
  if [ ! -s /root/.ssh/authorized_keys ]; then
    echo -e "\n====================\nFile /root/.ssh/authorized_keys is empty!\n====================\n"
    exit 1
  fi
fi

command_check() {
  if ! command -v "$1" &>/dev/null; then
    echo -e "\n====================\n$2 could not be found!\nInstalling...\n====================\n"
    apt-get install -y "$3"
    echo -e "\nDONE\n"
  fi
}

iptables_add() {
  if ! iptables -C "$1" &>/dev/null; then
    iptables -A "$1"
  fi
}

restore_bkp() {
  if [ -f "$1".bkp ]; then
    if [ -f "$1" ]; then
      rm "$1" && mv "$1".bkp "$1"
    else
      mv "$1".bkp "$1"
    fi
  else
    rm "$1"
  fi
}

bkp() {
  if [ -f "$1" ]; then
    cp "$1" "$1".bkp
  fi
}

apt-get update
command_check wget "Wget" wget
command_check iptables "Iptables" iptables
command_check netfilter-persistent "Netfilter-persistent" iptables-persistent
command_check openssl "Openssl" openssl
command_check update-ca-certificates "Ca-certificates" ca-certificates

if [ ! -f /etc/ssh/sshd_config ]; then
  echo -e "\n====================\nFile /etc/ssh/sshd_config not found!\n====================\n"
  exit 1
fi

if [ ! -f /etc/default/grub ]; then
  echo -e "\n====================\nFile /etc/default/grub not found!\n====================\n"
  exit 1
fi

echo -e "\n====================\nSetting timezone\n===================="
timedatectl set-timezone Europe/Moscow
systemctl restart systemd-timesyncd.service
timedatectl
echo -e "\nDONE\n"

echo -e "\n====================\nNew user config\n===================="

while true; do
  read -r -n 1 -p "Continue or Skip? (c|s) " cs
  case $cs in
  [Cc]*)
    while true; do
      read -r -p $'\n'"new username: " username
      if id "$username" >/dev/null 2>&1; then
        echo -e "\nUser $username exists!\n"
      else
        break
      fi
    done

    read -r -p "new password: " -s password

    useradd -p "$(openssl passwd -1 "$password")" "$username" -s /bin/bash -m -G sudo
    cp -r /root/.ssh/ /home/"$username"/ && chown -R "$username":"$username" /home/"$username"/.ssh/
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

echo -e "\n====================\nRepo config\n===================="

while true; do
  read -r -n 1 -p "Continue or Skip? (c|s) " cs
  echo -e "\n"
  case $cs in
  [Cc]*)
    bkp /etc/apt/sources.list.d/own_repo.list
    bkp /etc/apt/auth.conf

    read -r -p $'\n\n'"login for repo.justnikobird.ru (default nikolay): " repo_login
    read -r -p "password for repo.justnikobird.ru (default Sm1rn0V187187): " -s repo_pass

    if ! grep -Fxq "deb https://repo.justnikobird.ru:1111/lab focal main" /etc/apt/sources.list.d/own_repo.list &>/dev/null; then
      echo "deb https://repo.justnikobird.ru:1111/lab focal main" >>/etc/apt/sources.list.d/own_repo.list
    fi

    if ! grep -Fxq "machine repo.justnikobird.ru:1111" /etc/apt/auth.conf &>/dev/null; then
      echo -e "machine repo.justnikobird.ru:1111\nlogin $repo_login\npassword $repo_pass" >>/etc/apt/auth.conf
    else
      echo -e "\n\nrepo.justnikobird.ru has been configured in /etc/apt/auth.conf!\nPlease manually clean configuration or skip this stage."
      restore_bkp /etc/apt/sources.list.d/own_repo.list
      restore_bkp /etc/apt/auth.conf
      exit 1
    fi

    if ! wget --no-check-certificate -P ~/ https://"$repo_login":"$repo_pass"@repo.justnikobird.ru:1111/lab/labtest.asc; then
      restore_bkp /etc/apt/sources.list.d/own_repo.list
      restore_bkp /etc/apt/auth.conf
      exit 1
    fi
    apt-key add ~/labtest.asc

    if ! wget --no-check-certificate -P /usr/local/share/ca-certificates/ https://"$repo_login":"$repo_pass"@repo.justnikobird.ru:1111/lab/ca.crt; then
      restore_bkp /etc/apt/sources.list.d/own_repo.list
      restore_bkp /etc/apt/auth.conf
      exit 1
    fi
    update-ca-certificates

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

echo -e "\n====================\nIptables config\n===================="
while true; do
  read -r -n 1 -p "Current ssh session may drop! To continue you have to relogin to this host via 1870 ssh-port and run this script again. Are you ready? (y|n) " yn
  case $yn in
  [Yy]*) #---DNS---
    iptables_add 'OUTPUT -p tcp --dport 53 -j ACCEPT -m comment --comment dns'
    iptables_add 'OUTPUT -p udp --dport 53 -j ACCEPT -m comment --comment dns'
    #---NTP---
    iptables_add 'OUTPUT -p udp --dport 123 -j ACCEPT -m comment --comment ntp'
    #---REPO---
    iptables_add 'OUTPUT -p tcp --dport 1111 -j ACCEPT -m comment --comment repo.justnikobird.ru'
    #---ICMP---
    iptables_add 'OUTPUT -p icmp -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT'
    iptables_add 'INPUT -p icmp -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT'
    #---loopback---
    iptables_add 'OUTPUT -o lo -j ACCEPT'
    iptables_add 'INPUT -i lo -j ACCEPT'
    #---Input-SSH---
    iptables_add 'INPUT -p tcp --dport 1870 -j ACCEPT -m comment --comment ssh'
    #---Output-HTTP---
    iptables_add 'OUTPUT -p tcp -m multiport --dports 443,80 -j ACCEPT'
    #---ESTABLISHED---
    iptables_add 'INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT'
    iptables_add 'OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT'
    #---INVALID---
    iptables_add 'OUTPUT -m state --state INVALID -j DROP'
    iptables_add 'INPUT -m state --state INVALID -j DROP'
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
