#!/bin/bash

# copy command line for restart
cmd="$0"
if [ "${cmd#/}" = "$cmd" ]; then cmd="$PWD/$cmd"; fi
typeset -r cmd
declare -r args=("$@")

# target device name to monitor/notify
declare -r devpattern='^sd[a-z][1-9]$'

# button IDs of dialog
declare -r cancel=0
declare -r rdwr=1
declare -r rdonly=2

# geometry of yad
yadgeo=(--posx -1 --posy 0 --height 180)

# arithmetic const.
declare -r Gi=1073741824
declare -r Mi=1048576
declare -r Ki=1024

# default mount options
defmopts='nosuid,noexec,nodev,noatime'

SetDevInfo () {
    local -r dev="/sys/$1"
    local -r rmname='removable'
    local tag val rmfile

    if [ -z "$1" -o ! -e "$dev" ]; then return 1; fi

    unset "${!DevInfo_@}"
    # cannot use pipe here (to set variables)
    while read -r tag val; do
	if [ "$tag" = 'E:' ]; then
	    # for
	    # - items separated by space
	    # - backslash-escaped characters
	    eval "DevInfo_${val/=/=\$\'}'"
	    # eval echo "\$DevInfo_${val%%=*}"
	elif [ "$tag" = 'N:' ]; then
	    DevInfo__NAME="$val"
	fi
    done < <(udevadm info -p "$dev")

    rmfile="$dev/$rmname"
    if [ ! -f "$rmfile" ]; then
	rmfile="${dev%/*}/$rmname"
	if [ ! -f "$rmfile" ]; then
	    rmfile=
	fi
    fi
    if [ "$rmfile" ]; then
	read DevInfo__RM _ < "$rmfile"
    fi

    return 0
}

End () {
    if [ "$COPROC_PID" -ne 0 ]; then kill "$COPROC_PID"; wait; fi
}

ReDo () {
    End
    exec "$cmd" "${args[@]}"
    exit 1
}

trap End EXIT
trap ReDo SIGUSR1

coproc stdbuf -oL -- udevadm monitor -u -s block

while read -r -u "${COPROC[0]}" -- _ _ event devpath _; do
    if [ "$event" != 'add' ]; then continue; fi

    SetDevInfo "$devpath"
    if [[ ! "$DevInfo__NAME" =~ $devpattern ]]; then continue; fi

    file="$DevInfo_DEVNAME"
    msg=
    if [ "$DevInfo__RM" -ne 1 ]; then
	msg="Skip non-RM: $file"
    elif [ "${DevInfo_ID_FS_TYPE#LVM}" != "$DevInfo_ID_FS_TYPE" ]; then
	msg="Skip LV: $file"
    elif [ "$DevInfo_ID_FS_TYPE" = 'crypto_LUKS' ]; then
	msg="Skip LUKS partition: $file"
    fi
    if [ "$msg" ]; then
	# echo "$msg" | yad --text-info "${yadgeo[@]}" --width 280 --title 'Mount: skip' --button="OK:0" --listen --wrap &
	echo "$msg"
	continue
    fi
    {
	echo "Mount $file; Ok?"
	echo -n "  SIZE:$DevInfo_ID_PART_ENTRY_SIZE"
	# block to KiB
	size=$(($DevInfo_ID_PART_ENTRY_SIZE / 2))
	if [ "$size" -ge "$Gi" ]; then
	    echo " ($(echo "scale=2; $size / $Gi" | bc) TiB)"
	elif [ "$size" -ge "$Mi" ]; then
	    echo " ($(echo "scale=2; $size / $Mi" | bc) GiB)"
	elif [ "$size" -ge "$Ki" ]; then
	    echo " ($(echo "scale=2; $size / $Ki" | bc) MiB)"
	else
	    echo
	fi
	echo "  LABEL:$DevInfo_ID_FS_LABEL_ENC"
	echo "  FSTYPE:$DevInfo_ID_FS_TYPE"
	echo "  UUID:$DevInfo_ID_FS_UUID_ENC"
    } | yad --text-info "${yadgeo[@]}" --title 'Mount: option' --button="Cancel:$cancel" --button="R/O:$rdonly" --button="OK (R/W):$rdwr" --listen --wrap
    ret="$?"
    mopt="$defmopts"
    if [ "$ret" -eq "$cancel" ]; then
	continue
    elif [ "$ret" -eq "$rdonly" ]; then
	mopt="$mopt,ro"
    fi
    msg="$(udisksctl mount --block-device "$dir$file" --no-user-interaction ${mopt:+-o $mopt} 2>&1)"
    ret="$?"
    {
	if [ "$ret" -ne 0 ]; then
	    echo "Failed to mount $file."
	    echo -n '> '
	fi
	echo "$msg"
    } | yad --text-info "${yadgeo[@]}" --width 280 --title 'Mount: result' --button="OK:0" --listen --wrap &
done
