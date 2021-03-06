#!/bin/bash
##Scripts installs ubuntu server on encrypted zfs with headless remote unlocking.
##Script date: 2022-05-02

set -euo pipefail
#set -x

##Usage: <script_filename> initial | postreboot | remoteaccess | datapool
##Script: https://github.com/dynerose/RemoteZfsUnlock

##Script to be run in two parts.
##Part 1: Run with "initial" option from Ubuntu 21.04 live iso (desktop version) terminal.
##Part 2: Reboot into new install.
##Part 2: Run with "postreboot" option after first boot into new install (login as root. p/w as set in variable section below). 

##Remote access can be installed by either:
##  setting the remoteaccess variable to "yes" in the variables section below, or
##  running the script with the "remoteaccess" option after part 1 and part 2 are run.
##Connect as "root" on port 222 to the server's ip.
##It's better to leave the remoteaccess variable below as "no" and run the script with the "remoteaccess" option
##  as that will use the user's authorized_keys file. Setting the remoteaccess variable to "yes" will use root's authorized_keys.
##Login as "root" during remote access, even if using a user's authorized_keys file. No other users are available during remote access.
##The user's authorized_keys file will not be available until the user account is created in part 2 of the script.
##So remote login using root's authorized_keys file is the only option during the first reboot.

##A non-root drive can be setup as an encrypted data pool using the "datapool" option.
##The drive will be unlocked automatically after the root drive password is entered at boot.

##If running in a Virtualbox virtualmachine, setup tips below:
##1. Enable EFI.
##2. Set networking to bridged mode so VM gets its own IP. Fewer problems with ubuntu keyserver.
##3. Minimum drive size of 5GB.

##Rescuing using a Live CD
##zpool export -a #Export all pools.
##zpool import -N -R /mnt rpool #"rpool" should be the root pool name.
##zfs load-key -r -L prompt -a #-r Recursively loads the keys. -a Loads the keys for all encryption roots in all imported pools. -L is for a keylocation or to "prompt" user for an input.
##zfs mount -a #Mount all datasets.

##Variables:
ubuntuver="jammy" #Ubuntu release to install. "hirsute" (21.04). "impish" (21.10). "jammy" (22.04).
distro_variant="server" #Ubuntu variant to install. "server" (Ubuntu server; cli only.) "desktop" (Default Ubuntu desktop install). "kubuntu" (KDE plasma desktop variant). "xubuntu" (Xfce desktop variant). "MATE" (MATE desktop variant).
user="sa" #Username for new install.
useremail="other@gmail.com"
PASSWORD="Password" #Password for user in new install.
hostname="ubuntu" #Name to identify the main system on the network. An underscore is DNS non-compliant.
zfspassword="Password" #Password for root pool and data pool. Minimum 8 characters.
locale="en_GB.UTF-8" #New install language setting.
timezone="Europe/London" #New install timezone setting.
zfs_rpool_ashift="12" #Drive setting for zfs pool. ashift=9 means 512B sectors (used by all ancient drives), ashift=12 means 4KiB sectors (used by most modern hard drives), and ashift=13 means 8KiB sectors (used by some modern SSDs).

RPOOL="rootpool" #Root pool name.
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
zfs_compression="lz4" #"lz4" is the zfs default; "zstd" may offer better compression at a cost of higher cpu usage.
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
remoteaccess_bridge_ip="192.168.100.2"
remoteacces_port=2222
remoteaccess_netmask="255.255.255.0" #Remote access subnet mask. Not used for "dhcp" automatic IP configuration.
ethernetinterface="$(basename "$(find /sys/class/net -maxdepth 1 -mindepth 1 -name "${ethprefix}*")")"
echo "$ethernetinterface"
datum_now=$(date "+%Y.%m.%d")

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

ipv6_apt_live_iso_fix(){
	##Try diabling ipv6 in the live iso if setting the preference to ipv4 doesn't work \
	## to resolve slow apt-get and slow debootstrap in the live Ubuntu iso.
	##https://askubuntu.com/questions/620317/apt-get-update-stuck-connecting-to-security-ubuntu-com
	
	prefer_ipv4(){
		sed -i 's,#precedence ::ffff:0:0/96  100,precedence ::ffff:0:0/96  100,' /etc/gai.conf
	}
	
	dis_ipv6(){
		cat >> /etc/sysctl.conf <<-EOF
			net.ipv6.conf.all.disable_ipv6 = 1
			#net.ipv6.conf.default.disable_ipv6 = 1
			#net.ipv6.conf.lo.disable_ipv6 = 1
		EOF
		tail -n 3 /etc/sysctl.conf
		sudo sysctl -p /etc/sysctl.conf
		sudo netplan apply
	}

	if [ "$ipv6_apt_fix_live_iso" = "yes" ]; then
		prefer_ipv4
		#dis_ipv6
	else
		true
	fi

}

debootstrap_part1_Func(){
	##use closest mirrors
	cp /etc/apt/sources.list /etc/apt/sources.list.bak
	sed -i 's,deb http://security,#deb http://security,' /etc/apt/sources.list ##Uncomment to resolve security pocket time out. Security packages are copied to the other pockets frequently, so should still be available for update. See https://wiki.ubuntu.com/SecurityTeam/FAQ
	sed -i \
		-e 's/http:\/\/archive/mirror:\/\/mirrors/' \
		-e 's/\/ubuntu\//\/mirrors.txt/' \
		-e '/mirrors/ s,main restricted,main restricted universe multiverse,' \
		/etc/apt/sources.list
	cat /etc/apt/sources.list
	
	trap 'printf "%s\n%s" "The script has experienced an error during the first apt update. That may have been caused by a queried server not responding in time. Try running the script again." "If the issue is the security server not responding, then comment out the security server in the /etc/apt/sources.list. Alternatively, you can uncomment the command that does this in the install script. This affects the temporary live iso only. Not the permanent installation."' ERR
	apt update
	trap - ERR	##Resets the trap to doing nothing when the script experiences an error. The script will still exit on error if "set -e" is set.
	
	ssh_Func(){
		##1.2 Setup SSH to allow remote access in live environment
		apt install --yes openssh-server
		service sshd start
		ip addr show scope global | grep inet
	}
	#ssh_Func
	
	
	DEBIAN_FRONTEND=noninteractive apt-get -yq install debootstrap software-properties-common gdisk zfsutils-linux zfs-initramfs
#	if service --status-all | grep -Fq 'zfs-zed'; then
#		systemctl stop zfs-zed
#	fi

	##2 Disk formatting
	
	##2.1 Disk variable name (set prev)
	
	##2.2 Wipe disk 
	
	##Clear partition table
	clear_partition_table "root"
	sleep 2

	##Partition disk
	partitionsFunc(){
		##gdisk hex codes:
		##EF02 BIOS boot partitions
		##EF00 EFI system
		##BE00 Solaris boot
		##BF00 Solaris root
		##BF01 Solaris /usr & Mac Z
		##8200 Linux swap
		##8300 Linux file system
		##FD00 Linux RAID

		case "$topology_root" in
			single|mirror)
				swap_hex_code="8200"
			;;

			raidz*)
				swap_hex_code="FD00"
			;;

			*)
				echo ""
				exit 1
			;;
		esac
		
		while IFS= read -r diskidnum;
		do
			echo "Creating partitions on disk ${diskidnum}."
			##2.3 create bootloader partition
			sgdisk -n1:1M:+"$EFI_boot_size"M -t1:EF00 /dev/disk/by-id/"${diskidnum}"
                        sgdisk -n2:0:+1024M  -t2:8300 -c2:Boot  /dev/disk/by-id/"${diskidnum}"
                        #For a single-disk install:
                        #sgdisk -n2:0:+1024M  -t2:8300 -c2:Boot   /dev/disk/by-id/"${diskidnum}"
		
			##2.4 create swap partition 
			##bug with swap on zfs zvol so use swap on partition:
			##https://github.com/zfsonlinux/zfs/issues/7734
			##hibernate needs swap at least same size as RAM
			##hibernate only works with unencrypted installs
                        sgdisk -n3:0:+"$swap_size"M -t3:"$swap_hex_code" /dev/disk/by-id/"${diskidnum}"


			##2.6 Create root pool partition
			##Unencrypted or ZFS native encryption:

			sgdisk -n4:0:0 -t4:BF00 /dev/disk/by-id/"${diskidnum}"
 partprobe /dev/disk/by-id/"${diskidnum}"
 sgdisk --print /dev/disk/by-id/"${diskidnum}"
		
		done < /tmp/diskid_check_"${pool}".txt
		sleep 2
	}
	partitionsFunc
}

debootstrap_createzfspools_Func(){

	zpool_encrypted_Func(){
		##2.8b create root pool encrypted
		echo Password must be min 8 characters.
		
		zpool_create_temp="/tmp/${RPOOL}_creation.sh"
		cat > "$zpool_create_temp" <<-EOF
			zpool create -f \
				-o ashift=$zfs_rpool_ashift \
				-o autotrim=on \
				-O acltype=posixacl \
				-O canmount=off \
				-O compression=$zfs_compression \
				-O dnodesize=auto \
				-O normalization=formD \
                                -O xattr=sa \
                                -O atime=off \
				-O encryption=aes-256-gcm -O keylocation=prompt -O keyformat=passphrase \
				-O mountpoint=none -R "$mountpoint" \\
		EOF

		add_zpool_disks(){
			while IFS= read -r diskidnum;
			do
				echo "/dev/disk/by-id/${diskidnum}-part4 \\" >> "$zpool_create_temp"
			done < /tmp/diskid_check_root.txt
		
			sed -i '$s,\\,,' "$zpool_create_temp"
		}


		case "$topology_root" in
			single)
				echo "$RPOOL \\" >> "$zpool_create_temp"	
				add_zpool_disks
			;;

			mirror)
				echo "$RPOOL mirror \\" >> "$zpool_create_temp"
				add_zpool_disks
			;;
			
			raidz1)
				echo "$RPOOL raidz1 \\" >> "$zpool_create_temp"
				add_zpool_disks	
			;;

			raidz2)
				echo "$RPOOL raidz2 \\" >> "$zpool_create_temp"
				add_zpool_disks	
			;;

			raidz3)
				echo "$RPOOL raidz3 \\" >> "$zpool_create_temp"
				add_zpool_disks	
			;;

			*)
				echo "Pool topology not recognised. Check pool topology variable."
				exit 1
			;;

		esac
		
	}
	zpool_encrypted_Func
	echo -e "$zfspassword" | sh "$zpool_create_temp" 
	
	##3. System installation
        mountpointsFunc(){

		##zfsbootmenu setup for no separate boot pool
		##https://github.com/zbm-dev/zfsbootmenu/wiki/Debian-Buster-installation-with-ESP-on-the-zpool-disk

		sleep 2
		##3.1 Create filesystem datasets to act as containers
		zfs create -o canmount=noauto -o mountpoint=/ "$RPOOL"/root
		#zfs create -o canmount=off -o mountpoint=none "$RPOOL"/ROOT 

		##3.2 Create root filesystem dataset
#		rootzfs_full_name="ubuntu.$(date +%Y.%m.%d)"
		#zfs create -o canmount=noauto -o mountpoint=/ "$RPOOL"/ROOT/"$rootzfs_full_name" ##zfsbootmenu debian guide
		##assigns canmount=noauto on any file systems with mountpoint=/ (that is, on any additional boot environments you create).
		##With ZFS, it is not normally necessary to use a mount command (either mount or zfs mount). 
		##This situation is an exception because of canmount=noauto.
		zfs mount "$RPOOL"/root
		#zfs mount "$RPOOL"/ROOT/"$rootzfs_full_name"
		#zpool set bootfs="$RPOOL"/ROOT/"$rootzfs_full_name" "$RPOOL"

		##3.3 create datasets
		##Aim is to separate OS from user data.
		##Allows root filesystem to be rolled back without rolling back user data such as logs.
		##https://didrocks.fr/2020/06/16/zfs-focus-on-ubuntu-20.04-lts-zsys-dataset-layout/
		##https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Buster%20Root%20on%20ZFS.html#step-3-system-installation
		##"-o canmount=off" is for a system directory that should rollback with the rest of the system.
	
#		zfs create	"$RPOOL"/srv 						##server webserver content
#		zfs create -o canmount=off	"$RPOOL"/usr
#		zfs create	"$RPOOL"/usr/local					##locally compiled software
		zfs create -o canmount=off -o setuid=off -o exec=off "$RPOOL"/var
		zfs create -o canmount=off "$RPOOL"/var/lib
#		zfs create	"$RPOOL"/var/games					##game files
#		zfs create	"$RPOOL"/var/mail 					##local mails
#		zfs create	"$RPOOL"/var/snap					##snaps handle revisions themselves
#		zfs create	"$RPOOL"/var/spool					##printing tasks
#		zfs create	"$RPOOL"/var/www					##server webserver content


		##USERDATA datasets
		zfs create "$RPOOL"/home
		zfs create -o mountpoint=/root "$RPOOL"/home/root
		chmod 700 "$mountpoint"/root

		##optional
		##exclude from snapshots
		zfs create -o com.sun:auto-snapshot=false "$RPOOL"/var/cache
		zfs create -o com.sun:auto-snapshot=false "$RPOOL"/var/log 					##log files
		zfs create -o com.sun:auto-snapshot=false "$RPOOL"/var/spool 					##spool files
		zfs create -o com.sun:auto-snapshot=false  -o exec=on "$RPOOL"/var/tmp
#		chmod 1777 "$mountpoint"/var/tmp
		zfs create -o canmount=off -o com.sun:auto-snapshot=false "$RPOOL"/var/lib/docker ##Docker manages its own datasets & snapshots

		##Mount a tempfs at /run
#		mkdir "$mountpoint"/run
#		mount -t tmpfs tmpfs "$mountpoint"/run

	}
	mountpointsFunc

}

systemsetupFunc_part0(){

        mkdir -p  "$mountpoint"/boot/efi
mountpoints=/boot/efi
i=0
        while IFS= read -r diskidnum;
        do
#          if (( i > 0 )); then
          if [ "$i" -gt "0" ]; then
            mountpoints=/boot/efi$((i + 1));
          fi
#          echo $mountpoints

          mkfs.ext4 /dev/disk/by-id/"${diskidnum}"-part2
          sleep 2

          mkdosfs -F 32 -s 1 -n EFI  /dev/disk/by-id/"${diskidnum}"-part1
          sleep 2

          if [[ "$i" -eq 0 ]]; then
            mkdir -p  "$mountpoint"/boot
            mount /dev/disk/by-id/"${diskidnum}"-part2 "$mountpoint"/boot
            mkdir -p  "$mountpoint"/boot/efi
            mount /dev/disk/by-id/"${diskidnum}"-part1 "$mountpoint"/boot/efi
          fi
          let "i+=1"
        done < /tmp/diskid_check_root.txt
}


debootstrap_installminsys_Func(){
	##3.4 install minimum system
	##drivesizecheck
	FREE="$(df -k --output=avail "$mountpoint" | tail -n1)"
	if [ "$FREE" -lt 5242880 ]; then               # 15G = 15728640 = 15*1024*1024k
		 echo "Less than 5 GBs free!"
		 exit 1
	fi
	
	debootstrap "$ubuntuver" "$mountpoint"
}

remote_zbm_access_Func(){
  echo "remote_zbm_access_Func"
}

systemsetupFunc_part1(){

	##4. System configuration
	##4.1 configure hostname
	echo "$hostname" > "$mountpoint"/etc/hostname
	echo "127.0.1.1       $hostname" >> "$mountpoint"/etc/hosts

	##4.2 configure network interface

	##get ethernet interface
#	ethernetinterface="$(basename "$(find /sys/class/net -maxdepth 1 -mindepth 1 -name "${ethprefix}*")")"
#	echo "$ethernetinterface"

	##troubleshoot: sudo netplan --debug generate
cat > "$mountpoint"/etc/netplan/01-"$ethernetinterface".yaml <<-EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $ethernetinterface:
      dhcp4: no
      addresses:
        - 192.168.100.10/24
      gateway4: 192.168.100.2
      nameservers:
        addresses:
          - 8.8.8.8
          - 8.8.4.4
EOF

	##4.4 bind virtual filesystems from LiveCD to new system
	mount --rbind /dev  "$mountpoint"/dev
	mount --rbind /proc "$mountpoint"/proc
	mount --rbind /sys  "$mountpoint"/sys 

	chroot "$mountpoint" /bin/bash -x <<-EOCHROOT
		##4.3 configure package sources
		cp /etc/apt/sources.list /etc/apt/sources.bak
		cat > /etc/apt/sources.list <<-EOLIST
			deb http://archive.ubuntu.com/ubuntu $ubuntuver main universe restricted multiverse
			#deb-src http://archive.ubuntu.com/ubuntu $ubuntuver main universe restricted multiverse
			
			deb http://archive.ubuntu.com/ubuntu $ubuntuver-updates main universe restricted multiverse
			#deb-src http://archive.ubuntu.com/ubuntu $ubuntuver-updates main universe restricted multiverse
			
			deb http://archive.ubuntu.com/ubuntu $ubuntuver-backports main universe restricted multiverse
			#deb-src http://archive.ubuntu.com/ubuntu $ubuntuver-backports main universe restricted multiverse
			
			deb http://security.ubuntu.com/ubuntu $ubuntuver-security main universe restricted multiverse
			#deb-src http://security.ubuntu.com/ubuntu $ubuntuver-security main universe restricted multiverse
		EOLIST
		##4.5 configure basic system
		apt update
		
		#dpkg-reconfigure locales
		locale-gen en_US.UTF-8 $locale
		echo 'LANG="$locale"' > /etc/default/locale
		
		##set timezone
		ln -fs /usr/share/zoneinfo/"$timezone" /etc/localtime
		dpkg-reconfigure -f noninteractive tzdata
		
	EOCHROOT
}

systemsetupFunc_part2(){
	chroot "$mountpoint" /bin/bash -x <<-EOCHROOT
		##install zfs
		apt update
		apt install --no-install-recommends -y linux-headers-generic linux-image-generic ##need to use no-install-recommends otherwise installs grub
		
#		apt install --yes --no-install-recommends dkms wget nano htop gdisk
		apt install --yes wget nano htop gdisk openssh-server 
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
cat > /etc/ssh/sshd_config <<-EOF
Include /etc/ssh/sshd_config.d/*.conf
Port 1992
PasswordAuthentication yes
KbdInteractiveAuthentication no
UsePAM yes
X11Forwarding yes
PrintMotd no
AcceptEnv LANG LC_*
Subsystem       sftp    /usr/lib/openssh/sftp-server
EOF
#		apt install -yq software-properties-common
#		DEBIAN_FRONTEND=noninteractive apt-get -yq install zfs-dkms
#		apt install --yes zfsutils-linux
                # zfs-zed
		apt install --yes zfs-initramfs grub-efi-amd64-signed shim-signed
		
	EOCHROOT
}

systemsetupFunc_part3(){

	identify_ubuntu_dataset_uuid

        blkid_part1=""
	blkid_part1="$(blkid -s UUID -o value /dev/disk/by-id/"${DISKID}"-part1)"
	echo "$blkid_part1"

        blkid_part2=""
        blkid_part2="$(blkid -s UUID -o value /dev/disk/by-id/"${DISKID}"-part2)"
        echo "$blkid_part2"


	chroot "$mountpoint" /bin/bash -x <<-EOCHROOT
                echo /dev/disk/by-uuid/"$blkid_part1" /boot/efi vfat defaults 0 0 >> /etc/fstab
                echo /dev/disk/by-uuid/"$blkid_part2" /boot ext4 noatime,nofail,x-systemd.device-timeout=5s 0 1 >> /etc/fstab

#mount /boot
#mount /boot/efi
		if grep /boot/efi /proc/mounts; then
                	echo "/boot/efi mounted."
		else
			echo "/boot/efi not mounted."
			exit 1
		fi
	EOCHROOT
}

systemsetupFunc_part31(){
	echo "systemctl mask grub-initrd-fallback.service"
	if [ "${disks_root}" > "1" ]; then
                chroot "$mountpoint" /bin/bash -x <<-EOCHROOT
			apt install efibootmgr
			systemctl mask grub-initrd-fallback.service
		EOCHROOT
        fi

}

systemsetupFunc_part4(){
	if [ "${remoteaccess_first_boot}" = "yes" ]; then
		remote_zbm_access_Func "chroot"
	fi
}


systemsetupFunc_part5(){
	chroot "$mountpoint" /bin/bash -x <<-EOCHROOT
		##4.11 set root password
		echo -e "root:$PASSWORD" | chpasswd
	EOCHROOT
	
	##4.12 configure swap
	multi_disc_swap_loc="/tmp/multi_disc_swap.sh"
	
	multi_disc_swap_Func(){
		mdadm_level="$1" ##ZFS raidz = MDADM raid5, raidz2 = raid6. MDADM does not have raid7, so no triple parity equivalent to raidz3.
		mdadm_devices="$2" ##Number of disks.
	
		cat > "$multi_disc_swap_loc" <<-EOF
			##Swap setup for mirror or raidz topology.
			apt install --yes cryptsetup mdadm
			##Set MDADM level and number of disks.
			mdadm --create /dev/md0 --metadata=1.2 \
			--level="$mdadm_level" \
			--raid-devices="$mdadm_devices" \\
		EOF
	
		##Add swap disks.
		while IFS= read -r diskidnum;
		do
			echo "/dev/disk/by-id/${diskidnum}-part2 \\" >> "$multi_disc_swap_loc"
		done < /tmp/diskid_check_root.txt
#		sed -i '$s,\\,,' "$zpool_create_temp" ##Remove escape characters needed for last line of EOF code block.
	
		##Update fstab and cryptsetup.
		cat >> "$multi_disc_swap_loc" <<-EOF
			##"plain" required in crypttab to avoid message at boot: "From cryptsetup: couldn't determine device type, assuming default (plain)."
			echo swap /dev/md0 /dev/urandom \
				  plain,swap,cipher=aes-xts-plain64:sha256,size=512 >> /etc/crypttab
			echo /dev/mapper/swap none swap defaults 0 0 >> /etc/fstab
		EOF
		
		##Check MDADM status.
		cat >> "$multi_disc_swap_loc" <<-EOF
			cat /proc/mdstat
			mdadm --detail /dev/md0
		EOF
		
		##Copy MDADM setup file into chroot and run. 
		cp "$multi_disc_swap_loc" "$mountpoint"/tmp/
		chroot "$mountpoint" /bin/bash -x "$multi_disc_swap_loc"
	}
	
	case "$topology_root" in
		single)
			chroot "$mountpoint" /bin/bash -x <<-EOCHROOT
			##Single disk install
			apt install --yes cryptsetup
			##"plain" required in crypttab to avoid message at boot: "From cryptsetup: couldn't determine device type, assuming default (plain)."
			echo swap /dev/disk/by-id/"$DISKID"-part2 /dev/urandom \
				plain,swap,cipher=aes-xts-plain64:sha256,size=512 >> /etc/crypttab
			echo /dev/mapper/swap none swap defaults 0 0 >> /etc/fstab
			EOCHROOT
		;;

		mirror)
			##mdadm --level=mirror is the same as --level=1.
			multi_disc_swap_Func "mirror" "$disks_root"
		;;

		raidz1)
			multi_disc_swap_Func "5" "$disks_root"
		;;

		raidz2)
			multi_disc_swap_Func "6" "$disks_root"
		;;

		raidz3)
			##mdadm has no equivalent raid7 to raidz3. Use raid6.
			multi_disc_swap_Func "6" "$disks_root"
		;;

		*)
			echo "Pool topology not recognised. Check pool topology variable."
			exit 1
		;;

	esac

	chroot "$mountpoint" /bin/bash -x <<-EOCHROOT
		##4.13 mount a tmpfs to /tmp
		cp /usr/share/systemd/tmp.mount /etc/systemd/system/
		systemctl enable tmp.mount
		##4.14 Setup system groups
		addgroup --system lpadmin
		addgroup --system lxd
		addgroup --system sambashare
	EOCHROOT
}


systemsetupFunc_part51(){
	identify_ubuntu_dataset_uuid

	localdiskidnum=
	i=0
        while IFS= read -r diskidnum;
        do
          	if [ "$i" -gt "0" ]; then
			dd if=$localdiskidnum  of=/dev/disk/by-id/"${diskidnum}"-part1
		        mountpoints=/boot/efi$((i + 1));
#			efibootmgr -c -d /dev/disk/by-id/"${diskidnum}" -p 1 -L "ubuntu2" -l '\EFI\ubuntu\shimx64.efi'
			efibootmgr --create --disk /dev/disk/by-id/"${diskidnum}" --label "ubuntu-$((i + 1))" --loader '\EFI\ubuntu\grubx64.efi'

          	fi

	        if [[ "$i" -eq 0 ]]; then
			localdiskidnum=/dev/disk/by-id/"${diskidnum}"-part1
	        fi
        	let "i+=1"
        done < /tmp/diskid_check_root.txt

        chroot "$mountpoint" /bin/bash -x <<-EOCHROOT
                update-initramfs -c -k all
                update-grub
                grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Ubuntu --recheck --no-floppy
	EOCHROOT
}


systemsetupFunc_part6(){
	
	identify_ubuntu_dataset_uuid

	chroot "$mountpoint" /bin/bash -x <<-EOCHROOT
		##5.8 Fix filesystem mount ordering
		
		
		fixfsmountorderFunc(){
			mkdir -p /etc/zfs/zfs-list.cache
			
			
			touch /etc/zfs/zfs-list.cache/$RPOOL
			ln -s /usr/lib/zfs-linux/zed.d/history_event-zfs-list-cacher.sh /etc/zfs/zed.d
			zed -F &
			sleep 2
			
			##Verify that zed updated the cache by making sure this is not empty:
			##If it is empty, force a cache update and check again:
			##Note can take a while. c.30 seconds for loop to succeed.
			cat /etc/zfs/zfs-list.cache/$RPOOL
			while [ ! -s /etc/zfs/zfs-list.cache/$RPOOL ]
			do
				zfs set canmount=noauto $RPOOL/ROOT/${rootzfs_full_name}
				sleep 1
			done
			cat /etc/zfs/zfs-list.cache/$RPOOL	
			
			
			
			##Stop zed:
			pkill -9 "zed*"
			##Fix the paths to eliminate $mountpoint:
			sed -Ei "s|$mountpoint/?|/|" /etc/zfs/zfs-list.cache/$RPOOL
			cat /etc/zfs/zfs-list.cache/$RPOOL
		}
		fixfsmountorderFunc
	EOCHROOT
	
}

systemsetupFunc_part7(){
	identify_ubuntu_dataset_uuid
	chroot "$mountpoint" /bin/bash -x <<-EOCHROOT
		##install samba mount access
#		apt install -yq cifs-utils
		##install openssh-server
		if [ "$openssh" = "yes" ];
		then
			apt install -y openssh-server
		fi

		##6.2 exit chroot
		echo 'Exiting chroot.'
	EOCHROOT

	##Copy script into new installation
	cp "$(readlink -f "$0")" "$mountpoint"/root/
	if [ -f "$mountpoint"/root/"$(basename "$0")" ];
	then
		echo "Install script copied to /root/ in new installation."
	else
		echo "Error copying install script to new installation."
	fi
}

before_reboot(){
mount | grep -v zfs | tac | awk '/\/mnt/ {print $3}' | xargs -i{} umount -lf {}
#for virtual_fs_dir in dev sys proc; do
#    if mountpoint -q "$c_zfs_mount_dir/$virtual_fs_dir"; then
#      echo "Re-issuing umount for $c_zfs_mount_dir/$virtual_fs_dir"
#      umount --recursive --force --lazy "$c_zfs_mount_dir/$virtual_fs_dir"
#    fi
zpool export -a
}
usersetup(){
	##6.6 create user account and setup groups
	zfs create -o mountpoint=/home/"$user" "$RPOOL"/home/${user}

	##gecos parameter disabled asking for finger info
	adduser --disabled-password --gecos "" "$user"
	cp -a /etc/skel/. /home/"$user"
	chown -R "$user":"$user" /home/"$user"
	usermod -a -G adm,cdrom,dip,lpadmin,lxd,plugdev,sambashare,sudo "$user"
	echo -e "$user:$PASSWORD" | chpasswd
}

distroinstall(){
	##7.1 Upgrade the minimal system
	#if [ ! -e /var/lib/dpkg/status ]
	#then touch /var/lib/dpkg/status
	#fi
	apt update 
	
	DEBIAN_FRONTEND=noninteractive apt dist-upgrade --yes
	##7.2a Install command-line environment only
	
	#rm -f /etc/resolv.conf ##Gives an error during ubuntu-server install. "Same file as /run/systemd/resolve/stub-resolv.conf". https://bugs.launchpad.net/ubuntu/+source/systemd/+bug/1774632
	#ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf
	
	if [ "$distro_variant" != "server" ];
	then
		zfs create 	"$RPOOL"/var/lib/AccountsService
	fi

	case "$distro_variant" in
		server)	
			##Server installation has a command line interface only.
			##Minimal install: ubuntu-server-minimal
			apt install --yes ubuntu-server
		;;
		desktop)
			##Ubuntu default desktop install has a full GUI environment.
			##Minimal install: ubuntu-desktop-minimal
			apt install --yes ubuntu-desktop
		;;
		kubuntu)
			##Ubuntu KDE plasma desktop install has a full GUI environment.
			##Select sddm as display manager if asked during install.
			apt install --yes kubuntu-desktop
		;;
		xubuntu)
			##Ubuntu xfce desktop install has a full GUI environment.
			##Select lightdm as display manager if asked during install.
			apt install --yes xubuntu-desktop
		;;
		MATE)
			##Ubuntu MATE desktop install has a full GUI environment.
			##Select lightdm as display manager if asked during install.
			apt install --yes ubuntu-mate-desktop
		;;
		*)
			echo "Ubuntu variant variable not recognised. Check ubuntu variant variable."
			exit 1
		;;
	esac

	##additional programs
	apt install --yes man-db tldr locate
}

logcompress(){
	##7.3 Disable log compression
	for file in /etc/logrotate.d/* ; do
		if grep -Eq "(^|[^#y])compress" "$file" ; then
			sed -i -r "s/(^|[^#y])(compress)/\1#\2/" "$file"
		fi
	done
}

pyznapinstall(){
	##snapshot management
	snapshotmanagement(){
		##https://github.com/yboetz/pyznap
		apt install -y python3-pip
		pip3 --version
		##https://docs.python-guide.org/dev/virtualenvs/
		pip3 install virtualenv
		virtualenv --version
		pip3 install virtualenvwrapper
		mkdir /root/pyznap
		cd /root/pyznap
		virtualenv venv
		source venv/bin/activate ##enter virtual env
		pip install pyznap
		deactivate ##exit virtual env
		ln -s /root/pyznap/venv/bin/pyznap /usr/local/bin/pyznap
		/root/pyznap/venv/bin/pyznap setup ##config file created /etc/pyznap/pyznap.conf
		chown root:root -R /etc/pyznap/
		##update config
		cat >> /etc/pyznap/pyznap.conf <<-EOF
			[$RPOOL/ROOT]
			frequent = 4                    
			hourly = 24
			daily = 7
			weekly = 4
			monthly = 6
			yearly = 1
			snap = yes
			clean = yes
		EOF
		
		cat > /etc/cron.d/pyznap <<-EOF
			SHELL=/bin/sh
			PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
			*/15 * * * *   root    /root/pyznap/venv/bin/pyznap snap >> /var/log/pyznap.log 2>&1
		EOF

		##integrate with apt
		cat > /etc/apt/apt.conf.d/80-zfs-snapshot <<-EOF
			DPkg::Pre-Invoke {"if [ -x /usr/local/bin/pyznap ]; then /usr/local/bin/pyznap snap; fi"};
		EOF
	
		pyznap snap ##Take ZFS snapshots and perform cleanup as per config file.
	}
	snapshotmanagement
}

createsshkey(){
#ssh-keygen -t rsa -N '' -f -b 4096 -C "dynerose@gmail.com"
	mkdir -p /home/"$user"/.ssh
        chmod 700 /home/"$user"/.ssh
        touch /home/"$user"/.ssh/authorized_keys
        chmod 644 /home/"$user"/.ssh/authorized_keys
        chown "$user":"$user" /home/"$user"/.ssh/authorized_keys
	if [ -f /home/"$user"/.ssh/remote_unlock_dropbear*.* ]; then
		rm /home/"$user"/.ssh/remote_unlock_dropbear.pub
	fi
#       ssh-keygen -t rsa -b 4096 -N '' -C "$useremail" -f /home/"$user"/.ssh/remote_unlock_dropbear
        ssh-keygen -t ed25519 -N '' -C "$useremail" -f /home/"$user"/.ssh/remote_unlock_dropbear
        chown "$user":"$user" /home/"$user"/.ssh/remote_unlock_dropbear*.*
        #ssh-copy-id -p 1992 sa@192.168.100.10
        cat /home/$user/.ssh/remote_unlock_dropbear.pub >> /home/"$user"/.ssh/authorized_keys
}

setup_dropbear(){
	if [ -f /etc/dropbear/initramfs/dropbear.conf  ]; then
		echo "dropbear is installed"
	else
		apt install -y dropbear-initramfs
		#	cp /etc/dropbear/initramfs/dropbear.conf /etc/dropbear/initramfs/dropbear.conf.old
		cat > /etc/dropbear/initramfs/dropbear.conf <<-EOF
			DROPBEAR_OPTIONS="-p "$remoteaccess_port" -I 180 -j -k -s"
		EOF
		#	cp /etc/initramfs-tools/initramfs.conf  /etc/initramfs-tools/initramfs.conf.old
		#	cp /etc/initramfs-tools/initramfs.conf /etc/initramfs-tools/initramfs.conf.old
		cat > /etc/initramfs-tools/initramfs.conf <<-EOF
			DEVICE=$ethernetinterface
			IP=$remoteaccess_ip::$remoteaccess_bridge_ip:$remoteaccess_netmask.0::$ethernetinterface:off
		EOF
		update-initramfs -u
		touch /etc/dropbear/initramfs/authorized_key
		chmod 600 /etc/dropbear/initramfs/authorized_key
		cat /home/"$user"/.ssh/remote_unlock_dropbear.pub >> /etc/dropbear/initramfs/authorized_keys
		update-initramfs -u
	fi
}

zfs_unlocks(){
# cat > /usr/share/initramfs-tools/zfsunlock 
echo "Remote access already appears /usr/share/initramfs-tools/zfsunlock"
}

setupremoteaccess(){
	if [ -f /etc/dropbear/initramfs/dropbear.conf ];
#	if [ -f /etc/zfsbootmenu/dracut.conf.d/dropbear.conf ];
	then echo "Remote access already appears to be installed owing to the presence of /etc/dropbear/initramfs/dropbear.conf. Install cancelled."
	else
		disclaimer
		# remote_zbm_access_Func "base"
		# sed -i 's,#dropbear_acl,dropbear_acl,' /etc/zfsbootmenu/dracut.conf.d/dropbear.conf
		createsshkey
		setup_dropbear
		#hostname -I
		echo "Remote unlock zfs access installed. Connect as root on port 2222 during boot: "ssh root@{IP_ADDRESS or FQDN of zfsbootmenu}" -p 2222"
		echo "Your SSH public key must be placed in "/home/$user/.ssh/authorized_keys" prior to reboot or remote access will not work."
		echo "You can add your remote user key from the remote user's terminal using: "ssh-copy-id -i \~/.ssh/id_rsa.pub $user@{IP_ADDRESS or FQDN of the server}""
		echo "Run \"generate-zbm\" after copying across the remote user's public ssh key into the authorized_keys file."
	fi

}

function checker() {
	which "$1" | grep -o "$1" > /dev/null &&  return 0 || return 1
}

setup_kodi(){

	if checker "kodi" == 0 ; then echo "Installed"; 
	else 
		echo "Not Installed!";

apt install -y software-properties-common
add-apt-repository ppa:team-xbmc/ppa
apt install kodi xinit xorg dbus-x11 xserver-xorg-video-intel xserver-xorg-legacy pulseaudio upower -y --no-install-recommends --no-install-suggests
adduser --disabled-password --disabled-login --gecos "" kodi

# add user to groups
usermod -a -G audio,video,input,dialout,plugdev,tty kodi

# edit /etc/X11/Xwrapper.config and replace allowed_users=console for allowed_users=anybody
sed -ie 's/allowed_users=console/allowed_users=anybody/g' /etc/X11/Xwrapper.config

# add to the end of /etc/X11/Xwrapper.config
echo "needs_root_rights=yes" >> /etc/X11/Xwrapper.config

cat > /etc/systemd/system/kodi.service << EOFD
[Unit]
Description = Kodi Media Center

# if you don't need the MySQL DB backend, this should be sufficient
After = systemd-user-sessions.service network.target sound.target

# if you need the MySQL DB backend, use this block instead of the previous
# After = systemd-user-sessions.service network.target sound.target mysql.service
# Wants = mysql.service

[Service]
User = kodi
Group = kodi
Type = simple
#PAMName = login # you might want to try this one, did not work on all systems
ExecStart = /usr/bin/xinit /usr/bin/dbus-launch --exit-with-session /usr/bin/kodi-standalone -- :0 -nolisten tcp vt7
Restart = on-abort
RestartSec = 5

[Install]
WantedBy = multi-user.target
EOFD

# CP powermenu_in_kodi.pkla to the correct place
#cp powermenu_in_kodi.pkla 
cat >/etc/polkit-1/localauthority/50-local.d/powermenu_in_kodi.pkla  << EOFD
/etc/polkit-1/localauthority/50-local.d/powermenu_in_kodi.pkla
[Actions for kodi user]
Identity=unix-user:kodi
Action=org.freedesktop.upower.*;org.freedesktop.consolekit.system.*;org.freedesktop.udisks.*;org.freedesktop.login1.*
ResultAny=yes
ResultInactive=yes
ResultActive=yes
EOFD

apt install -y kodi-vfs-libarchive
# Start Kodi on boot
systemctl enable kodi
fi
zfs snapshot $RPOOL@$datum_now.2.Kodi.Start -r
}


setup_samba(){
        if checker "kodi" == 0 ; then echo "Installed";
        else
		echo "Not Installed!";
#samba-server
		apt install -y samba smbclient cifs-utils
#mkdir /smb-public
#mkdir /smb-private
cp /etc/samba/smb.conf /etc/samba/smb.conf.old
cat > [global] << EOFD
   unix charset = UTF-8
   workgroup = WORKGROUP
   server string = %h server (Samba, Ubuntu)
   log file = /var/log/samba/log.%m
   log level = 1
   max log size = 1000
   logging = file
   panic action = /usr/share/samba/panic-action %d
   server role = standalone server
   obey pam restrictions = yes
   unix password sync = yes
   passwd program = /usr/bin/passwd %u
   passwd chat = *Enter\snew\s*\spassword:* %n\n *Retype\snew\s*\spassword:* %n\n *password\supdated\ssuccessfully* .
   pam password change = yes
   map to guest = bad user
   usershare allow guests = yes


   min protocol = SMB2
# For samba version 4.x, you can set
#	protocol = SMB3
[printers]
   comment = All Printers
   browseable = no
   path = /var/spool/samba
   printable = yes
   guest ok = no
   read only = yes
   create mask = 0700
[print$]
   comment = Printer Drivers
   path = /var/lib/samba/printers
   browseable = yes
   read only = yes
   guest ok = no
[homes]
   comment = Home Directories
   browseable = yes
   read only = no
   create mask = 0700
   directory mask = 0700
   valid users = %S
[publicshare]
   path = /smb-public
   writable = yes
   guest ok = yes
   guest only = yes
   force create mode = 775
   force directory mode = 775
[privateshare]
   path = /smb-private
   writable = yes
   guest ok = no
   valid users = @smbinternal
   force create mode = 770
   force directory mode = 770
   inherit permissions = yes
EOFD
	groupadd smbinternal
	chgrp -R smbinternal /smb-private/
	chgrp -R smbinternal /smb-public
	chmod 2770 /smb-private/
	chmod 2775 /smb-public
	useradd -M -s /sbin/nologin demouser
	usermod -aG smbinternal demouser
	smbpasswd -a demouser
	smbpasswd -e demouser
	testparm
	systemctl enable smbd
	systemctl restart smbd
#	systemctl restart smbd.service

	mkdir /smb-private/demofolder-priv /smb-public/demofolder-pub
	touch /smb-private/demofile-priv /smb-public/demofile-pub
#	ufw allow from 192.168.59.0/24 to any app Samba
fi
}

createutility(){
        if checker "docker" == 0 ; then echo "Installed";
        else
                echo "Not Installed!";
        fi
}

createdocker(){
	if checker "docker" == 0 ; then echo "Installed";
	else
echo "Not Installed!"
sudo apt install -y apt-transport-https ca-certificates curl software-properties-common gnupg lsb-release
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
sudo echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo apt-cache policy docker-ce
sudo apt install -y docker-ce
sudo systemctl status docker
sudo usermod -aG docker ${USER}
su - ${USER}
groups
sudo usermod -aG docker username
#https://www.digitalocean.com/community/tutorials/how-to-install-and-use-docker-on-ubuntu-22-04
systemctl status docker
sudo systemctl start docker.service
sudo systemctl enable docker.service
sudo curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
docker-compose --version
#docker-compose up -d
fi
}


createdatapool(){
	disclaimer
		
	##Check on whether data pool already exists
	if [ "$(zpool status "$datapool")" ];
	then
		echo "Warning: $datapool already exists. Are you use you want to wipe the drive and destroy $datapool? Press Enter to Continue or CTRL+C to abort."
		read -r _
	else true
	fi
	
	##Get datapool disk ID(s)
	getdiskID_pool "data"
	
	##Clear partition table
	clear_partition_table "data"
	sleep 2
	
	##create pool mount point
	if [ -d "$datapoolmount" ]; then
		echo "Data pool mount point exists."
	else
		mkdir -p "$datapoolmount"
		chown "$user":"$user" "$datapoolmount"
		echo "Data pool mount point created."
	fi
		
	##automount with zfs-mount-generator
	#touch /etc/zfs/zfs-list.cache/"$datapool"

	##Set data pool key to use rpool key for single unlock at boot. So data pool uses the same password as the root pool.
	datapool_keyloc="/etc/zfs/$RPOOL.key"
if [ -f $datapool_keyloc ]; then echo "Exists ";
else  echo "Not Exists ";
cat > $datapool_keyloc <<-EOF
$PASSWORD
EOF
fi
	##Create data pool
	create_dpool_Func(){
		echo "$datapoolmount"
		
		zpool_create_temp="/tmp/${datapool}_creation.sh"
		cat > "$zpool_create_temp" <<-EOF
			zpool create \
				-o ashift="$zfs_dpool_ashift" \
				-O acltype=posixacl \
				-O compression="$zfs_compression" \
				-O normalization=formD \
				-O relatime=on \
				-O dnodesize=auto \
				-O xattr=sa \
				-O encryption=aes-256-gcm \
				-O keylocation=file://"$datapool_keyloc" \
				-O keyformat=passphrase \
				-O mountpoint="$datapoolmount" \\
		EOF

		add_zpool_disks(){
			while IFS= read -r diskidnum;
			do
				echo "/dev/disk/by-id/${diskidnum} \\" >> "$zpool_create_temp"
			done < /tmp/diskid_check_data.txt
		
			sed -i '$s,\\,,' "$zpool_create_temp" ##Remove escape characters needed for last line of EOF code block.
		}


		case "$topology_root" in
			single)
				echo "$datapool \\" >> "$zpool_create_temp"	
				add_zpool_disks
			;;

			mirror)
				echo "$datapool mirror \\" >> "$zpool_create_temp"
				add_zpool_disks
			;;
			
			raidz1)
				echo "$datapool raidz1 \\" >> "$zpool_create_temp"
				add_zpool_disks	
			;;

			raidz2)
				echo "$datapool raidz2 \\" >> "$zpool_create_temp"
				add_zpool_disks	
			;;

			raidz3)
				echo "$datapool raidz3 \\" >> "$zpool_create_temp"
				add_zpool_disks	
			;;

			*)
				echo "Pool topology not recognised. Check pool topology variable."
				exit 1
			;;

		esac
	
	}
	create_dpool_Func
	sh "$zpool_create_temp" 
	
	##Verify that zed updated the cache by making sure the cache file is not empty.
#	cat /etc/zfs/zfs-list.cache/"$datapool"
	##If it is empty, force a cache update and check again.
	##Note can take a while. c.30 seconds for loop to succeed.
#	while [ ! -s /etc/zfs/zfs-list.cache/"$datapool" ]
#	do
#		##reset any pool property to update cache files
#		zfs set canmount=on "$datapool"
#		sleep 1
#	done
#	cat /etc/zfs/zfs-list.cache/"$datapool"	
	
	##Create link to datapool mount point in user home directory.
	ln -s "$datapoolmount" "/home/$user/"
	chown -R "$user":"$user" {"$datapoolmount","/home/$user/$datapool"}
	
	zpool status
	zfs list
	
}


##--------
logFunc
date
resettime(){
	##Manual reset time to correct out of date virtualbox clock
	timedatectl
	timedatectl set-ntp off
	sleep 1
	timedatectl set-time "2021-01-01 00:00:00"
	timedatectl
}
#resettime

initialinstall(){
	disclaimer
        mkdir -p "$mountpoint"
echo  mkdir -p "$mountpoint"

	getdiskID_pool "root"
	ipv6_apt_live_iso_fix #Only if ipv6_apt_fix_live_iso variable is set to "yes".
debootstrap_part1_Func
debootstrap_createzfspools_Func
systemsetupFunc_part0

debootstrap_installminsys_Func
systemsetupFunc_part1 #Basic system configuration.#
systemsetupFunc_part2 #Install zfs.

systemsetupFunc_part3 #Format EFI partition. 
systemsetupFunc_part31 #Format EFI boot partition.
#	systemsetupFunc_part4 #Install zfsbootmenu. remote
systemsetupFunc_part5 #Config swap, tmpfs, rootpass.
systemsetupFunc_part51
#	systemsetupFunc_part6 #ZFS file system mount ordering.
#systemsetupFunc_part7 #Samba.
#        before_reboot	
	logcopy(){
		##Copy install log into new installation.
		if [ -d "$mountpoint" ]; then
			cp "$log_loc"/"$install_log" "$mountpoint""$log_loc"
		else 
			echo "No mountpoint dir present. Install log not copied."
		fi
	}
	logcopy
	zfs snapshot $RPOOL@$datum_now.1.Alap -r
	echo "Reboot."
	echo "Post reboot login as root and run script with postreboot function enabled."
	echo "Script should be in the root login dir following reboot (/root/)"
	echo "First login is root:${PASSWORD-}"
}


postreboot(){
	disclaimer
	usersetup #Create user account and setup groups.
#	distroinstall #Upgrade the minimal system.
	logcompress #Disable log compression.
#	dpkg-reconfigure keyboard-configuration && setupcon #Configure keyboard and console.
#	pyznapinstall #Snapshot management.
	
	echo "Install complete: ${distro_variant}."
}

setup_motd(){
apt install -y  figlet toilet
echo nano /etc/ssh/sshd_config
echo    Banner /etc/issue.net
echo nano /etc/issue.net
echo    ##Create a MOTD banner ( optional )
echo #nano  /etc/motd
echo #sudo systemctl reload ssh.service
}

setup_alap(){
echo "1."
apt-get -y install aptitude
apt install -y mc pv htop rsync
echo "2."
apt install -y build-essential
echo "3."
apt install -y net-tools nmap dnsutils
echo "4."
apt install -y curl  git
echo "5."
apt install -y p7zip-full p7zip-rar
software-properties-common sshpass  whois mc
iptables rsync
# cops
apt-get install -y php7.0-gd php7.0-sqlite3 php7.0-json php7.0-intl php7.0-xml php7.0-mbstring php7.0-zip
# apdatapoolmount
BACKUPPATH=$datapoolmount\BACKUPS
mkdir -p $BACKUPPATH
cd $BACKUPPATH
wget https://github.com/teejee2008/aptik/releases/download/v18.8/aptik-v18.8-amd64.deb
dpkg -i aptik-v18.8-amd64.deb
}
setup_alapbeallitasok(){
sysctl -w net.ipv6.conf.all.disable_ipv6=1
sysctl -w net.ipv6.conf.default.disable_ipv6=1
sysctl -w net.ipv6.conf.lo.disable_ipv6=1
}

setup_transmission(){
echo "Setup transmission-daemon"
}

setup_necessary(){
setup_alap
setup_motd
setup_alapbeallitasok
setup_transmission
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
	kodi)
                echo "Setup Kodi"
                read -r _
                setup_kodi
        ;;
	samba)
                echo "Setup Kodi"
                read -r _
                setup_samba
        ;;
        docker)
                echo "Setup Docker"
                read -r _
                createdocker
        ;;
	necessary)
                echo "Setup necessary"
                read -r _
                setup_necessary
        ;;

        vege)
                echo "Setup vege"
                read -r _
		systemsetupFunc_part7
                before_reboot
        ;;

	*)
		echo -e "Usage: $0 initial | postreboot | remoteaccess | datapool | kodi | samba | docker | necessary | vege"
	;;
esac

date
exit 0


#smbclient //sambaserver/share -U sambausername
#Example:
# smbclient //192.168.122.52/user1 -U user1

#You can mount a samba share to a directory in your local Linux system using the mount and cifs type option.
# mkdir -p ~/mounts/shares
# mount -t cifs -o username=user1 //192.168.122.52/user1 ~/mounts/shares
# df -h

#You can use fstab file to persist Samba shares mounting through system reboots. In my example, I have the following line added to the end of /ect/fstab file.
#//192.168.122.52/user1  /mnt/shares cifs credentials=/.sambacreds 0 0
