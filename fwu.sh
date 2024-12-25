#!/bin/sh
exec 2>/dev/null
# luna firmware upgrade  script
# $1 image destination (0 or 1) 
# Kernel and root file system images are assumed to be located at the same directory named uImage and rootfs respectively
# ToDo: use arugements to refer to kernel/rootfs location.

d_img="dtb"
d_vol="ubi_DTB"
k_img="kimage"
u_img="uImage"
k_vol="ubi_k"
r_img="rootfs"
r_vol="ubi_r"
b_img="encode_uboot.img"
img_ver="fwu_ver"
md5_cmp="md5.txt"
md5_cmd="/bin/md5sum"
nandwrite_cmd="/bin/nandwrite"
new_fw_ver="new_fw_ver.txt"
cur_fw_ver="cur_fw_ver.txt"
env_sw_ver="env_sw_ver.txt"
hw_ver_file="hw_ver"
skip_hwver_check="/tmp/skip_hwver_check"
skip_swver_check="/tmp/skip_swver_check"

# For CMCC
o_img="osgi.img"
osgi_vol="ubi_osgi"
osgi_install_prebundle=0
install_prebundle_flag="install_prebundle_flag"
osgi_partition_prebundle_dir="/usr/local/class/prebundle"
osgi_var_prebundle_dir="/var/osgi_app/prebundle"
osgi_var_runbundle_dir="/var/osgi_app/bundle"
osgi_var_intall_prebundle="/var/osgi_app/install_prebundle_flag"
osgi_var_no_osgi_partition="/var/osgi_app/osgi_no_Partition"

# For YueMe/CU framework
framework_img="framework.img"
framework_sh="framework.sh"
framework_vol="ubi_framework1"

# For FTTR Master FPGA bitfile
fpga_img="fpgafs"
fpga_vol="ubi_fpga"

arg1="$1"
arg2="$2"

do_update_framework() {
	tar_file=$2
	if [ "`tar -tf $tar_file $framework_sh`" = "$framework_sh" ] && [ "`tar -tf $tar_file $framework_img`" = "$framework_img" ]; then
		echo "Updaing framework from $tar_file !!"
		tar -xf $tar_file $framework_sh

		# Run firmware upgrade script extracted from image tar ball
		sh $framework_sh $tar_file
		
		rm $framework_sh
	fi
}

do_update_fpga() {
	tar_file=$2
	if [ "`tar -tf $tar_file $fpga_img`" = "$fpga_img" ]; then
		do_update_img "${tar_file}" "${fpga_img}" "${fpga_vol}"
	fi
}

do_update_osgi() {
	img_num=$1
	tar_file=$2
	
	vdimg=$(get_vol_num_from_vol_name "0" "${osgi_vol}")
	if [ $? != 0 ] || [ ! -e "${vdimg}" ]; then
		# echo "Ignore update OSGI !!"
		return 0
	fi

	size=$(tar -tvf "${tar_file}" "${o_img}")
	if [ $? = 0 ]; then
		osgi_upgraded=1
		rm -rf $osgi_var_no_osgi_partition
	else
		touch $osgi_var_no_osgi_partition
	fi
	
	size=$(tar -tvf "${tar_file}" "${install_prebundle_flag}")
	if [ $? = 0 ]; then
		osgi_install_prebundle=1
		touch $osgi_var_intall_prebundle
		flash set CMCC_JAR_LINK 0
	fi
	
	if [ -d $osgi_var_prebundle_dir ]; then
		echo "/var/osgi_app/prebundle exist!"
	else
		# mkdir $osgi_var_prebundle_dir
		# cp -rf $osgi_partition_prebundle_dir/* $osgi_var_prebundle_dir
		# rm -rf $osgi_var_runbundle_dir
		flash set CMCC_JAR_LINK 0
		echo "Copy prebundles from OSGI partition to /var/osgi_app/prebundle"
	fi
	
	if [ $osgi_upgraded = 1 ]; then
		killall -9 java
		sleep 1
		umount /usr/local
		do_update_img "${tar_file}" "${o_img}" "${osgi_vol}"
	fi
}

do_hwver_check() {
	if [ -f $skip_hwver_check ]; then
		echo "Skip HW_VER check!!"
	else
		img_hw_ver=`tar -xf $2 $hw_ver_file -O`
		mib_hw_ver=`flash get HW_HWVER | sed s/HW_HWVER=//g`
		if [ "$img_hw_ver" = "skip" ]; then
				echo "skip HW_VER check!!"
		else
				echo "img_hw_ver=$img_hw_ver mib_hw_ver=$mib_hw_ver"
				if [ "$img_hw_ver" != "$mib_hw_ver" ]; then
						echo "HW_VER $img_hw_ver inconsistent, aborted image updating !"
						echo "4001" > /tmp/check_status
						if [ -f /config/ota_check ]; then
							cp /tmp/check_status /config/ota_check
						fi
						exit 1
				fi
		fi
	fi
}

BOOT_MTD=/dev/mtd0
do_update_preloader(){
	tar_file=$2
	tar -xf ${tar_file} $b_img 2> /dev/null
	if [ ! -f "$b_img" ]; then
		return 0
	fi
	
	size=$(tar -tvf "${tar_file}" "$b_img")
	IFS=" "
	set -- ${size}
	size=$3
	
	chk_size=$(cat /proc/mtd | grep "\"boot\"")
	IFS=" "
	set -- ${chk_size}
	chk_size=$(printf %d 0x$2)
	if [ $size -gt ${chk_size} ]; then
		echo "Error size(${size}) of $b_img was over the limit size(${chk_size}) !!"
		rm $b_img
		return 1;
	fi

	if [ -f "./nandwrite" ]; then
		nandwrite_cmd="./nandwrite"
		chmod +x ./nandwrite
	fi
	if [ ! -f "$nandwrite_cmd" ]; then
		echo "No nandwrite command!"
		rm $b_img
		return 1;
	fi
	echo 0 > /proc/spi_nand/protected
	echo "Erase bootloader setction"
	flash_eraseall ${BOOT_MTD}
	echo "Write bootloader!"
	$nandwrite_cmd --noecc --oob ${BOOT_MTD} $b_img
	rm $b_img
	return 0
}

do_check_img_md5() {
	tar_file=$1
	img_file=$2
	cmp_file=$3
	
	size=$(tar -tf "${tar_file}" "${img_file}")
	if [ $? != 0 ]; then
		return 0
	fi
	img_sum=$(tar -xf "${tar_file}" "${img_file}" -O | md5sum)
	img_sum=${img_sum// */}
	img_chk=$(grep ${img_file} ${cmp_file})
	img_chk=${img_chk// */}
	if [ "${img_chk}" = "${img_sum}" ]; then
		return 0
	fi
	echo "${img_file} md5_sum inconsistent, aborted image updating !"
	echo "5001" > /tmp/check_status
	if [ -f /config/ota_check ]; then
		cp /tmp/check_status /config/ota_check
	fi
	exit 1
}

do_extract_img_md5() {
	img_num=$1
	tar_file=$2
	
	# Extract bootloader image
	do_check_img_md5 $tar_file $b_img $md5_cmp
	
	# Extract DTB image
	do_check_img_md5 $tar_file $d_img $md5_cmp
	
	# Extract kernel image
	do_check_img_md5 $tar_file $k_img $md5_cmp
	
	# Extract rootfs image
	do_check_img_md5 $tar_file $r_img $md5_cmp
	
	# Extract osgi image
	do_check_img_md5 $tar_file $o_img $md5_cmp
	
	# Extract framework image
	do_check_img_md5 $tar_file $framework_img $md5_cmp
	do_check_img_md5 $tar_file $framework_sh $md5_cmp
	
	echo "Integrity of image is okay."
}

genFwVersion()
{
	local s=${1#V}
	local s=${s//-*/} # remove possible date information e.g. V4.0.0-230419
	local n=0
	local i=0
	while [ ! $i = 5 ]
	do
		v=${s##*.}
		n=$(($n+($v<<(($i)*8))))
		if [ "$s" = "${s%.*}" ]; then
			break
		fi
		s=${s%.*}
		i=$(($i+1))
	done
	echo $n
}

do_firware_ver_chk() {
	# Check upgrade firmware's version with current firmware version
	
	tar -xf $2 $img_ver
	if [ $? != 0 ]; then
		echo "1" > /var/firmware_upgrade_status
		echo "Firmware version incorrect: no fwu_ver in img.tar !"
		echo "6001" > /tmp/check_status
		if [ -f /config/ota_check ]; then
			cp /tmp/check_status /config/ota_check
		fi
		exit 1
	fi
	
	PROVINCE_NAME=$(/etc/scripts/flash get "HW_PROVINCE_NAME" | awk -F'=' '{print $2}')
	if  [ -n "$PROVINCE_NAME" ]; then
		cat $img_ver | grep $PROVINCE_NAME | awk -F'   ' '{print $2}' > $new_fw_ver
		if [ -s $new_fw_ver ]; then
			echo ""
		else
			head -1 $img_ver > $new_fw_ver
		fi
		cat /etc/version | grep $PROVINCE_NAME | awk -F'   ' '{print $2}'> $cur_fw_ver
		if [ -s $cur_fw_ver ]; then
			echo ""
		else
			head -1 /etc/version > $cur_fw_ver
		fi
	else
		head -1 $img_ver >$new_fw_ver
		head -1 /etc/version > $cur_fw_ver
	fi

	if [ -f $skip_swver_check ]; then
		echo "Skip SW_VER check!!"
		return 0
	fi

	cur_fw_ver_str=$(cat $cur_fw_ver)
	cur_fw_ver_str=${cur_fw_ver_str//--*/}
	new_fw_ver_str=$(cat $new_fw_ver)
	new_fw_ver_str=${new_fw_ver_str//--*/}

	echo $new_fw_ver_str | grep -n '^V[0-9]\+.[0-9]\+.[0-9]\+' 
	if [ $? != 0 ]; then
		echo "1" > /var/firmware_upgrade_status
		echo "Firmware version incorrect: `cat $new_fw_ver` !"
		echo "6002" > /tmp/check_status	
		if [ -f /config/ota_check ]; then
			cp /tmp/check_status /config/ota_check
		fi	
		exit 1
	fi

	echo "Try to upgrade firmware version from $cur_fw_ver_str"
	echo "                                  to $new_fw_ver_str"
	
	cur_fw_ver_num=$(genFwVersion $cur_fw_ver_str)
	new_fw_ver_num=$(genFwVersion $new_fw_ver_str)
	
	if [ "$cur_fw_ver_str" == "$new_fw_ver_str" ]; then
		# echo "4" > /var/firmware_upgrade_status
		echo "Current firmware version is already $cur_fw_ver_str !"
		# echo "6003" > /tmp/check_status
		if [ -f /config/ota_check ]; then
			cp /tmp/check_status /config/ota_check
		fi
		# exit 1
	fi		

	echo "Firware version check okay."
}

do_version_check() {
	img_num=$1
	tar_file=$2
	
	size=$(tar -tf "${tar_file}" "$r_img" > /dev/null)
	if [ $? != 0 ]; then
		echo "Ignore version check !!"
		return 0
	fi
	
	do_hwver_check "$arg1" "$arg2"
	do_firware_ver_chk "$arg1" "$arg2"
}

do_update_mtd_mount_check() {
	local mtd_name=$1
	local dev_path
	local info
	
	info=$(cat /proc/mtd | grep "\"${mtd_name}\"")
	if [ $? != 0 ]; then
		echo "No found ${mtd_name} ..."
		return 1
	fi
	IFS=" "
	set -- ${info}
	info=$1

	dev_path=${info/mtd/}
	dev_path=${dev_path//:}
	dev_path=/dev/mtdblock${dev_path}
	if [ -e ${dev_path} ]; then
		cat /proc/mounts | grep "${dev_path}" &> /dev/null
		if [ $? = 0 ]; then
			echo "The ${mtd_name}(${dev_path}) was mounted !!"
			echo "umount ${dev_path} ..."
			umount ${dev_path}
			if [ $? != 0 ]; then
				echo "fail to umount ${dev_path} !!"
				return 1
			fi
		fi
	else
		echo "No found ${mtd_name}(${dev_path}) ..."
		return 1
	fi
	return 0
}

get_vol_num_from_vol_name() {
	dev_num="$1"
	vol_name="$2"
	info=$(ubinfo -d "${dev_num}" -N "${vol_name}")
	if [ $? != 0 ]; then
		return 1
	fi
	set $info
	echo "/dev/ubi${dev_num}_$3"
	return 0
}

do_img_space_check() {
	tar_file=$1
	img_file=$2
	mtd_dev=$3
	
	size=$(tar -tvf "${tar_file}" "${img_file}")
	if [ $? != 0 ]; then
		return 0
	fi
	IFS=" "
	set -- ${size}
	size=$3
	
	info=$(ubinfo -d 0 -N "${mtd_dev}" | grep "Type:")
	if [ $? = 0 ] && [ ! "${info//dynamic/}" = "${info}" ]; then
		chk_size=$(cat /proc/mtd | grep "${mtd_dev}")
		IFS=" "
		set -- ${chk_size}
		chk_size=$(printf %d 0x$2)
		if [ ! $size -gt ${chk_size} ]; then
			return 0
		fi
		echo "Error size(${size}) of ${img_file} was over the limit size(${chk_size}) of partion ${mtd_dev} !!"
		echo "7001" > /tmp/check_status
		if [ -f /config/ota_check ]; then
			cp /tmp/check_status /config/ota_check
		fi
	else
		echo "ignore check size of ${img_file} !!"
		return 0
	fi

	echo "3" > /var/firmware_upgrade_status
	exit 1
}

do_extract_space_check() {
	img_num=$1
	tar_file=$2
	
	# Extract kernel image
	do_img_space_check $tar_file $d_img "${d_vol}${img_num}"
	
	# Extract kernel image
	do_img_space_check $tar_file $k_img "${k_vol}${img_num}"
	
	# Extract rootfs image
	do_img_space_check $tar_file $r_img "${r_vol}${img_num}"
	
	# Extract osgi image
	do_img_space_check $tar_file $o_img "${osgi_vol}"
	
	# Extract framework image
	do_img_space_check $tar_file $framework_img "${framework_vol}"
	
	echo "Check firmware size is okay, start updating ..."
}

do_update_img() {
	tar_file=$1
	img_file=$2
	mtd_dev=$3
	ret=0

	size=$(tar -tvf "${tar_file}" "${img_file}")
	if [ $? != 0 ]; then
		return 0
	fi
	IFS=" "
	set -- ${size}
	size=$3
	if [ ! $size -gt 0 ]; then
		echo "Error File Size of ${img_file}, aborted image updating !"
		return 1
	fi
	
	vdimg=$(get_vol_num_from_vol_name "0" "${mtd_dev}")
	if [ $? != 0 ] || [ ! -e "${vdimg}" ]; then
		echo "Error Partition of ${mtd_dev}, aborted image updating !"
		return 1
	fi
	
	do_update_mtd_mount_check "${mtd_dev}"
	if [ $? != 0 ]; then
		echo "Error check, aborted image updating !"
		return 1
	fi
	
	tar -xf "${tar_file}" "${img_file}" -O | ubiupdatevol "${vdimg}" - -s $size
	if [ $? != 0 ]; then
		echo "Error Update image of ${img_file} to ${mtd_dev}, aborted image updating !"
		echo "8001" > /tmp/check_status
		if [ -f /config/ota_check ]; then
			cp /tmp/check_status /config/ota_check
		fi
		return 1
	fi
	
	echo "Success updated image ${img_file} to ${mtd_dev}(${vdimg}) !!"
	return 0
}

do_extract_and_update_img() {
	echo "---write flash 1\n"
	echo "1" > /tmp/upgrade_status
	FILE=/tmp/uSleepFlag1

	i=0
	while [ $i -lt 5 ]; do
		if [ -f "$FILE" ]; then
			break
		fi		
		echo "---i=$i---"
		let i++
		#i=$($i+1)	
		echo "---usleepflag1 doesn't exist,sleep 1"
		sleep 1
	done
	
	img_num=$1
	tar_file=$2

	do_update_img "${tar_file}" "${d_img}" "${d_vol}${img_num}"

	do_update_img "${tar_file}" "${k_img}" "${k_vol}${img_num}"

	do_update_img "${tar_file}" "${r_img}" "${r_vol}${img_num}"
	echo "2" > /tmp/upgrade_status
	echo "---write flash 2\n"
}

write_ver_record_and_clean() {

	if [ -f $new_fw_ver ]; then
		cat $new_fw_ver | grep CST
		if [ $? = 0 ]; then
			echo `cat $new_fw_ver` | sed 's/ *--.*$//g' > $env_sw_ver
		else
			cat $new_fw_ver > $env_sw_ver
		fi
		# Write image version information 
		nv setenv sw_version"$1" "`cat $env_sw_ver |awk -F- '{print $1}'`"
	fi

	#lgh add, for ihgu profile(include CONFIG_E8B) to pass "GuangDian Network test"
	ver="`cat $env_sw_ver|cut -d'-' -f1`"
	if [ -n $ver ]; then
		mib set PROVINCE_SW_VERSION $ver
		mib commit
	fi
	
	#omci
	SWACTIVE=$(/bin/nv getenv sw_active | awk -F'=' '{print $2}') 
	if [ "$SWACTIVE" == "1" ]; then
	        $FLASH set "OMCI_SW_VER1" $ver
	        mib set "OMCI_SW_VER1" $ver
	else
	        $FLASH set "OMCI_SW_VER2" $ver
	        mib set "OMCI_SW_VER2" $ver
	fi
	mib commit
	
	
	# Clean up temporary files
	rm -f $md5_cmp $img_ver $new_fw_ver $cur_fw_ver $env_sw_ver $2

	# Post processing (for future extension consideration)

	echo "Successfully updated image $1!!"
}

do_check_kimage_name() {
	img_num=$1
	tar_file=$2
	
	size=$(tar -tvf "${tar_file}" "${u_img}")
	if [ $? = 0 ]; then
		k_img=${u_img}
	fi
}

main() {
	do_check_kimage_name "$arg1" "$arg2"
	do_extract_img_md5 "$arg1" "$arg2"
	do_version_check "$arg1" "$arg2"
	do_update_preloader "$arg1" "$arg2"
	do_extract_space_check "$arg1" "$arg2"
	do_update_osgi "$arg1" "$arg2"
	do_update_framework "$arg1" "$arg2"
	do_update_fpga "$arg1" "$arg2"
	do_extract_and_update_img "$arg1" "$arg2"
	write_ver_record_and_clean "$arg1" "$arg2"
}

main

# Stop this script upon any error
# set -e

