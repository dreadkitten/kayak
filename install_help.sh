#!/usr/bin/bash

LOG_SETUP=0

ConsoleLog(){
  exec 4>/dev/console
  exec 1>${1}
  exec 2>${1}
  INSTALL_LOG=${1}
}
CopyInstallLog(){
  if [[ -n "$INSTALL_LOG" ]]; then
    cp $INSTALL_LOG $ALTROOT/var/log/install/kayak.log
  fi
}
OutputLog(){
  if [[ "$LOG_SETUP" -eq "0" ]]; then
    open 4>/dev/null
    LOG_SETUP=1
  fi
}
log() {
  TS=`date +%Y/%m/%d-%H:%M:%S`
  echo "[$TS] $*" 1>&4
  echo "[$TS] $*"
}
bomb() {
  log
  log ======================================================
  log "$*"
  log ======================================================
  if [[ -n "$INSTALL_LOG" ]]; then
  log "For more information, check $INSTALL_LOG"
  log ======================================================
  fi
  exit 1
}

. /kayak/net_help.sh
. /kayak/disk_help.sh

ICFILE=/tmp/_install_config
getvar(){
  prtconf -v /devices | sed -n '/'$1'/{;n;p;}' | cut -f2 -d\'
}

# Blank
ROOTPW='$5$kr1VgdIt$OUiUAyZCDogH/uaxH71rMeQxvpDEY2yX.x0ZQRnmeb9'
RootPW(){
  ROOTPW="$1"
}
SetRootPW(){
  sed -i -e 's%^root::%root:'$ROOTPW':%' $ALTROOT/etc/shadow
}
ForceDHCP(){
  /sbin/ifconfig -a plumb 2> /dev/null
  /sbin/ifconfig -a dhcp
}

BuildBE() {
  MEDIA=`getvar install_media`
  zfs set compression=on rpool
  zfs create rpool/ROOT
  zfs set canmount=off rpool/ROOT
  zfs set mountpoint=legacy rpool/ROOT
  log "Receiving image: $MEDIA"
  curl -s $MEDIA | pv -B 128m | bzip2 -dc | zfs receive -u rpool/ROOT/omnios
  zfs set canmount=noauto rpool/ROOT/omnios
  zfs set mountpoint=legacy rpool/ROOT/omnios
  log "Cleaning up boot environment"
  beadm mount omnios /mnt
  ALTROOT=/mnt
  cp $ALTROOT/lib/svc/seed/global.db $ALTROOT/etc/svc/repository.db
  chmod 0600 $ALTROOT/etc/svc/repository.db
  chown root:sys $ALTROOT/etc/svc/repository.db
  /usr/sbin/devfsadm -r /mnt
  [[ -L $ALTROOT/dev/msglog ]] || \
    ln -s ../devices/pseudo/sysmsg@0:msglog $ALTROOT/dev/msglog
  zfs destroy omnios@kayak
}

FetchConfig(){
  ETHER=`Ether`
  CONFIG=`getvar install_config`
  L=${#ETHER}
  while [[ "$L" -gt "0" ]]; do
    URL="$CONFIG/${ETHER:0:$L}"
    log "... trying $URL"
    /bin/curl -s -o $ICFILE $URL
    if [[ -f $ICFILE ]]; then
      if [[ -n $(grep BuildRpool $ICFILE) ]]; then
        log "fetched config."
        return 0
      fi
      rm -f $ICFILE
    fi
    L=$(($L - 1))
  done
  return 1
}

MakeBootable(){
  log "Making boot environment bootable"
  mkdir -p /rpool/boot/grub/bootsign || bomb "mkdir rpool/boot/grub failed"
  touch /rpool/boot/grub/bootsign/pool_rpool || bomb "making bootsign failed"
  chown -R root:root /rpool/boot || bomb "rpool/boot chown failed"
  chmod 444 /rpool/boot/grub/bootsign/pool_rpool || bomb "chmod bootsign failed"
  for f in capability menu.lst splash.xpm.gz ; do
    cp -p $ALTROOT/boot/grub/$f /rpool/boot/grub/$f || \
      bomb "setup rpool/boot/grub/$f failed"
  done
  zpool set bootfs=rpool/ROOT/omnios rpool || bomb "setting bootfs failed"
  beadm activate omnios || bomb "activating be failed"
  $ALTROOT/boot/solaris/bin/update_grub -R $ALTROOT
  bootadm update-archive -R $ALTROOT
  RELEASE=`head -1 $ALTROOT/etc/release | sed -e 's/ *//;'`
  sed -i -e '/BOOTADM/,/BOOTADM/d' /rpool/boot/grub/menu.lst
  sed -i -e "s/^title.*/title $RELEASE/;" /rpool/boot/grub/menu.lst
  CopyInstallLog
  beadm umount omnios
  return 0
}

SetHostname()
{
  log "Setting hostname: ${1}"
  /bin/hostname "$1"
  echo "$1" > $ALTROOT/etc/nodename
}

SetTimezone()
{
  log "Setting timezone: ${1}"
  sed -i -e "s:^TZ=.*:TZ=${1}:" $ALTROOT/etc/default/init
}

ApplyChanges(){
  SetRootPW
  [[ -L $ALTROOT/etc/svc/profile/generic.xml ]] || \
    ln -s generic_limited_net.xml $ALTROOT/etc/svc/profile/generic.xml
  [[ -L $ALTROOT/etc/svc/profile/name_service.xml ]] || \
    ln -s ns_dns.xml $ALTROOT/etc/svc/profile/name_service.xml
  return 0
}

Postboot() {
  [[ -f $ALTROOT/.initialboot ]] || touch $ALTROOT/.initialboot
  echo "$*" >> $ALTROOT/.initialboot
}

Reboot() {
  svccfg -s "system/boot-config:default" setprop config/fastreboot_default=false
  svcadm refresh svc:/system/boot-config:default
  reboot
}

RunInstall(){
  FetchConfig || bomb "Could not fecth kayak config for target"
  . $ICFILE
  Postboot 'exit $SMF_EXIT_OK'
  ApplyChanges || bomb "Could not apply all configuration changes"
  MakeBootable || bomb "Could not make new BE bootable"
  return 0
}