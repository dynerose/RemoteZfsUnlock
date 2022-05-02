#!/bin/bash
##Scripts installs ubuntu server on encrypted zfs with headless remote unlocking.
##Script date: 2022-05-02

set -euo pipefail
#set -x

##Usage: <script_filename> initial | postreboot | remoteaccess | datapool
##Script: https://github.com/dynerose/RemoteZfsUnlock

##Variables:
ubuntuver="jammy" #Ubuntu release to install. "hirsute" (21.04). "impish" (21.10). "jammy" (22.04).
distro_variant="server" #Ubuntu variant to install. "server" (Ubuntu server; cli only.) "desktop" (Default Ubuntu desktop install). "kubuntu" (KDE plasma desktop variant). "xubuntu" (Xfce desktop variant). "MATE" (MATE desktop variant).
user="sa" #Username for new install.
PASSWORD="Password" #Password for user in new install.
hostname="ubuntu" #Name to identify the main system on the network. An underscore is DNS non-compliant.
zfspassword="Password" #Password for root pool and data pool. Minimum 8 characters.
locale="en_GB.UTF-8" #New install language setting.
timezone="Europe/London" #New install timezone setting.
zfs_rpool_ashift="12" #Drive setting for zfs pool. ashift=9 means 512B sectors (used by all ancient drives), ashift=12 means 4KiB sectors (used by most modern hard drives), and ashift=13 means 8KiB sectors (used by some modern SSDs).

RPOOL="rpool" #Root pool name.
topology_root="single" #"single", "mirror", "raidz1", "raidz2", or "raidz3" topology on root pool.
disks_root="1" #Number of disks in array for root pool. Not used with single topology.
EFI_boot_size="512" #EFI boot loader partition size in mebibytes (MiB).
swap_size="4000" #Swap partition size in mebibytes (MiB). Size of swap will be larger than defined here with Raidz topologies.
openssh="yes" #"yes" to install open-ssh server in new install.
datapool="datapool" #Non-root drive data pool name.
topology_data="single" #"single", "mirror", "raidz1", "raidz2", or "raidz3" topology on data pool.
disks_data="1" #Number of disks in array for data pool. Not used with single topology.
datapoolmount="/mnt/$datapool" #Non-root drive data pool mount point in new install.
zfs_dpool_ashift="12" #See notes for rpool ashift. If ashift is set too low, a significant read/write penalty is incurred. Virtually no penalty if set higher.
zfs_compression="zstd" #"lz4" is the zfs default; "zstd" may offer better compression at a cost of higher cpu usage.
mountpoint="/mnt/ub_server" #Mountpoint in live iso.
remoteaccess_first_boot="no" #"yes" to enable remoteaccess during first boot. Recommend leaving as "no" and run script with "remoteaccess". See notes in section above.
timeout_rEFInd="5" #Timeout in seconds for rEFInd boot screen until default choice selected.
timeout_zbm_no_remote_access="15" #Timeout in seconds for zfsbootmenu when no remote access enabled.
timeout_zbm_remote_access="30" #Timeout in seconds for zfsbootmenu when remote access enabled.
quiet_boot="yes" #Set to "no" to show boot sequence.
ethprefix="e" #First letter of ethernet interface. Used to identify ethernet interface to setup networking in new install.
install_log="ubuntu_setup_zfs_root.log" #Installation log filename.
log_loc="/var/log" #Installation log location.
ipv6_apt_fix_live_iso="no" #Try setting to "yes" gif apt-get is slow in the ubuntu live iso. Doesn't affect ipv6 functionality in the new install.
remoteaccess_hostname="zbm" #Name to identify the zfsbootmenu system on the network.
remoteaccess_ip_config="static" #"static" or "dhcp". Manual or automatic IP assignment for zfsbootmenu remote access.
remoteaccess_ip="192.168.100.10" #Remote access IP address to connect to ZFSBootMenu. Not used for "dhcp" automatic IP configuration.
remoteaccess_netmask="255.255.255.0" #Remote access subnet mask. Not used for "dhcp" automatic IP configuration.

##Check for root priviliges
if [ "$(id -u)" -ne 0 ]; then
   echo "Please run as root."
   exit 1
fi

##Check for EFI boot environment
if [ -d /sys/firmware/efi ]; then
   echo "Boot environment check passed. Found EFI boot environment."
else
   echo "Boot environment check failed. EFI boot environment not found. Script requires EFI."
   exit 1
fi

##Functions
topology_min_disk_check(){
	##Check that number of disks meets minimum number for selected topology.
	pool="$1"
	echo "Checking script variables for $pool pool..."
	
	topology_pool_pointer="topology_$pool"
	eval echo "User defined topology for ${pool} pool: \$${topology_pool_pointer}"
	eval topology_pool_pointer="\$${topology_pool_pointer}"
	
	disks_pointer="disks_${pool}"
	eval echo "User defined number of disks in pool: \$${disks_pointer}"
	eval disks_pointer=\$"${disks_pointer}"

	num_disks_check(){
		min_num_disks="$1"
		
		if [ "$disks_pointer" -lt "$min_num_disks" ]
		then
			echo "A ${topology_pool_pointer} topology requires at least ${min_num_disks} disks. Check variable for number of disks or change the selected topology."
			exit 1
		else true
		fi
	}
	
	case "$topology_pool_pointer" in
		single) true ;;
		
		mirror|raidz1)
			num_disks_check "2"
		;;
		
		raidz2)
			num_disks_check "3"
		;;

		raidz3)
			num_disks_check "4"
		;;

		*)
			echo "Pool topology not recognised. Check pool topology variable."
			exit 1
		;;
	esac
	printf "%s\n\n" "Minimum disk topology check passed for $pool pool."
}

logFunc(){
	# Log everything we do
	exec > >(tee -a "$log_loc"/"$install_log") 2>&1
}

disclaimer(){
	echo "***WARNING*** This script could wipe out all your data, or worse! I am not responsible for your decisions. Press Enter to Continue or CTRL+C to abort."
	read -r _
}

getdiskID(){
	pool="$1"
	diskidnum="$2"
	total_discs="$3"
	
	##Get disk ID(s)	
	
	manual_read(){
		ls -la /dev/disk/by-id
		echo "Enter Disk ID for disk $diskidnum of $total_discs on $pool pool (must match exactly):"
		read -r DISKID
	}
	#manual_read
	
	menu_read(){
		diskidmenu_loc="/tmp/diskidmenu.txt"
		ls -la /dev/disk/by-id | awk '{ print $9, $11 }' | sed -e '1,3d' | grep -v "part\|CD-ROM" > "$diskidmenu_loc"
		
		echo "Please enter Disk ID option for disk $diskidnum of $total_discs on $pool pool."
		nl "$diskidmenu_loc"
		count="$(wc -l "$diskidmenu_loc" | cut -f 1 -d' ')"
		n=""
		while true; 
		do
			read -r -p 'Select option: ' n
			if [ "$n" -eq "$n" ] && [ "$n" -gt 0 ] && [ "$n" -le "$count" ]; then
				break
			fi
		done
		DISKID="$(sed -n "${n}p" "$diskidmenu_loc" | awk '{ print $1 }' )"
		printf "%s\n\n" "Option number $n selected: '$DISKID'"
	}
	menu_read
	
	#DISKID=ata-VBOX_HARDDISK_VBXXXXXXXX-XXXXXXXX ##manual override
	##error check
	errchk="$(find /dev/disk/by-id -maxdepth 1 -mindepth 1 -name "$DISKID")"
	if [ -z "$errchk" ];
	then
		echo "Disk ID not found. Exiting."
		exit 1
	fi
		
	errchk="$(grep "$DISKID" /tmp/diskid_check_"${pool}".txt || true)"
	if [ -n "$errchk" ];
	then
		echo "Disk ID has already been entered. Exiting."
		exit 1
	fi
	
	printf "%s\n" "$DISKID" >> /tmp/diskid_check_"${pool}".txt
}

getdiskID_pool(){
	pool="$1"

	##Check that number of disks meets minimum number for selected topology.
	topology_min_disk_check "$pool"

	echo "Carefully enter the ID of the disk(s) YOU WANT TO DESTROY in the next step to ensure no data is accidentally lost."
	
	##Create temp file to check for duplicated disk ID entry.
	true > /tmp/diskid_check_"${pool}".txt
	
	topology_pool_pointer="topology_$pool"
	#eval echo \$"${topology_pool_pointer}"
	eval topology_pool_pointer="\$${topology_pool_pointer}"
	
	disks_pointer="disks_${pool}"
	#eval echo \$"${disks_pointer}"
	eval disks_pointer=\$"${disks_pointer}"

	case "$topology_pool_pointer" in
		single)
			echo "The $pool pool disk topology is a single disk."
			getdiskID "$pool" "1" "1"
		;;

		raidz*|mirror)
			echo "The $pool pool disk topology is $topology_pool_pointer with $disks_pointer disks."
			diskidnum="1"
			while [ "$diskidnum" -le "$disks_pointer" ];
			do
				getdiskID "$pool" "$diskidnum" "$disks_pointer"
				diskidnum=$(( diskidnum + 1 ))
			done
		;;

		*)
			echo "Pool topology not recognised. Check pool topology variable."
			exit 1
		;;

	esac

}

clear_partition_table(){
	pool="$1" #root or data
	while IFS= read -r diskidnum;
	do
		echo "Clearing partition table on disk ${diskidnum}."
		sgdisk --zap-all /dev/disk/by-id/"$diskidnum"
	done < /tmp/diskid_check_"${pool}".txt
}

identify_ubuntu_dataset_uuid(){
	rootzfs_full_name=0
	rootzfs_full_name="$(zfs list -o name | awk '/ROOT\/ubuntu/{print $1;exit}'|sed -e 's,^.*/,,')"
}

case "${1-default}" in
	initial)
		echo "Running initial install. Press Enter to Continue or CTRL+C to abort."
		read -r _
		initialinstall
	;;
	postreboot)
		echo "Running postreboot setup. Press Enter to Continue or CTRL+C to abort."
		read -r _
		postreboot
	;;
	remoteaccess)
		echo "Running remote access to ZFSBootMenu install. Press Enter to Continue or CTRL+C to abort."
		read -r _
		setupremoteaccess
	;;
	datapool)
		echo "Running create data pool on non-root drive. Press Enter to Continue or CTRL+C to abort."
		read -r _
		createdatapool
	;;
	*)
		echo -e "Usage: $0 initial | postreboot | remoteaccess | datapool"
	;;
esac

date
exit 0
