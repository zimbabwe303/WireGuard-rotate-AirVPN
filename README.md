# WireGuard-rotate-AirVPN
This is a couple of Linux scripts and a systemd service intended to be used with the [AirVPN](https://airvpn.org) service provider.

### prepare_AirVPN_wg.sh
* Unpacks the .tar.gz file created by the Config Generator into `/etc/wireguard/AirVPN_wg`
* (optionally) Fixes permissions
* (optionally) Disables IPv6 in the conf files

### wg_rotate.sh
* Reads the `/etc/wireguard/wg_rotate_servers.txt` file containing a wild-card list of servers to use
* Creates a full list of .conf files (`wg_rotate_servers_full.txt`)
* Reads and shuffles the list
* Adds the AmneziaWG options into the conf file
* Connects to the server
* Verifies the connection availability and feasibility, if it's poor moves to the next server
* (optionally) Restarts `dnsmasq.service` and `danted.service`
* Starts the timer or waits for a switch file to appear, once triggered moves to the next server
* If the connection becomes non-responsive, moves to the next server

Almost everything is configurable through the variables at the beginning of the script.

### By default
* The root dir is `/etc/wireguard`
* Configured to work with AmneziaWG (change `wg_quick` and `wg` variables)
* Does not rotate servers by timer (`rotate_interval=0`) but instead waits forever for the switch file to appear (`/tmp/wg_switch`)
* The switch file is created by the cron job at 6:00 AM every day

### Installation
* For AmneziaWG download, compile and install [amneziawg-tools](https://github.com/amnezia-vpn/amneziawg-tools) and [amneziawg-go](https://github.com/amnezia-vpn/amneziawg-go) (alternatively install [the kernel module](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module) instead of `amneziawg-go`). It is highly recommended to compile with `PREFIX=/usr/local` instead of the default `/usr`
* Mask the default AmneziaWG service: `systemctl mask awg-quick@wg0.service`
* For the standard WireGuard: `systemctl mask wg-quick@wg0.service`
* Copy `wg_rotate.sh`, `wg_rotate_servers.txt` and `prepare_AirVPN_wg.sh` to `/etc/wireguard`
* Copy `systemd/wg_rotate.service` to `/etc/systemd/system`
* Run `systemctl enable wg_rotate.service`
* (optionally) Copy `cron.d/wg` to `/etc/cron.d`
* Generate the .tar.gz file using the [AirVPN's Config Generator](https://airvpn.org/generator/) for the WireGuard protocol and all servers on the planet (use the "Invert" button, it is also recommended to switch to the Advanced mode and turn on "Resolved hosts")
* Run `prepare_AirVPN_wg.sh <AirVPN.tar.gz>` and follow the instructions
* Edit the `wg_rotate_servers.txt` to better suit your geographical location
* Test-run `/etc/wireguard/wg_rotate.sh` directly
* If it's all okay, then start the service with `systemctl start wg_rotate.service`

If you want to use the server rotate timer set `rotate_interval=<minutes>` and `rotate_variation=<minutes>`, the latter randomizes the switching time.

