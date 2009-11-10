#!/bin/bash

####################################################################### 
#
# Generation of a deployment kernel/ramdisk :
# 1. Downloads a fresh kernel from kernel.org
# 2. Let the user configure in the kernel
# 3. Builds kernel
# 4. Builds ramdisk and includes the kadeploy ramdisk base
#
# !! Must be run with root rights !!
#
#######################################################################

PATH=/bin:/sbin:/usr/bin:/usr/sbin

# Fill-in these values (absolute path is needed)
KERNEL_CONFIG=""
KERNEL_VERSION=""
OUTPUT_KERNEL="deploy-vmlinuz"
OUTPUT_INITRD="deploy-initrd"
KERNEL_2_6_ARCHIVE_URL="http://www.eu.kernel.org/pub/linux/kernel/v2.6/"

# Ramdisk size in Ko
INITRD_SIZE="200000"
INITRD_ROOTDEVICE="/dev/ram0"

# For // kernel compilation
NUMBER_OF_CPU=2
NUMBER_OF_CORE=2
COMPILATION_PARALLELISM=$(( ${NUMBER_OF_CPU} * ${NUMBER_OF_CORE} ))

# TMP_INITRD=$OUTPUT_INITRD.uncompressed
CURRENT_DIR=$( pwd )
TODAY=$( date +%Y%m%d-%H%M-%N )
CURRENT_BUILTDIR="$CURRENT_DIR/built-$TODAY"
TMP_ROOTDIR="/tmp"
RD_MOUNT="$TMP_ROOTDIR/__mountrd"
RD_FILE="$TMP_ROOTDIR/initrd.build"
TMP_KERNELDIR="$TMP_ROOTDIR/__buildkernel"

DEBOOTSTRAP=debootstrap

Die()
{
  echo "(!!) Error : $1" && exit 1
}

Info()
{
  echo "(II) $1 ..."
}

Warn()
{
  echo "(WW) $1 !"
}

Banner()
{
  echo -e "\n\n\t=== $1 ===\n"
}

CreateInitrd()
{
  local initrd_size=""

  Banner "Deployment ramdisk creation"
  echo -en "- Enter INITRD size (in Ko / default = 200000 Ko) : "
  read initrdsize
  if [ -z "$initrdsize" ]; then
    initrdsize=${INITRD_SIZE}
  fi
   
  if [ ! -d "$RD_MOUNT" ]; then
    mkdir "$RD_MOUNT" || Die "Failed to create $RD_MOUNT"
  fi

  Info "Creating empty ramdisk file"
  dd if=/dev/zero of=${RD_FILE} bs=1024 count=${initrdsize} 2>&1 >/dev/null || Die "Failed to create empty ramdisk FS"
  mkfs.ext2 -F -q ${RD_FILE} 2>&1 >/dev/null || Die "Failed to format $RD_FILE"
  tune2fs -c 0 ${RD_FILE} 2>&1 >/dev/null
  mount -o loop -t ext2 ${RD_FILE} ${RD_MOUNT} || Die "Unable to mount empty ramdisk loopback file"

  Info "Copying debootstrap"
  (cd $DEBOOTSTRAP; tar cO .) | (cd ${RD_MOUNT}; tar xvf -)
}

GrabKernelArchive()
{
  if [ ! -d "$TMP_KERNELDIR" ]; then 
    mkdir "$TMP_KERNELDIR" || Die "Failed to create $TMP_KERNELDIR"
  fi
  
  Banner "Retrieving linux kernel"
  echo -en "- Enter wanted version of kernel : "

  while true; do
    read KERNEL_VERSION
    if [ -f "$CURRENT_DIR/linux-$KERNEL_VERSION.tar.bz2" ]; then
      Info "linux-$KERNEL_VERSION already grabbed"
      break
    else
      wget --verbose --progress=bar "${KERNEL_2_6_ARCHIVE_URL}/linux-${KERNEL_VERSION}.tar.bz2"
      if [ "$?" -eq 0 ]; then
        break
      else
        echo 
        Warn "Previous entry is not a valid version !"
        echo -en "- Please enter a valid kernel version number : "
      fi
    fi
  done

  Info "Decompressing kernel archive"
  ( bzip2 -cd $CURRENT_DIR/linux-${KERNEL_VERSION}.tar.bz2|tar -C $TMP_KERNELDIR -xvf - 2>&1 >/dev/null ) || ( CleanOut && Die "Failed to decompress kernel archive" )

}

BuildKernel()
{  
  Banner "Kernel build"

  echo -en "- Enter pathname of a kernel config file or [Return] otherwise (use defaults) : "
  read configfile

  while true; do
    if [ -z "$configfile" ]; then
      Info "Trying to launch kernel configuration utility..."
      ( cd ${TMP_KERNELDIR}/linux-${KERNEL_VERSION} && make menuconfig ) || ( CleanOut && Die "Failed to run kernel menuconfig" )
      break
    elif [ ! -f "$configfile" ]; then
       Warn "$configfile : not a valid kernel config file"
       echo -en "- Enter pathname of a kernel config file or [Return] otherwise (use defaults) : "
       read configfile
    else
      echo -en "Do you wish to setup manually new kernel options (Y/n) ? "
      read rep
      case "$rep" in
        N|n|No|no|non|Non)
	  ( cd ${TMP_KERNELDIR}/linux-${KERNEL_VERSION} && KCONFIG_ALLCONFIG=${configfile} make allmodconfig 2>&1 >/dev/null ) || ( CleanOut && Die "Failed to run : make allmodconfig" )
	  ;;
	*)
	  cp ${configfile} ${TMP_KERNELDIR}/linux-${KERNEL_VERSION}/.config
	  ( cd ${TMP_KERNELDIR}/linux-${KERNEL_VERSION} && make silentoldconfig && make menuconfig ) || ( CleanOut && Die "Failed to run kernel menuconfig" )
	  ;;
      esac
      break
    fi
  done


  cd ${TMP_KERNELDIR}/linux-${KERNEL_VERSION}/
  make oldconfig
  Info "Making bzImage"
  make -j${COMPILATION_PARALLELISM} bzImage 2>&1 >/dev/null || ( CleanOut && Die "Failed to make bzImage" )
  
  Info "Making modules"
  make -j${COMPILATION_PARALLELISM} modules 2>&1 >/dev/null || ( CleanOut && Die "Failed to make modules" )
  
  Info "Making kernel install to ${CURRENT_BUILTDIR}"
  INSTALL_PATH=${CURRENT_BUILTDIR} make install  || ( CleanOut && Die "Failed to make kernel installation in ${CURRENT_BUILTDIR}" )

  Info "Making modules install to ${RD_MOUNT}"
  INSTALL_MOD_PATH=${RD_MOUNT} make modules_install || ( CleanOut && Die "Failed to make modules installation in ${RD_MOUNT}" )

  cp ${CURRENT_BUILTDIR}/vmlinuz-${KERNEL_VERSION} ${CURRENT_BUILTDIR}/${OUTPUT_KERNEL}-${KERNEL_VERSION}
  rdev ${CURRENT_BUILTDIR}/${OUTPUT_KERNEL}-${KERNEL_VERSION} ${INITRD_ROOTDEVICE}
  cd "${RD_MOUNT}/lib/modules" && depmod -b ${RD_MOUNT} ${KERNEL_VERSION}
  
  Info "Deployment kernel built : ${CURRENT_BUILTDIR}/${OUTPUT_KERNEL}-${KERNEL_VERSION}"
  Info "The kernel config file used for building : ${CURRENT_BUILTDIR}/config-${KERNEL_VERSION}"
}

BuildInitrd()
{
  df -h
  cd ${CURRENT_DIR} && umount ${RD_MOUNT}
  cat ${RD_FILE} | gzip -9 -c > "${CURRENT_BUILTDIR}/${OUTPUT_INITRD}-${KERNEL_VERSION}"
  
  Info "Ramdisk built : ${CURRENT_BUILTDIR}/${OUTPUT_INITRD}-${KERNEL_VERSION}"
}


CleanOut()
{
  Banner "Cleaning out temporary files"

  local mounted=$( mount|grep $RD_MOUNT )
  if [ -n "$mounted" ]; then
    ( cd ${CURRENT_DIR} && umount ${RD_MOUNT} ) || Warn "Failed to unmount ${RD_MOUNT}"
  fi
  rm -rf ${TMP_KERNELDIR} || Warn "Failed to remove kernel build directory ${TMP_KERNELDIR}"
  rm -rf ${RD_MOUNT} || Warn "Failed to remove initrd build directory ${RD_MOUNT}"
  rm -f ${RD_FILE} || Warn "Failed to remove initrd loopback file ${RD_FILE}"
  # rm -f "${CURRENT_BUILTDIR}/vmlinuz*" 2>&1 >/dev/null || Warn "Failed to rm ${CURRENT_BUILTDIR}/vmlinuz* files" 
  # rm -f "${CURRENT_BUILTDIR}/System.map*" 2>&1 >/dev/null || Warn "Failed to rm ${CURRENT_BUILTDIR}/System.map* files"
  
  return 0

}

Exit_handler()
{
  # Disables signals trap
  # Ctrl-C / INTerrupt
  trap 2 
  # TERMinate
  trap 15
  
  echo
  CleanOut && Die "Script interrupted ; exiting ..."
}

Main()
{
  # For INT/TERM signals handling
  trap Exit_handler 2 15
  
  if [ ! -d "$CURRENT_BUILTDIR" ]; then
    mkdir ${CURRENT_BUILTDIR}
  fi

  # Builds deployment environment
  CreateInitrd  
  GrabKernelArchive 
  BuildKernel
  BuildInitrd

  # Cleaning temporary files and mount
  CleanOut
  
  exit 0
  
}

Main $*

