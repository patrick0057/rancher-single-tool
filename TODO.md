1. Create function / option to create backup archives from all eligable docker volumes.
```bash
{
    DOCKER_VOLUME_BASE='/var/lib/docker/volumes/'
    ARCHIVEDIR=/tmp/
    for dir in /var/lib/docker/volumes/*; do
        ls $dir | grep _data &>/dev/null
        if [[ "${PIPESTATUS[1]}" == "0" ]]; then
            #echo GOOD: ${dir##*\/}
            VOL_DATE=$(ls -l --time-style=full-iso $dir | tr -s " " | cut -d" " -f6)
            VOL_TIME=$(ls -l --time-style=full-iso $dir | tr -s " " | cut -d" " -f7 | cut -d"." -f1 | tr -d ":")
            VOL_FULLNAME=${ARCHIVEDIR}rancher-data-backup-v0.0.0-${VOL_DATE}--${VOL_TIME}.tar.gz
            VOL_FULLNAME=${VOL_FULLNAME//$'\n'/}
            tar -cvzf ${VOL_FULLNAME} --transform 's,^_data,var/lib/rancher,' -C ${DOCKER_VOLUME_BASE}${dir##*\/}/ _data/
        fi
    done
}
```

2. Add more Rancher environment variables for restore function's auto detection feature.
