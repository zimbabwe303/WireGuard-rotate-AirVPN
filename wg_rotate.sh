#!/bin/sh
# Rotate servers (WireGuard version)
# 13.05.2026

# THIS SCRIPT IS SELF-CONTAINED
# IT DOES NOT REQUIRE ANY OTHER SCRIPTS

# Set rotate_interval to 0 to disable automatic switching.
# Manual switching can be triggered by creating a file. The file name and
# location is defined by the switch_file variable. The file is deleted after
# its existence was detected by the script.

rotate_interval=0     # in minutes, set to 0 to disable automatic rotation
rotate_variation=30   # in minutes

# Speed test using curl (e.g. download file)
# curl_test_url should be a direct link, size ~10MB
# curl_test_min_speed is in KB/s
# curl_timeout is in seconds
curl_test=1
curl_test_url="http://ftp.nl.debian.org/debian/pool/main/f/fonts-noto-color-emoji/fonts-noto-color-emoji_2.051-0+deb13u1_all.deb"
curl_test_min_speed=2000
curl_timeout=30

root_dir=/etc/wireguard
wg_quick=awg-quick  # use AmneziaWG's wg-quick
wg=awg              # use AmneziaWG's wg
wg_wait=15          # in seconds
switch_file=/tmp/wg_switch
system_dns=1        # use system DNS (e.g. DNSCrypt daemon)

connect_ping_max=250          # in ms
connect_ping_count=3          # set to 0 to disable connect ping entirely
connect_ping_addr=1.1.1.1
test_ping_every=30            # in seconds
test_ping_count=3
ping_timeout=10               # in seconds, used for all pings
mtu=1500                      # default is 1320

# AmneziaWG parameters
amnezia_ENABLE=1   # Add the AmneziaWG parameters
amnezia_Jc=35      # Junk packet count (1-128)
amnezia_Jmin=150   # Junk packet minimum size (1-1279)
amnezia_Jmax=1280  # Junk packet maximum size (2-1280)
amnezia_S1=0       # Handshake init padding
amnezia_S2=0       # Handshake response padding
amnezia_S3=0       # Cookie reply padding
amnezia_S4=0       # Transport data padding
amnezia_CustomH=1  # Set to 1 to use custom H1..4 parameters, 0 to use random (except 1,2,3,4)
amnezia_H1=1       # Init packet magic header
amnezia_H2=2       # Response packet magic header
amnezia_H3=3       # Transport packet magic header
amnezia_H4=4       # Underload packet magic header
# Custom signature (junk) packets
# If you specify the I-list file a random set of values will be extracted from it
# Download the I-list files: https://github.com/VoidWaifu/Special-Junk-Packet-List
amnezia_Ilist="$root_dir"/I-list1.json
amnezia_I1=""
amnezia_I2=""
amnezia_I3=""
amnezia_I4=""
amnezia_I5=""

# Local proxy server:
# 0 - none
# 1 - microsocks
# 2 - hev-socks5-server
proxy=2
proxy_timeout=5  # How long to wait until proxy has started
microsocks_port=1080
hevsocks5_conf=/etc/hev-socks5-server.yml

restart_dnsmasq=1  # Restart dnsmasq after (re)connect
list_file="$root_dir"/wg_rotate_servers.txt
full_file="$root_dir"/wg_rotate_servers_full.txt
current_server_txt="$root_dir"/current_server.txt
wg_conf_file="$root_dir"/wg0.conf
interface_name=wg0

stop_daemons()
{
  if [ $proxy -eq 1 ] &&
    pgrep -f microsocks > /dev/null; then
    echo "Killing microsocks..."
    killall microsocks > /dev/null 2>&1
  fi
  if [ $proxy -eq 2 ] &&
    pgrep -f hev-socks5-server > /dev/null; then
    echo "Killing hev-socks5-server..."
    killall hev-socks5-server > /dev/null 2>&1
  fi
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

# (Re)start proxy server
start_proxy()
{
 if which $1 > /dev/null && \
      ! pgrep -f $1 > /dev/null; then
    echo "$sn: (Re)starting $1"
    $1 "$2" > /dev/null 2>&1 &
    t=0
    while [ $t -lt $proxy_timeout ]; do
      if pgrep -f $1 > /dev/null; then
        break
      fi
      sleep 1
      t=$((t+1))
    done
    if [ $t -eq $proxy_timeout ]; then
      echo "$sn: Cannot start $1, continuing anyway..."
    else
      echo "$sn: $1 (re)started"
    fi
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
    if [ $amnezia_CustomH -eq 0 ]; then
      echo "$sn: using random H1..4 parameters"
      h="$(shuf -e 1 2 3 4)"
      amnezia_H1=$(echo "$h" | sed '1q;d')
      amnezia_H2=$(echo "$h" | sed '2q;d')
      amnezia_H3=$(echo "$h" | sed '3q;d')
      amnezia_H4=$(echo "$h" | sed '4q;d')
    else
      echo "$sn: using custom H1..4 parameters"
    fi
    if [ "$amnezia_Ilist" ]; then
      valnum=$(shuf -i 1-800 -n 1)
      echo "$sn: using the value set $valnum from the I-list file"
      amnezia_I1=$(cat "$amnezia_Ilist" | sed -n "s/.*\"I1_c$valnum\": \"\(.*\)\".*/\1/p")
      amnezia_I2=$(cat "$amnezia_Ilist" | sed -n "s/.*\"I2_c$valnum\": \"\(.*\)\".*/\1/p")
      amnezia_I3=$(cat "$amnezia_Ilist" | sed -n "s/.*\"I3_c$valnum\": \"\(.*\)\".*/\1/p")
      amnezia_I4=$(cat "$amnezia_Ilist" | sed -n "s/.*\"I4_c$valnum\": \"\(.*\)\".*/\1/p")
      amnezia_I5=$(cat "$amnezia_Ilist" | sed -n "s/.*\"I5_c$valnum\": \"\(.*\)\".*/\1/p")
    else
      echo "$sn: using the predefined set of I values"
    fi
    sed "/^\[Interface\]/a\Jc = $amnezia_Jc\nJmin = $amnezia_Jmin\nJmax = $amnezia_Jmax\nS1 = $amnezia_S1\nS2 = $amnezia_S2\nS3 = $amnezia_S3\nS4 = $amnezia_S4\nH1 = $amnezia_H1\nH2 = $amnezia_H2\nH3 = $amnezia_H3\nH4 = $amnezia_H4\nI1 = $amnezia_I1\nI2 = $amnezia_I2\nI3 = $amnezia_I3\nI4 = $amnezia_I4\nI5 = $amnezia_I5\n" \
      "$newdir"/"$newfile" > "$wg_conf_file"
  else
    echo "$sn: Copy \"$newfile\" as \"$wg_conf_file\"..."
    cp "$newfile" "$wg_conf_file"
  fi
  if [ $system_dns -gt 0 ]; then
    sed -i "/^DNS = .*$/d" "$wg_conf_file"
  fi
  sed -i "s/MTU = .*/MTU = $mtu/" "$wg_conf_file"

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
  if [ ! "$endpoint" ]; then
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
      received=$(ping -q -c 1 -W 1 "$endpoint" | sed -n 's/^.* \([0-9]*\) received.*/\1/p')
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

  # Test connection
  if [ $curl_test -gt 0 ]; then
    echo "$sn: Testing speed with $curl_test_url, required speed is $curl_test_min_speed KB/s..."
    min_speed=$(( $curl_test_min_speed * 1000 ))
    speed=$(curl -qfsS -w '%{speed_download}' -o /dev/null --url "$curl_test_url" -m $curl_timeout)
    speed_kb=$(( $speed / 1000 ))
    if [ $? -gt 0 ]; then
      echo "$sn: curl failed"
      stop_daemons
      return 105
    fi
    if [ $speed -lt $min_speed ]; then
      echo "$sn: slow average speed ($speed_kb KB/sec)"
      stop_daemons
      return 106
    fi
    echo "$sn: good average speed ($speed_kb KB/sec)"
  elif [ $connect_ping_count -gt 0 ]; then
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

  # Start proxy
  if [ $proxy -eq 1 ]; then
    start_proxy microsocks -p$microsocks_port
  fi
  if [ $proxy -eq 2 ]; then
    start_proxy hev-socks5-server "$hevsocks5_conf"
  fi

  # Save current server name to txt
  echo "$sn: Saving current server name to $current_server_txt"
  echo "$newdir"/"$newfile" > "$current_server_txt"

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
      # Restart proxy if it has crashed
      if [ $proxy -eq 1 ]; then
        start_proxy microsocks -p$microsocks_port
      fi
      if [ $proxy -eq 2 ]; then
        start_proxy hev-socks5-server "$hev_socks5-server_conf"
      fi
      a=$(( $a+1 ))
    done
  done
done
