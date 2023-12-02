#!/bin/bash

set -e

if [[ "${UID}" -ne 0 ]]; then
  echo "You need to run this script as root!"
  exit 1
fi

command_check() {
  if ! command -v "$1" &>/dev/null; then
    echo -e "\n====================\n$2 could not be found!\nInstalling...\n====================\n"
    apt-get install -y "$3"
    echo -e "\nDONE\n"
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

iptables_add() {
  if ! iptables -C "$@" &>/dev/null; then
    iptables -A "$@"
  fi
}

systemctl restart systemd-timesyncd.service
apt-get update
command_check wget "Wget" wget
command_check iptables "Iptables" iptables
command_check netfilter-persistent "Netfilter-persistent" iptables-persistent
command_check rngd "Rng-tools" rng-tools
command_check nginx "Nginx" nginx
command_check htpasswd "Htpasswd" apache2-utils
command_check basename "Basename" coreutils


echo -e "\n====================\nAptly Configuration...\n====================\n"
wget -P /tmp/ https://github.com/aptly-dev/aptly/releases/download/v1.5.0/aptly_1.5.0_linux_amd64.tar.gz
tar xvf /tmp/aptly_1.5.0_linux_amd64.tar.gz
mv /tmp/aptly_1.5.0_linux_amd64/aptly /usr/local/bin/
echo '{
  "rootDir": "/opt/aptly",
  "downloadConcurrency": 4,
  "downloadSpeedLimit": 0,
  "architectures": [],
  "dependencyFollowSuggests": false,
  "dependencyFollowRecommends": false,
  "dependencyFollowAllVariants": false,
  "dependencyFollowSource": false,
  "dependencyVerboseResolve": false,
  "gpgDisableSign": false,
  "gpgDisableVerify": false,
  "gpgProvider": "gpg",
  "downloadSourcePackages": true,
  "skipLegacyPool": true,
  "ppaDistributorID": "ubuntu",
  "ppaCodename": "",
  "FileSystemPublishEndpoints": {
    "lab": {
      "rootDir": "/var/www/aptly",
      "linkMethod": "symlink",
      "verifyMethod": "md5"
    }
  },
  "enableMetricsEndpoint": false
}' > /etc/aptly.conf

aptly repo create -comment="lab repo" -component="main" -distribution="focal" lab

package_path=$(path_request "first package")
aptly repo add lab "$package_path"

rngd -r /dev/urandom
gpg --default-new-key-algo rsa4096 --gen-key --keyring pubring
gpg --list-keys

aptly publish repo lab filesystem:lab:lab

gpg --export --armor > /var/www/aptly/lab/pubtest.asc

ca_crt=$(path_request "ca certificate")
cp "$ca_crt" /var/www/aptly/lab/

echo -e "\n====================\nNginx Configuration...\n====================\n"

read -r -p $'\n'"repo domain name (default repo.justnikobird.ru): " repo_name

server_crt=$(path_request certificate)
cp "$server_crt" /etc/nginx/
cert_file=$(basename "$server_crt")

server_key=$(path_request key)
cp "$server_key" /etc/nginx/
key_file=$(basename "$server_key")

read -r -p $'\n\n'"login for ${repo_name} (default nikolay): " repo_login
read -r -p "password for ${repo_name} (default Sm1rn0V187187): " -s repo_pass

htpasswd -nbB -C 10 "$repo_login" "$repo_pass" >> /etc/nginx/conf.d/.htpasswd

echo '
server {
        listen 1111 ssl default_server;
        server_name '"$repo_name"';
        auth_basic              "Restricted Access!";
        auth_basic_user_file    /etc/nginx/conf.d/.htpasswd;
        ssl_certificate     '"$cert_file"';
        ssl_certificate_key '"$key_file"';
        ssl_protocols       TLSv1 TLSv1.1 TLSv1.2 TLSv1.3;
        ssl_ciphers         HIGH:!aNULL:!MD5;

        root /var/www/aptly;

        location / {
                autoindex on;
        }
}

#nginx prometheus exporter
server {
        listen 8080;

        location /stub_status {
                stub_status;
                allow 127.0.0.1;
                deny all;
        }
}'

echo -e "\n====================\nIptables configuration\n====================\n"
iptables_add INPUT -p tcp --dport 1111 -j ACCEPT -m comment --comment repo_nginx
echo -e "\n====================\nSaving iptables config\n====================\n"
service netfilter-persistent save
echo -e "\nDONE\n"

systemctl restart nginx.service
systemctl enable nginx.service

echo -e "\n====================\nRepo listening on port 1111\n====================\n"
echo -e "\nOK\n"


