#!/bin/sh

BINARY=wfm.sh
CONFIG=wfm.conf
TARGETS=targets.txt
INITSCRIPT=init.d/wfm

BINARY_TARGET=/usr/bin
INITSCRIPT_TARGET=/etc/init.d
CONFIG_TARGET=/etc/wfm

if [ "$1" == "remove" ]
then
    if [ -e /etc/debian_version ]
    then
        update-rc.d -f wfm remove
    elif [ -e /etc/redhat-release ]
    then
        chkconfig --del wfm
    fi

    rm "$BINARY_TARGET/$BINARY"
    rm "$CONFIG_TARGET/$CONFIG"
    rm "$CONFIG_TARGET/$TARGETS"
    rm $INITSCRIPT_TARGET/`basename $INITSCRIPT`
    exit
fi

if [ ! -e "$CONFIG_TARGET" ]
then
    mkdir -p "$CONFIG_TARGET"
fi

cp "$BINARY" "$BINARY_TARGET"
cp "$INITSCRIPT" "$INITSCRIPT_TARGET"

chmod 755 "$BINARY_TARGET/$BINARY"
chmod 755 "$INITSCRIPT_TARGET/`basename $INITSCRIPT`"

if [ -e $CONFIG_TARGET/$CONFIG ]
then
    echo
    echo "-------------------------------------------------------------------"
    echo "Existing configuration found. Creating $CONFIG_TARGET/$CONFIG.new."
    echo "Update your existing configuration file with the new one or WFM may"
    echo "not operate properly due to changes. Press enter to continue."
    echo "-------------------------------------------------------------------"
    read
    cp "$CONFIG" "$CONFIG_TARGET/$CONFIG.new"
    cp "$TARGETS" "$CONFIG_TARGET/$TARGETS.new"
else
    cp "$CONFIG" "$CONFIG_TARGET/$CONFIG"
    cp "$TARGETS" "$CONFIG_TARGET/$TARGETS" 
fi

if [ -e /etc/debian_version ]
then
    update-rc.d wfm defaults 99 10
elif [ -e /etc/redhat-release ]
then
    chkconfig --levels 2345 wfm on
fi


