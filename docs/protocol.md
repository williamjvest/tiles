# Sony cameras over Camera Remote (PTP-IP)

Tiles' notes on the protocol: what commands and properties each camera exposes, observed from live cameras and
the binary fixtures in `fixtures/`.

> **Scope**: Network-only (PTP-IP) control of ILME-FX3(A), ILME-FX30, ILME-FX2, ILME-FX6, MPC-2610 (BURANO).

---

## 1. Transport

### 1.1 PTP-IP Overview

Sony's Camera Remote uses PTP-IP (CIPA DC-005-2005) over TCP. Sony's vendor extensions sit on top of
standard PTP-IP framing: once PTP-IP is connected, everything is PTP operations. All packet fields are **little-endian**. The only TCP port
used for PTP-IP is **15740**. SSH mode port-forwards localhost:15740 over SSH port 22.

### 1.2 PTP-IP Packet Types

Packet framing is standard PTP-IP (CIPA DC-005-2005). All packets share:

```
Length     (4 bytes, UINT32) — total packet length including this field
PacketType (4 bytes, UINT32)
Payload    (variable)
```

| PacketType | Name                    | Direction | Notes                                  |
|------------|-------------------------|-----------|----------------------------------------|
| 0x00000001 | Init_Command_Request    | I→R       | GUID(16) + FriendlyName(UTF-16LE null-term) + ProtocolVersion(4) |
| 0x00000002 | Init_Command_Ack        | R→I       | ConnectionNumber(4) + GUID(16) + FriendlyName + ProtocolVersion(4) |
| 0x00000003 | Init_Fail               | R→I       | Reason(4) — see reason codes below      |
| 0x00000004 | Cmd_Request (Op Req)    | I→R       | DataPhaseInfo(4) + OpCode(2) + TransactionID(4) + Params(4×N) |
| 0x00000005 | Cmd_Response (Op Resp)  | R→I       | ResponseCode(2) + TransactionID(4) + Params(4×N) |
| 0x00000006 | Event                   | R→I       | EventCode(2) + TransactionID(4) + Params(4×N) |
| 0x00000007 | Start_Data_Packet       | I↔R       | TransactionID(4) + TotalDataLength(8)  |
| 0x00000008 | Data_Packet             | I↔R       | TransactionID(4) + Payload             |
| 0x00000009 | Cancel_Transaction      | I→R       | TransactionID(4)                       |
| 0x0000000A | End_Data_Packet         | I↔R       | TransactionID(4) + Payload             |
| 0x0000000C | Probe_Request           | I→R       | Keepalive; no payload beyond header    |
| 0x0000000D | Probe_Response          | R→I       | Reply to Probe_Request                 |

**Init_Fail reason codes** (standard PTP-IP): 0x00000001 = Rejected, 0x00000002 = Busy,
0x00000003 = Unspecified.

**ProtocolVersion** for PTP-IP: 0x00010000 (major=1, minor=0) per CIPA DC-005.

**GUID**: 16 bytes, initiator-generated. Must be stable per device; camera stores up to 20 paired GUIDs. Use a UUID v4, stored persistently in the app's keychain per camera IP.

**FriendlyName**: UTF-16LE null-terminated string. Shown to the user on camera during pairing.
Keep ≤ ~32 characters for display readability.

**Sony-specific vs standard**: Sony uses all standard PTP-IP packet types. No Sony-specific packet types
were found. The vendor extensions are purely at the PTP operation/property/event layer.

### 1.3 TCP Connections

PTP-IP requires two TCP connections to the same host:port (15740):

1. **Command channel** — carries Init_Command_Request/Ack, then all Operation and Data packets.
2. **Event channel** — carries Init_Event_Request/Ack, then Event packets only.

Connection sequence:
1. Open Command TCP connection → send Init_Command_Request (GUID, FriendlyName, version).
2. Receive Init_Command_Ack (or Init_Fail).
3. Open Event TCP connection → send Init_Event_Request (ConnectionNumber from Ack).
4. Receive Init_Event_Ack.
5. PTP-IP is now connected; proceed with OpenSession.

No connect timeout is specified by the protocol; 10–15 s is reasonable in practice. For the keepalive/probe: send
Probe_Request on the command channel if no traffic for ~5 s; expect Probe_Response.

### 1.4 Clean Shutdown

Call `CloseSession` (0x1003) then close both TCP connections. Do not drop TCP without
CloseSession; the camera may hold the session slot open until its own timeout.

---

## 2. Discovery

### 2.1 SSDP / UPnP

Camera advertises via UPnP SSDP:
- **Service name (USN)**: `urn:schemas-sony-com:service:DigitalImaging:1`
- **Multicast**: `239.255.255.250:1900`
- **SSDP NOTIFY example**: `LOCATION: http://192.168.122.1:80/dd.xml`

Steps:
1. Listen for SSDP NOTIFY (or issue M-SEARCH for the service name).
2. Fetch `dd.xml` from the LOCATION URL.
3. From `dd.xml` extract `<SCPDURL>` (→ path to `DigitalImagingDesc.xml`) and `<friendlyName>` /
   `<UDN>` for display.
4. Fetch `DigitalImagingDesc.xml`.

### 2.1.1 What Tiles does (`SonyDiscovery`, 2026-11-15)

Add Camera's On This Network (with Blackmagic cameras' Bonjour adverts: `NetworkCameras`) and `camctl find` search two
ways at once, each camera listed as it's found: the M-SEARCH above (sent three
times in the first second, answers taken for 3 s), and every other address of this device's networks (up to its /24)
asked for `/DigitalImagingDesc.xml` on **64321**, where the FX5, the FX6 and the BURANO all serve it (not port 80 as in
Sony's example). The second exists for iOS, which sends no multicast without Apple's multicast networking entitlement
(Tiles hasn't asked for it), and because the FX5 ignores an M-SEARCH sent straight to its address. An address no one
has is given up on after 1.5 s the first time (ARP), so a first sweep of a /24 takes about 6 s, a second about 2 s.
The FX5 answers the M-SEARCH 0.8–2.2 s after it, whatever MX says, and not every time (one of three searches in a
row): don't rely on SSDP alone. On a HaLow mesh (Add Camera with nodes known) only the devices the nodes leased an
address to are asked, not every address: a /24 sweep sends about 240 broadcast ARP requests, which every node
of a mesh carries.

### 2.2 DigitalImagingDesc.xml Key Tags

| Tag | Meaning |
|-----|---------|
| `X_ModelName` | Camera model name string |
| `X_FirmwareVersion` | Firmware version |
| `X_ServerVersion` | ≥ 3.00 required for PTP-IP |
| `X_PTP_Versions` | Supported PTP versions |
| `X_PTP_PairingNecessity` | `"Necessary"` → pairing required; `"Unnecessary"` → connect directly |
| `X_PTP_MediaServerSupport` | `"Enable"` → Content Transfer Mode available |
| `X_PTP_RemoteControlSupport` | `"Enable"` → Remote Control Mode available |
| `X_SSH_Support` | `"Enable"` → SSH **required**; direct TCP 15740 blocked |

### 2.3 Direct-IP (No Discovery)

SSDP isn't required: connecting directly to a known IP:15740 and sending Init_Command_Request works. **However**: you cannot read `X_SSH_Support` or
`X_PTP_PairingNecessity` without fetching DigitalImagingDesc.xml (HTTP GET `http://<ip>:80/DigitalImagingDesc.xml`
using the path from dd.xml, or guess `/DigitalImagingDesc.xml`). For skip-SSDP workflows, fetch the XML
directly by IP before connecting.

`SDIO_GetDeviceDescriptionFile` (0x923A) can retrieve the XML file over PTP, and can be called **before**
OpenSession, so it is safe to discover capabilities after a bare TCP connect.

---

## 3. Session Setup

Full authenticated sequence:

```
PTP-IP Init (§1.3)
  → OpenSession (0x1002, SessionID=1)
  → SDIO_Connect (0x9201, PhaseType=0x01, KeyCode1=0, KeyCode2=0) + Data(0)
  → SDIO_Connect (0x9201, PhaseType=0x02, KeyCode1=0, KeyCode2=0) + Data(0)
  → SDIO_GetExtDeviceInfo (0x9202, InitiatorVersion=0x012C) → Data(SDIExtDeviceInfo)
  → SDIO_Connect (0x9201, PhaseType=0x03, KeyCode1=0, KeyCode2=0) + Data(0)
  → PTP Remote Protocol Connected
```

**SDIO_Connect** (0x9201): Param1=PhaseType, Param2=KeyCode1, Param3=KeyCode2.
Send phases 1 and 2 first, then `SDIO_GetExtDeviceInfo`, then phase 3. Phase values: 0x01, 0x02, 0x03.

**SDIO_GetExtDeviceInfo** (0x9202): Param1=InitiatorVersion. Use **0x012C** (= 300
decimal = v3.00). Returns `SDIExtDeviceInfo` dataset:

| Field | Order | Bytes | Type |
|-------|-------|-------|------|
| SDIExtensionVersion | 1 | 2 | UINT16 |
| SDIDevicePropCode Array | 2 | variable | UINT16[] |
| SDIControlCode Array | 3 | variable | UINT16[] |

Check that the returned `SDIExtensionVersion` major == 0x03 (camera rejects if initiator major < camera
major, returning `Authentication_Failed` 0xA101).

If `SDIO_GetExtDeviceInfo` returns data size zero, **retry until successful**.

After phase 3, call `SDIO_OpenSession` (0x9210) to select function mode — for v1 remote control use
**FunctionMode=0x00000000** (Remote Control Mode). `SDIO_OpenSession` is separate from
the standard `OpenSession` (0x1002).

**Extended property codes** (0xE000–0xEFFF) and extended control codes (0xF000–0xFFFF) require
`SDIO_GetVendorCodeVersion` support and vendor code version ≥ 3.10. Always set
`Flag of Device Property Option = 0x00000001` in `SDIO_SetExtDevicePropValue`,
`SDIO_ControlDevice`, and `SDIO_GetAllExtDevicePropInfo` Parameter 2 to enable these.

---

## 4. Reading State

### 4.1 SDIO_GetAllExtDevicePropInfo (0x9209)

- Param1: `0x00000000` = all data; `0x00000001` = changed-only (diff).
- Param2: `0x00000001` = enable extended prop/control codes.
- Returns: `SDIDevicePropInfo Dataset Array`.

**SDIDevicePropInfo Dataset Array**:

| Field | Order | Bytes | Type |
|-------|-------|-------|------|
| Num of Elements | 1 | 8 | UINT64 |
| SDIDevicePropInfo Dataset[0..N-1] | 2..N | variable each | — |

**SDIExtDevicePropInfo Dataset** (per property):

| Field | Order | Bytes | Type | Notes |
|-------|-------|-------|------|-------|
| Device Property Code | 1 | 2 | UINT16 | |
| DataType | 2 | 2 | UINT16 | see §4.2 |
| GetSet | 3 | 1 | UINT8 | 0x00=Get only, 0x01=Get/Set |
| IsEnabled | 4 | 1 | UINT8 | 0x00=False/grayed, 0x01=True, 0x02=DispOnly |
| Factory Default Value | 5 | variable | per DataType | not guaranteed if IsEnabled=False |
| Current Value | 6 | variable | per DataType | not guaranteed if IsEnabled=False |
| Form Flag | 7 | 1 | UINT8 | 0x01=Range, 0x02=Enumeration |

If `FormFlag = 0x02 (Enumeration)`, two additional enum lists follow:
- `Num of Enum lists (Set)` (UINT16) + N values — settable values only
- `Num of Enum lists (Get/Set)` (UINT16) + M values — all readable values

If `FormFlag = 0x01 (Range)`: min, max, step (each = DataType size).

### 4.2 DataType Codes

| Code | Type | Bytes |
|------|------|-------|
| 0x0001 | INT8 | 1 |
| 0x0002 | UINT8 | 1 |
| 0x0003 | INT16 | 2 |
| 0x0004 | UINT16 | 2 |
| 0x0005 | INT32 | 4 |
| 0x0006 | UINT32 | 4 |
| 0x0007 | INT64 | 8 |
| 0x0008 | UINT64 | 8 |

### 4.3 Events and Polling Pattern

**Primary event**: `SDIE_DevicePropChanged` (0xC203) — fires when any property value changes.
Arrives on the Event TCP channel as a standard PTP-IP Event packet.

Events can be lost if the event channel isn't read all the time, and older bodies drop them anyway, so a poll
backs them up.

**What Tiles does** (measured on a real FX3, 2026-10-09; see `docs/fx3-controls.md`):
1. A reader on the event channel that never stops. On `SDIE_DevicePropChanged`, wait 100 ms for more,
   then one `SDIO_GetAllExtDevicePropInfo` with Param1=0x00000001 (changed only). A change announced
   while a fetch is in flight gets its own fetch afterwards.
2. A safety-net changed-only fetch every 30 s. Events are reliable on 2019+ models as long as the event channel is
   always read.
   The camera's own 10 s keepalive probes maintain the link; the poll catches any missed events.

Other relevant events:
- `SDIE_MovieRecOperationResults` (0xC224) — async result of movie rec start/stop.
- `SDIE_CautionDisplayEvent` (0xC228) — camera caution/warning state.
- `SDIE_OperationResults` (0xC222) — general async operation completion.

---

## 5. Writing

### 5.1 SDIO_SetExtDevicePropValue (0x9205)

Sets a property value:
- Param1: DevicePropCode
- Param2: `0x00000001` (enable extended codes flag)
- Data (I→R): new value encoded per the property's DataType

Response codes: `OK`, `Device_Busy`, `Parameter_Not_Supported`. No partial-success; on
`Device_Busy` retry after a brief delay.

### 5.2 SDIO_ControlDevice (0x9207)

Sends a button/control command:
- Param1: SDIControlCode
- Param2: `0x00000001` (enable extended codes flag)
- Data (I→R): SDIControl Value (UINT32 unless noted otherwise)

**Button semantics**:
- On/off buttons (e.g., S1, S2, Movie Rec): `0x0002` = Down, `0x0001` = Up.
- Up/down step controls (F-number, shutter speed, ISO step): value = signed step count.
- One-shot controls: value = command-specific.

**Camera returns OK even if the action fails** (e.g., S2 fire when camera can't expose) — check property
state afterward.

### 5.3 Value Encodings (key properties)

See §6 dashboard table for property-specific encoding. General rules:
- Shutter angle: UINT32, value = angle × 1000 (e.g., 180° = 180000 = 0x0002BF20).
- Color temperature: UINT16, direct Kelvin value; 0x0000 = below range, 0xFFFF = above range.
- ND Filter Value (0xD01B): UINT64, upper 4 bytes = numerator, lower 4 bytes = denominator
  (transmittance fraction); 0xFFFFFFFFFFFFFFFF = nothing to display.
- ISO Sensitivity (0xD21E) / ISO Current Sensitivity (0xD023): UINT32, direct ISO value
  (e.g., 0x00000064 = ISO 100, 0x00000C80 = ISO 3200).
- Exposure Index (0xD022): UINT16, direct EI value (e.g., 0x00C8 = 200 EI).

### 5.4 Response / Error Codes

| Code | Meaning |
|------|---------|
| 0x2001 | OK |
| 0x2002 | General_Error |
| 0x2006 | Device_Busy |
| 0x2009 | Parameter_Not_Supported |
| 0x201D | Session_Not_Open |
| 0xA101 | Authentication_Failed (version mismatch or auth error) |
| 0xA102 | Password_Length_Over_Max |
| 0xA103 | Password_Includes_Invalid_Character |
| 0xA104 | Feature_Version_Invalid_Value |
| 0xA105 | Temporary_Storage_Full |
| 0xA106 | Camera_Status_Error |

---

## 6. Dashboard Mapping Table

**Camera column key**: FX3 = ILME-FX3(A), FX6 = ILME-FX6, BUR = MPC-2610 (BURANO).
✓ = the camera reported the code (its dump in `fixtures/`); — = it didn't; R = the dump shows the property as read-only.

---

### 6.1 Timecode Display

| Item | Code | Name | DataType | Encoding | R/W | FX3 | FX6 | BUR |
|------|------|------|----------|----------|-----|-----|-----|-----|
| TC/UB display mode | 0xD1FD | TC/UB Display Setting | UINT8 | 0x01=Counter, 0x02=TC, 0x03=U-Bit, 0x04=Duration | R/W | ✓ | — | — |
| TC preset | 0xD0D3 | Time Code Preset | UINT32 | Bits 24–31=Hour, 16–23=Min, 8–15=Sec, 0–7=Frame(0–29) | R/W | ✓ | — | — |
| TC format | 0xD0D5 | Time Code Format | UINT8 | 0x01=DF, 0x02=NDF | R/W | ✓ | — | — |
| TC run | 0xD0D6 | Time Code Run | UINT8 | 0x01=Rec Run, 0x02=Free Run | R/W | ✓ | — | — |
| TC make | 0xD0D7 | Time Code Make | UINT8 | 0x01=Preset, 0x02=Regenerate | R/W | ✓ | — | — |
| Recording duration | 0xD120 | Recording Duration | — | Current recording elapsed time | R | — | — | — |

Timecode (0xD0D3–0xD0D7) and TC/UB Display Setting (0xD1FD) are the FX3's: neither the FX6 nor the BURANO
reported them. Treat cinema-line timecode as not available over PTP.

---

### 6.2 Recording State / Tally / REC Start-Stop

| Item | Code | Name | DataType | Encoding | R/W | FX3 | FX6 | BUR |
|------|------|------|----------|----------|-----|-----|-----|-----|
| Movie recording state | 0xD21D | Movie Recording State | UINT8 | 0x00=Not Recording, 0x01=Recording, 0x02=Failed, 0x03=Waiting | R | ✓ R | — | — |
| Start/Stop REC (toggle) | 0xF001 | Movie Rec Button (Toggle) | UINT32 | single press = 0x0001 | W | — | ✓ | ✓ |
| Start/Stop REC (hold) | 0xD2C8 | Movie Rec Button (Hold) | UINT16 | 0x0002=Down, 0x0001=Up | W | ✓ | ✓ | — |
| Red Tally Lamp | 0xE0D2 | Red Tally Lamp Control | — | Get/Set tally on/off | R/W | — | — | ✓ |
| Green Tally Lamp | 0xE0D3 | Green Tally Lamp Control | — | Get/Set | R/W | — | — | ✓ |
| Yellow Tally Lamp | 0xE0D4 | Yellow Tally Lamp Control | — | Get/Set | R/W | — | — | — |

*0xF001 (Movie Rec Button Toggle, extended code) requires vendor code version ≥ 3.10 and
`Flag=0x00000001`. Check via `SDIO_GetVendorCodeVersion`; fall back to 0xD2C8 Hold.

Movie Recording State (0xD21D) is NOT on the FX6's or BURANO's list. Their REC state is the
recorder's: `Recorder Main Status` 0xE010, UINT8, get only: 0x00 Idle, 0x01 Ready, 0x02 PreparingToRecord,
0x03 Standby, 0x04 Recording, 0x05 Stopping; `Recorder Start Main` 0xE00E says whether REC
can start (0x00 Rec Start Disable, 0x01 Enable). Tiles reads 0xD21D where it's listed, else 0xE010, and
only 0x04 counts as a take (2026-10-15; until then REC stayed disabled on both). REC buttons: the FX6 lists the
Hold 0xD2C8 and the Toggle 0xF001; BURANO only the Toggle, which Tiles presses only when the
recorder's status says the take has to change.

---

### 6.3 ND Filter

| Item | Code | Name | DataType | Encoding | R/W | FX3 | FX6 | BUR |
|------|------|------|----------|----------|-----|-----|-----|-----|
| ND on/off | 0xD018 | ND Filter | UINT8 | 0x01=OFF, 0x02=ON | R/W | — | ✓ | ✓ |
| ND mode | 0xD019 | ND Filter Mode | UINT8 | 0x01=Auto, 0x02=Preset, 0x03=PresetClear, 0x04=Variable, 0x05=VariableClear, 0x06=Step, 0x07=StepClear | R | — | ✓ R | ✓ R |
| ND mode setting | 0xD01A | ND Filter Mode Setting | UINT8 | 0x01=Automatic, 0x02=Manual | R/W | — | ✓ | ✓ |
| ND value (transmittance) | 0xD01B | ND Filter Value | UINT64 | upper 4B=numerator, lower 4B=denominator; 0xFFFF…=none | R/W | — | ✓ | ✓ |
| ND switching | 0xD073 | ND Filter Switching Setting | — | — | R/W | — | ✓ | ✓ |
| ND preset select | 0xD074 | ND Filter Preset Select | — | Which preset (1/2/3) | R/W | — | — | — |
| ND preset 1 value | 0xD075 | ND Filter Preset 1 Value | — | | R/W | — | — | — |
| ND preset 2 value | 0xD076 | ND Filter Preset 2 Value | — | | R/W | — | — | — |
| ND preset 3 value | 0xD077 | ND Filter Preset 3 Value | — | | R/W | — | — | — |
| ND position setting | 0xE0E5 | ND Filter Position Setting | — | (extended code) | R/W | — | — | ✓ |
| ND OD value | 0xD14F | ND Filter Optical Density Value | — | | R/W | — | ✓ | ✓ |
| Manual ND value input | 0xE0E2 | Manual Input for ND Filter Value | — | (extended code) | R/W | ✓ | — | — |

**The FX3, FX30 and FX2 have no built-in ND filter**, so the FX3 reports none of the ND properties.
ND step −/+ on FX6/BURANO: use ND Filter Value (0xD01B). The ND preset properties (0xD074–0xD077) aren't on
their lists.

---

### 6.4 Shutter Angle / Shutter Speed / Shutter Mode

| Item | Code | Name | DataType | Encoding | R/W | FX3 | FX6 | BUR |
|------|------|------|----------|----------|-----|-----|-----|-----|
| Shutter angle | 0xD00E | Shutter Angle | UINT32 | value × 1000 (e.g. 180°=180000=0x0002BF20) | R/W | ✓ | ✓ | ✓ |
| Shutter mode | 0xD010 | Shutter Mode | UINT8 | 0x01=Speed, 0x02=Angle | R/W | ✓ | ✓ | ✓ |
| Shutter mode status | 0xD011 | Shutter Mode Status | UINT8 | 0x01=OFF, 0x02=Speed, 0x03=Angle, 0x04=ECS, 0x05=Auto | R | — | ✓ | ✓ |
| Shutter mode setting | 0xD013 | Shutter Mode Setting | UINT8 | on/off of overall shutter setting | R/W | ✓ | ✓ | ✓ |
| Shutter speed value | 0xD016 | Shutter Speed Value | — | Set when mode=Speed | R/W | — | ✓ | ✓ |
| Shutter speed current | 0xD017 | Shutter Speed Current Value | — | Read-only current | R | — | ✓ R | ✓ R |
| ECS setting | 0xE006 | Shutter ECS Setting | — | (extended) | R/W | — | ✓ | ✓ |
| ECS number | 0xE007 | Shutter ECS Number | — | (extended) | R/W | — | ✓ | ✓ |
| ECS number step | 0xF000 | Shutter ECS Number Step | — | (extended control) | W | — | ✓ | ✓ |

Check `Shutter Mode Status` (0xD011) to know the current active mode; `Shutter Angle` IsEnabled will be
`0x01` only when angle mode is active. `Shutter Setting` (0xD00F) 0x01=OFF, 0x02=ON governs whether
the shutter is even active.

---

### 6.5 Frame Rate

| Item | Code | Name | DataType | Encoding | R/W | FX3 | FX6 | BUR |
|------|------|------|----------|----------|-----|-----|-----|-----|
| Recording frame rate | 0xD286 | Recording Frame Rate Setting (Movie) | UINT8 | enum: 0x01=120p, 0x03=60p, 0x05=30p, 0x06=25p, 0x08=23.98p, 0x09=29.97p, 0x0A=59.94p, 0x16=24.00p … | R/W | ✓ | ✓ | ✓ |
| Project frame rate (proxy) | 0xD028 | Recording Frame Rate Proxy Setting (Movie) | UINT8 | same enum as 0xD286 | R/W | — | ✓ | ✓ |
| S&Q mode | 0xD051 | S&Q Mode Setting | UINT8 | on/off | R/W | — | ✓ | ✓ |
| S&Q frame rate | 0xD052 | S&Q Frame Rate | UINT8 | | R/W | ✓ | ✓ | ✓ |
| S&Q rec frame rate | 0xD0D0 | S&Q Rec Frame Rate | UINT8 | | R/W | ✓ | — | — |

**Frame rate is settable remotely** via 0xD286 on all target cameras. 0xD028 is not a project
rate: it is the PROXY's recording frame rate (FX6/BURANO), and Tiles no longer shows it as the frame
rate. S&Q Mode Setting 0xD051 (0x01 Off, 0x02 On) is FX6/BURANO only; the FX3 neither ticks it nor
reports it.

---

### 6.6 ISO / Exposure Index / Gain

| Item | Code | Name | DataType | Encoding | R/W | FX3 | FX6 | BUR |
|------|------|------|----------|----------|-----|-----|-----|-----|
| ISO sensitivity | 0xD21E | ISO Sensitivity | UINT32 | Direct ISO value (0x64=ISO100, 0xC80=ISO3200) | R/W | ✓ | ✓ | ✓ |
| ISO current sensitivity | 0xD023 | ISO Current Sensitivity | UINT32 | Read-only actual current ISO | R | ✓ R | ✓ R | ✓ R |
| Exposure Index (EI) | 0xD022 | Exposure Index | UINT16 | Direct EI value (0x00C8=200EI) | R/W | ✓ | ✓ | ✓ |
| Gain control setting | 0xD01C | Gain Control Setting | UINT8 | 0x01=Automatic, 0x02=Manual | R/W | ✓ | ✓ | ✓ |
| Gain unit | 0xD01D | Gain Unit Setting | UINT8 | 0x01=dB, 0x02=ISO | R/W | — | ✓ | ✓ |
| Gain dB value | 0xD01E | Gain dB Value | INT8 | dB value | R/W | — | ✓ | ✓ |
| Gain dB current | 0xD01F | Gain dB Current Value | INT8 | read-only | R | — | ✓ R | ✓ R |
| Gain base ISO | 0xD020 | Gain Base ISO Sensitivity | UINT8 | 0x01=High, 0x02=Low | R/W | ✓ | ✓ | ✓ |
| Gain base sensitivity | 0xD021 | Gain Base Sensitivity | UINT8 | 0x01=High, 0x02=Low | R/W | — | ✓ | ✓ |
| Base ISO switch EI | 0xD0CB | Base ISO Switch EI | — | EI threshold at which base switches | R/W | — | — | — |

**The FX3** uses `Exposure Index` (0xD022) in Cine EI mode and `ISO Sensitivity` (0xD21E) in other
modes. `Gain Base ISO Sensitivity` (0xD020) switches between low/high base. `Gain Unit
Setting` (0xD01D) / `Gain dB Value` (0xD01E) are FX6/BURANO only; `Gain Control Setting` (0xD01C) is on every body. Use `IsEnabled` to determine which gain property is
currently active.

---

### 6.7 White Balance

| Item | Code | Name | DataType | Encoding | R/W | FX3 | FX6 | BUR |
|------|------|------|----------|----------|-----|-----|-----|-----|
| WB mode (broad) | 0x5005 | White Balance | UINT16 | PTP standard enumeration | R/W | ✓ | — | — |
| WB mode setting | 0xD00C | White Balance Mode Setting | UINT8 | 0x01=Automatic, 0x02=Manual | R/W | — | ✓ | ✓ |
| WB tint | 0xD00D | White Balance Tint | INT8 | −99 to +99, step 1 | R/W | — | ✓ | ✓ |
| Color temperature | 0xD20F | Color Temperature | UINT16 | Kelvin (range variable); 0x0000=<2500K, 0xFFFF=>9900K | R/W | ✓ | ✓ | ✓ |
| WB preset color temp | 0xD086 | White Balance Preset Color Temperature | — | Preset Kelvin value | R/W | — | — | — |
| WB switch | 0xD085 | White Balance Switch | — | Selected current WB mode | R/W | — | — | — |
| WB R gain | 0xD087 | White Balance R Gain | — | | R/W | — | — | — |
| WB B gain | 0xD088 | White Balance B Gain | — | | R/W | — | — | — |
| Color temp step (control) | 0xD2EC | Color Temperature Step | — | Control: increment color temp | W | — | ✓ | ✓ |
| WB tint step (control) | 0xD2ED | White Balance Tint Step | — | Control: increment tint | W | — | ✓ | ✓ |

Color Temperature (0xD20F) is universally supported across all target cameras.
For the "Live" fader use: set `Color Temperature` (0xD20F) directly for Kelvin. For tint: the FX6 and
BURANO have `White Balance Tint` (0xD00D, INT8 −99…+99); **the FX3 (verified 2026-10-08) hasn't, and has 0xD210
instead (G-M Biaxial Fine-Tuning, UINT8, mid=0xC0=0, range −9.0 to +9.0 step 0.25)**. Read the camera's property table to determine which code is
present. `Color Temperature Step` controls (0xD2EC/0xD2ED) are FX6/BURANO only.

---

### 6.8 Continuous "Live" Faders (Iris, ND, Focus, Zoom)

| Control | Code | Name | Type | Continuous? | FX3 | FX6 | BUR |
|---------|------|------|------|-------------|-----|-----|-----|
| Iris (F-Number) | 0x5007 / 0xD000 | F-Number / T-Number | UINT16 | Step via ControlDevice | ✓ | ✓ | ✓ |
| Iris mode | 0xD001 | Iris Mode Setting | UINT8 | 0x01=Auto, 0x02=Manual | ✓ | ✓ | ✓ |
| ND filter (variable) | 0xD01B | ND Filter Value | UINT64 | Set directly (transmittance ratio) | — | ✓ | ✓ |
| Focus position (absolute) | 0xE042 | Focus Position Setting | — | Set absolute position (extended) | ✓ | — | — |
| Focus position current | 0xE043 | Focus Position Current Value | — | Read current absolute pos | ✓ | — | — |
| Focus (near/far step) | 0xD2D1 | Near/Far | — | Control: direction+speed | ✓ | — | — |
| Focus operation | 0xD2EF | Focus Operation | — | Execute focus | — | ✓ | ✓ |
| Focus with INT16 | 0xF004 | Focus Operation with INT16 | — | Speed+direction INT16 (extended) | — | — | — |
| Zoom position (absolute) | 0xE040 | Zoom Position Setting | — | Set absolute zoom (extended) | ✓ | — | — |
| Zoom operation | 0xD2DD | Zoom Operation | — | Tele/wide direction+speed | ✓ | ✓ | ✓ |
| Zoom with INT16 | 0xF003 | Zoom Operation with INT16 | — | Speed+direction INT16 (extended) | — | — | — |

**Iris**: `F-Number` (0x5007, PTP standard) on all three; the BURANO also has `T-Number` (0xD000, Sony's cinema
extension), and a T-Number the camera has switched off (a lens without one) falls back to the F-Number. Use
`IsEnabled` and the property's presence to decide. `IsEnabled` will be 0x00 when iris is in auto mode.

**ND variable fader** (FX6/BURANO only): write `ND Filter Value` (0xD01B) with a transmittance ratio.
FX3/FX30/FX2 have no ND hardware.

**Focus/Zoom**: absolute position controls (0xE040–0xE043) require extended code support.
`Focus Operation with INT16` (0xF004) and `Zoom Operation with INT16` (0xF003) give the smoothest
continuous operation; check `Focus Operation with INT16 Enable Status` (0xE045) first.

---

### 6.9 GATE Tile (Clip Flag / OK Mark)

**Not available.** None of the cameras reports a clip flag or OK mark, as a property or a control. The MediaProfile XML uses a `status` attribute on Material elements
(e.g., `status="none"`), but this is a metadata field in the media file, not a PTP-controllable
property. There is no remote clip-flag mechanism via PTP 3.

---

### 6.10 Sensor Flip (Image Flip)

**NOT FOUND** as a settable camera property in PTP 3. The MediaProfile XML has a `flip`
attribute on Material elements (`flip="none"`), but this is a recorded metadata indicator, not a live
control. No `Image Flip`, `Sensor Flip`, or `Image Rotation` property appears in any of the cameras' dumps.

---

### 6.11 Web GUI / HTTP Remote

Sony's pan/tilt cameras (ILME-FR7, BRC-AM7) have a **Web App** for settings such as stream resolution. For the
target cameras:
- ILME-FX6 and MPC-2610 (BURANO) expose media content via HTTP on **port 8080** (MediaProfile URL
  `http://localhost:8080/A/MEDIAPRO.XML`), accessible after SSH port-forwarding.
- `LiveViewURL` (0xD278), an HTTP URL served by the camera (e.g., `http://192.168.122.1:60152/liveviewstream`), is
  the pan/tilt cameras' live view. The FX3 reports it, but the endpoint answers 503 (§8, gotcha 5).
- **No web remote-control page** is known for the FX3, FX6 or BURANO: they're controlled over PTP.
- Ports: TCP 15740 (PTP-IP), 22 (SSH), 80 (UPnP/dd.xml), 8080 (MediaProfile/content), and the variable HTTP port in
  LiveViewURL.

---

### 6.12 Status: Battery, Media, Overheat

| Item | Code | Name | DataType | Encoding | R/W | FX3 | FX6 | BUR |
|------|------|------|----------|----------|-----|-----|-----|-----|
| Battery remaining (%) | 0xD218 | Battery Remaining | UINT8? | 0–100 percent | R | ✓ R | ✓ R | ✓ R |
| Battery level indicator | 0xD20E | Battery Level Indicator | UINT8 | Discrete level steps | R | ✓ R | — | — |
| Battery remaining (min) | 0xD038 | Battery Remaining in Minutes | — | Minutes | R | — | ✓ R | ✓ R |
| Media SLOT1 status | 0xD248 | Media SLOT1 Status | UINT8 | Card state enum | R | ✓ R | ✓ R | ✓ R |
| Media SLOT1 remaining time | 0xD24A | Media SLOT1 Remaining shooting time | — | Seconds of remaining movie record | R | ✓ R | ✓ R | ✓ R |
| Media SLOT2 status | 0xD256 | Media SLOT2 Status | UINT8 | Card state enum | R | ✓ R | ✓ R | ✓ R |
| Media SLOT2 remaining time | 0xD258 | Media SLOT2 Remaining shooting time | — | | R | ✓ R | ✓ R | ✓ R |
| Overheat state | 0xD251 | Device Overheating State | UINT8 | Non-zero = overheating | R | ✓ R | — | — |
| Camera error info | 0xD07A | Camera System Error Info | — | System error bitmask | R | — | — | — |
| Camera error caution | 0xD1BB | Camera Error Caution Status | — | | R | ✓ | — | — |
| System error caution | 0xD1BC | System Error Caution Status | — | | R | ✓ | — | — |

Battery Remaining (0xD218) is on all three. Overheat (0xD251): the FX3 reports it; the FX6 and BURANO don't. Monitor `SDIE_CautionDisplayEvent` (0xC228) for live caution/overheat notifications.

---

## 7. Pairing Mode and SSH Mode

### 7.1 Pairing Mode (Access Authentication OFF)

Required when `X_PTP_PairingNecessity = "Necessary"` in DigitalImagingDesc.xml, or when SSH is
disabled.

**Camera setup**:
- FX3/FX30/FX2: Enable "PC Remote Function" via Help Guide (menu path varies by model).
- FX6/BURANO: Set "Network > SSH > SSH Setting" to "On" for SSH mode; for pairing mode ensure SSH is
  off and PC Remote is enabled.
- Navigate to the **Pairing menu** on the camera before initiating connection.

**Connection flow**:
1. Initiator sends Init_Command_Request with GUID + FriendlyName.
2. Camera displays: *"Allow pairing with the device? 'FriendlyName'"*
3. User presses OK on camera.
4. Camera saves GUID (up to 20 stored) → sends Init_Command_Ack.
5. Connection proceeds normally.

On subsequent connections from the same GUID, the camera does not prompt again.

**Failure signals**: Init_Fail with reason 0x00000001 (Rejected) if user denies; `Authentication_Failed`
(0xA101) if GUID not recognized and pairing menu is not displayed.

### 7.2 SSH Mode (Access Authentication ON)

Required when `X_SSH_Support = "Enable"` in DigitalImagingDesc.xml.

**Camera setup**:
- Set "Network > SSH > SSH Setting" to "On" on the camera.
- Set SSH user/password in "Network > SSH > SSH Access Authentication".
- Supported cipher: **aes128-ctr only**.

**Connection flow**:
1. SSH to camera: `ssh -c aes128-ctr -N -L 15740:localhost:15740 <user>@<camera-ip>` (port 22).
2. Verify SSH host fingerprint against camera's displayed fingerprint.
3. Initiate PTP-IP connection to `localhost:15740` (the forwarded port).
4. Normal PTP-IP Init sequence follows.

Do NOT execute remote SSH commands (`-N` flag). The SSH tunnel is transport-only.

**In-app SSH**: Uses libssh2 with OpenSSL (`scripts/build-cssh.sh`, a binary target in `Package.swift`) to establish the tunnel programmatically. The user verifies the fingerprint on first connection (TOFU).

---

## 8. Gotchas & Open Questions

### Known Gotchas

1. **SDIO_Connect phase order is strict**: phases 1 and 2 must both complete before
   `SDIO_GetExtDeviceInfo`; then phase 3 must follow. Skipping any step leaves the connection in an
   unaccepted state.

2. **GetExtDeviceInfo retry required**: if data size returns zero, retry in a loop until non-zero data is
   received. No maximum retry count is specified; implement a timeout (suggest 10 s).

3. **Extended codes need feature version check**: 0xE000–0xEFFF and 0xF000–0xFFFF properties
   require `SDIO_GetVendorCodeVersion` support and vendor code ≥ 3.10. Always check before
   using Movie Rec Toggle (0xF001), Focus/Zoom with INT16 (0xF003/0xF004), etc.

4. **SSH blocks direct TCP 15740**: when SSH is enabled on camera, plain TCP to port 15740 is rejected.
   The app must detect `X_SSH_Support=Enable` and always tunnel.

5. **FX3/FX30/FX2: live view via GetObject(0xFFFFC002)**:
   When `Live View Status` (0xD221) == 0x01 (Enabled), call `GetObjectInfo(0xFFFFC002)` once,
   then `GetObject(0xFFFFC002)` per frame. Parse the LiveView Dataset to extract the JPEG.
   FX3 verified 2026-10-09: 0xD221=Enabled, 640×360 JPEG at Low quality (0xD26A=0x01),
   ~6835 B avg JPEG, ~7249 B avg on-wire per frame at 1 fps ≈ 58 kbit/s.
   Measured data: `docs/network-budget.md`.
   `0xD278` (LiveViewURL) is for **pan/tilt cameras only** (BRC-AM7, ILME-FR7). The FX3
   reports it but the HTTP endpoint returns 503 — do not use the HTTP path for cinema bodies.
   **FX6 and BURANO**: no live view over the network, and 0xD221 isn't on their lists. Don't attempt
   GetObject(0xFFFFC002) on either; they're watched on their SDI/HDMI.

6. **IsEnabled=False means values are garbage**: Factory Default and Current Value fields are not
   guaranteed when IsEnabled=0x00. Always gate UI on IsEnabled before displaying.

7. **ControlDevice always returns OK at protocol level** even when the physical action fails.
   Read state back after any critical control command.

8. **BURANO = MPC-2610**: no live view and no content transfer over the network, like the FX6. Mostly the FX6's properties; the BURANO alone lists T-Number 0xD000 and the tally lamps 0xE0D2/0xE0D3, and lacks the Hold REC button 0xD2C8. Neither lists timecode (0xD0D3–0xD0D7). Measured: `docs/burano-controls.md`, `docs/fx6-controls.md`.

9. **Mode dependency for Shutter Angle**: `Shutter Angle` (0xD00E) `IsEnabled` will be 0x00 unless
   the camera is in Angle shutter mode. `Shutter Mode Status` (0xD011) = 0x03 confirms angle mode is
   active.

10. **EI vs ISO**: In Cine EI shooting mode (FX3/FX6/BURANO), use `Exposure Index` (0xD022); in other
    modes, use `ISO Sensitivity` (0xD21E). Check `Movie Shooting Mode` (0xE000) to determine which
    applies. `Gain Unit Setting` (0xD01D) on FX6/BURANO indicates whether gain is expressed in dB or
    ISO.

11. **Reconnection after disconnect**: `SDIO_OpenSession` function mode cannot be changed while
    connected — must disconnect and reconnect to switch between Remote Control and Content Transfer
    modes.

12. **Frame rate on video-only cameras**: For FX6/BURANO 0xD286 is the recording frame rate and 0xD028 the
    proxy's. Not all combinations of format + frame rate are valid; the camera will return
    `Device_Busy` or similar if the combination is unsupported.

### Open Questions

1. **Timecode on FX6 and BURANO**: neither camera's dump lists 0xD0D3–0xD0D7 or 0xD1FD. Does either expose any timecode read-back property? Not found in testing.

2. **ND Filter Value encoding**: The UINT64 transmittance ratio (numerator/denominator) is confirmed, but the mapping from "ND steps" (1/4 stop, 1/3 stop, etc.) to specific transmittance ratios
   isn't known. Need empirical measurement on FX6/BURANO hardware, or use
   `SDIO_GetAllExtDevicePropInfo` enumeration list.

3. **ND Filter Preset Value encoding** (0xD075–0xD077): What values represent "Clear", "ND4", "ND16", etc.? Unknown; needs hardware testing.

4. **Clip flag / OK mark**: Not found in PTP 3. Is there an FTP metadata write path, or is this only
   available via physical camera button? Out of scope for v1 unless Sony confirms a mechanism.

5. **Rate-limiting**: no rate limit is known for `SDIO_GetAllExtDevicePropInfo` polling. What is the practical
   minimum poll interval before the camera returns Device_Busy?

6. **Tally lamp on FX3/FX30/FX2**: Red/Green/Yellow Tally properties (0xE0D2–0xE0D4) appear to be pan/tilt camera specific (the BURANO reports two of them); the FX3's dump has none. Confirm whether any tally indication exists for those cameras.

7. **SDIO_OpenSession on FX6/BURANO**: these cameras may not need or support function mode
   selection (Tiles calls 0x9210 and carries on if it's refused). Does the session work without this call, or should it be skipped for those models?
   The standard SDIO_Connect + SDIO_GetExtDeviceInfo sequence applies to all cameras.

