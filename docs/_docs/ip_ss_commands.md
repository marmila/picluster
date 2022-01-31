# net-tools package deprecated in favor of iproute2 package

## New ip/ss commands instead of old ifconfig/netstat.

`ifconfig` and `netstat` commands are not installed by default on Ubuntu 20.04. They are part of the package `net-tools` that have been deprecated in favor of `iproute2` package.

`iproute2`

Alternative new commands:
- `ifconfig` -> `ip`
- `netstat`  -> `ss`


For example, to display a list of network interfaces, run the ss command instead of netstat. To display information for IP addresses, run the ip addr command instead of ifconfig -a.

Examples are as follows:

```
USE THIS IPROUTE COMMAND     INSTEAD OF THIS NET-TOOL COMMAND
ip addr                      ifconfig -a
ss                           netstat
ip route                     route
ip maddr                     netstat -g
ip link set eth0 up          ifconfig eth0 up
ip -s neigh                  arp -v
ip link set eth0 mtu 9000    ifconfig eth0 mtu 9000
```

Examples are as follows:

```
ip neigh
198.51.100.2 dev eth0 lladdr 00:50:56:e2:02:0f STALE
198.51.100.254 dev eth0 lladdr 00:50:56:e7:13:d9 STALE
198.51.100.1 dev eth0 lladdr 00:50:56:c0:00:08 DELAY

arp -a
? (198.51.100.2) at 00:50:56:e2:02:0f [ether] on eth0
? (198.51.100.254) at 00:50:56:e7:13:d9 [ether] on eth0
? (198.51.100.1) at 00:50:56:c0:00:08 [ether] on eth0
```

To list all TCP or UDP ports that are being listened on, including the services using the ports and the socket status use the following command:

    sudo ss -tunlp

The options used in this command have the following meaning:

-t - Show TCP ports.
-u - Show UDP ports.
-n - Show numerical addresses instead of resolving hosts.
-l - Show only listening ports.
-p - Show the PID and name of the listener’s process. This information is shown only if you run the command as root or sudo user.