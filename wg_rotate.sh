#!/bin/sh
# Rotate servers (WireGuard version)
# 29.08.2024

# THIS SCRIPT IS SELF-CONTAINED
# IT DOES NOT REQUIRE ANY OTHER SCRIPTS

# Set rotate_interval to 0 to disable automatic switching.
# Manual switching can be triggered by creating a file. The file name and
# location is defined by the switch_file variable. The file is deleted after
# its existence was detected by the script.

rotate_interval=0     # in minutes, set to 0 to disable automatic rotation
rotate_variation=60   # in minutes

root_dir=/etc/wireguard
wg_quick=awg-quick  # use AmneziaWG's wg-quick
wg=awg              # use AmneziaWG's wg
wg_wait=30          # in seconds
switch_file=/tmp/wg_switch

connect_ping_max=200          # in ms
connect_ping_count=3          # set to 0 to disable connect ping entirely
connect_ping_addr=1.1.1.1
test_ping_every=30            # in seconds
test_ping_count=3
ping_timeout=10               # in seconds, used for all pings

# AmneziaWG parameters
amnezia_ENABLE=1   # Add the AmneziaWG parameters
amnezia_Jc=15      # Junk packet count
amnezia_Jmin=40    # Junk packet minimum size
amnezia_Jmax=80    # Junk packet maximum size
amnezia_S1=0       # Init packet junk size
amnezia_S2=0       # Response packet junk size
amnezia_CustomH=1  # Set to 1 to use custom H1..4 parameters
amnezia_H1=1       # Init packet magic header
amnezia_H2=2       # Response packet magic header
amnezia_H3=3       # Transport packet magic header
amnezia_H4=4       # Underload packet magic header

restart_dnsmasq=1
restart_danted=1

list_file="$root_dir"/wg_rotate_servers.txt
full_file="$root_dir"/wg_rotate_servers_full.txt
current_server_txt="$root_dir"/current_server.txt
wg_conf_file="$root_dir"/wg0.conf
interface_name=wg0

random_bytestr()
{
  return $(cat /dev/urandom | head -c1 | od -An -vtu1 | sed 's/^ *//')
}

stop_daemons()
{
  if ip link | grep $interface_name > /dev/null; then
    echo "Killing WireGuard (interface: $interface_name)... "
    "$wg_quick" down "$wg_conf_file"
  fi
  echo "Daemons stopped"
}

# Ctrl+C trap
ctrlc()
{
  echo "Ctrl+C: Stopping daemons and exiting..."
  stop_daemons
  exit 255
}
trap ctrlc INT

# Critical error with exit
critical_error()
{
  if [ $1 -gt 0 ]; then
    echo "Critical error: $1. Stopping daemons and exiting..."
    stop_daemons
    exit $1
  fi
}

# Change server
change_server()
{
  # Stage name
  sn="Changing server"

  # Prepare vars
  newfile="${1##*/}"
  newdir=$(dirname "$1")

  # Deal with the old daemons
  echo "$sn: Stopping the old daemons..."
  stop_daemons

  # Stage name
  sn="Starting tunnels"

  # Copy and patch the WireGuard configuration
  if [ $amnezia_ENABLE -gt 0 ]; then
    echo "$sn: Copy \"$newfile\" as \"$wg_conf_file\" and add custom options..."
    if [ $amnezia_CustomH -gt 0 ]; then
      echo "$sn: using custom H1..4 parameters"
      sed "/^\[Interface\]/a\Jc = $amnezia_Jc\nJmin = $amnezia_Jmin\nJmax = $amnezia_Jmax\nS1 = $amnezia_S1\nS2 = $amnezia_S2\nH1 = $amnezia_H1\nH2 = $amnezia_H2\nH3 = $amnezia_H3\nH4 = $amnezia_H4" \
        "$newdir"/"$newfile" > "$wg_conf_file"
    else
      echo "$sn: using default H1..4 parameters"
      sed "/^\[Interface\]/a\Jc = $amnezia_Jc\nJmin = $amnezia_Jmin\nJmax = $amnezia_Jmax\nS1 = $amnezia_S1\nS2 = $amnezia_S2" \
        "$newdir"/"$newfile" > "$wg_conf_file"
    fi
  else
    echo "$sn: Copy \"$newfile\" as \"$wg_conf_file\"..."
    cp "$newfile" "$wg_conf_file"
  fi

  # Start WireGuard
  echo "$sn: Starting the WireGuard client..."
  "$wg_quick" up "$wg_conf_file"; ec=$?
  if [ $ec -gt 0 ]; then
    stop_daemons
    return $ec
  fi
  echo "$sn: WireGuard client started"

  # Get endpoint address
  endpoint=$("$wg" show $interface_name endpoints | cut -f2 | sed 's/:.*$//')
  echo "$sn: Endpoint address is $endpoint"
  if [ ! $endpoint ]; then
    echo "$sn: cannot get endpoint address"
    stop_daemons
    return 102
  fi

  # Wait for the tunnel to appear
  echo "$sn: Waiting for the tunnel to appear ("$wg_wait"s max)..."
  a=0
  while [ $a -lt $wg_wait ]
  do
    if ip link | grep $interface_name > /dev/null; then
      received=$(ping -q -c 1 -W 1 $endpoint | sed -n 's/^.* \([0-9]*\) received.*/\1/p')
      if [ $received -gt 0 ]; then
        break
      fi
    else
      sleep 1
    fi
    a=$(( $a+1 ))
  done
  if [ $a -ge $wg_wait ]; then
    stop_daemons
    return 101
  fi
  echo "$sn: WireGuard tunnel started"

  # Connect ping
  if [ $connect_ping_count -gt 0 ]; then
    echo "$sn: Ping $connect_ping_addr, $connect_ping_count time(s)..."
    ping_time=$(ping -q -c $connect_ping_count -W $ping_timeout $connect_ping_addr | sed -n 's/^rtt .*=.*\/\([0-9]*\)\..*\/.* ms$/\1/p')
    if [ ! $ping_time ]; then
      echo "$sn: ping failed"
      stop_daemons
      return 103
    fi
    echo "$sn: average ping time $ping_time ms (max allowed: $connect_ping_max ms)"
    if [ $ping_time -gt $connect_ping_max ]; then
      echo "$sn: slow ping"
      stop_daemons
      return 104
    fi
    echo "$sn: good ping"
  fi

  # Restart dnsmasq
  if [ $restart_dnsmasq -gt 0 ] && \
    [ $(systemctl is-active dnsmasq.service) = "active" ]; then
    echo "$sn: Restarting dnsmasq"
    systemctl restart dnsmasq.service
    ec=$?
    if [ $ec -gt 0 ]; then
      critical_error $ec
    fi
    echo "$sn: dnsmasq restarted"
  fi

  # Restart danted
  if [ $restart_danted -gt 0 ] && \
    [ $(systemctl is-active danted.service) = "active" ]; then
    echo "$sn: Restarting danted"
    systemctl restart danted.service
    ec=$?
    if [ $ec -gt 0 ]; then
      critical_error $ec
    fi
    echo "$sn: danted restarted"
  fi

  # Save current server name to txt
  echo "$sn: Saving current server name to $current_server_txt"
  bn=$(basename "$newfile")
  server_name="${bn%.*}"
  echo "$server_name" > "$current_server_txt"

  echo "$sn: Done"
}

# get_sleep MIN RANGE // in minutes
get_sleep()
{
  if [ $2 -lt 1 ]; then
    # Range is 0
    echo $(( $1*60 ))
  fi
  echo $(( ($1*60) + $(od -vAn -N2 -d < /dev/urandom) / (65535 / ($2*60) ) ))
}

# === MAIN ===

# Delete the old full list
if [ -f "$full_file" ]; then
  printf "Deleting the old full list... "
  rm -f "$full_file"
  echo "deleted"
fi

# Create the new full list
printf "Creating the full list of servers to rotate... "
for f in $(cat "$list_file")
do
  ls "$f" >> "$full_file"
done
echo "created"

# Shuffle the list
printf "Shuffling the list... "
list=$(shuf --random-source=/dev/urandom "$full_file")
echo "done"

# Repeat the whole list indefinitely
while :
do
  # Go through the list
  for f in $list
  do
    # Show new IP
    echo "New server: $f"

    # Change server
    change_server "$f"
    ec=$?
    if [ $ec -gt 100 ]; then
      echo "Something went wrong. Trying another server..."
      continue
    elif [ $ec -gt 0 ]; then
      echo "Something went wrong. Exiting..."
      exit
    else
      echo "Done!"
    fi

    # Sleep for a while, slightly randomly
    echo "Doing test pings to the endpoint address $endpoint every $test_ping_every second(s),"
    if [ $rotate_interval -gt 0 ]; then
      sleep_for=$( get_sleep $rotate_interval $rotate_variation )
      echo "for ~$(($sleep_for/60)) minute(s) or"
    else
      sleep_for=0
    fi
    echo "until the switch file ($switch_file) appears..."
    a=0
    while [ $a -lt $(($sleep_for/$test_ping_every)) ] || [ $sleep_for = 0 ]
    do
      sleep $test_ping_every
      received=$(ping -q -c $test_ping_count -W $ping_timeout $endpoint | sed -n 's/^.* \([0-9]*\) received.*/\1/p')
      if [ ! $received ]; then
        # Ping error
        echo "Cannot ping endpoint, trying another server..."
        break
      fi
      if [ $received -eq 0 ]; then
        # The WireGuard tunnel has died
        echo "No ping from endpoint, trying another server..."
        break
      fi
      if [ -f "$switch_file" ]; then
        # Switch manually
        echo "$switch_file detected, switching to another server..."
        rm -f "$switch_file"
        break
      fi
      a=$(( $a+1 ))
    done
  done
done
