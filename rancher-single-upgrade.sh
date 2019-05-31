#!/bin/bash
red=$(tput setaf 1)
green=$(tput setaf 2)
reset=$(tput sgr0)
START_TIME=$(date +%Y-%m-%d--%H%M%S)
SCRIPT_NAME="rancher-single-upgrade.sh"
function helpmenu() {
    echo "Usage: ./checkfix-certs.sh [-y]
-y  Script will automatically install all dependencies
-f  Force option will cause script to delete rancher-data container if it exists
-v <new_rancher_version>  This will set the version of Rancher to upgrade to.
    If this is left blank the upgrade will fill in your current version automatically.
    This is useful for situations where you need to make changes to your Rancher
    deployment but don't want to upgrade to a newer version.
        Usage Example: ./${SCRIPT_NAME} -v v2.2.3
-d <docker options>  This will pass docker options to the docker run command. 
    Options must be surrounded by double quotes.
        Usage Example: ./${SCRIPT_NAME} -d \"-d --restart=unless-stopped -p 80:80 -p 443:443\"
-r <rancher options>  This will pass rancher options to the rancher container.
    Options must be surrounded by double quotes.
        Usage Example: ./${SCRIPT_NAME} -r \"--acme-domain super.secret.rancher.instal.local\"
"
    exit 1
}
#TODO
#Add SSL regenerate section, in order to prevent duplication of work I will create a CFSSL script that can be called for this.
#Add confirmation logic for docker run command
while getopts "hyfd:r:v:" opt; do
    case ${opt} in
    h) # process option h
        helpmenu
        ;;
    y) # process option y: auto install dependencies
        INSTALL_MISSING_DEPENDENCIES=yes
        ;;
    v) # process option v: set version
        NEW_VERSION=$OPTARG
        echo "${green}New Rancher version set to: ${red}${NEW_VERSION}${reset}"
        ;;
    d) # process option d: set docker options
        DOCKER_OPTIONS=$OPTARG
        echo "${green}Docker options set to: ${red}${DOCKER_OPTIONS}${reset}"
        ;;
    r) # process option r: set docker options
        RANCHER_OPTIONS=$OPTARG
        echo "${green}Rancher options set to: ${red}${RANCHER_OPTIONS}${reset}"
        ;;
    f) # process option f: force install, in this case means delete rancher-data if it exists
        FORCE_OPTION=yes
        echo "${green}Force option has been set, the script will delete rancher-data container if it exists.${reset}"
        ;;
    \?)
        helpmenu
        exit 1
        ;;
    esac
done
function yesno() {
    shopt -s nocasematch
    response=''
    i=0
    while [[ ${response} != 'y' ]] && [[ ${response} != 'n' ]]; do
        i=$((i + 1))
        if [ $i -gt 10 ]; then
            echo "Script is destined to loop forever, aborting!  Make sure your docker run command has -ti then try again."
            exit 1
        fi
        printf '(y/n): '
        read -n1 response
        echo
    done
    shopt -u nocasematch
}
function checkpipecmd() {
    RC=("${PIPESTATUS[@]}")
    if [[ "$2" != "" ]]; then
        PIPEINDEX=$2
    else
        PIPEINDEX=0
    fi
    if [ "${RC[${PIPEINDEX}]}" != "0" ]; then
        echo "${green}$1${reset}"
        exit 1
    fi
}
#pre-flight checks
if [[ ${FORCE_OPTION} == 'yes' ]]; then
    docker inspect rancher-data &>/dev/null
    if [[ $? -eq 0 ]]; then
        echo ${red}rancher-data container detected, deleting because option -f was passed.${reset}
        docker rm -f rancher-data
    fi

fi

docker ps | grep -E "rancher/rancher:|rancher/rancher " &>/dev/null
checkpipecmd "Failed to find a running Rancher container with image rancher/rancher, aborting script!" 1

RANCHERSERVER=$(docker ps | grep -E "rancher/rancher:|rancher/rancher " | awk '{ print $1 }')
echo "${green}Providing full output of 'docker ps' for reference.${reset}"
docker ps
echo
echo "${red}${RANCHERSERVER} ${green}<- Is this the Rancher server container that we are upgrading?${reset}"
echo "${green}$(docker ps | grep ${RANCHERSERVER})${reset}"
yesno
if [ ${response} == 'y' ]; then
    echo
    echo
    echo "${green}Great, moving on to the next part of the script.${reset}"
else
    RANCHERSERVER=''
    response=''
    while [[ ${response} == 'n' ]] || [[ ${response} == '' ]]; do
        echo
        docker ps
        echo
        echo "${green}No problem, please select your rancher server ID from the above output.${reset}"
        read RANCHERSERVER
        echo "${red}${RANCHERSERVER} ${green}<- Is this correct?${reset}"
        yesno
        echo
    done
fi
echo "${green}Your Rancher server container ID is: ${red}${RANCHERSERVER}${reset}"

CURRENT_RANCHER_VERSION="$(docker exec -ti ${RANCHERSERVER} rancher -v)"
checkpipecmd "Unable to exec into ${RANCHERSERVER}, aborting script!"

CURRENT_RANCHER_VERSION=$(sed -r 's,^.*version (\w),\1,g' <<<${CURRENT_RANCHER_VERSION%$'\r'})

#turn off case matching
shopt -s nocasematch
if [[ "$CURRENT_RANCHER_VERSION" == *"rancher"* ]]; then
    echo "${green}Unable to detect current Rancher version, aborting script!${reset}"
    exit 1
fi
#turn on case matching
shopt -u nocasematch

echo "${green}Your current Rancher server version is ${CURRENT_RANCHER_VERSION}${reset}"
#if we didn't pass -v, then set the version to current version.
if [[ ${NEW_VERSION} == '' ]]; then
    echo "${green}New Rancher version not specified, setting it to your current Rancher version: ${red}${CURRENT_RANCHER_VERSION}${reset}"
    NEW_VERSION=${CURRENT_RANCHER_VERSION}
fi

echo "${red}Stopping Rancher container ${RANCHERSERVER}${reset}"
docker stop ${RANCHERSERVER}
checkpipecmd "Error while stopping Rancher container, aborting script!"

echo "${red}Creating rancher-data container${reset}"
docker create --volumes-from ${RANCHERSERVER} --name rancher-data rancher/rancher:${CURRENT_RANCHER_VERSION}
checkpipecmd "Error while creating Rancher data container, aborting script!"

echo "${red}Creating archive of rancher-data in working directory, filename: ${green}rancher-data-backup-${CURRENT_RANCHER_VERSION}-${START_TIME}.tar.gz${reset}"
docker run --volumes-from rancher-data -v $PWD:/backup alpine tar zcvf /backup/rancher-data-backup-${CURRENT_RANCHER_VERSION}-${START_TIME}.tar.gz /var/lib/rancher >/dev/null
checkpipecmd "Creation of /backup/rancher-data-backup-${CURRENT_RANCHER_VERSION}-${START_TIME}.tar.gz has failed, aborting script!"

echo "${green}Checking existence of tar.gz archive with ls.${reset}"
ls -lash rancher-data-backup-${CURRENT_RANCHER_VERSION}-${START_TIME}.tar.gz

echo "${red}Pulling rancher/rancher:${NEW_VERSION} before launching the new Rancher container.${reset}"
docker pull rancher/rancher:${NEW_VERSION}
checkpipecmd "Image pull for rancher/rancher:${NEW_VERSION} has failed, aborting script!"

echo "${red}Launching the new Rancher container.${reset}"
docker run ${DOCKER_OPTIONS} ${REGENERATE_SELF_SIGNED} rancher/rancher:${NEW_VERSION} ${RANCHER_OPTIONS}
checkpipecmd "Unable to start new Rancher container, aborting script!"
