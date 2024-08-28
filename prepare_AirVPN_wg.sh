#!/bin/sh
# Prepare files made by the AirVPN generator
# WireGuard version
# 28.08.2024

basedir=/etc/wireguard
steps=5

dir_wg=$basedir/AirVPN_wg

sed_disable_ipv6_wg="s/^(Address = .*)(, .*)$/\1/g ; s/^(DNS = .*)(, .*)$/\1/g ; s/^(AllowedIPs = .*)(, .*)$/\1/g"

ask_continue () {
  read -p "Continue = Enter; Skip = s; Quit = q " ans
  if [ "$ans" = "q" ]; then
    ret=1
  elif [ "$ans" = "s" ]; then
    ret=2
  else
    ret=0
  fi
}

purgecreate () {
  if [ -d "$dir" ]; then
    echo "Purging $dir"
    rm "$dir"/* 2> /dev/null
  else
    if [ ! -d "$dir" ]; then
      echo "Creating $dir"
      mkdir "$dir"
    fi
  fi
}

if [ $# -lt 1 ]; then
  echo "Usage: prepare_AirVPN.sh <path_to_AirVPN_wg.tar.gz>"
  exit
fi
gzfile=$1
if [ ! -f "$gzfile" ]; then
  echo "File $gzfile not found"
  echo "Exiting..."
  exit
fi
if ! file -b -L "$gzfile" | grep "gzip compressed data" > /dev/null; then
  echo "File $gzfile is not a gzip file"
  echo "Exiting..."
fi

step=1
echo
echo "Step $step/$steps: purge/create the target directories"
ask_continue
if [ $ret -eq 0 ]; then
  dir="$dir_wg"
  purgecreate
elif [ $ret -eq 1 ]; then
  echo "Exiting..."
  exit 1
fi

step=$(expr $step + 1)
echo
echo "Step $step/$steps: move $gzfile to $basedir"
ask_continue
if [ $ret -eq 0 ]; then
  mv "$gzfile" "$basedir"
  echo "Done"
elif [ $ret -eq 1 ]; then
  echo "Exiting..."
  exit 1
fi
gzbasename=$(basename "$gzfile")
gzfile="$basedir"/"$gzbasename"
if [ ! -f "$gzfile" ]; then
  echo "File $gzfile does not exist"
  echo "Exiting..."
fi

step=$(expr $step + 1)
echo
echo "Step $step/$steps: unpack $gzfile"
ask_continue
if [ $ret -eq 0 ]; then
  echo "$gzfile"
  echo "Unpacking WireGuard files to $dir_wg..."
  tar xv -C "$dir_wg" -f "$gzfile" --wildcards "*.conf"
elif [ $ret -eq 1 ]; then
  echo "Exiting..."
  exit 1
fi

step=$(expr $step + 1)
echo
echo "Step $step/$steps: fix permissions"
ask_continue
if [ $ret -eq 0 ]; then
  echo "Setting to 600 for files in $dir_wg"
  chmod 600 "$dir_wg"/*
elif [ $ret -eq 1 ]; then
  echo "Exiting..."
  exit 1
fi

step=$(expr $step + 1)
echo
echo "Step $step/$steps: disable IPv6 everywhere"
ask_continue
if [ $ret -eq 0 ]; then
  echo "Disabling for WireGuard"
  find "$dir_wg" -print -type f -exec sed -i -E "$sed_disable_ipv6_wg" {} \;
elif [ $ret -eq 1 ]; then
  echo "Exiting..."
  exit 1;
fi

echo
echo "Done!"
