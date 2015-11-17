 #!/bin/bash

ONE_LOCATION=$1

function usage {
    echo "usage: $0 if OpenNebula is installed system-wide"
    echo "usage: $0 ONE_LOCATION if OpenNebula is installed in a directory"
}

if [ -z "$ONE_LOCATION" ]; then
  if [ ! -e "/usr/bin/oned" ]; then
    echo "Could not find OpenNebula executables installed system wide"
    usage
    exit 1
  fi
  VAR_LOCATION="/var/lib/one"
  ETC_LOCATION="/etc/one"
elif [ ! -e "$ONE_LOCATION/bin/oned" ]; then
  echo "Could not find OpenNebula in specified directory $ONE_LOCATION"
  echo "Check whether main program $ONE_LOCATION/bin/oned really exists"
  usage
  exit 2
else
  VAR_LOCATION="$ONE_LOCATION/var"
  ETC_LOCATION="$ONE_LOCATION/etc"
fi

cp ./etc/one/one_bursting_driver.conf $ETC_LOCATION/one_bursting_driver.conf
chown root:oneadmin $ETC_LOCATION/one_bursting_driver.conf

mkdir -p $VAR_LOCATION/remotes/im/opennebula.d
cp ./remotes/im/opennebula.d/* $VAR_LOCATION/remotes/im/opennebula.d/
chown oneadmin:oneadmin -R $VAR_LOCATION/remotes/im/opennebula.d/

mkdir -p $VAR_LOCATION/remotes/vmm/opennebula
cp ./var/remotes/vmm/opennebula/* $VAR_LOCATION/remotes/vmm/opennebula/
chown oneadmin:oneadmin -R $VAR_LOCATION/remotes/vmm/opennebula