# HaLow node monitoring

Tiles can show the HaLow link from the node you're attached to, on Heltec's HT-HD01 nodes with the firmware Heltec
ships (Morse Micro's OpenWrt) or with OpenMANET (OpenWrt with Wi-Fi HaLow). It finds the nodes itself, and it is
**read-only**: the app never changes a radio setting, so it can't cut the link it controls cameras through. Nothing
about any one network is built in: no addresses, no node names, nothing installed on the nodes.

Checked on real nodes (Heltec HT-HD01, OpenMANET 1.8.0) on 2026-10-11: `camctl halow` on a Mac cabled to one node,
with only the password set, found it over Bonjour, got the other two live nodes from its list of the mesh, polled all
three, and listed the mesh's devices by name (static leases included). Heltec's own firmware is supported from its
image and four factory units' flash (§ Heltec's firmware), not yet from a node running it.

## Setup

Settings → **HaLow Nodes**:

1. **Password**: the nodes' admin password (user `root` unless you change **Username**; `heltec.org` on a node as
   Heltec ships it). One login for every node, kept in the Keychain with the camera passwords.
2. That's it: nodes on the network appear under **Nodes**, each with its state. Opening the page also looks for nodes
   before there's a password, so you can see they're there.
3. **Add Node Address** is the fallback, for a node the app can't find by itself (no Bonjour on that network, a
   firmware neither check knows, or across a router).
4. **Show:** *When a node answers* (default) shows HaLow only while a node answers. *Always* also shows nodes you
   added, and nodes that have answered, when they stop, so a dropped link reads as down instead of disappearing.
   *Off* polls and looks for nothing.

States: Connected, Needs password, Login failed, Access denied (the account can't read the radios through rpcd),
Not a HaLow node (answers, but isn't rpcd or has no HaLow radio), No answer.

## Finding nodes

`HaLowMonitor`, with a password saved, at launch and whenever it comes back to the front:

1. **Bonjour**: one 4 s browse for `_http._tcp`, which every OpenWrt node running avahi advertises for its web
   interface (so do printers and NAS boxes). Each service is resolved to IPv4 by connecting to it on each interface
   it was seen on; unpinned, a connection can stall on an interface with no route, such as a bridge member on a Mac
   that shares its internet with a node. The default gateway is a candidate too. No answer anywhere: it browses again
   every 2 min.
2. **Check**: each candidate gets two password-free GETs side by side: `:8080/auth/check` (OpenMANET's web API,
   openmanetd) and `/cgi-bin/luci/`, LuCI's login page, which on a Morse Micro HaLow node names itself
   (`<meta name="application-name" content="<hostname> - MM HaLow Device">`, from the theme Heltec ships and the
   OpenMANET theme forked from it). Only a host that passes one is sent the password. A login page without that line
   makes a host not a node for the session: a plain OpenWrt router, the venue's or yours at home, gets nothing more.
   Silence on port 80 never does; the host is asked again later.
3. **The rest of the mesh**: once an OpenMANET node answers, its API is asked for the others: `POST :8080/auth/login`
   (same username and password; the token comes back in the JSON and goes back as the `session` cookie), then
   `openmanet.service.v1.NodeService/ListNodes` (Connect RPC, JSON). Every 5 min after that, through one answering
   node. Those addresses are polled without the check, since a node already logged into vouched for them.
4. A node the mesh lists that doesn't answer (it keeps nodes that have gone quiet) stays hidden and is retried after
   1, 2, 4… min, up to 15. A host that turns out to have no HaLow radio is dropped. One node at two addresses (its LAN
   address over Bonjour, its mesh address from the list) is polled once, recognized by its HaLow interface's MAC.

Heltec's firmware keeps no list of the other nodes, so each of its nodes is found by itself (Bonjour, or as the
gateway). It's still asked for one with the rest (nothing listens on its 8080, so that's a refused connection every
5 min): an OpenMANET node whose openmanetd was restarting when it was checked passes on its login page alone and looks
the same. The radio's band tells the HaLow interface (`band s1g`, `hwmode 11ah` in the radio's settings, which
`getWirelessDevices` carries) wherever iwinfo doesn't, on an interface iwinfo reports (one that's down has none).

The password goes over plain HTTP, like every rpcd login. Anyone on the network can read it there, and a host faking
either check could collect it; the check only keeps it away from devices that aren't pretending.

## Which node you're on

The tile shows, and the top bar lists first, the node this device is on:

- the node whose 2.4 GHz access point has this device as a station (`iwinfo assoclist` with a `mac`, in the same
  request as every poll, so it follows you from one node's Wi-Fi to another's);
- else the node holding this device's DHCP lease (cable or USB);
- else the default gateway, when that's a node.

This device's MAC comes from the node holding its lease (the lease records the private Wi-Fi address iOS uses), and
its own IPv4 addresses from `getifaddrs`. That node is polled every 10 s, over local Wi-Fi or cable; every other node
every minute, across the HaLow link.

## What you see

- **Top bar:** the link meter's bars are the weaker of the camera links and the HaLow link, since the cameras are
  controlled through it. Tap the bars: cameras first, then a HaLow section listing each node and its signal.
- **HaLow tile** (Add Tile → HaLow, offered once a node is known; never in a default layout): your node's signal in
  dBm, colored like the meter, with PHY rate, MCS (when reported), channel width and retry % beside or under it when
  the tile has room. "No link" means the node answers but hears no HaLow peer.

Signal steps (HaLow decodes far weaker signals than Wi-Fi; MM6108 sensitivity is around −100 dBm at the lowest rates):

| Signal | Bars |
|---|---|
| −75 dBm or better | 4, green |
| −85 | 3, green |
| −95 | 2, yellow |
| below −95 | 1, red |
| no peer | 0, red |

## Devices on the mesh (Add Camera)

With a node known (and HaLow not Off), Add Camera lists **On the HaLow Mesh**: every device the answering nodes have
leased an address to, and every static lease, named; static leases nobody holds right now are marked **Not on the
mesh**. Tap one to put its address in the form.

- One batched request per node when the form opens or on refresh, never polled: `luci-rpc getDHCPLeases` and
  `uci get {config: dhcp, type: host}` (OpenWrt's static leases). Both are in the stock LuCI ACLs.
- A device several nodes have leased to (it moved) is listed once, by its newest lease. A static lease's name wins
  over the name in the lease.
- **Cameras come first**, recognized by what they say about themselves, never by address. Sony's cameras send
  `SonyImagingDevice` as their DHCP hostname (checked on an FX3); their Wi-Fi MAC is the module maker's (Murata on
  the FX3), so the MAC can't tell. Otherwise the maker's IEEE OUI on its network port: Blackmagic Design `7C:2E:0D`,
  Sony Imaging Products & Solutions `2C:97:ED`. A recognized camera also sets the form's camera type when tapped.
  dnsmasq puts a static lease's name in place of the name a device sent, so a camera with a static lease is listed by
  that name and not recognized as a camera.

## What it sends

Without a password nothing is sent, except while Settings → HaLow Nodes is open: then it browses and checks,
password-free, to list what's there. Nothing in the background, nothing when Off, and a password a node refused isn't
tried again until it changes.

Per node, once: a login, then one batch: `system board` (hostname), `luci-rpc getWirelessDevices` (every interface's
iwinfo: the HaLow radio, its MAC, the access points) and `luci-rpc getDHCPLeases` (is this device's lease here). All in
the stock LuCI ACLs; a node without LuCI's rpcd calls reads Access denied.

HaLow radio detection: `hwmodes` contains `"ah"` (802.11ah); the MM6108 reports `"hwmodes":["ah"]` and no
`frequency` at all. Fallback for other firmware: `frequency` below 1 GHz after normalizing (values ≥ 100 000 are kHz).
The 2.4 GHz AP reports `"frequency":2437000` (kHz), so it's excluded.

After that, **every poll is one request**: `iwinfo assoclist` on the HaLow radio, plus, once this device's MAC is
known, `iwinfo assoclist` with that `mac` on each access point (a station, or `UBUS_STATUS_NOT_FOUND`). rpcd renews a
session each time it's used; after a long background stretch it lapses, the node answers −32002, and that poll logs in
once more (three requests instead of one). One login at a time per node, however many requests want a session.

| | Every | Request + reply | Per minute |
|---|---|---|---|
| The node this device is on | 10 s | ~1.3 KB | ~7.7 KB, local Wi-Fi or cable only |
| Any other node (crosses the HaLow link) | 60 s | ~1.3 KB | ~1.3 KB of HaLow airtime |
| The mesh's list (one node) | 5 min | ~0.7 KB | ~0.14 KB |

The ~1.3 KB (427 B out + 857 B back) is from the fake with one HaLow peer carrying every field rpcd sends (the budget
test prints it), plus estimated HTTP headers (~300 B out, ~150 B back). Each extra peer adds about 750 B to the reply,
and this device's station on an access point about as much again (local only). The first batch per node is ~3 KB once
(`getWirelessDevices` alone is ~2.5 KB). The Bonjour browse is a few hundred bytes of multicast, which crosses the mesh
at its slowest rate; that's why it's one browse, not a standing one.

## What the real node reports (Heltec HT-HD01, OpenMANET 1.8.0)

- `iwinfo info {"device":"wlh0"}`: no `frequency` key, `"hwmodes":["ah"]`, `"channel":0`, mode `Mesh Point`, `bssid`
  the HaLow MAC. `phy0-ap0`: `"frequency":2437000` (kHz), `"hwmodes":["b","g","n"]`, mode `Master`.
- `iwinfo assoclist {"device":"wlh0"}` with no peer → `{"results":[]}` (link down, not an error). With a `mac` that
  isn't associated → result code 4.
- `iwinfo devices` is denied by the stock ACLs; `luci-rpc getWirelessDevices`, `getDHCPLeases`, `uci get dhcp`,
  `iwinfo info/assoclist` and `system board` are allowed to root.
- openmanetd listens on 8080 (and 8087). `/auth/check` → `{"username":"","authenticated":false,"authEnabled":true}`.
  `ListNodes` → `{"nodes":[{"mac","hostname","ipaddr","position"}]}`, every node but itself, quiet ones included.
- rpcd's unauthenticated `session access` also identifies rpcd, but any OpenWrt box answers it, so it isn't the check.

## Heltec's firmware (HT-HD01 V2, 2.8.5-20260420)

Read from Heltec's image (`openwrt-2.8.5-20260420-heltec-ht-hd01-v2-squashfs-sysupgrade.bin`) and from the flash of
four V2s as they came from Heltec (two factory pairs), 2026-11-19:

- Morse Micro's OpenWrt 23.05.5 (ramips/mt76x8) with LuCI and Morse's theme, `morseargon`, active on all four.
- uhttpd on port 80, no redirect to HTTPS. `/ubus` is set at first boot (`/etc/uci-defaults/00_uhttpd_ubus`); all
  four had `ubus_prefix '/ubus'`. rpcd with `iwinfo.so` and `luci.so`.
- `root` / `heltec.org`. rpcd gives root every ACL (`list read '*'`, `list write '*'`), so `system board`, `luci-rpc
  getWirelessDevices` / `getDHCPLeases`, `uci get` and `iwinfo info` / `assoclist` are allowed; no ACL grants
  `iwinfo devices`, as on OpenMANET. Unauthenticated: `session access` / `login` and `luci getFeatures` only.
- The login page, `GET /cgi-bin/luci/` (403 before a login), is the theme's: LuCI's dispatcher renders
  `themes/morseargon/sysauth`, whose `<head>` carries `<meta name="application-name" content="<hostname> - MM HaLow
  Device">` on every page (`header.htm`, outside the theme's `blank_page` switch). That's the check. OpenMANET
  1.8.0's `openmanetargon` header has the same line.
- Nothing on 8080 (no openmanetd), and no list of the other nodes.
- The morse radio: `band 's1g'`, `hwmode '11ah'`, `channel '28'`, `country 'US'`. libiwinfo (20250326, as OpenMANET's)
  knows the `ah` hwmode.
- A factory pair is an access point and a station, routed, not bridged. The access point (`HT-HD01-<last 4 of its
  MAC>`): HaLow `ap` with `wds '1'` and its 2.4 GHz AP on `ahwlan`, 192.168.100.1/24 with DHCP from .100; its Ethernet
  is `lan`, a DHCP client. The station: HaLow `sta` on `ahwlan` (a lease from the access point); its own `lan`,
  10.42.0.1/24 with DHCP from .100, on its Ethernet, USB-C and its own 2.4 GHz AP.
- umdns advertises uhttpd (`_http._tcp`) on `lan` and `ahwlan` (all four units' config), so on the access point's
  Wi-Fi Bonjour finds both nodes of the pair; on the station's LAN, the station (it's the gateway there too).
- For camera control that matters more than the readout: the factory station masquerades its LAN onto the HaLow side
  (zone `ahwlan`, `masq '1'`, forwarding only `lan` → `ahwlan`), so nothing on the access point's side can open a
  connection to a camera on the station's Ethernet. Heltec's own pages say the same in their terms: the default pair
  is "Upstream Router → Dongle-AP → Dongle-STA → Terminal Devices", and in the station's default mode its devices get
  10.42.0.x ([IP allocation rules](https://wiki.heltec.org/docs/devices/wifi-halow/ht-hd01/ip_rules)). In the
  station's **Bridge** mode they get their addresses from the access point (192.168.100.x in its factory Ethernet-Router
  mode), or from the upstream router with the access point in Ethernet-Bridge mode too. The wizard's Bridged traffic
  mode puts the station's Ethernet and Wi-Fi on `ahwlan` and sets `wds '1'` on its HaLow station. The README's setup
  note follows that; not yet run with Tiles on a stock pair.

A station that joins an access point in 4-address mode (the wizard's Bridged traffic mode sets `wds '1'` on it, and
the factory access point already has it) is moved by mac80211 to an interface of its own, `<HaLow interface>.sta<N>`,
and the access point's own station list loses it. So on a HaLow access point the monitor also lists those
interfaces (`luci-rpc getNetworkDevices`: every 30 s while its own list is empty, else every 5 min) and reads them in
the same batch as the rest; without that, the node the iPad is on would read as link down with the link up.

Not checked yet: a node running it. The first stock pair to hand gets `camctl halow` with
`CAMCTL_NODE_PASSWORD=heltec.org`, as it ships and again with the station set to Bridged, from each end.

## Field check: `camctl halow`

```
export CAMCTL_NODE_PASSWORD=<the nodes' admin password>   # CAMCTL_NODE_USER if it isn't root
camctl halow                 # find the nodes, poll each once, list the mesh's devices
camctl halow 192.0.2.1       # the same, with a node added by hand
```

It runs the app's `HaLowMonitor` once: Bonjour, the gateway, the check, the mesh's list, a poll of every node, then
the device list, and prints how long that took.

## Sources

- **rpcd `iwinfo.c`** (github.com/openwrt/rpcd): assoclist station fields L548–581 (`signal`, `noise`, `tx.packets`,
  `tx.retries`, …); rate info L472–503 (`rate` is kbit/s, as iwinfo's `format_rate` shows; `mcs` is only sent for
  HT/VHT/HE/EHT rates, so it may be absent on HaLow); the `mac` filter L53–55.
- **uhttpd `ubus.c`** (github.com/openwrt/uhttpd): a JSON array is a batch; a call the session may not
  make, an expired session included, answers error −32002 "Access denied".
- **OpenMANET**: openmanetd's API was read from its web UI's protobuf descriptors (OpenMANET 1.8.0) and checked against
  the nodes. The UI logs in at `/auth/login` and calls Connect RPC at `/rpc/<service>/<method>`.
- **dnsmasq**: a `dhcp-host` name replaces the client's own in the lease (rfc2131.c).
- The default gateway comes from the routing table (sysctl `NET_RT_FLAGS`), read locally.
- Node battery: no build we've seen exposes one over ubus, so nothing reads it; the tile shows it if one is added.

Still to check on hardware: picking this device's node, through the access point's station list (a phone on a node's
Wi-Fi) or the lease (a Mac on a node's cable; the Mac checked was the uplink for its node, so it had no lease); a Sony
camera's lease reading `SonyImagingDevice` on the mesh (seen on the home LAN); Blackmagic's OUI on a PYXIS.
