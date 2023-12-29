#!/bin/bash

set -e

if [[ "${UID}" -ne 0 ]]; then
  echo -e "You need to run this script as root!"
  exit 1
fi

if [[ ! $(grep -rhE ^deb /etc/apt/sources.list*) == *"deb https://repo.justnikobird.ru:1111/lab focal main"* ]]; then
  echo -e "Lab repo not connected!\nPlease run vm_start.sh script!\n"
  exit 1
fi

command_check() {
  if ! command -v "$1" &>/dev/null; then
    echo -e "\n====================\n$2 could not be found!\nInstalling...\n====================\n"
    apt-get install -y "$3"
    echo -e "\nDONE\n"
  fi
}

iptables_add() {
  if ! iptables -C "$@" &>/dev/null; then
    iptables -A "$@"
  fi
}

path_request() {
  while true; do
    read -r -e -p $'\n'"Please input valid path to ${1}: " path
    if [ -f "$path" ]; then
      echo "$path"
      break
    fi
  done
}

systemctl restart systemd-timesyncd.service
apt-get update
command_check iptables "Iptables" iptables
command_check netfilter-persistent "Netfilter-persistent" iptables-persistent
command_check prometheus "Prometheus" just-prometheus
command_check basename "Basename" coreutils
command_check grafana-server "Grafana" grafana-enterprise

echo -e "\n====================\nIptables configuration\n====================\n"
iptables_add INPUT -p tcp --dport 3000 -j ACCEPT -m comment --comment grafana
echo -e "\n====================\nSaving iptables config\n====================\n"
service netfilter-persistent save
echo -e "\nDONE\n"

echo -e "\n====================\nHTTPS configuration\n====================\n"

cert_path=$(path_request certificate)
cp "$cert_path" /etc/grafana/
cert_file=$(basename "$cert_path")
chmod 744 /etc/grafana/"$cert_file"
chown root:grafana /etc/grafana/"$cert_file"

key_path=$(path_request key)
cp "$key_path" /etc/grafana/
key_file=$(basename "$key_path")
chmod 744 /etc/grafana/"$key_file"
chown root:grafana /etc/grafana/"$key_file"

read -r -e -p $'\n'"Please input domain (example: justnikobird.ru): " domain

sed -i 's/^\(protocol\).*$/\1 = https/' /etc/grafana/grafana.ini
sed -i 's/^\;\(domain\).*$/\1 = '"$domain"'/' /etc/grafana/grafana.ini
sed -i 's@^\;\(root_url\).*$@\1 = https://'"$domain"'@' /etc/grafana/grafana.ini
sed -i 's@^\;\(cert_file\).*$@\1 = /etc/grafana/'"$cert_file"'@' /etc/grafana/grafana.ini
sed -i 's@^\;\(cert_key\).*$@\1 = /etc/grafana/'"$key_file"'@' /etc/grafana/grafana.ini

echo -e "\nDONE\n"

systemctl daemon-reload
systemctl restart grafana-server.service
systemctl enable grafana-server.service
echo -e "\nOK\n"
