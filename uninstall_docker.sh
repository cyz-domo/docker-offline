#!/bin/bash
# Release date: 2023-04-04
# 

read -r -p "Do you want to uninstall docker? [Y/n] " input
case $input in
[yY][eE][sS]|[yY])
# Stop docker
systemctl stop docker.service
systemctl stop containerd.service
#/usr/bin/*
rm -fv /usr/bin/containerd
rm -fv /usr/bin/containerd-shim
rm -fv /usr/bin/containerd-shim-runc-v2
rm -fv /usr/bin/ctr
rm -fv /usr/bin/docker
rm -fv /usr/bin/docker-init
rm -fv /usr/bin/docker-proxy
rm -fv /usr/bin/dockerd
rm -fv /usr/bin/runc
rm -fv /usr/bin/docker-compose
#/usr/local/bin/*
rm -fv /usr/local/bin/containerd
rm -fv /usr/local/bin/containerd-shim
rm -fv /usr/local/bin/containerd-shim-runc-v2
rm -fv /usr/local/bin/ctr
rm -fv /usr/local/bin/docker
rm -fv /usr/locsl/bin/docker-init
rm -fv /usr/local/bin/docker-proxy
rm -fv /usr/local/bin/dockerd
rm -fv /usr/local/bin/runc
rm -fv /usr/local/bin/docker-compose
#configuration
rm -fv /etc/systemd/system/docker.service
cp -fv /etc/docker/daemon.json{,.delete}
rm -fv /etc/docker/daemon.json
cp -fv /etc/containerd/config.toml{,.delete}
rm -fv /etc/containerd/config.toml
systemctl daemon-reload
;;
[nN][oO]|[nN])
echo -e "Exit this script \n"
;;
*)
echo "Invalid input..."
;;
esac

echo  -e "Done ！ 
\n Tips: This script do not delete the docker's root data directory.
\n Example: /var/lib/docker or /data/docker-data
\n copy /etc/docker/daemon.json  to /etc/docker/daemon.json.delete
\n"
