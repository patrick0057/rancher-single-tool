# rancher-single-upgrade
This script simplifies the process for upgrading, backing up, restoring and installing single server rancher installations.  This script also has a recovery option (-i/-I) for creating rancher backup images from docker volumes.  Please see the script's help menu (option -h) for a full list of options.  You are able to pass enough options to make the script fully automatic or you can pass no options and the script will prompt you for everything.

Usage:
```bash
curl -LO https://github.com/patrick0057/rancher-single-tool/raw/master/rancher-single-tool.sh
bash rancher-single-tool.sh -h
```
