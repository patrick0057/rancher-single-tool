#!/bin/bash
if hash tput 2>/dev/null; then
    red=$(tput setaf 1)
    green=$(tput setaf 2)
    reset=$(tput sgr0)
fi
function grecho() {
    echo "${green}$1${reset}"
}
function recho() {
    echo "${red}$1${reset}"
}
START_TIME=$(date +%Y-%m-%d--%H%M%S)
SCRIPT_NAME="rancher-single-tool.sh"
RANCHER_IMAGE_NAME="rancher/rancher"
LOGFILE="${SCRIPT_NAME}-${START_TIME}.log"
function helpmenu() {
    grecho "Usage: ${SCRIPT_NAME}

-y                          Script will automatically install all dependencies.  (Optional)

-f                          Force option will cause script to not prompt you for questions.  (Optional)

-e                          Delete rancher-data instead of renaming it to rancher-data.date--time.  (Optional)

-x                          Delete old Rancher container after a restore.  (Optional)

-c <containerID>            Set the Rancher container ID that you want to work with.  (Optional)
        Usage Example: bash ${SCRIPT_NAME} -t'install'

-t <task>                   Set the task you wish to perform: install, upgrade or restore.  (Optional)
        Usage Example: bash ${SCRIPT_NAME} -t'install'

-b <backup file>            Set the backup file you wish to restore from.
        Usage Example: bash ${SCRIPT_NAME} -b'/root/rancher-data-backup-v2.1.3-2019-06-07--201957.tar.gz'

-v <new_rancher_version>    This will set the version of Rancher to upgrade to.  If this is left blank the upgrade will fill in your current version automatically.  This is useful for situations where you need to make changes to your Rancher deployment but don't want to upgrade to a newer version.
        Usage Example: bash ${SCRIPT_NAME} -v v2.2.3

-d <docker options>         This will pass docker options to the docker run command.  Options must be surrounded by double quotes.  If you pass \"default\" the script will use the options shown in the usage example below.  Do not add \"--volumes-from rancher-data\" in this command, it is always added for you.
        Usage Example: bash ${SCRIPT_NAME} -d \"-d --restart=unless-stopped -p 80:80 -p 443:443\"

-r <rancher options>        This will pass rancher options to the rancher container.  Options must be surrounded by double quotes.
        Usage Example: bash ${SCRIPT_NAME} -r \"--acme-domain super.secret.rancher.instal.local\"
        Usage Example: bash ${SCRIPT_NAME} -r \"--no-cacerts\"

-s <ssl hostname>           This will renew your SSL certificates with a newly generated set good for 10 years upon upgrade.  When using this command you will also have to apply a kubectl yaml for each preexisting cluster in order for your downstream clusters to be upgraded properly.  You will receive a print out of commands to run on one controlplane node of each cluster attached to your Rancher installation.
        Usage Example: bash ${SCRIPT_NAME} -s vps.rancherserver.com
"
    exit 1
}
#TODO
#Add confirmation logic for docker run command
while getopts "hyfxc:b:t:s:d:r:v:" opt; do
    case ${opt} in
    h) # process option h
        helpmenu
        ;;
    y) # process option y: auto install dependencies
        INSTALL_MISSING_DEPENDENCIES=yes
        ;;
    v) # process option v: set version
        NEW_VERSION=$OPTARG
        grecho "New Rancher version set to: ${red}${NEW_VERSION}"
        ;;
    t) # process option t: set task
        TASK=$OPTARG
        ;;
    x) # process option x: delete restore container
        DELETE_RESTORE_CONTAINER="yes"
        ;;
    c) # process option c: set container ID
        RANCHERSERVER=$OPTARG
        if [[ "${RANCHERSERVER}" == "" ]]; then
            grecho "Option -c was passed but no container ID was specified."
            exit 1
        fi
        ;;
    e) # process option e: erase/delete rancher-data
        DELETE_RANCHER_DATA="yes"
        ;;

    b) # process option b: set backup file
        BACKUPFILEPATH=$OPTARG
        if [[ ! -f "${BACKUPFILEPATH}" ]]; then
            grecho "Backup file ${BACKUPFILEPATH} does not exist, aborting script."
            exit 1
        else
            grecho "Found ${BACKUPFILEPATH}, script will proceed."
        fi
        ;;
    s) # process option s: renew SSL for ten years
        SSLVOLUMES="-v /etc/rancherssl/certs/cert.pem:/etc/rancher/ssl/cert.pem -v /etc/rancherssl/certs/key.pem:/etc/rancher/ssl/key.pem -v /etc/rancherssl/certs/ca.pem:/etc/rancher/ssl/cacerts.pem"
        RANCHER_SSL_HOSTNAME="$OPTARG"
        grecho "SSL regenerate has been set, the following options will be added to your docker run command:
        ${red}${SSLVOLUMES}"
        grecho "SSL hostname set to: ${red}${RANCHER_SSL_HOSTNAME}"
        ;;
    d) # process option d: set docker options
        if [[ "$OPTARG" == "default" ]]; then
            DOCKER_OPTIONS="-d --restart=unless-stopped -p 80:80 -p 443:443"
        else
            DOCKER_OPTIONS=$OPTARG
        fi
        grecho "Docker options set to: ${red}${DOCKER_OPTIONS}${reset}"
        ;;
    r) # process option r: set docker options
        RANCHER_OPTIONS=$OPTARG
        grecho "Rancher options set to: ${red}${RANCHER_OPTIONS}${reset}"
        ;;
    f) # process option f: force install, in this case means delete rancher-data if it exists
        FORCE_OPTION=yes
        grecho "Force option has been set, the script will delete rancher-data container if it exists."
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
        if [ $i -gt 1000 ]; then
            grecho "Script is destined to loop forever, aborting!"
            exit 1
        fi
        if [[ "$1" == "" ]]; then
            printf '(y/n): '
        else
            printf "${green}Does this look right?: ${red}$1${reset}
(y/n):"
        fi
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
function taskset() {
    shopt -s nocasematch
    if [[ ${TASK} == "" ]]; then
        grecho "You did not set a task on startup with -t, please set one now.  Your options are restore, backup, upgrade or install."
        read TASK
    fi
    if [[ "${TASK}" != "restore" ]] && [[ "$TASK" != "upgrade" ]] && [[ "$TASK" != "install" ]] && [[ "$TASK" != "backup" ]]; then
        grecho "You selected an invalid task \"$TASK\", please choose from one of the following."
        grecho "restore, backup, upgrade or install."
        exit 1
    else
        grecho "Task set to: ${red}${TASK}"
    fi
    shopt -u nocasematch
}
function rancherpsafilter() {
    echo
    grecho "Providing full docker ps -a output so you can select from stopped containers."
    docker ps -a | grep -v -E "${RANCHER_IMAGE_NAME}:|${RANCHER_IMAGE_NAME} " 2>/dev/null
    grecho "---------------excluding rancher/rancher above this line---------------"
    grecho "--------------filtered by rancher/rancher below this line--------------"
    docker ps -a | grep -E "${RANCHER_IMAGE_NAME}:|${RANCHER_IMAGE_NAME} " 2>/dev/null
    echo
}
function getranchercontainerid() {
    if [[ ${RANCHERSERVER} == "" ]]; then
        docker ps | grep -E "${RANCHER_IMAGE_NAME}:|${RANCHER_IMAGE_NAME} " &>/dev/null

        if [[ "${PIPESTATUS[1]}" != "0" ]]; then
            grecho "Failed to find a running Rancher container with image ${RANCHER_IMAGE_NAME}"
            #No running Rancher servers were found, let's check stopped servers instead.
            RANCHERSERVER=''
            response=''
            while [[ ${response} == 'n' ]] || [[ ${response} == '' ]]; do
                rancherpsafilter
                grecho "Please select your rancher server ID from the above output."
                read RANCHERSERVER
                if [[ "${RANCHERSERVER// /}" == "" ]]; then
                    grecho "Empty response detected!  If you did not see a qualifying Rancher server, you can always install a new one and restore to that if you need to."
                    exit 1
                fi
                recho "${RANCHERSERVER}${green} <- Is this correct?"
                grecho "$(docker ps -a | grep ${RANCHERSERVER})"
                yesno
                echo
            done
        else
            #We found a running Rancher server, let's start there
            RANCHERSERVER=$(docker ps | grep -E "${RANCHER_IMAGE_NAME}:|${RANCHER_IMAGE_NAME} " | awk '{ print $1 }')
            #grecho "Providing full output of 'docker ps' for reference."
            rancherpsafilter
            recho "${RANCHERSERVER} ${green}<- Is this the Rancher server container that we are working with?"
            grecho "${red}!!!WARNING!!!${green} If this is not the server you want and you proceed without shutting it down first, a restore attempt will likely fail. ${red}!!!WARNING!!!"
            grecho "It is safe to CTRL+C at this point if you need to."
            grecho "$(docker ps | grep ${RANCHERSERVER})"
            yesno
            if [ ${response} == 'y' ]; then
                echo
                echo
                grecho "Great, moving on to the next part of the script."
            else
                RANCHERSERVER=''
                response=''
                while [[ ${response} == 'n' ]] || [[ ${response} == '' ]]; do
                    rancherpsafilter
                    grecho "No problem, please select your rancher server ID from the above output."
                    read RANCHERSERVER
                    recho "${RANCHERSERVER}${green} <- Is this correct?"
                    grecho "$(docker ps -a | grep ${RANCHERSERVER})"
                    yesno
                    echo
                done
            fi
        fi
        grecho "Your Rancher server container ID has been set to: ${red}${RANCHERSERVER}"
        docker inspect ${RANCHERSERVER} &>/dev/null
        checkpipecmd "${RANCHERSERVER} does not seem to exist."
    else
        grecho "Your Rancher server container ID has been set to: ${red}${RANCHERSERVER}"
        docker inspect ${RANCHERSERVER} &>/dev/null
        checkpipecmd "${RANCHERSERVER} does not seem to exist."
    fi
}

function getrancherverion_deprecated() {
    CURRENT_RANCHER_VERSION="$(docker exec -ti ${RANCHERSERVER} rancher -v)"
    checkpipecmd "Unable to exec into ${RANCHERSERVER}, aborting script!"

    CURRENT_RANCHER_VERSION=$(sed -r 's,^.*version (\w),\1,g' <<<${CURRENT_RANCHER_VERSION%$'\r'})

    #turn off case matching
    shopt -s nocasematch
    if [[ "$CURRENT_RANCHER_VERSION" == *"rancher"* ]]; then
        grecho "Unable to detect current Rancher version, aborting script!"
        exit 1
    fi
    #turn on case matching
    shopt -u nocasematch

    grecho "Your current Rancher server version is ${CURRENT_RANCHER_VERSION}"
}

function getrancherversion() {
    if [[ "${CURRENT_RANCHER_VERSION}" == "" ]]; then
        REGEX='CATTLE_SERVER_VERSION=([a-z|A-Z|0-9|\.]+)'
        DOCKER_INSPECT=$(docker inspect ${RANCHERSERVER})
        checkpipecmd "Unable to inspect ${RANCHERSERVER} for version check!  Verify that you have the correct Rancher container, failing that you could also set the version manually with -v."
        if [[ ${DOCKER_INSPECT} =~ ${REGEX} ]]; then
            CURRENT_RANCHER_VERSION=${BASH_REMATCH[1]}
            grecho "Your current Rancher server version is ${CURRENT_RANCHER_VERSION}"
        else
            grecho "Regex failed to get Rancher version.  Try setting it manually with -v."
            exit 1
        fi
    else
        grecho "Your current Rancher server version is ${CURRENT_RANCHER_VERSION}"
    fi
}

function gen10yearcerts() {
    if [[ "${RANCHER_SSL_HOSTNAME}" != "" ]]; then
        recho "Generating new 10-year SSL certificates for your Rancher installation."
        docker run -v /etc/rancherssl/certs:/certs -e CA_SUBJECT="Generic CA" -e CA_EXPIRE="3650" -e SSL_EXPIRE="3650" -e SSL_SUBJECT="${RANCHER_SSL_HOSTNAME}" -e SSL_DNS="${RANCHER_SSL_HOSTNAME}" -e SILENT="true" patrick0057/genericssl
        checkpipecmd "Failed to generate certificates from docker image patrick0057/genericssl"
    fi
}

function stopandbackuprancher() {
    if [[ "${DELETE_RANCHER_DATA}" == 'yes' ]]; then
        docker inspect rancher-data &>/dev/null
        if [[ $? -eq 0 ]]; then
            recho "rancher-data container detected, deleting because option -e was passed."
            docker rm -f rancher-data
        fi
    else
        docker inspect rancher-data &>/dev/null
        if [[ $? -eq 0 ]]; then
            recho "rancher-data container detected, renaming it to rancher-data.${START_TIME}."
            docker rename rancher-data rancher-data.${START_TIME}
        fi
    fi
    recho "Stopping Rancher container ${RANCHERSERVER}"
    docker stop ${RANCHERSERVER}
    checkpipecmd "Error while stopping Rancher container, aborting script!"

    recho "Creating rancher-data container"
    docker create --volumes-from ${RANCHERSERVER} --name rancher-data ${RANCHER_IMAGE_NAME}:${CURRENT_RANCHER_VERSION}
    checkpipecmd "Error while creating Rancher data container, aborting script!"

    RANCHER_BACKUP_ARCHIVE="rancher-data-backup-${CURRENT_RANCHER_VERSION}-${START_TIME}.tar.gz"

    recho "Creating archive of rancher-data in working directory, filename: ${green}${RANCHER_BACKUP_ARCHIVE}"
    docker run --volumes-from rancher-data -v $PWD:/backup alpine tar zcvf /backup/${RANCHER_BACKUP_ARCHIVE} /var/lib/rancher &>backup-${LOGFILE}
    checkpipecmd "Creation of /backup/${RANCHER_BACKUP_ARCHIVE} has failed, aborting script!"

    grecho "Checking existence of ${RANCHER_BACKUP_ARCHIVE} archive with ls -lash."
    ls -lash ${RANCHER_BACKUP_ARCHIVE}
}

function setnewrancherversion() {
    if [[ ${NEW_VERSION// /} == "" ]]; then
        response=''
        while [[ ${response// /} == "" ]] || [[ ${response} == "n" ]]; do
            grecho "What version of Rancher would you like to install?  Your answer should include a v in it like v2.2.3 instead of 2.2.3:"
            read NEW_VERSION
            yesno "${NEW_VERSION}"
        done
    fi
}

function installrancher() {

    recho "Pulling ${RANCHER_IMAGE_NAME}:${NEW_VERSION} before launching the new Rancher container."
    docker pull ${RANCHER_IMAGE_NAME}:${NEW_VERSION}
    checkpipecmd "Image pull for ${RANCHER_IMAGE_NAME}:${NEW_VERSION} has failed, aborting script!"

    if [[ ${DOCKER_OPTIONS// /} == "" ]]; then
        DOCKER_OPTIONS="-d --restart=unless-stopped -p 80:80 -p 443:443"
    fi

    recho "Launching the new Rancher container."
    NEW_RANCHERSERVER=$(docker run ${DOCKER_OPTIONS} ${SSLVOLUMES} ${RANCHER_IMAGE_NAME}:${NEW_VERSION} ${RANCHER_OPTIONS})
    checkpipecmd "Unable to start new Rancher container, aborting script!"
}

function detectoptions() {
    RUNLIKE=$(docker run --rm -v /var/run/docker.sock:/var/run/docker.sock patrick0057/runlike ${RANCHERSERVER})
    if [[ "$?" == "0" ]]; then
        #DOCKER OPTIONS
        PORTS=$(grep -P -o -- "-p\s\d+:\d+" <<<${RUNLIKE})
        RESTART_POLICY=$(grep -P -o -- "--restart=[\w|-]+" <<<${RUNLIKE})
        #If we passed -s then we are overriding whatever is set for SSL volumes.
        if [[ ${SSLVOLUMES// /} == "" ]]; then
            SSLVOLUMES=$(grep -P -o -- "--volume=[\/|\w\.]+:\/etc\/rancher\/ssl\/[cert|key|cacerts]+\.pem" <<<${RUNLIKE})
        fi
        AUTO_DOCKER_OPTIONS="-d ${PORTS} ${RESTART_POLICY} ${SSLVOLUMES}"
        #replace newlines with spaces
        AUTO_DOCKER_OPTIONS=${AUTO_DOCKER_OPTIONS//$'\n'/ }
        #RANCHER OPTIONS
        ACME_DOMAIN=$(grep -P -o -- "--acme-domain[\s=]+[\w|\d|\.]+" <<<${RUNLIKE})
        NO_CACERTS=$(grep -P -o -- "--no-cacerts" <<<${RUNLIKE})
        AUTO_RANCHER_OPTIONS="${ACME_DOMAIN} ${NO_CACERTS}"
        #replace newlines with spaces
        AUTO_RANCHER_OPTIONS=${AUTO_RANCHER_OPTIONS//$'\n'/ }
    else
        grecho "Failed to detect options."
    fi
}

function setoptions() {
    if [[ "${FORCE_OPTION}" == "yes" ]]; then
        if [[ ${DOCKER_OPTIONS// /} == "" ]]; then
            grecho "Force option -f detected with no ${red}Docker${green} options set, automatically setting these for you based on your old container options."
            detectoptions
            DOCKER_OPTIONS=${AUTO_DOCKER_OPTIONS}
        fi
        if [[ ${RANCHER_OPTIONS// /} == "" ]]; then
            grecho "Force option -f detected with no ${red}Rancher${green} options set, automatically setting these for you based on your old container options."
            detectoptions
            RANCHER_OPTIONS=${AUTO_RANCHER_OPTIONS}
        fi
    else
        #BEGINNING OF NO FORCE OPTION SECTION
        if [[ ${DOCKER_OPTIONS// /} == "" ]]; then
            echo
            echo
            grecho "Your ${red}Docker${green} options have not been set, would you like me to auto detect these for you?  Answering no here will give you the opportunity to set these yourself or choose defaults."
            grecho "Default options: \"-d --restart=unless-stopped -p 80:80 -p 443:443\""
            yesno
            shopt -s nocasematch
            if [[ ${response} == "y" ]]; then
                detectoptions
                echo
                echo
                grecho "These are the ${red}Docker${green} options I've detected from your original Rancher container.  If you passed -s as a launch option of the script, the SSL volumes found below have been set from that option and not from the original container."
                recho "${AUTO_DOCKER_OPTIONS}"
                echo
                grecho "Would you like me to set these for you?"
                yesno
                if [[ ${response} == "y" ]]; then
                    recho "Setting ${green}Docker${red} options to: ${AUTO_DOCKER_OPTIONS}"
                    DOCKER_OPTIONS=${AUTO_DOCKER_OPTIONS}
                else
                    manualdockerset
                fi
            else
                manualdockerset
            fi
            shopt -u nocasematch
        else
            #if your docker options are not blank
            grecho "Your ${red}Docker${green} options have been set to:"
            DOCKER_OPTIONS="${DOCKER_OPTIONS} ${SSLVOLUMES}"
            recho "$DOCKER_OPTIONS"
        fi
        if [[ ${RANCHER_OPTIONS// /} == "" ]]; then
            echo
            echo
            grecho "Your ${red}Rancher${green} options have not been set, would you like me to auto detect these for you?  Answering no here will give you the opportunity to set these yourself or choose defaults."
            grecho "Default options: \"\""
            yesno
            shopt -s nocasematch
            if [[ ${response} == "y" ]]; then
                detectoptions
                if [[ ${AUTO_RANCHER_OPTIONS// /} == "" ]]; then
                    grecho "No previous ${red}Rancher${green} options found."
                    grecho "Would you like to manually set any?"
                    yesno
                    if [[ ${response} == "y" ]]; then
                        manualrancherset
                    else
                        RANCHER_OPTIONS=${AUTO_RANCHER_OPTIONS// /}
                    fi
                else
                    echo
                    echo
                    grecho "These are the ${red}Rancher${green} options I've detected from your original Rancher container:"
                    recho "${AUTO_RANCHER_OPTIONS}"
                    echo
                    grecho "Would you like me to set these for you?"
                    yesno
                    if [[ ${response} == "y" ]]; then
                        recho "Setting ${green}Rancher${red} options to: ${AUTO_RANCHER_OPTIONS}"
                        RANCHER_OPTIONS=${AUTO_RANCHER_OPTIONS}
                    else
                        manualrancherset
                    fi
                fi
            else
                manualrancherset
            fi
            shopt -u nocasematch
        else
            #if your Rancher options are not blank
            grecho "Your ${red}Rancher${green} options have been set to:"
            recho "$RANCHER_OPTIONS"
        fi
    #END OF FORCE OPTIONS NOT SET SECTION
    fi
}
manualdockerset() {
    response=''
    shopt -s nocasematch
    while [[ "${response// /}" == "" ]] || [[ "${response}" == "n" ]]; do
        if [[ "${RANCHER_SSL_HOSTNAME// /}" != "" ]]; then
            grecho "You passed -s at the launch of the script, the options you set below should not include volume binds for SSL certificates.  It will be added for you by the script."
        fi
        grecho "OK, what would you like the Docker options to be?  Enter \"default\" or nothing at all for default options."
        grecho "Default options: \"-d --restart=unless-stopped -p 80:80 -p 443:443\""
        read DOCKER_OPTIONS
        if [[ "${DOCKER_OPTIONS}" == "default" ]] || [[ "${DOCKER_OPTIONS// /}" == "" ]]; then
            grecho "Detected request for default or an empty response, setting default options."
            DOCKER_OPTIONS="-d --restart=unless-stopped -p 80:80 -p 443:443"
        fi
        yesno "${DOCKER_OPTIONS}"
    done
    DOCKER_OPTIONS="${DOCKER_OPTIONS} ${SSLVOLUMES}"
    shopt -u nocasematch
}
manualrancherset() {
    response=''
    shopt -s nocasematch
    while [[ ${response// /} == "" ]] || [[ ${response} == "n" ]]; do
        grecho "OK, what would you like the Rancher options to be?  By default there are no options you need to pass to the Rancher container.  Common options set here would be --no-cacert or --acme-domain <domain name>.  Press enter for none."
        read RANCHER_OPTIONS
        if [[ "${RANCHER_OPTIONS// /}" == "" ]]; then
            grecho "Detected an empty response, setting RANCHER_OPTIONS to \"\"."
            RANCHER_OPTIONS=""
            response='y'
        else
            yesno "${RANCHER_OPTIONS}"
        fi
    done
    shopt -u nocasematch
}
#getbackupfileversion #requires ${BACKUPFILEPATH}
function getbackupfileversion() {
    REGEX="rancher-data-backup-(v[0-9]\.[0-9]+\.[0-9]+)-.*--.*\.tar\.gz"
    if [[ "${BACKUPFILEPATH}" =~ ${REGEX} ]]; then
        grecho "Backup filename matches the format used by this script, checking version of backup..."
        BACKUP_FILE_VERSION=${BASH_REMATCH[1]}
    else
        BACKUP_FILE_VERSION="invalid"
    fi
}

#TASKS
taskset

shopt -s nocasematch
if [[ "$TASK" == "backup" ]]; then
    shopt -u nocasematch
    getranchercontainerid
    getrancherverion
    stopandbackuprancher
    grecho "Restarting your rancher container"
    docker start ${RANCHERSERVER}
fi

shopt -s nocasematch
if [[ "$TASK" == "install" ]]; then
    shopt -u nocasematch
    setnewrancherversion
    installrancher

fi

shopt -s nocasematch
if [[ "$TASK" == "restore" ]]; then
    if [[ "${RANCHER_SSL_HOSTNAME// /}" != "" ]]; then
        grecho "Option -s has been detected but your task is currently set to \"restore\".  Ignoring option, please use it with task \"upgrade\" instead."
    fi
    shopt -u nocasematch
    #Check to see if we set a backup file with option -b
    if [[ ! -f "${BACKUPFILEPATH}" ]]; then
        #while loop to keep us in the script if an incorrect option was selected
        while [[ ${PROCEED} == '' ]]; do
            grecho "Would you like me to recursively find and list backups named rancher-data-backup*.tar.gz in the current directory ${PWD}?"
            yesno
            shopt -s nocasematch
            PROCEED=''

            if [[ "$response" == "y" ]]; then
                #Store list of backups in an array.
                ARRAY=()
                while IFS= read -r -d $'\0'; do
                    ARRAY+=("$REPLY")
                done < <(find . -name "rancher-data-backup*.tar.gz" -print0 | sort -z)
                for ((i = 0; i < ${#ARRAY[@]}; i++)); do
                    echo -e "${red}$i${green}\t-- ${ARRAY[$i]}${reset}"
                done
                response=''
                while [[ ${response} == '' ]] || [[ ${response} == 'n' ]]; do
                    grecho "Please select the backup ${red}#${green} that you would like to have restored."
                    read BACKUPNUMBER
                    yesno "${ARRAY[${BACKUPNUMBER}]}"
                done
                BACKUPFILEPATH=${ARRAY[${BACKUPNUMBER}]}
            else
                response=''
                while [[ ${response} == '' ]] || [[ ${response} == 'n' ]]; do
                    grecho "No problem, please provide me with the full path to the upgrade file."
                    read BACKUPFILEPATH
                    yesno "${BACKUPFILEPATH}"
                done
            fi
            if [[ ! -f "${BACKUPFILEPATH}" ]]; then
                grecho "Backup file does not exist!"
            else
                grecho "I've confirmed that ${BACKUPFILEPATH} exists, script will proceed."
                PROCEED='y'
            fi
        done
        shopt -u nocasematch
    fi
    #End of section that determines the backup file.

    getranchercontainerid

    getrancherversion

    getbackupfileversion #requires ${BACKUPFILEPATH} to be set, then sets ${BACKUP_FILE_VERSION}
    if [[ "${BACKUP_FILE_VERSION}" == "unknown" ]]; then
        grecho "I was unable to determine the backup file version because the backup file did not use the same syntax as this script."
        response=''
        while [[ ${response// /} == "" ]] || [[ ${response} == "n" ]]; do
            grecho "What version of Rancher is this backup from?"
            read BACKUP_FILE_VERSION
            yesno "${BACKUP_FILE_VERSION}"
        done
    elif [[ "${BACKUP_FILE_VERSION}" == "${CURRENT_RANCHER_VERSION}" ]]; then
        grecho "Your current rancher version matches the backup file version, proceeding with restore."
    else
        grecho "Your current version of Rancher does not match the backup file version."
        grecho "Backup file version: ${red}${BACKUP_FILE_VERSION}"
        grecho "Your current version: ${red}${CURRENT_RANCHER_VERSION}"
        echo
        response=''
        grecho "Do you want to restore your backup to a new Rancher container that matches the version of your backup?"
        yesno
        shopt -s nocasematch
        if [[ "${response}" == "y" ]]; then
            stopandbackuprancher
            grecho "OK, starting process to install new Rancher container..."
            setoptions
            #SET VERSION OF RANCHER TO BE INSTALLED
            NEW_VERSION=${BACKUP_FILE_VERSION}
            echo
            recho "Installing Rancher..."
            installrancher
            OLD_RANCHERSERVER=${RANCHERSERVER}
            RANCHERSERVER=${NEW_RANCHERSERVER}
            #set restart policy on old container to never
            echo
            recho "Setting your old Rancher container to never restart.  Make sure you delete this once you are satisfied with the new installation."
            recho "${OLD_RANCHERSERVER} <-${green}Old Rancher container ID, delete this once you are sure everything is working after the restore."
            docker update --restart=no ${OLD_RANCHERSERVER}
        fi
    fi
    if [[ ${OLD_RANCHERSERVER// /} == "" ]]; then
        stopandbackuprancher
    fi

    recho "Running restore command.  Results of command can be found in restore-${LOGFILE}"
    docker run --volumes-from ${RANCHERSERVER} -v $PWD:/backup alpine sh -c "rm /var/lib/rancher/* -rf  && tar zxvf /backup/${BACKUPFILEPATH}" /backup/${RANCHER_BACKUP_ARCHIVE} /var/lib/rancher &>restore-${LOGFILE}
    checkpipecmd "Restore failed!  Aborting script!"

    docker start ${RANCHERSERVER}
    checkpipecmd "Failed to start the Rancher server after restore."

    grecho "Restore has completed!"

    if [[ "${DELETE_RESTORE_CONTAINER}" == "yes" ]] && [[ ${OLD_RANCHERSERVER// /} != "" ]]; then
        echo
        recho "Option -x was passed at script launch, deleting old Rancher container."
        docker rm -f ${OLD_RANCHERSERVER}
    fi

fi

shopt -s nocasematch
if [[ "$TASK" == "upgrade" ]]; then
    shopt -u nocasematch

    gen10yearcerts

    getranchercontainerid

    getrancherverion

    setoptions

    stopandbackuprancher

    #if we didn't pass -v, then set the version to current version.
    if [[ ${FORCE_OPTION} != "yes" ]]; then
        if [[ ${NEW_VERSION} == '' ]]; then
            grecho "You did not set a Rancher version to upgrade to.  Do you want to set one now?  If you do not set a version, the script will upgrade you to the same version.  This is useful for changing install options.  Ensure that you include a \"v\" in the version, like v2.2.3 instead of just 2.2.3."
            yesno
            shopt -s nocasematch
            if [[ "${response}" == "n" ]]; then
                grecho "New Rancher version not specified, setting it to your current Rancher version: ${red}${CURRENT_RANCHER_VERSION}"
                NEW_VERSION=${CURRENT_RANCHER_VERSION}
            else
                setnewrancherversion
            fi
            shopt -u nocasematch
        fi
    else
        if [[ ${NEW_VERSION} == '' ]]; then
            grecho "Force option -f detected but new Rancher version not specified, setting it to your current Rancher version: ${red}${CURRENT_RANCHER_VERSION}"
            NEW_VERSION=${CURRENT_RANCHER_VERSION}
        fi
    fi
    recho "Pulling ${RANCHER_IMAGE_NAME}:${NEW_VERSION} before launching the new Rancher container."
    docker pull ${RANCHER_IMAGE_NAME}:${NEW_VERSION}
    checkpipecmd "Image pull for ${RANCHER_IMAGE_NAME}:${NEW_VERSION} has failed, aborting script!"

    recho "Launching the new Rancher container."
    docker run --volumes-from rancher-data ${DOCKER_OPTIONS} ${RANCHER_IMAGE_NAME}:${NEW_VERSION} ${RANCHER_OPTIONS}
    checkpipecmd "Unable to start new Rancher container, aborting script!"
fi
