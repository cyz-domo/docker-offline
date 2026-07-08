#!/bin/bash
# Release date: 2023-04-04

# x86_64

echo "What version of Docker do you want to install or upgrade?
"
docker_pkg=( 
  "docker-18.09.9"
  "docker-19.03.15"
  "docker-20.10.24"
  "docker-23.0.6"
  "docker-24.0.6"
  "docker-29.6.1"
) 

select var in ${docker_pkg[@]} 
do
  if [ $var = "docker-18.09.9" ]; then
    echo -e "Your select is $var \n"
    docker_pkg="docker-18.09.9.tgz"
    break
  elif [ $var = 'docker-19.03.15' ]; then
    docker_pkg="docker-19.03.15.tgz"
    break
  elif [ $var = 'docker-20.10.24' ]; then
    docker_pkg="docker-20.10.24.tgz"
    break
  elif [ $var = 'docker-23.0.6' ]; then
    docker_pkg="docker-23.0.6.tgz"
    break
  elif [ $var = 'docker-24.0.6' ]; then
    docker_pkg="docker-24.0.6.tgz"
    break
  elif [ $var = 'docker-29.6.1' ]; then
    docker_pkg="docker-29.6.1.tgz"
    break
  else
    echo "End the install or upgrade task !"
    break
  fi
done

cur_time=$(date "+%Y%m%d%H%M%S")

# check the runtime user permission
echo -e "--->Permission checking ! \n"
if [ $UID -ne 0 ]; then
    echo -e "Please run this script by root user! \n"
    exit 1
else
    echo -e "The current environment is root privilege.\n"
fi

#Print the kernel version and os version
cat /etc/os-release
uname -a

#Get the script path
echo -e "--->Print the script path\n"
DIR_PATH="$( cd "$( dirname "$0"  )" && pwd  )"
echo -e ${DIR_PATH}"\n"

#Check if docker is installed
echo -e "--->Check if docker is installed (rpm install) \n"
if [ -f "/usr/bin/docker" ] || [ -f "/usr/local/bin/docker" ]; then
    echo -e "The docker is installed !\n"
    rpm -ql docker-ce
    whereis docker
    docker -v
fi

if [ -f "/usr/bin/docker-compose" ] || [ -f "/usr/local/bin/docker-compose" ]; then
    echo -e "The docker-compose is installed ! \n"
    file "/usr/bin/docker-compose"
    file "/usr/local/bin/docker-compose"
fi

read -r -p "Are you sure continue to upgrade the docker version? [Y/n] " input
case $input in
[yY][eE][sS]|[yY])

################################
echo "Starting install docker..."
#Backup old docker programe
if [ -f "/usr/bin/docker" ] || [ -f "/usr/local/bin/docker" ]; then
    echo "The docker-ce is installed. \n"
    rpm -ql docker-ce
    echo -e "Start to back the old docker data"
    
    ##### docker-18.06.3-ce added #####
    #docker
    mv -vf "/usr/bin/docker" "/usr/bin/docker.bk."${cur_time}
    mv -vf "/usr/local/bin/docker" "/usr/local/bin/docker.bk."${cur_time}
    #docker-init
    mv -vf "/usr/bin/docker-init" "/usr/bin/docker-init.bk."${cur_time}
    mv -vf "/usr/local/bin/docker-init" "/usr/local/bin/docker-init.bk."${cur_time}
    #docker-proxy
    mv -vf "/usr/bin/docker-proxy" "/usr/bin/docker-proxy.bk."${cur_time}
    mv -vf "/usr/local/bin/docker-proxy" "/usr/local/bin/docker-proxy.bk."${cur_time}
    #dockerd
    mv -vf "/usr/bin/dockerd"  "/usr/bin/dockerd.bk."${cur_time}
    mv -vf "/usr/local/bin/dockerd"  "/usr/local/bin/dockerd.bk."${cur_time}
    #dockerd-runc
    mv -vf "/usr/bin/docker-runc"  "/usr/bin/docker-runc.bk."${cur_time}
    mv -vf "/usr/local/bin/docker-runc"  "/usr/local/bin/docker-runc.bk."${cur_time}
    #docker-containerd
    mv -vf "/usr/bin/docker-containerd"  "/usr/bin/docker-containerd.bk."${cur_time}
    mv -vf "/usr/local/bin/docker-containerd"  "/usr/local/bin/docker-containerd.bk."${cur_time}
    #docker-containerd-shim
    mv -vf "/usr/bin/docker-containerd-shim"  "/usr/bin/docker-containerd-shim.bk."${cur_time}
    mv -vf "/usr/local/bin/docker-containerd-shim"  "/usr/local/bin/docker-containerd-shim.bk."${cur_time}
    #docker-containerd-ctr
    mv -vf "/usr/bin/docker-containerd-ctr"  "/usr/bin/docker-containerd-ctr.bk."${cur_time}
    mv -vf "/usr/local/bin/docker-containerd-ctr"  "/usr/local/bin/docker-containerd-ctr.bk."${cur_time}

    ##### docker-18.09.9 and docker-19.03.15 added ####
    #containerd
    mv -vf "/usr/bin/containerd"  "/usr/bin/containerd.bk."${cur_time}
    mv -vf "/usr/local/bin/containerd"  "/usr/local/bin/containerd.bk."${cur_time}
    #containerd-shim
    mv -vf "/usr/bin/containerd-shim"  "/usr/bin/containerd-shim.bk."${cur_time}
    mv -vf "/usr/local/bin/containerd-shim"  "/usr/local/bin/containerd-shim.bk."${cur_time}
    #ctr
    mv -vf "/usr/bin/ctr"  "/usr/bin/ctr.bk."${cur_time}
    mv -vf "/usr/local/bin/ctr"  "/usr/local/bin/ctr.bk."${cur_time}
    #runc
    mv -vf "/usr/bin/runc"  "/usr/bin/runc.bk."${cur_time}
    mv -vf "/usr/local/bin/runc"  "/usr/local/bin/runc.bk."${cur_time}

    ##### docker-20.10.8 added ####
    #containerd-shim-runc-v2
    mv -vf "/usr/bin/containerd-shim-runc-v2"  "/usr/bin/containerd-shim-runc-v2.bk."${cur_time}
    mv -vf "/usr/local/bin/containerd-shim-runc-v2"  "/usr/local/bin/containerd-shim-runc-v2.bk."${cur_time} 
    
    #systemd service configuration
    mv -vf "/usr/lib/systemd/system/docker.service" "/usr/lib/systemd/system/docker.service.bk."${cur_time}
    mv -vf "/usr/lib/systemd/system/docker.socket" "/usr/lib/systemd/system/docker.socket.bk."${cur_time}
    mv -vf "/etc/systemd/system/docker.service" "/etc/systemd/system/docker.service.bk."${cur_time}

    #containerd configuration
    mv -vf "/etc/containerd/config.toml" "/etc/containerd/config.toml.bk."${cur_time}

    #docker-compose
    if [ -f "/usr/bin/docker-compose" ] || [ -f "/usr/local/bin/docker-compose" ]; then
        echo "The docker-ce is installed. \n"
        echo -e "Start to back the old docker-compose program."
        mv -vf "/usr/bin/docker-compose" "/usr/bin/docker-compose.bk."${cur_time}
        mv -vf "/usr/local/bin/docker-compose" "/usr/local/bin/docker-compose.bk."${cur_time}  
    fi 
fi 

#Install the docker-compose
echo -e "--->Install the docker-compose \n"
cp -vf ${DIR_PATH}"/packages/docker-ce/docker-compose-Linux-x86_64" "/usr/bin/docker-compose"
chmod 755 "/usr/bin/docker-compose"

#Uncompress the Docker 
echo -e "--->Uncompress the Docker \n"
tar -zxvf ${DIR_PATH}"/packages/docker-ce/"${docker_pkg} -C ${DIR_PATH}"/packages/docker-ce"

#Install the Docker
echo -e "--->Install the Docker \n"
cp -fv ${DIR_PATH}/packages/docker-ce/docker/* "/usr/bin/"

#Configure the systemd service configuration
echo -e "--->Configure the systemd service configuration \n"
cp -fv ${DIR_PATH}"/config/docker.service" "/etc/systemd/system/"
cp -fv ${DIR_PATH}"/config/containerd.service" "/lib/systemd/system/containerd.service"

#Start the docker service 
echo -e "--->start the docker service  \n"
systemctl daemon-reload
systemctl start docker.service
systemctl enable docker.service

echo "Do you want disbale containerd CRI plugin ？（port: 10010）?
"
cri_option=( 
  "Enable_CRI"
  "Disable_CRI"
) 

select var in ${cri_option[@]} 
do
  if [ $var = "Enable_CRI" ]; then
    echo -e "Your select is $var \n"
    cri="enable"
    break
  elif [ $var = 'Disable_CRI' ]; then
    cri="disable"
    break
  else
    echo "error cri option!"
    break
  fi
done

if [[ ${cri} == "disable" ]];then
  #Disbale CRI plugins (This plugin will listen on port 10010 by default)
  echo -e "--->Disbale CRI plugins (This plugin will listen on port 10010 by default) \n"
  mkdir -p "/etc/containerd"
  cp -fv ${DIR_PATH}"/config/config.toml" "/etc/containerd/"
fi
#start the docker service 
echo -e "--->Restart the docker service  \n"
systemctl daemon-reload
systemctl restart containerd.service
systemctl restart docker.service
systemctl enable docker.service

#Check the docker and docker-compose version and status
echo -e "--->Check the docker and docker-compose version and status  \n"
docker -v
docker-compose -v
containerd -v
runc -v
systemctl status docker
####################

;;

[nN][oO]|[nN])
echo "No"
exit 1
;;

*)
echo "Invalid input..."
exit 1
;;
esac
