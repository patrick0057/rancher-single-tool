#!/bin/bash
red=$(tput setaf 1)
green=$(tput setaf 2)
reset=$(tput sgr0)
START_TIME=$(date +%Y-%m-%d--%H%M%S)
SCRIPT_NAME="rancher-single-upgrade.sh"
RANCHER_IMAGE_NAME="rancher/rancher"
function helpmenu() {
    echo "Usage: ${SCRIPT_NAME}

-y                          Script will automatically install all dependencies

-f                          Force option will cause script to delete rancher-data container if it exists

-v <new_rancher_version>    This will set the version of Rancher to upgrade to.  If this is left blank the upgrade will fill in your current version automatically.  This is useful for situations where you need to make changes to your Rancher deployment but don't want to upgrade to a newer version.
        Usage Example: ./${SCRIPT_NAME} -v v2.2.3

-d <docker options>         This will pass docker options to the docker run command.  Options must be surrounded by double quotes.  If you pass \"default\" the script will use the options shown in the usage example below.  Do not add \"--volumes-from rancher-data\" in this command, it is always added for you.
        Usage Example: ./${SCRIPT_NAME} -d \"-d --restart=unless-stopped -p 80:80 -p 443:443\"

-r <rancher options>        This will pass rancher options to the rancher container.  Options must be surrounded by double quotes.
        Usage Example: ./${SCRIPT_NAME} -r \"--acme-domain super.secret.rancher.instal.local\"

-s <ssl hostname>           This will renew your SSL certificates with a newly generated set good for 10 years upon upgrade.  When using this command you will also have to apply a kubectl yaml for each preexisting cluster in order for your downstream clusters to be upgraded properly.  You will receive a print out of commands to run on one controlplane node of each cluster attached to your Rancher installation.
        Usage Example: ./${SCRIPT_NAME} -s vps.rancherserver.com
"
    exit 1
}
#TODO
#Add confirmation logic for docker run command
#Add restore task
while getopts "hyfs:d:r:v:" opt; do
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
    s) # process option s: renew SSL for ten years
        REGENERATE_SELF_SIGNED="-v /etc/rancherssl/certs/cert.pem:/etc/rancher/ssl/cert.pem -v /etc/rancherssl/certs/key.pem:/etc/rancher/ssl/key.pem -v /etc/rancherssl/certs/ca.pem:/etc/rancher/ssl/cacerts.pem"
        RANCHER_SSL_HOSTNAME="$OPTARG"
        echo "${green}SSL regenerate has been set, the following options will be added to your docker run command:
        ${red}${REGENERATE_SELF_SIGNED}${reset}"
        echo "${green}SSL hostname set to: ${red}${RANCHER_SSL_HOSTNAME}${reset}"
        ;;
    d) # process option d: set docker options
        if [[ "$OPTARG" == "default" ]]; then
            DOCKER_OPTIONS="-d --restart=unless-stopped -p 80:80 -p 443:443"
        else
            DOCKER_OPTIONS=$OPTARG
        fi
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
if [[ "${FORCE_OPTION}" == 'yes' ]]; then
    docker inspect rancher-data &>/dev/null
    if [[ $? -eq 0 ]]; then
        echo ${red}rancher-data container detected, deleting because option -f was passed.${reset}
        docker rm -f rancher-data
    fi

fi
if [[ "${RANCHER_SSL_HOSTNAME}" != "" ]]; then
    echo "${red}Generating new 10-year SSL certificates for your Rancher installation.${reset}"
    docker run -v /etc/rancherssl/certs:/certs -e CA_SUBJECT="Generic CA" -e CA_EXPIRE="3650" -e SSL_EXPIRE="3650" -e SSL_SUBJECT="${RANCHER_SSL_HOSTNAME}" -e SSL_DNS="${RANCHER_SSL_HOSTNAME}" -e SILENT="true" patrick0057/genericssl
    checkpipecmd "Failed to generate certificates from docker image patrick0057"
fi

docker ps | grep -E "${RANCHER_IMAGE_NAME}:|${RANCHER_IMAGE_NAME} " &>/dev/null
checkpipecmd "Failed to find a running Rancher container with image ${RANCHER_IMAGE_NAME}, aborting script!" 1

RANCHERSERVER=$(docker ps | grep -E "${RANCHER_IMAGE_NAME}:|${RANCHER_IMAGE_NAME} " | awk '{ print $1 }')
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
        echo "${red}${RANCHERSERVER}${green} <- Is this correct?${reset}"
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
docker create --volumes-from ${RANCHERSERVER} --name rancher-data ${RANCHER_IMAGE_NAME}:${CURRENT_RANCHER_VERSION}
checkpipecmd "Error while creating Rancher data container, aborting script!"

RANCHER_BACKUP_ARCHIVE="rancher-data-backup-${CURRENT_RANCHER_VERSION}-${START_TIME}.tar.gz"

echo "${red}Creating archive of rancher-data in working directory, filename: ${green}${RANCHER_BACKUP_ARCHIVE}${reset}"
docker run --volumes-from rancher-data -v $PWD:/backup alpine tar zcvf /backup/${RANCHER_BACKUP_ARCHIVE} /var/lib/rancher >/dev/null
checkpipecmd "Creation of /backup/${RANCHER_BACKUP_ARCHIVE} has failed, aborting script!"

echo "${green}Checking existence of ${RANCHER_BACKUP_ARCHIVE} archive with ls -lash.${reset}"
ls -lash ${RANCHER_BACKUP_ARCHIVE}

echo "${red}Pulling ${RANCHER_IMAGE_NAME}:${NEW_VERSION} before launching the new Rancher container.${reset}"
docker pull ${RANCHER_IMAGE_NAME}:${NEW_VERSION}
checkpipecmd "Image pull for ${RANCHER_IMAGE_NAME}:${NEW_VERSION} has failed, aborting script!"

echo "${red}Launching the new Rancher container.${reset}"
docker run --volumes-from rancher-data ${DOCKER_OPTIONS} ${REGENERATE_SELF_SIGNED} ${RANCHER_IMAGE_NAME}:${NEW_VERSION} ${RANCHER_OPTIONS}
checkpipecmd "Unable to start new Rancher container, aborting script!"
