#!/bin/bash

set -e

if [[ "${UID}" -ne 0 ]]; then
  echo "You need to run this script as root!"
  exit 1
fi

if [[ ! $(grep -rhE ^deb /etc/apt/sources.list*) == *"deb https://repo.justnikobird.ru:1111/lab focal main"* ]]; then
  echo -e "Lab repo not connected!\nPlease run vm_start.sh script!\n"
  exit 1
fi

while true; do
  read -r -e -p $'\n'"Path for easy-rsa location (format: /home/nikolay): " dest_dir
  if [[ "$dest_dir" == */ ]]; then
    echo -e "\nWrong path format!\n"
  else
    if [ ! -d "$dest_dir" ]; then
      echo -e "\nDirectory $dest_dir doesn't exist!\n"
    else
      break
    fi
  fi
done

if [ ! -d /usr/share/easy-rsa/ ]; then
  echo -e "\n====================\nEasy-rsa could not be found\nInstalling...\n====================\n"
  apt-get update
  apt-get install -y easy-rsa just-easy-rsa
  echo -e "\nDONE\n"
else
  while true; do
    read -r -n 1 -p $'\n'"Are you ready to reinstall easy-rsa? (y|n) " yn
    case $yn in
    [Yy]*)
      apt-get remove -y easy-rsa
      apt-get purge -y easy-rsa
      apt-get install -y easy-rsa just-easy-rsa
      echo -e "\nDONE\n"
      break
      ;;
    [Nn]*) exit ;;
    *) echo -e "\nPlease answer Y or N!\n" ;;
    esac
  done
fi

while true; do
  read -r -p $'\n'"Easy-rsa owner user: " username
  if id "$username" >/dev/null 2>&1; then
    mkdir "$dest_dir"/easy-rsa/
    cp -r /usr/share/easy-rsa/* "$dest_dir"/easy-rsa/
    chmod -R 700 "$dest_dir"/easy-rsa/
    chown -R "$username":"$username" "$dest_dir"/easy-rsa/
    break
  else
    echo -e "\nUser $username doesn't exists!\n"
  fi
done

while true; do
  read -r -n 1 -p $'\n'"Are you ready to create pair of CA keys? (y|n) " yn
  case $yn in
  [Yy]*)
    cd "$dest_dir"/easy-rsa
    sudo -u "$username" ./easyrsa build-ca
    echo -e "\nDONE\n"
    break
    ;;
  [Nn]*) exit ;;
  *) echo -e "\nPlease answer Y or N!\n" ;;
  esac
done

echo -e "\nOK\n"
exit 0
