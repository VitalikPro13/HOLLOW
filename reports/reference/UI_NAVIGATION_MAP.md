# UI navigation map

Generated 2026-09-26 by `scripts\ui_nav_map.ps1` from the running app.
Do not hand-edit; regenerate it.

Every row carries the target string the UI probe accepts, so a
scenario can be written from this document without guessing how a
widget is addressed. The grammar is in
``integration_test\probe\probe_targets.dart``.

## Screens

- [01-home](#ui-map-01-home)
- [02-server](#ui-map-02-server)
- [03-channel-menu](#ui-map-03-channel-menu)
- [04-sidebar-menu](#ui-map-04-sidebar-menu)
- [05-server-settings](#ui-map-05-server-settings)
- [06-channels-tab](#ui-map-06-channels-tab)
- [07-member-card](#ui-map-07-member-card)
- [08-settings](#ui-map-08-settings)
- [09-home-dock](#ui-map-09-home-dock)

---

## UI map: 01-home

Screen 1265.6 x 682.4 logical pixels. 149 entries.

### Open surfaces

- dialog open: false
- context menu open: false

### Providers

- server: null (null)
- channel: null (null)
- layout mode: LayoutMode.dock
- peer: null
- identity: 12D3KooWFGeEoJ4dHAgiCErWGzmkDPRgynnB3eRwrEB66ixpXHTJ (loaded: true)
- device: 12D3KooWB344tiTY149CzuMB6r3Ct6bBMT9SpQhzd2cPWsXGwuDr
- connection: connected
- relay: relay.anonlisten.com
- friends (1):
  - 12D3KooWRsPZ7CSeumSbaRhGZBhvsCHvotXMQj3MtwWqyeHbsqQp â€” accepted

#### Server strip

```
```

#### Stored layout

```
(empty layout)
```

### On screen

`y,x` is the top-left corner. Paste a target straight into a scenario; `xN` means the target matches N widgets, so scope it (`dialog > ...`) or pass an index.

| y,x | size | kind | label | target |
|---|---|---|---|---|
| 0,0 | 1266x682 | keyed |  | `key:_ScaffoldSlot.body` |
| 0,1128 | 46x44 | semantics | Minimize | `semantics:Minimize` |
| 0,1174 | 46x44 | semantics | Maximize | `semantics:Maximize` |
| 0,1220 | 46x44 | semantics | Close | `semantics:Close` |
| 6,12 | 32x32 | tooltip | Add friend | `tooltip:Add friend` |
| 6,12 | 32x32 | pressable | Add friend | `semantics:Add friend` x2 |
| 6,12 | 32x32 | semantics | Add friend | `semantics:Add friend` x2 |
| 6,12 | 32x32 | icon | userPlus (0xe1a2) | `icon:userPlus` |
| 6,56 | 94x32 | pressable | probe-b | `semantics:probe-b` x2 |
| 6,56 | 94x32 | keyed |  | `key:12D3KooWRsPZ7CSeumSbaRhGZBhvsCHvotXMQj3MtwWqyeHbsqQp` |
| 6,56 | 94x32 | semantics | probe-b | `semantics:probe-b` x2 |
| 6,1092 | 32x32 | semantics | Annotate the screen | `semantics:Annotate the screen` |
| 6,1092 | 32x32 | icon | pencil (0xe1f9) | `icon:pencil` |
| 13,92 | 50x18 | text | probe-b | `text:probe-b` x2 |
| 14,1143 | 16x16 | icon | 0xe11c | `icon:0xe11c` |
| 14,1189 | 16x16 | icon | 0xe167 | `icon:0xe167` |
| 14,1235 | 16x16 | icon | x (0xe1b2) | `icon:x` |
| 15,66 | 12x13 | text | PR | `text:PR` x3 |
| 15,1032 | 48x15 | text | Annotate | `text:Annotate` |
| 27,77 | 7x7 | semantics | Offline | `semantics:Offline` x2 |
| 44,0 | 1266x581 | keyed |  | `key:single` |
| 44,0 | 1266x581 | keyed |  | `key:(empty, empty)` |
| 68,792 | 142x36 | button | New message | `text:New message` x2 |
| 68,987 | 249x229 | pressable | News | `text:News` x2 |
| 72,544 | 240x28 | field | hint "Search conversations" | `hint:Search conversations` |
| 73,32 | 500x26 | text | Good afternoon, probe-a | `text:Good afternoon, probe-a` |
| 76,588 | 180x20 | text | Search conversations | `text:Search conversations` |
| 76,588 | 180x20 | input |  | `type:EditableText` |
| 78,544 | 40x16 | icon | search (0xe151) | `icon:search` |
| 78,808 | 16x16 | icon | plus (0xe13d) | `icon:plus` x2 |
| 80,832 | 86x13 | text | New message | `text:New message` x2 |
| 85,1003 | 163x18 | text | News | `text:News` x2 |
| 86,1169 | 46x15 | text | v0.11.1 | `text:v0.11.1` |
| 115,1003 | 217x60 | text | v0.11.1 - Linux Call Audio, Self-Hosted Relays, Personal Emotes & Relay Restarts | `text:v0.11.1 - Linux Call Audio, Self-Hosted Relays, Personal Emotes & Relay Restarts` |
| 128,872 | 52x29 | button | Hide | `text:Hide` x2 |
| 132,32 | 84x22 | text | Get Set Up | `text:Get Set Up` |
| 135,124 | 33x15 | text | 3 / 6 | `text:3 / 6` |
| 136,884 | 28x13 | text | Hide | `text:Hide` x2 |
| 173,44 | 20x20 | semantics | Done | `semantics:Done` x3 |
| 173,44 | 20x20 | icon | 0xe226 | `icon:0xe226` x3 |
| 173,76 | 133x20 | text | Create your identity | `text:Create your identity` |
| 177,1003 | 103x15 | text | September 10, 2026 | `text:September 10, 2026` |
| 200,1003 | 217x51 | text | Linux got a bit upgrade on the call stability. Lots of issues with it are now pa... | `text:Linux got a bit upgrade on the call stability. Lots of issues with it are now pa...` |
| 213,44 | 20x20 | semantics | Done | `semantics:Done` x3 |
| 213,44 | 20x20 | icon | 0xe226 | `icon:0xe226` x3 |
| 213,76 | 199x20 | text | Back up your recovery phrase | `text:Back up your recovery phrase` |
| 253,44 | 20x20 | icon | 0xe226 | `icon:0xe226` x3 |
| 253,44 | 20x20 | semantics | Done | `semantics:Done` x3 |
| 253,76 | 81x20 | text | Add a friend | `text:Add a friend` |
| 263,1003 | 120x18 | semantics | What's new in 0.11.1 | `semantics:What's new in 0.11.1` |
| 263,1003 | 120x18 | text | What's new in 0.11.1 | `text:What's new in 0.11.1` |
| 297,76 | 149x20 | text | Join or create a server | `text:Join or create a server` |
| 299,802 | 110x33 | button | Add a server | `text:Add a server` x2 |
| 306,44 | 20x20 | icon | 0xe076 | `icon:0xe076` x3 |
| 306,44 | 20x20 | semantics | Not done yet | `semantics:Not done yet` x3 |
| 309,818 | 78x13 | text | Add a server | `text:Add a server` x2 |
| 317,76 | 295x17 | text | A server is a group space its members host together. | `text:A server is a group space its members host together.` |
| 329,1003 | 143x18 | text | Relay | `text:Relay` |
| 330,1157 | 62x17 | text | Connected | `text:Connected` |
| 349,1003 | 217x15 | text | relay.anonlisten.com | `text:relay.anonlisten.com` |
| 358,801 | 111x29 | button | Choose image | `text:Choose image` x2 |
| 363,44 | 20x20 | semantics | Not done yet | `semantics:Not done yet` x3 |
| 363,44 | 20x20 | icon | 0xe076 | `icon:0xe076` x3 |
| 363,76 | 130x20 | text | Set a profile picture | `text:Set a profile picture` |
| 366,813 | 87x13 | text | Choose image | `text:Choose image` x2 |
| 376,1019 | 127x14 | text | RAM | `text:RAM` |
| 376,1149 | 70x14 | text | 625 / 7940 MB | `text:625 / 7940 MB` |
| 377,1003 | 12x12 | icon | 0xe445 | `icon:0xe445` |
| 406,1019 | 127x14 | text | Bandwidth | `text:Bandwidth` |
| 406,1150 | 70x14 | text | 0.1 / 950 Mbps | `text:0.1 / 950 Mbps` |
| 407,76 | 129x20 | text | Link another device | `text:Link another device` |
| 407,1003 | 12x12 | icon | 0xe038 | `icon:0xe038` |
| 411,819 | 93x29 | button | Link device | `text:Link device` x2 |
| 416,44 | 20x20 | icon | 0xe076 | `icon:0xe076` x3 |
| 416,44 | 20x20 | semantics | Not done yet | `semantics:Not done yet` x3 |
| 419,831 | 69x13 | text | Link device | `text:Link device` x2 |
| 427,76 | 331x17 | text | Use Hollow on your phone and computer with one identity. | `text:Use Hollow on your phone and computer with one identity.` |
| 446,1019 | 194x14 | text | Online | `text:Online` |
| 446,1213 | 7x14 | text | 5 | `text:5` |
| 447,1003 | 12x12 | icon | users (0xe1a4) | `icon:users` |
| 480,738 | 33x28 | pressable | All | `text:All` x2 |
| 480,778 | 63x28 | pressable | Unread | `text:Unread` x2 |
| 480,849 | 74x28 | pressable | Mentions | `text:Mentions` x2 |
| 483,32 | 109x22 | text | Conversations | `text:Conversations` |
| 485,747 | 15x18 | text | All | `text:All` x2 |
| 485,787 | 45x18 | text | Unread | `text:Unread` x2 |
| 485,858 | 56x18 | text | Mentions | `text:Mentions` x2 |
| 492,987 | 88x22 | text | Active Now | `text:Active Now` |
| 516,24 | 908x53 | keyed |  | `key:[<'saved'>]` |
| 516,24 | 908x53 | keyed |  | `key:saved` |
| 516,24 | 908x53 | pressable | Saved messages,  | `semantics:Saved messages, ` x2 |
| 516,24 | 908x53 | semantics | Saved messages, | `semantics:Saved messages, ` x2 |
| 522,987 | 156x17 | text | Nobody is around right now | `text:Nobody is around right now` |
| 524,80 | 111x20 | text | Saved messages | `text:Saved messages` |
| 534,41 | 18x18 | icon | 0xe060 | `icon:0xe060` |
| 543,987 | 249x30 | text | Friends who are online, and voice rooms they are in, show up here. | `text:Friends who are online, and voice rooms they are in, show up here.` |
| 569,24 | 908x53 | pressable | probe-b, No messages yet | `semantics:probe-b, No messages yet` x2 |
| 569,24 | 908x53 | keyed |  | `key:dm:12D3KooWRsPZ7CSeumSbaRhGZBhvsCHvotXMQj3MtwWqyeHbsqQp` |
| 569,24 | 908x53 | semantics | probe-b, No messages yet | `semantics:probe-b, No messages yet` x2 |
| 569,24 | 908x53 | keyed |  | `key:[<'dm:12D3KooWRsPZ7CSeumSbaRhGZBhvsCHvotXMQj3MtwWqyeHbsqQp'>]` |
| 577,80 | 54x20 | text | probe-b | `text:probe-b` x2 |
| 586,41 | 18x19 | text | PR | `text:PR` x3 |
| 597,80 | 97x17 | text | No messages yet | `text:No messages yet` |
| 606,60 | 8x8 | semantics | Offline | `semantics:Offline` x2 |
| 634,138 | 40x40 | pressable | Home | `semantics:Home` x2 |
| 634,138 | 40x40 | tooltip | Home | `tooltip:Home` |
| 634,138 | 40x40 | semantics | Home | `semantics:Home` x2 |
| 634,194 | 40x40 | tooltip | Create a server | `tooltip:Create a server` |
| 634,194 | 40x40 | pressable | Create a server | `semantics:Create a server` x2 |
| 634,194 | 40x40 | semantics | Create a server | `semantics:Create a server` x2 |
| 636,12 | 101x36 | semantics | probe-a, Online | `semantics:probe-a, Online` x2 |
| 636,12 | 101x36 | pressable | probe-a, Online | `semantics:probe-a, Online` x2 |
| 636,12 | 101x36 | tooltip | Your profile and status | `tooltip:Your profile and status` |
| 638,949 | 32x32 | tooltip | Conferences | `tooltip:Conferences` |
| 638,949 | 32x32 | pressable | Conferences | `semantics:Conferences` x2 |
| 638,949 | 32x32 | semantics | Conferences | `semantics:Conferences` x2 |
| 638,949 | 32x32 | icon | video (0xe1a5) | `icon:video` |
| 638,985 | 32x32 | tooltip | Public channels | `tooltip:Public channels` |
| 638,985 | 32x32 | pressable | Public channels | `semantics:Public channels` x2 |
| 638,985 | 32x32 | semantics | Public channels | `semantics:Public channels` x2 |
| 638,985 | 32x32 | icon | globe (0xe0e8) | `icon:globe` |
| 638,1021 | 32x32 | tooltip | Share | `tooltip:Share` |
| 638,1021 | 32x32 | pressable | Share | `semantics:Share` x2 |
| 638,1021 | 32x32 | semantics | Share | `semantics:Share` x2 |
| 638,1021 | 32x32 | icon | 0xe156 | `icon:0xe156` |
| 638,1057 | 32x32 | tooltip | Archive | `tooltip:Archive` |
| 638,1057 | 32x32 | pressable | Archive | `semantics:Archive` x2 |
| 638,1057 | 32x32 | semantics | Archive | `semantics:Archive` x2 |
| 638,1057 | 32x32 | icon | 0xe041 | `icon:0xe041` |
| 638,1093 | 32x32 | pressable | Hollow Shop | `semantics:Hollow Shop` x2 |
| 638,1093 | 32x32 | semantics | Hollow Shop | `semantics:Hollow Shop` x2 |
| 638,1093 | 32x32 | icon | 0xe3e4 | `icon:0xe3e4` |
| 638,1093 | 32x32 | tooltip | Hollow Shop | `tooltip:Hollow Shop` |
| 638,1150 | 32x32 | icon | download (0xe0b2) | `icon:download` |
| 638,1150 | 32x32 | semantics | Downloads | `semantics:Downloads` x2 |
| 638,1150 | 32x32 | pressable | Downloads | `semantics:Downloads` x2 |
| 638,1150 | 32x32 | tooltip | Downloads | `tooltip:Downloads` |
| 638,1186 | 32x32 | pressable | Help | `semantics:Help` x2 |
| 638,1186 | 32x32 | semantics | Help | `semantics:Help` x2 |
| 638,1186 | 32x32 | icon | 0xe082 | `icon:0xe082` |
| 638,1186 | 32x32 | tooltip | Help | `tooltip:Help` |
| 638,1222 | 32x32 | tooltip | Settings | `tooltip:Settings` |
| 638,1222 | 32x32 | pressable | Settings | `semantics:Settings` x2 |
| 638,1222 | 32x32 | semantics | Settings | `semantics:Settings` x2 |
| 638,1222 | 32x32 | icon | settings (0xe154) | `icon:settings` |
| 644,204 | 20x20 | icon | plus (0xe13d) | `icon:plus` x2 |
| 645,56 | 49x18 | text | probe-a | `text:probe-a` |
| 647,27 | 14x15 | text | PR | `text:PR` x3 |
| 661,41 | 7x7 | semantics | Online | `semantics:Online` |

---

## UI map: 02-server

Screen 1265.6 x 682.4 logical pixels. 152 entries.

### Open surfaces

- dialog open: false
- context menu open: false

### Providers

- server: navmap (45f623ca41ad07fd661d0cbaf0b7938f)
- channel: general (45f623ca-general)
- layout mode: LayoutMode.dock
- peer: null
- identity: 12D3KooWFGeEoJ4dHAgiCErWGzmkDPRgynnB3eRwrEB66ixpXHTJ (loaded: true)
- device: 12D3KooWB344tiTY149CzuMB6r3Ct6bBMT9SpQhzd2cPWsXGwuDr
- connection: connected
- relay: relay.anonlisten.com
- friends (1):
  - 12D3KooWRsPZ7CSeumSbaRhGZBhvsCHvotXMQj3MtwWqyeHbsqQp â€” accepted

#### Server strip

```
server navmap
```

#### Stored layout

```
(empty layout)
```

#### Effective layout (stored + unplaced channels)

```
[0] general (text, 45f623ca-general)
```

### On screen

`y,x` is the top-left corner. Paste a target straight into a scenario; `xN` means the target matches N widgets, so scope it (`dialog > ...`) or pass an index.

| y,x | size | kind | label | target |
|---|---|---|---|---|
| 0,0 | 1266x682 | keyed |  | `key:_ScaffoldSlot.body` |
| 0,1128 | 46x44 | semantics | Minimize | `semantics:Minimize` |
| 0,1174 | 46x44 | semantics | Maximize | `semantics:Maximize` |
| 0,1220 | 46x44 | semantics | Close | `semantics:Close` |
| 6,12 | 32x32 | tooltip | Add friend | `tooltip:Add friend` |
| 6,12 | 32x32 | pressable | Add friend | `semantics:Add friend` x2 |
| 6,12 | 32x32 | semantics | Add friend | `semantics:Add friend` x2 |
| 6,12 | 32x32 | icon | userPlus (0xe1a2) | `icon:userPlus` x2 |
| 6,56 | 94x32 | keyed |  | `key:12D3KooWRsPZ7CSeumSbaRhGZBhvsCHvotXMQj3MtwWqyeHbsqQp` |
| 6,56 | 94x32 | pressable | probe-b | `semantics:probe-b` x2 |
| 6,56 | 94x32 | semantics | probe-b | `semantics:probe-b` x2 |
| 6,1092 | 32x32 | semantics | Annotate the screen | `semantics:Annotate the screen` |
| 6,1092 | 32x32 | icon | pencil (0xe1f9) | `icon:pencil` |
| 13,92 | 50x18 | text | probe-b | `text:probe-b` |
| 14,1143 | 16x16 | icon | 0xe11c | `icon:0xe11c` |
| 14,1189 | 16x16 | icon | 0xe167 | `icon:0xe167` |
| 14,1235 | 16x16 | icon | x (0xe1b2) | `icon:x` |
| 15,66 | 12x13 | text | PR | `text:PR` x3 |
| 15,1032 | 48x15 | text | Annotate | `text:Annotate` |
| 27,77 | 7x7 | semantics | Offline | `semantics:Offline` |
| 44,0 | 240x48 | keyed |  | `key:header-navmap` |
| 44,240 | 6x581 | semantics | Resize the channel list | `semantics:Resize the channel list` |
| 44,246 | 734x581 | keyed |  | `key:single` |
| 44,246 | 734x581 | keyed |  | `key:(45f623ca-general, 45f623ca-general)` |
| 44,246 | 734x581 | keyed |  | `key:ch:45f623ca-general` |
| 44,980 | 6x581 | semantics | Resize the member list | `semantics:Resize the member list` |
| 52,864 | 32x32 | tooltip | Search messages | `tooltip:Search messages` |
| 52,864 | 32x32 | pressable | Search messages | `semantics:Search messages` x2 |
| 52,864 | 32x32 | semantics | Search messages | `semantics:Search messages` x2 |
| 52,864 | 32x32 | icon | search (0xe151) | `icon:search` |
| 52,900 | 32x32 | pressable | Split view | `semantics:Split view` x2 |
| 52,900 | 32x32 | tooltip | Split view | `tooltip:Split view` |
| 52,900 | 32x32 | semantics | Split view | `semantics:Split view` x2 |
| 52,900 | 32x32 | icon | 0xe098 | `icon:0xe098` |
| 52,936 | 32x32 | semantics | Hide members | `semantics:Hide members` x2 |
| 52,936 | 32x32 | tooltip | Hide members | `tooltip:Hide members` |
| 52,936 | 32x32 | pressable | Hide members | `semantics:Hide members` x2 |
| 52,936 | 32x32 | icon | users (0xe1a4) | `icon:users` x3 |
| 56,160 | 24x24 | tooltip | Invite people | `tooltip:Invite people` |
| 56,160 | 24x24 | pressable | Invite people | `semantics:Invite people` x2 |
| 56,160 | 24x24 | semantics | Invite people | `semantics:Invite people` x2 |
| 56,184 | 24x24 | tooltip | Files & storage | `tooltip:Files & storage` |
| 56,184 | 24x24 | pressable | Files & storage | `semantics:Files & storage` x2 |
| 56,184 | 24x24 | semantics | Files & storage | `semantics:Files & storage` x2 |
| 56,208 | 24x24 | tooltip | Server settings | `tooltip:Server settings` |
| 56,208 | 24x24 | semantics | Server settings | `semantics:Server settings` x2 |
| 56,208 | 24x24 | pressable | Server settings | `semantics:Server settings` x2 |
| 57,16 | 144x22 | text | navmap | `text:navmap` |
| 57,290 | 57x22 | text | general | `text:general` x3 |
| 57,1030 | 70x22 | text | Members | `text:Members` |
| 58,262 | 20x20 | icon | hash (0xe0ef) | `icon:hash` x3 |
| 58,1002 | 20x20 | icon | users (0xe1a4) | `icon:users` x3 |
| 60,164 | 16x16 | icon | userPlus (0xe1a2) | `icon:userPlus` x2 |
| 60,188 | 16x16 | icon | hardDrive (0xe0ed) | `icon:hardDrive` |
| 60,212 | 16x16 | icon | settings (0xe154) | `icon:settings` x2 |
| 60,787 | 64x15 | keyed |  | `key:conn-45f623ca41ad07fd661d0cbaf0b7938f` |
| 60,787 | 64x15 | tooltip | You're connected. Nobody else is online here right now | `tooltip:You're connected. Nobody else is online here right now` |
| 60,805 | 46x15 | text | Only you | `text:Only you` |
| 61,787 | 14x14 | icon | users (0xe1a4) | `icon:users` x3 |
| 92,0 | 240x533 | keyed |  | `key:server-45f623ca41ad07fd661d0cbaf0b7938f` |
| 92,986 | 280x533 | keyed |  | `key:members:45f623ca41ad07fd661d0cbaf0b7938f` |
| 100,994 | 254x34 | keyed |  | `key:[<'group:Owner'>]` |
| 100,994 | 254x34 | keyed |  | `key:group:Owner` |
| 100,994 | 254x34 | pressable | Collapse Owner, 1 member | `semantics:Collapse Owner, 1 member` x2 |
| 100,994 | 254x34 | semantics | Collapse Owner, 1 member | `semantics:Collapse Owner, 1 member` x2 |
| 104,210 | 22x22 | pressable | Create channel | `semantics:Create channel` x2 |
| 104,210 | 22x22 | semantics | Create channel | `semantics:Create channel` x2 |
| 106,18 | 85x18 | text | Text channels | `text:Text channels` |
| 108,214 | 14x14 | icon | plus (0xe13d) | `icon:plus` x3 |
| 108,1002 | 41x18 | text | Owner | `text:Owner` |
| 110,1051 | 7x15 | text | 1 | `text:1` |
| 110,1226 | 14x14 | icon | chevronDown (0xe06d) | `icon:chevronDown` |
| 134,994 | 254x36 | semantics | probe-a | `semantics:probe-a` x2 |
| 134,994 | 254x36 | pressable | probe-a | `semantics:probe-a` x2 |
| 134,994 | 254x36 | keyed |  | `key:member:12D3KooWFGeEoJ4dHAgiCErWGzmkDPRgynnB3eRwrEB66ixpXHTJ` |
| 134,994 | 254x36 | keyed |  | `key:[<'member:12D3KooWFGeEoJ4dHAgiCErWGzmkDPRgynnB3eRwrEB66ixpXHTJ'>]` |
| 138,0 | 230x40 | keyed |  | `key:ach-45f623ca-general` |
| 138,0 | 230x40 | keyed |  | `key:[<'ach-45f623ca-general'>]` |
| 140,10 | 220x36 | pressable | general | `text:general` x3 |
| 142,1042 | 53x20 | text | probe-a | `text:probe-a` x2 |
| 144,1010 | 16x17 | text | PR | `text:PR` x3 |
| 148,46 | 174x20 | text | general | `text:general` x3 |
| 149,20 | 18x18 | icon | hash (0xe0ef) | `icon:hash` x3 |
| 161,1027 | 7x7 | semantics | Online | `semantics:Online` x2 |
| 289,601 | 24x24 | icon | hash (0xe0ef) | `icon:hash` x3 |
| 325,543 | 140x20 | text | Welcome to #general | `text:Welcome to #general` |
| 349,521 | 185x15 | text | This is the beginning of the channel. | `text:This is the beginning of the channel.` |
| 569,310 | 606x48 | field | hint "Message #general" | `hint:Message #general` |
| 573,258 | 44x44 | icon | plus (0xe13d) | `icon:plus` x3 |
| 573,258 | 44x44 | semantics | Attach a file | `semantics:Attach a file` x2 |
| 573,258 | 44x44 | pressable | Attach a file | `semantics:Attach a file` x2 |
| 573,258 | 44x44 | tooltip | Attach a file | `tooltip:Attach a file` |
| 573,924 | 44x44 | semantics | Record a voice message | `semantics:Record a voice message` x2 |
| 573,924 | 44x44 | pressable | Record a voice message | `semantics:Record a voice message` x2 |
| 573,924 | 44x44 | tooltip | Record a voice message | `tooltip:Record a voice message` |
| 573,924 | 44x44 | icon | mic (0xe118) | `icon:mic` |
| 577,880 | 32x32 | icon | smile (0xe164) | `icon:smile` |
| 577,880 | 32x32 | semantics | Emoji, GIFs and stickers | `semantics:Emoji, GIFs and stickers` x2 |
| 577,880 | 32x32 | pressable | Emoji, GIFs and stickers | `semantics:Emoji, GIFs and stickers` x2 |
| 577,880 | 32x32 | tooltip | Emoji, GIFs and stickers | `tooltip:Emoji, GIFs and stickers` |
| 583,326 | 550x20 | text | Message #general | `text:Message #general` |
| 583,326 | 550x20 | input |  | `type:EditableText` |
| 634,138 | 40x40 | tooltip | Home | `tooltip:Home` |
| 634,138 | 40x40 | semantics | Home | `semantics:Home` x2 |
| 634,138 | 40x40 | pressable | Home | `semantics:Home` x2 |
| 634,194 | 40x40 | pressable | navmap | `semantics:navmap` x2 |
| 634,194 | 40x40 | keyed |  | `key:bounce-45f623ca41ad07fd661d0cbaf0b7938f` |
| 634,194 | 40x40 | semantics | navmap | `semantics:navmap` x2 |
| 634,194 | 40x40 | tooltip | navmap | `tooltip:navmap` |
| 634,242 | 40x40 | tooltip | Create a server | `tooltip:Create a server` |
| 634,242 | 40x40 | pressable | Create a server | `semantics:Create a server` x2 |
| 634,242 | 40x40 | semantics | Create a server | `semantics:Create a server` x2 |
| 636,12 | 101x36 | tooltip | Your profile and status | `tooltip:Your profile and status` |
| 636,12 | 101x36 | pressable | probe-a, Online | `semantics:probe-a, Online` x2 |
| 636,12 | 101x36 | semantics | probe-a, Online | `semantics:probe-a, Online` x2 |
| 638,949 | 32x32 | pressable | Conferences | `semantics:Conferences` x2 |
| 638,949 | 32x32 | tooltip | Conferences | `tooltip:Conferences` |
| 638,949 | 32x32 | semantics | Conferences | `semantics:Conferences` x2 |
| 638,949 | 32x32 | icon | video (0xe1a5) | `icon:video` |
| 638,985 | 32x32 | pressable | Public channels | `semantics:Public channels` x2 |
| 638,985 | 32x32 | semantics | Public channels | `semantics:Public channels` x2 |
| 638,985 | 32x32 | icon | globe (0xe0e8) | `icon:globe` |
| 638,985 | 32x32 | tooltip | Public channels | `tooltip:Public channels` |
| 638,1021 | 32x32 | tooltip | Share | `tooltip:Share` |
| 638,1021 | 32x32 | pressable | Share | `semantics:Share` x2 |
| 638,1021 | 32x32 | icon | 0xe156 | `icon:0xe156` |
| 638,1021 | 32x32 | semantics | Share | `semantics:Share` x2 |
| 638,1057 | 32x32 | tooltip | Archive | `tooltip:Archive` |
| 638,1057 | 32x32 | pressable | Archive | `semantics:Archive` x2 |
| 638,1057 | 32x32 | semantics | Archive | `semantics:Archive` x2 |
| 638,1057 | 32x32 | icon | 0xe041 | `icon:0xe041` |
| 638,1093 | 32x32 | tooltip | Hollow Shop | `tooltip:Hollow Shop` |
| 638,1093 | 32x32 | semantics | Hollow Shop | `semantics:Hollow Shop` x2 |
| 638,1093 | 32x32 | icon | 0xe3e4 | `icon:0xe3e4` |
| 638,1093 | 32x32 | pressable | Hollow Shop | `semantics:Hollow Shop` x2 |
| 638,1150 | 32x32 | semantics | Downloads | `semantics:Downloads` x2 |
| 638,1150 | 32x32 | pressable | Downloads | `semantics:Downloads` x2 |
| 638,1150 | 32x32 | tooltip | Downloads | `tooltip:Downloads` |
| 638,1150 | 32x32 | icon | download (0xe0b2) | `icon:download` |
| 638,1186 | 32x32 | pressable | Help | `semantics:Help` x2 |
| 638,1186 | 32x32 | semantics | Help | `semantics:Help` x2 |
| 638,1186 | 32x32 | icon | 0xe082 | `icon:0xe082` |
| 638,1186 | 32x32 | tooltip | Help | `tooltip:Help` |
| 638,1222 | 32x32 | tooltip | Settings | `tooltip:Settings` |
| 638,1222 | 32x32 | pressable | Settings | `semantics:Settings` x2 |
| 638,1222 | 32x32 | semantics | Settings | `semantics:Settings` x2 |
| 638,1222 | 32x32 | icon | settings (0xe154) | `icon:settings` x2 |
| 644,252 | 20x20 | icon | plus (0xe13d) | `icon:plus` x3 |
| 645,56 | 49x18 | text | probe-a | `text:probe-a` x2 |
| 645,205 | 19x18 | text | NA | `text:NA` |
| 647,27 | 14x15 | text | PR | `text:PR` x3 |
| 661,41 | 7x7 | semantics | Online | `semantics:Online` x2 |

---

## UI map: 03-channel-menu

Screen 1265.6 x 682.4 logical pixels. 178 entries.

### Open surfaces

- dialog open: false
- context menu open: true
- menu rows: Mark as read | Mute channel | Rename channel | Visibility | Everyone | Who can post | Everyone | Temporary access | Delete channel

### Providers

- server: navmap (45f623ca41ad07fd661d0cbaf0b7938f)
- channel: general (45f623ca-general)
- layout mode: LayoutMode.dock
- peer: null
- identity: 12D3KooWFGeEoJ4dHAgiCErWGzmkDPRgynnB3eRwrEB66ixpXHTJ (loaded: true)
- device: 12D3KooWB344tiTY149CzuMB6r3Ct6bBMT9SpQhzd2cPWsXGwuDr
- connection: connected
- relay: relay.anonlisten.com
- friends (1):
  - 12D3KooWRsPZ7CSeumSbaRhGZBhvsCHvotXMQj3MtwWqyeHbsqQp â€” accepted

#### Server strip

```
server navmap
```

#### Stored layout

```
(empty layout)
```

#### Effective layout (stored + unplaced channels)

```
[0] general (text, 45f623ca-general)
```

### On screen

`y,x` is the top-left corner. Paste a target straight into a scenario; `xN` means the target matches N widgets, so scope it (`dialog > ...`) or pass an index.

| y,x | size | kind | label | target |
|---|---|---|---|---|
| 0,0 | 1266x682 | keyed |  | `key:_ScaffoldSlot.body` |
| 0,0 | 1266x682 | surface |  | `type:_HollowMenuHost` |
| 0,1128 | 46x44 | semantics | Minimize | `semantics:Minimize` |
| 0,1174 | 46x44 | semantics | Maximize | `semantics:Maximize` |
| 0,1220 | 46x44 | semantics | Close | `semantics:Close` |
| 6,12 | 32x32 | tooltip | Add friend | `tooltip:Add friend` |
| 6,12 | 32x32 | pressable | Add friend | `semantics:Add friend` x2 |
| 6,12 | 32x32 | semantics | Add friend | `semantics:Add friend` x2 |
| 6,12 | 32x32 | icon | userPlus (0xe1a2) | `icon:userPlus` x3 |
| 6,56 | 94x32 | keyed |  | `key:12D3KooWRsPZ7CSeumSbaRhGZBhvsCHvotXMQj3MtwWqyeHbsqQp` |
| 6,56 | 94x32 | pressable | probe-b | `semantics:probe-b` x2 |
| 6,56 | 94x32 | semantics | probe-b | `semantics:probe-b` x2 |
| 6,1092 | 32x32 | semantics | Annotate the screen | `semantics:Annotate the screen` |
| 6,1092 | 32x32 | icon | pencil (0xe1f9) | `icon:pencil` x2 |
| 13,92 | 50x18 | text | probe-b | `text:probe-b` |
| 14,1143 | 16x16 | icon | 0xe11c | `icon:0xe11c` |
| 14,1189 | 16x16 | icon | 0xe167 | `icon:0xe167` |
| 14,1235 | 16x16 | icon | x (0xe1b2) | `icon:x` |
| 15,66 | 12x13 | text | PR | `text:PR` x3 |
| 15,1032 | 48x15 | text | Annotate | `text:Annotate` |
| 27,77 | 7x7 | semantics | Offline | `semantics:Offline` |
| 44,0 | 240x48 | keyed |  | `key:header-navmap` |
| 44,240 | 6x581 | semantics | Resize the channel list | `semantics:Resize the channel list` |
| 44,246 | 734x581 | keyed |  | `key:(45f623ca-general, 45f623ca-general)` |
| 44,246 | 734x581 | keyed |  | `key:single` |
| 44,246 | 734x581 | keyed |  | `key:ch:45f623ca-general` |
| 44,980 | 6x581 | semantics | Resize the member list | `semantics:Resize the member list` |
| 52,864 | 32x32 | tooltip | Search messages | `tooltip:Search messages` |
| 52,864 | 32x32 | pressable | Search messages | `semantics:Search messages` x2 |
| 52,864 | 32x32 | semantics | Search messages | `semantics:Search messages` x2 |
| 52,864 | 32x32 | icon | search (0xe151) | `icon:search` |
| 52,900 | 32x32 | tooltip | Split view | `tooltip:Split view` |
| 52,900 | 32x32 | pressable | Split view | `semantics:Split view` x2 |
| 52,900 | 32x32 | semantics | Split view | `semantics:Split view` x2 |
| 52,900 | 32x32 | icon | 0xe098 | `icon:0xe098` |
| 52,936 | 32x32 | tooltip | Hide members | `tooltip:Hide members` |
| 52,936 | 32x32 | pressable | Hide members | `semantics:Hide members` x2 |
| 52,936 | 32x32 | semantics | Hide members | `semantics:Hide members` x2 |
| 52,936 | 32x32 | icon | users (0xe1a4) | `icon:users` x3 |
| 56,160 | 24x24 | tooltip | Invite people | `tooltip:Invite people` |
| 56,160 | 24x24 | pressable | Invite people | `semantics:Invite people` x2 |
| 56,160 | 24x24 | semantics | Invite people | `semantics:Invite people` x2 |
| 56,184 | 24x24 | tooltip | Files & storage | `tooltip:Files & storage` |
| 56,184 | 24x24 | pressable | Files & storage | `semantics:Files & storage` x2 |
| 56,184 | 24x24 | semantics | Files & storage | `semantics:Files & storage` x2 |
| 56,208 | 24x24 | tooltip | Server settings | `tooltip:Server settings` |
| 56,208 | 24x24 | pressable | Server settings | `semantics:Server settings` x2 |
| 56,208 | 24x24 | semantics | Server settings | `semantics:Server settings` x2 |
| 57,16 | 144x22 | text | navmap | `text:navmap` |
| 57,290 | 57x22 | text | general | `text:general` x3 |
| 57,1030 | 70x22 | text | Members | `text:Members` |
| 58,262 | 20x20 | icon | hash (0xe0ef) | `icon:hash` x3 |
| 58,1002 | 20x20 | icon | users (0xe1a4) | `icon:users` x3 |
| 60,164 | 16x16 | icon | userPlus (0xe1a2) | `icon:userPlus` x3 |
| 60,188 | 16x16 | icon | hardDrive (0xe0ed) | `icon:hardDrive` |
| 60,212 | 16x16 | icon | settings (0xe154) | `icon:settings` x2 |
| 60,787 | 64x15 | tooltip | You're connected. Nobody else is online here right now | `tooltip:You're connected. Nobody else is online here right now` |
| 60,787 | 64x15 | keyed |  | `key:conn-45f623ca41ad07fd661d0cbaf0b7938f` |
| 60,805 | 46x15 | text | Only you | `text:Only you` |
| 61,787 | 14x14 | icon | users (0xe1a4) | `icon:users` x3 |
| 92,0 | 240x533 | keyed |  | `key:server-45f623ca41ad07fd661d0cbaf0b7938f` |
| 92,986 | 280x533 | keyed |  | `key:members:45f623ca41ad07fd661d0cbaf0b7938f` |
| 100,994 | 254x34 | keyed |  | `key:[<'group:Owner'>]` |
| 100,994 | 254x34 | keyed |  | `key:group:Owner` |
| 100,994 | 254x34 | pressable | Collapse Owner, 1 member | `semantics:Collapse Owner, 1 member` x2 |
| 100,994 | 254x34 | semantics | Collapse Owner, 1 member | `semantics:Collapse Owner, 1 member` x2 |
| 104,210 | 22x22 | semantics | Create channel | `semantics:Create channel` x2 |
| 104,210 | 22x22 | pressable | Create channel | `semantics:Create channel` x2 |
| 106,18 | 85x18 | text | Text channels | `text:Text channels` |
| 108,214 | 14x14 | icon | plus (0xe13d) | `icon:plus` x3 |
| 108,1002 | 41x18 | text | Owner | `text:Owner` |
| 110,1051 | 7x15 | text | 1 | `text:1` |
| 110,1226 | 14x14 | icon | chevronDown (0xe06d) | `icon:chevronDown` |
| 134,994 | 254x36 | pressable | probe-a | `semantics:probe-a` x2 |
| 134,994 | 254x36 | keyed |  | `key:[<'member:12D3KooWFGeEoJ4dHAgiCErWGzmkDPRgynnB3eRwrEB66ixpXHTJ'>]` |
| 134,994 | 254x36 | keyed |  | `key:member:12D3KooWFGeEoJ4dHAgiCErWGzmkDPRgynnB3eRwrEB66ixpXHTJ` |
| 134,994 | 254x36 | semantics | probe-a | `semantics:probe-a` x2 |
| 138,0 | 230x40 | keyed |  | `key:[<'ach-45f623ca-general'>]` |
| 138,0 | 230x40 | keyed |  | `key:ach-45f623ca-general` |
| 140,10 | 220x36 | pressable | general | `text:general` x3 |
| 142,1042 | 53x20 | text | probe-a | `text:probe-a` x2 |
| 144,1010 | 16x17 | text | PR | `text:PR` x3 |
| 148,46 | 174x20 | text | general | `text:general` x3 |
| 149,20 | 18x18 | icon | hash (0xe0ef) | `icon:hash` x3 |
| 159,134 | 308x34 | pressable | Mark as read | `text:Mark as read` x2 |
| 161,1027 | 7x7 | semantics | Online | `semantics:Online` x2 |
| 167,167 | 265x18 | text | Mark as read | `text:Mark as read` x2 |
| 169,144 | 15x15 | icon | 0xe38e | `icon:0xe38e` |
| 193,134 | 308x34 | pressable | Mute channel | `text:Mute channel` x2 |
| 201,167 | 265x18 | text | Mute channel | `text:Mute channel` x2 |
| 203,144 | 15x15 | icon | bellOff (0xe05a) | `icon:bellOff` |
| 232,134 | 308x34 | pressable | Rename channel | `text:Rename channel` x2 |
| 240,167 | 265x18 | text | Rename channel | `text:Rename channel` x2 |
| 242,144 | 15x15 | icon | pencil (0xe1f9) | `icon:pencil` x2 |
| 266,134 | 308x34 | pressable | Visibility | `text:Visibility` x2 |
| 274,167 | 190x18 | text | Visibility | `text:Visibility` x2 |
| 276,144 | 15x15 | icon | eye (0xe0ba) | `icon:eye` |
| 276,365 | 49x15 | text | Everyone | `text:Everyone` x2 |
| 276,418 | 14x14 | icon | chevronRight (0xe06f) | `icon:chevronRight` x2 |
| 289,601 | 24x24 | icon | hash (0xe0ef) | `icon:hash` x3 |
| 300,134 | 308x34 | pressable | Who can post | `text:Who can post` x2 |
| 308,167 | 190x18 | text | Who can post | `text:Who can post` x2 |
| 310,144 | 15x15 | icon | messageSquare (0xe117) | `icon:messageSquare` |
| 310,365 | 49x15 | text | Everyone | `text:Everyone` x2 |
| 310,418 | 14x14 | icon | chevronRight (0xe06f) | `icon:chevronRight` x2 |
| 325,543 | 140x20 | text | Welcome to #general | `text:Welcome to #general` |
| 334,134 | 308x34 | pressable | Temporary access | `text:Temporary access` x2 |
| 342,167 | 265x18 | text | Temporary access | `text:Temporary access` x2 |
| 344,144 | 15x15 | icon | userPlus (0xe1a2) | `icon:userPlus` x3 |
| 349,521 | 185x15 | text | This is the beginning of the channel. | `text:This is the beginning of the channel.` |
| 373,134 | 308x34 | pressable | Delete channel | `text:Delete channel` x2 |
| 381,167 | 265x18 | text | Delete channel | `text:Delete channel` x2 |
| 383,144 | 15x15 | icon | trash2 (0xe18e) | `icon:trash2` |
| 569,310 | 606x48 | field | hint "Message #general" | `hint:Message #general` |
| 573,258 | 44x44 | tooltip | Attach a file | `tooltip:Attach a file` |
| 573,258 | 44x44 | pressable | Attach a file | `semantics:Attach a file` x2 |
| 573,258 | 44x44 | semantics | Attach a file | `semantics:Attach a file` x2 |
| 573,258 | 44x44 | icon | plus (0xe13d) | `icon:plus` x3 |
| 573,924 | 44x44 | icon | mic (0xe118) | `icon:mic` |
| 573,924 | 44x44 | semantics | Record a voice message | `semantics:Record a voice message` x2 |
| 573,924 | 44x44 | pressable | Record a voice message | `semantics:Record a voice message` x2 |
| 573,924 | 44x44 | tooltip | Record a voice message | `tooltip:Record a voice message` |
| 577,880 | 32x32 | icon | smile (0xe164) | `icon:smile` |
| 577,880 | 32x32 | tooltip | Emoji, GIFs and stickers | `tooltip:Emoji, GIFs and stickers` |
| 577,880 | 32x32 | pressable | Emoji, GIFs and stickers | `semantics:Emoji, GIFs and stickers` x2 |
| 577,880 | 32x32 | semantics | Emoji, GIFs and stickers | `semantics:Emoji, GIFs and stickers` x2 |
| 583,326 | 550x20 | input |  | `type:EditableText` |
| 583,326 | 550x20 | text | Message #general | `text:Message #general` |
| 634,138 | 40x40 | semantics | Home | `semantics:Home` x2 |
| 634,138 | 40x40 | pressable | Home | `semantics:Home` x2 |
| 634,138 | 40x40 | tooltip | Home | `tooltip:Home` |
| 634,194 | 40x40 | semantics | navmap | `semantics:navmap` x2 |
| 634,194 | 40x40 | pressable | navmap | `semantics:navmap` x2 |
| 634,194 | 40x40 | tooltip | navmap | `tooltip:navmap` |
| 634,194 | 40x40 | keyed |  | `key:bounce-45f623ca41ad07fd661d0cbaf0b7938f` |
| 634,242 | 40x40 | tooltip | Create a server | `tooltip:Create a server` |
| 634,242 | 40x40 | pressable | Create a server | `semantics:Create a server` x2 |
| 634,242 | 40x40 | semantics | Create a server | `semantics:Create a server` x2 |
| 636,12 | 101x36 | semantics | probe-a, Online | `semantics:probe-a, Online` x2 |
| 636,12 | 101x36 | pressable | probe-a, Online | `semantics:probe-a, Online` x2 |
| 636,12 | 101x36 | tooltip | Your profile and status | `tooltip:Your profile and status` |
| 638,949 | 32x32 | icon | video (0xe1a5) | `icon:video` |
| 638,949 | 32x32 | tooltip | Conferences | `tooltip:Conferences` |
| 638,949 | 32x32 | pressable | Conferences | `semantics:Conferences` x2 |
| 638,949 | 32x32 | semantics | Conferences | `semantics:Conferences` x2 |
| 638,985 | 32x32 | tooltip | Public channels | `tooltip:Public channels` |
| 638,985 | 32x32 | pressable | Public channels | `semantics:Public channels` x2 |
| 638,985 | 32x32 | icon | globe (0xe0e8) | `icon:globe` |
| 638,985 | 32x32 | semantics | Public channels | `semantics:Public channels` x2 |
| 638,1021 | 32x32 | tooltip | Share | `tooltip:Share` |
| 638,1021 | 32x32 | pressable | Share | `semantics:Share` x2 |
| 638,1021 | 32x32 | semantics | Share | `semantics:Share` x2 |
| 638,1021 | 32x32 | icon | 0xe156 | `icon:0xe156` |
| 638,1057 | 32x32 | tooltip | Archive | `tooltip:Archive` |
| 638,1057 | 32x32 | pressable | Archive | `semantics:Archive` x2 |
| 638,1057 | 32x32 | semantics | Archive | `semantics:Archive` x2 |
| 638,1057 | 32x32 | icon | 0xe041 | `icon:0xe041` |
| 638,1093 | 32x32 | tooltip | Hollow Shop | `tooltip:Hollow Shop` |
| 638,1093 | 32x32 | pressable | Hollow Shop | `semantics:Hollow Shop` x2 |
| 638,1093 | 32x32 | semantics | Hollow Shop | `semantics:Hollow Shop` x2 |
| 638,1093 | 32x32 | icon | 0xe3e4 | `icon:0xe3e4` |
| 638,1150 | 32x32 | tooltip | Downloads | `tooltip:Downloads` |
| 638,1150 | 32x32 | semantics | Downloads | `semantics:Downloads` x2 |
| 638,1150 | 32x32 | icon | download (0xe0b2) | `icon:download` |
| 638,1150 | 32x32 | pressable | Downloads | `semantics:Downloads` x2 |
| 638,1186 | 32x32 | icon | 0xe082 | `icon:0xe082` |
| 638,1186 | 32x32 | semantics | Help | `semantics:Help` x2 |
| 638,1186 | 32x32 | pressable | Help | `semantics:Help` x2 |
| 638,1186 | 32x32 | tooltip | Help | `tooltip:Help` |
| 638,1222 | 32x32 | icon | settings (0xe154) | `icon:settings` x2 |
| 638,1222 | 32x32 | semantics | Settings | `semantics:Settings` x2 |
| 638,1222 | 32x32 | pressable | Settings | `semantics:Settings` x2 |
| 638,1222 | 32x32 | tooltip | Settings | `tooltip:Settings` |
| 644,252 | 20x20 | icon | plus (0xe13d) | `icon:plus` x3 |
| 645,56 | 49x18 | text | probe-a | `text:probe-a` x2 |
| 645,205 | 19x18 | text | NA | `text:NA` |
| 647,27 | 14x15 | text | PR | `text:PR` x3 |
| 661,41 | 7x7 | semantics | Online | `semantics:Online` x2 |

---

## UI map: 04-sidebar-menu

Screen 1265.6 x 682.4 logical pixels. 168 entries.

### Open surfaces

- dialog open: false
- context menu open: true
- menu rows: Mark server as read | Create channel | Create category | Invite people | Server settings

### Providers

- server: navmap (45f623ca41ad07fd661d0cbaf0b7938f)
- channel: general (45f623ca-general)
- layout mode: LayoutMode.dock
- peer: null
- identity: 12D3KooWFGeEoJ4dHAgiCErWGzmkDPRgynnB3eRwrEB66ixpXHTJ (loaded: true)
- device: 12D3KooWB344tiTY149CzuMB6r3Ct6bBMT9SpQhzd2cPWsXGwuDr
- connection: connected
- relay: relay.anonlisten.com
- friends (1):
  - 12D3KooWRsPZ7CSeumSbaRhGZBhvsCHvotXMQj3MtwWqyeHbsqQp â€” accepted

#### Server strip

```
server navmap
```

#### Stored layout

```
(empty layout)
```

#### Effective layout (stored + unplaced channels)

```
[0] general (text, 45f623ca-general)
```

### On screen

`y,x` is the top-left corner. Paste a target straight into a scenario; `xN` means the target matches N widgets, so scope it (`dialog > ...`) or pass an index.

| y,x | size | kind | label | target |
|---|---|---|---|---|
| 0,0 | 1266x682 | keyed |  | `key:_ScaffoldSlot.body` |
| 0,0 | 1266x682 | surface |  | `type:_HollowMenuHost` |
| 0,1128 | 46x44 | semantics | Minimize | `semantics:Minimize` |
| 0,1174 | 46x44 | semantics | Maximize | `semantics:Maximize` |
| 0,1220 | 46x44 | semantics | Close | `semantics:Close` |
| 6,12 | 32x32 | tooltip | Add friend | `tooltip:Add friend` |
| 6,12 | 32x32 | pressable | Add friend | `semantics:Add friend` x2 |
| 6,12 | 32x32 | semantics | Add friend | `semantics:Add friend` x2 |
| 6,12 | 32x32 | icon | userPlus (0xe1a2) | `icon:userPlus` x3 |
| 6,56 | 94x32 | keyed |  | `key:12D3KooWRsPZ7CSeumSbaRhGZBhvsCHvotXMQj3MtwWqyeHbsqQp` |
| 6,56 | 94x32 | pressable | probe-b | `semantics:probe-b` x2 |
| 6,56 | 94x32 | semantics | probe-b | `semantics:probe-b` x2 |
| 6,1092 | 32x32 | icon | pencil (0xe1f9) | `icon:pencil` |
| 6,1092 | 32x32 | semantics | Annotate the screen | `semantics:Annotate the screen` |
| 13,92 | 50x18 | text | probe-b | `text:probe-b` |
| 14,1143 | 16x16 | icon | 0xe11c | `icon:0xe11c` |
| 14,1189 | 16x16 | icon | 0xe167 | `icon:0xe167` |
| 14,1235 | 16x16 | icon | x (0xe1b2) | `icon:x` |
| 15,66 | 12x13 | text | PR | `text:PR` x3 |
| 15,1032 | 48x15 | text | Annotate | `text:Annotate` |
| 27,77 | 7x7 | semantics | Offline | `semantics:Offline` |
| 44,0 | 240x48 | keyed |  | `key:header-navmap` |
| 44,240 | 6x581 | semantics | Resize the channel list | `semantics:Resize the channel list` |
| 44,246 | 734x581 | keyed |  | `key:single` |
| 44,246 | 734x581 | keyed |  | `key:(45f623ca-general, 45f623ca-general)` |
| 44,246 | 734x581 | keyed |  | `key:ch:45f623ca-general` |
| 44,980 | 6x581 | semantics | Resize the member list | `semantics:Resize the member list` |
| 52,864 | 32x32 | tooltip | Search messages | `tooltip:Search messages` |
| 52,864 | 32x32 | pressable | Search messages | `semantics:Search messages` x2 |
| 52,864 | 32x32 | semantics | Search messages | `semantics:Search messages` x2 |
| 52,864 | 32x32 | icon | search (0xe151) | `icon:search` |
| 52,900 | 32x32 | semantics | Split view | `semantics:Split view` x2 |
| 52,900 | 32x32 | tooltip | Split view | `tooltip:Split view` |
| 52,900 | 32x32 | pressable | Split view | `semantics:Split view` x2 |
| 52,900 | 32x32 | icon | 0xe098 | `icon:0xe098` |
| 52,936 | 32x32 | semantics | Hide members | `semantics:Hide members` x2 |
| 52,936 | 32x32 | tooltip | Hide members | `tooltip:Hide members` |
| 52,936 | 32x32 | pressable | Hide members | `semantics:Hide members` x2 |
| 52,936 | 32x32 | icon | users (0xe1a4) | `icon:users` x3 |
| 56,160 | 24x24 | semantics | Invite people | `semantics:Invite people` x2 |
| 56,160 | 24x24 | tooltip | Invite people | `tooltip:Invite people` |
| 56,160 | 24x24 | pressable | Invite people | `semantics:Invite people` x2 |
| 56,184 | 24x24 | tooltip | Files & storage | `tooltip:Files & storage` |
| 56,184 | 24x24 | pressable | Files & storage | `semantics:Files & storage` x2 |
| 56,184 | 24x24 | semantics | Files & storage | `semantics:Files & storage` x2 |
| 56,208 | 24x24 | tooltip | Server settings | `tooltip:Server settings` |
| 56,208 | 24x24 | pressable | Server settings | `semantics:Server settings` x2 |
| 56,208 | 24x24 | semantics | Server settings | `semantics:Server settings` x2 |
| 57,16 | 144x22 | text | navmap | `text:navmap` |
| 57,290 | 57x22 | text | general | `text:general` x3 |
| 57,1030 | 70x22 | text | Members | `text:Members` |
| 58,262 | 20x20 | icon | hash (0xe0ef) | `icon:hash` x3 |
| 58,1002 | 20x20 | icon | users (0xe1a4) | `icon:users` x3 |
| 60,164 | 16x16 | icon | userPlus (0xe1a2) | `icon:userPlus` x3 |
| 60,188 | 16x16 | icon | hardDrive (0xe0ed) | `icon:hardDrive` |
| 60,212 | 16x16 | icon | settings (0xe154) | `icon:settings` x3 |
| 60,787 | 64x15 | tooltip | You're connected. Nobody else is online here right now | `tooltip:You're connected. Nobody else is online here right now` |
| 60,787 | 64x15 | keyed |  | `key:conn-45f623ca41ad07fd661d0cbaf0b7938f` |
| 60,805 | 46x15 | text | Only you | `text:Only you` |
| 61,787 | 14x14 | icon | users (0xe1a4) | `icon:users` x3 |
| 92,0 | 240x533 | keyed |  | `key:server-45f623ca41ad07fd661d0cbaf0b7938f` |
| 92,986 | 280x533 | keyed |  | `key:members:45f623ca41ad07fd661d0cbaf0b7938f` |
| 100,994 | 254x34 | keyed |  | `key:[<'group:Owner'>]` |
| 100,994 | 254x34 | keyed |  | `key:group:Owner` |
| 100,994 | 254x34 | pressable | Collapse Owner, 1 member | `semantics:Collapse Owner, 1 member` x2 |
| 100,994 | 254x34 | semantics | Collapse Owner, 1 member | `semantics:Collapse Owner, 1 member` x2 |
| 104,210 | 22x22 | semantics | Create channel | `semantics:Create channel` x2 |
| 104,210 | 22x22 | pressable | Create channel | `semantics:Create channel` x2 |
| 106,18 | 85x18 | text | Text channels | `text:Text channels` |
| 108,214 | 14x14 | icon | plus (0xe13d) | `icon:plus` x4 |
| 108,1002 | 41x18 | text | Owner | `text:Owner` |
| 110,1051 | 7x15 | text | 1 | `text:1` |
| 110,1226 | 14x14 | icon | chevronDown (0xe06d) | `icon:chevronDown` |
| 134,994 | 254x36 | semantics | probe-a | `semantics:probe-a` x2 |
| 134,994 | 254x36 | keyed |  | `key:[<'member:12D3KooWFGeEoJ4dHAgiCErWGzmkDPRgynnB3eRwrEB66ixpXHTJ'>]` |
| 134,994 | 254x36 | keyed |  | `key:member:12D3KooWFGeEoJ4dHAgiCErWGzmkDPRgynnB3eRwrEB66ixpXHTJ` |
| 134,994 | 254x36 | pressable | probe-a | `semantics:probe-a` x2 |
| 138,0 | 230x40 | keyed |  | `key:[<'ach-45f623ca-general'>]` |
| 138,0 | 230x40 | keyed |  | `key:ach-45f623ca-general` |
| 140,10 | 220x36 | pressable | general | `text:general` x3 |
| 142,1042 | 53x20 | text | probe-a | `text:probe-a` x2 |
| 144,1010 | 16x17 | text | PR | `text:PR` x3 |
| 148,46 | 174x20 | text | general | `text:general` x3 |
| 149,20 | 18x18 | icon | hash (0xe0ef) | `icon:hash` x3 |
| 161,1027 | 7x7 | semantics | Online | `semantics:Online` x2 |
| 289,601 | 24x24 | icon | hash (0xe0ef) | `icon:hash` x3 |
| 325,543 | 140x20 | text | Welcome to #general | `text:Welcome to #general` |
| 349,521 | 185x15 | text | This is the beginning of the channel. | `text:This is the beginning of the channel.` |
| 402,111 | 308x34 | pressable | Mark server as read | `text:Mark server as read` x2 |
| 410,144 | 265x18 | text | Mark server as read | `text:Mark server as read` x2 |
| 412,121 | 15x15 | icon | 0xe38e | `icon:0xe38e` |
| 441,111 | 308x34 | pressable | Create channel | `text:Create channel` x2 |
| 449,144 | 265x18 | text | Create channel | `text:Create channel` x2 |
| 451,121 | 15x15 | icon | plus (0xe13d) | `icon:plus` x4 |
| 475,111 | 308x34 | pressable | Create category | `text:Create category` x2 |
| 483,144 | 265x18 | text | Create category | `text:Create category` x2 |
| 485,121 | 15x15 | icon | 0xe0d9 | `icon:0xe0d9` |
| 514,111 | 308x34 | pressable | Invite people | `text:Invite people` x2 |
| 522,144 | 265x18 | text | Invite people | `text:Invite people` x2 |
| 524,121 | 15x15 | icon | userPlus (0xe1a2) | `icon:userPlus` x3 |
| 548,111 | 308x34 | pressable | Server settings | `text:Server settings` x2 |
| 556,144 | 265x18 | text | Server settings | `text:Server settings` x2 |
| 558,121 | 15x15 | icon | settings (0xe154) | `icon:settings` x3 |
| 569,310 | 606x48 | field | hint "Message #general" | `hint:Message #general` |
| 573,258 | 44x44 | icon | plus (0xe13d) | `icon:plus` x4 |
| 573,258 | 44x44 | pressable | Attach a file | `semantics:Attach a file` x2 |
| 573,258 | 44x44 | tooltip | Attach a file | `tooltip:Attach a file` |
| 573,258 | 44x44 | semantics | Attach a file | `semantics:Attach a file` x2 |
| 573,924 | 44x44 | icon | mic (0xe118) | `icon:mic` |
| 573,924 | 44x44 | semantics | Record a voice message | `semantics:Record a voice message` x2 |
| 573,924 | 44x44 | pressable | Record a voice message | `semantics:Record a voice message` x2 |
| 573,924 | 44x44 | tooltip | Record a voice message | `tooltip:Record a voice message` |
| 577,880 | 32x32 | tooltip | Emoji, GIFs and stickers | `tooltip:Emoji, GIFs and stickers` |
| 577,880 | 32x32 | icon | smile (0xe164) | `icon:smile` |
| 577,880 | 32x32 | semantics | Emoji, GIFs and stickers | `semantics:Emoji, GIFs and stickers` x2 |
| 577,880 | 32x32 | pressable | Emoji, GIFs and stickers | `semantics:Emoji, GIFs and stickers` x2 |
| 583,326 | 550x20 | text | Message #general | `text:Message #general` |
| 583,326 | 550x20 | input |  | `type:EditableText` |
| 634,138 | 40x40 | semantics | Home | `semantics:Home` x2 |
| 634,138 | 40x40 | tooltip | Home | `tooltip:Home` |
| 634,138 | 40x40 | pressable | Home | `semantics:Home` x2 |
| 634,194 | 40x40 | semantics | navmap | `semantics:navmap` x2 |
| 634,194 | 40x40 | pressable | navmap | `semantics:navmap` x2 |
| 634,194 | 40x40 | tooltip | navmap | `tooltip:navmap` |
| 634,194 | 40x40 | keyed |  | `key:bounce-45f623ca41ad07fd661d0cbaf0b7938f` |
| 634,242 | 40x40 | pressable | Create a server | `semantics:Create a server` x2 |
| 634,242 | 40x40 | semantics | Create a server | `semantics:Create a server` x2 |
| 634,242 | 40x40 | tooltip | Create a server | `tooltip:Create a server` |
| 636,12 | 101x36 | semantics | probe-a, Online | `semantics:probe-a, Online` x2 |
| 636,12 | 101x36 | pressable | probe-a, Online | `semantics:probe-a, Online` x2 |
| 636,12 | 101x36 | tooltip | Your profile and status | `tooltip:Your profile and status` |
| 638,949 | 32x32 | pressable | Conferences | `semantics:Conferences` x2 |
| 638,949 | 32x32 | semantics | Conferences | `semantics:Conferences` x2 |
| 638,949 | 32x32 | icon | video (0xe1a5) | `icon:video` |
| 638,949 | 32x32 | tooltip | Conferences | `tooltip:Conferences` |
| 638,985 | 32x32 | icon | globe (0xe0e8) | `icon:globe` |
| 638,985 | 32x32 | semantics | Public channels | `semantics:Public channels` x2 |
| 638,985 | 32x32 | pressable | Public channels | `semantics:Public channels` x2 |
| 638,985 | 32x32 | tooltip | Public channels | `tooltip:Public channels` |
| 638,1021 | 32x32 | icon | 0xe156 | `icon:0xe156` |
| 638,1021 | 32x32 | semantics | Share | `semantics:Share` x2 |
| 638,1021 | 32x32 | pressable | Share | `semantics:Share` x2 |
| 638,1021 | 32x32 | tooltip | Share | `tooltip:Share` |
| 638,1057 | 32x32 | icon | 0xe041 | `icon:0xe041` |
| 638,1057 | 32x32 | semantics | Archive | `semantics:Archive` x2 |
| 638,1057 | 32x32 | pressable | Archive | `semantics:Archive` x2 |
| 638,1057 | 32x32 | tooltip | Archive | `tooltip:Archive` |
| 638,1093 | 32x32 | icon | 0xe3e4 | `icon:0xe3e4` |
| 638,1093 | 32x32 | semantics | Hollow Shop | `semantics:Hollow Shop` x2 |
| 638,1093 | 32x32 | pressable | Hollow Shop | `semantics:Hollow Shop` x2 |
| 638,1093 | 32x32 | tooltip | Hollow Shop | `tooltip:Hollow Shop` |
| 638,1150 | 32x32 | semantics | Downloads | `semantics:Downloads` x2 |
| 638,1150 | 32x32 | pressable | Downloads | `semantics:Downloads` x2 |
| 638,1150 | 32x32 | tooltip | Downloads | `tooltip:Downloads` |
| 638,1150 | 32x32 | icon | download (0xe0b2) | `icon:download` |
| 638,1186 | 32x32 | tooltip | Help | `tooltip:Help` |
| 638,1186 | 32x32 | pressable | Help | `semantics:Help` x2 |
| 638,1186 | 32x32 | semantics | Help | `semantics:Help` x2 |
| 638,1186 | 32x32 | icon | 0xe082 | `icon:0xe082` |
| 638,1222 | 32x32 | tooltip | Settings | `tooltip:Settings` |
| 638,1222 | 32x32 | pressable | Settings | `semantics:Settings` x2 |
| 638,1222 | 32x32 | semantics | Settings | `semantics:Settings` x2 |
| 638,1222 | 32x32 | icon | settings (0xe154) | `icon:settings` x3 |
| 644,252 | 20x20 | icon | plus (0xe13d) | `icon:plus` x4 |
| 645,56 | 49x18 | text | probe-a | `text:probe-a` x2 |
| 645,205 | 19x18 | text | NA | `text:NA` |
| 647,27 | 14x15 | text | PR | `text:PR` x3 |
| 661,41 | 7x7 | semantics | Online | `semantics:Online` x2 |

---

## UI map: 05-server-settings

Screen 1265.6 x 682.4 logical pixels. 145 entries.

### Open surfaces

- dialog open: false
- context menu open: false

### Providers

- server: navmap (45f623ca41ad07fd661d0cbaf0b7938f)
- channel: general (45f623ca-general)
- layout mode: LayoutMode.dock
- peer: null
- identity: 12D3KooWFGeEoJ4dHAgiCErWGzmkDPRgynnB3eRwrEB66ixpXHTJ (loaded: true)
- device: 12D3KooWB344tiTY149CzuMB6r3Ct6bBMT9SpQhzd2cPWsXGwuDr
- connection: connected
- relay: relay.anonlisten.com
- friends (1):
  - 12D3KooWRsPZ7CSeumSbaRhGZBhvsCHvotXMQj3MtwWqyeHbsqQp â€” accepted

#### Server strip

```
server navmap
```

#### Stored layout

```
(empty layout)
```

#### Effective layout (stored + unplaced channels)

```
[0] general (text, 45f623ca-general)
```

### On screen

`y,x` is the top-left corner. Paste a target straight into a scenario; `xN` means the target matches N widgets, so scope it (`dialog > ...`) or pass an index.

| y,x | size | kind | label | target |
|---|---|---|---|---|
| 0,0 | 1266x682 | keyed |  | `key:_ScaffoldSlot.body` |
| 0,1128 | 46x44 | semantics | Minimize | `semantics:Minimize` |
| 0,1174 | 46x44 | semantics | Maximize | `semantics:Maximize` |
| 0,1220 | 46x44 | semantics | Close | `semantics:Close` |
| 6,12 | 32x32 | tooltip | Add friend | `tooltip:Add friend` |
| 6,12 | 32x32 | pressable | Add friend | `semantics:Add friend` x2 |
| 6,12 | 32x32 | semantics | Add friend | `semantics:Add friend` x2 |
| 6,12 | 32x32 | icon | userPlus (0xe1a2) | `icon:userPlus` |
| 6,56 | 94x32 | keyed |  | `key:12D3KooWRsPZ7CSeumSbaRhGZBhvsCHvotXMQj3MtwWqyeHbsqQp` |
| 6,56 | 94x32 | pressable | probe-b | `semantics:probe-b` x2 |
| 6,56 | 94x32 | semantics | probe-b | `semantics:probe-b` x2 |
| 6,1092 | 32x32 | icon | pencil (0xe1f9) | `icon:pencil` |
| 6,1092 | 32x32 | semantics | Annotate the screen | `semantics:Annotate the screen` |
| 13,92 | 50x18 | text | probe-b | `text:probe-b` |
| 14,1143 | 16x16 | icon | 0xe11c | `icon:0xe11c` |
| 14,1189 | 16x16 | icon | 0xe167 | `icon:0xe167` |
| 14,1235 | 16x16 | icon | x (0xe1b2) | `icon:x` x2 |
| 15,66 | 12x13 | text | PR | `text:PR` x2 |
| 15,1032 | 48x15 | text | Annotate | `text:Annotate` |
| 27,77 | 7x7 | semantics | Offline | `semantics:Offline` |
| 60,190 | 60x22 | text | navmap | `text:navmap` x2 |
| 60,1218 | 32x32 | tooltip | Close server settings (Esc) | `tooltip:Close server settings (Esc)` |
| 60,1218 | 32x32 | semantics | Close server settings | `semantics:Close server settings` x2 |
| 60,1218 | 32x32 | pressable | Close server settings | `semantics:Close server settings` x2 |
| 60,1218 | 32x32 | icon | x (0xe1b2) | `icon:x` x2 |
| 68,402 | 720x608 | keyed |  | `key:(45f623ca41ad07fd661d0cbaf0b7938f, ServerSettingsPage.overview)` |
| 68,402 | 720x26 | text | Overview | `text:Overview` x3 |
| 71,153 | 19x18 | text | NA | `text:NA` x4 |
| 82,190 | 85x17 | text | Server settings | `text:Server settings` |
| 118,890 | 232x18 | text | How an invite shows it | `text:How an invite shows it` |
| 119,154 | 181x15 | text | Server | `text:Server` |
| 131,462 | 28x20 | text | Icon | `text:Icon` |
| 136,787 | 71x29 | button | Change icon | `semantics:Change icon` x2 |
| 136,787 | 71x29 | semantics | Change icon | `semantics:Change icon` x2 |
| 138,142 | 205x30 | pressable | Overview | `text:Overview` x3 |
| 141,417 | 19x18 | text | NA | `text:NA` x4 |
| 144,182 | 153x18 | text | Overview | `text:Overview` x3 |
| 144,799 | 47x13 | text | Change | `text:Change` x2 |
| 145,154 | 16x16 | icon | 0xe0f9 | `icon:0xe0f9` |
| 153,462 | 225x17 | text | Square. A GIF or animated WebP moves. | `text:Square. A GIF or animated WebP moves.` |
| 170,142 | 205x30 | pressable | Access | `text:Access` x2 |
| 176,182 | 153x18 | text | Access | `text:Access` x2 |
| 177,154 | 16x16 | icon | lock (0xe10b) | `icon:lock` |
| 190,462 | 47x20 | text | Banner | `text:Banner` |
| 195,787 | 71x29 | button | Change banner | `semantics:Change banner` x2 |
| 195,787 | 71x29 | semantics | Change banner | `semantics:Change banner` x2 |
| 202,142 | 205x30 | pressable | Channels | `text:Channels` x2 |
| 203,799 | 47x13 | text | Change | `text:Change` x2 |
| 208,182 | 153x18 | text | Channels | `text:Channels` x2 |
| 209,154 | 16x16 | icon | hash (0xe0ef) | `icon:hash` |
| 212,462 | 64x17 | text | Wide, 3 to 1 | `text:Wide, 3 to 1` |
| 216,925 | 19x18 | text | NA | `text:NA` x4 |
| 234,142 | 205x30 | pressable | Roles | `text:Roles` x2 |
| 240,182 | 153x18 | text | Roles | `text:Roles` x2 |
| 241,154 | 16x16 | icon | shield (0xe158) | `icon:shield` |
| 249,402 | 456x18 | text | Name | `text:Name` |
| 257,906 | 60x22 | text | navmap | `text:navmap` x2 |
| 266,142 | 205x30 | pressable | Labels | `text:Labels` x2 |
| 271,402 | 456x48 | field | hint "Server name" | `hint:Server name` |
| 272,182 | 153x18 | text | Labels | `text:Labels` x2 |
| 273,154 | 16x16 | icon | tag (0xe17f) | `icon:tag` |
| 285,418 | 424x20 | input | navmap | `type:EditableText` x2 |
| 285,418 | 424x20 | text | Server name | `text:Server name` |
| 287,906 | 98x15 | text | 0 online Â· 1 member | `text:0 online Â· 1 member` |
| 298,142 | 205x30 | pressable | Emotes & stickers | `text:Emotes & stickers` x2 |
| 304,182 | 153x18 | text | Emotes & stickers | `text:Emotes & stickers` x2 |
| 305,154 | 16x16 | icon | smile (0xe164) | `icon:smile` |
| 323,833 | 25x15 | text | 6/32 | `text:6/32` |
| 330,142 | 205x30 | pressable | Members | `text:Members` x2 |
| 336,182 | 153x18 | text | Members | `text:Members` x2 |
| 337,154 | 16x16 | icon | users (0xe1a4) | `icon:users` |
| 350,402 | 456x18 | text | Description | `text:Description` |
| 362,142 | 205x30 | pressable | Files & storage | `text:Files & storage` x2 |
| 368,182 | 153x18 | text | Files & storage | `text:Files & storage` x2 |
| 369,154 | 16x16 | icon | hardDrive (0xe0ed) | `icon:hardDrive` |
| 372,402 | 456x76 | field | hint "What is this server about?" | `hint:What is this server about?` |
| 380,418 | 424x60 | input |  | `type:EditableText` x2 |
| 380,418 | 424x20 | text | What is this server about? | `text:What is this server about?` |
| 406,154 | 181x15 | text | You | `text:You` |
| 425,142 | 205x30 | pressable | Profile | `text:Profile` x2 |
| 431,182 | 153x18 | text | Profile | `text:Profile` x2 |
| 432,154 | 16x16 | icon | user (0xe19f) | `icon:user` |
| 452,826 | 32x15 | text | 0/256 | `text:0/256` |
| 457,142 | 205x30 | pressable | Notifications | `text:Notifications` x2 |
| 463,182 | 153x18 | text | Notifications | `text:Notifications` x2 |
| 464,154 | 16x16 | icon | bell (0xe059) | `icon:bell` |
| 516,402 | 90x26 | semantics | Show advanced settings | `semantics:Show advanced settings` x2 |
| 516,402 | 90x26 | pressable | Show advanced settings | `semantics:Show advanced settings` x2 |
| 520,426 | 62x18 | text | Advanced | `text:Advanced` |
| 521,406 | 16x16 | icon | chevronRight (0xe06f) | `icon:chevronRight` |
| 591,402 | 96x22 | text | Danger zone | `text:Danger zone` |
| 629,402 | 115x20 | text | Delete this server | `text:Delete this server` |
| 634,138 | 40x40 | tooltip | Home | `tooltip:Home` |
| 634,138 | 40x40 | pressable | Home | `semantics:Home` x2 |
| 634,138 | 40x40 | semantics | Home | `semantics:Home` x2 |
| 634,194 | 40x40 | pressable | navmap | `semantics:navmap` x2 |
| 634,194 | 40x40 | semantics | navmap | `semantics:navmap` x2 |
| 634,194 | 40x40 | keyed |  | `key:bounce-45f623ca41ad07fd661d0cbaf0b7938f` |
| 634,194 | 40x40 | tooltip | navmap | `tooltip:navmap` |
| 634,242 | 40x40 | tooltip | Create a server | `tooltip:Create a server` |
| 634,242 | 40x40 | pressable | Create a server | `semantics:Create a server` x2 |
| 634,242 | 40x40 | semantics | Create a server | `semantics:Create a server` x2 |
| 634,1016 | 106x29 | button | Delete server | `text:Delete server` x2 |
| 636,12 | 101x36 | semantics | probe-a, Online | `semantics:probe-a, Online` x2 |
| 636,12 | 101x36 | tooltip | Your profile and status | `tooltip:Your profile and status` |
| 636,12 | 101x36 | pressable | probe-a, Online | `semantics:probe-a, Online` x2 |
| 638,949 | 32x32 | tooltip | Conferences | `tooltip:Conferences` |
| 638,949 | 32x32 | pressable | Conferences | `semantics:Conferences` x2 |
| 638,949 | 32x32 | semantics | Conferences | `semantics:Conferences` x2 |
| 638,949 | 32x32 | icon | video (0xe1a5) | `icon:video` |
| 638,985 | 32x32 | tooltip | Public channels | `tooltip:Public channels` |
| 638,985 | 32x32 | pressable | Public channels | `semantics:Public channels` x2 |
| 638,985 | 32x32 | semantics | Public channels | `semantics:Public channels` x2 |
| 638,985 | 32x32 | icon | globe (0xe0e8) | `icon:globe` |
| 638,1021 | 32x32 | semantics | Share | `semantics:Share` x2 |
| 638,1021 | 32x32 | icon | 0xe156 | `icon:0xe156` |
| 638,1021 | 32x32 | pressable | Share | `semantics:Share` x2 |
| 638,1021 | 32x32 | tooltip | Share | `tooltip:Share` |
| 638,1057 | 32x32 | tooltip | Archive | `tooltip:Archive` |
| 638,1057 | 32x32 | pressable | Archive | `semantics:Archive` x2 |
| 638,1057 | 32x32 | semantics | Archive | `semantics:Archive` x2 |
| 638,1057 | 32x32 | icon | 0xe041 | `icon:0xe041` |
| 638,1093 | 32x32 | tooltip | Hollow Shop | `tooltip:Hollow Shop` |
| 638,1093 | 32x32 | pressable | Hollow Shop | `semantics:Hollow Shop` x2 |
| 638,1093 | 32x32 | semantics | Hollow Shop | `semantics:Hollow Shop` x2 |
| 638,1093 | 32x32 | icon | 0xe3e4 | `icon:0xe3e4` |
| 638,1150 | 32x32 | tooltip | Downloads | `tooltip:Downloads` |
| 638,1150 | 32x32 | pressable | Downloads | `semantics:Downloads` x2 |
| 638,1150 | 32x32 | semantics | Downloads | `semantics:Downloads` x2 |
| 638,1150 | 32x32 | icon | download (0xe0b2) | `icon:download` |
| 638,1186 | 32x32 | pressable | Help | `semantics:Help` x2 |
| 638,1186 | 32x32 | semantics | Help | `semantics:Help` x2 |
| 638,1186 | 32x32 | icon | 0xe082 | `icon:0xe082` |
| 638,1186 | 32x32 | tooltip | Help | `tooltip:Help` |
| 638,1222 | 32x32 | semantics | Settings | `semantics:Settings` x2 |
| 638,1222 | 32x32 | icon | settings (0xe154) | `icon:settings` |
| 638,1222 | 32x32 | tooltip | Settings | `tooltip:Settings` |
| 638,1222 | 32x32 | pressable | Settings | `semantics:Settings` x2 |
| 642,1028 | 82x13 | text | Delete server | `text:Delete server` x2 |
| 644,252 | 20x20 | icon | plus (0xe13d) | `icon:plus` |
| 645,56 | 49x18 | text | probe-a | `text:probe-a` |
| 645,205 | 19x18 | text | NA | `text:NA` x4 |
| 647,27 | 14x15 | text | PR | `text:PR` x2 |
| 651,402 | 391x17 | text | Every channel and message goes, for everyone. This can't be undone. | `text:Every channel and message goes, for everyone. This can't be undone.` |
| 661,41 | 7x7 | semantics | Online | `semantics:Online` |

---

## UI map: 06-channels-tab

Screen 1265.6 x 682.4 logical pixels. 128 entries.

### Open surfaces

- dialog open: false
- context menu open: false

### Providers

- server: navmap (45f623ca41ad07fd661d0cbaf0b7938f)
- channel: general (45f623ca-general)
- layout mode: LayoutMode.dock
- peer: null
- identity: 12D3KooWFGeEoJ4dHAgiCErWGzmkDPRgynnB3eRwrEB66ixpXHTJ (loaded: true)
- device: 12D3KooWB344tiTY149CzuMB6r3Ct6bBMT9SpQhzd2cPWsXGwuDr
- connection: connected
- relay: relay.anonlisten.com
- friends (1):
  - 12D3KooWRsPZ7CSeumSbaRhGZBhvsCHvotXMQj3MtwWqyeHbsqQp â€” accepted

#### Server strip

```
server navmap
```

#### Stored layout

```
(empty layout)
```

#### Effective layout (stored + unplaced channels)

```
[0] general (text, 45f623ca-general)
```

### On screen

`y,x` is the top-left corner. Paste a target straight into a scenario; `xN` means the target matches N widgets, so scope it (`dialog > ...`) or pass an index.

| y,x | size | kind | label | target |
|---|---|---|---|---|
| 0,0 | 1266x682 | keyed |  | `key:_ScaffoldSlot.body` |
| 0,1128 | 46x44 | semantics | Minimize | `semantics:Minimize` |
| 0,1174 | 46x44 | semantics | Maximize | `semantics:Maximize` |
| 0,1220 | 46x44 | semantics | Close | `semantics:Close` |
| 6,12 | 32x32 | tooltip | Add friend | `tooltip:Add friend` |
| 6,12 | 32x32 | pressable | Add friend | `semantics:Add friend` x2 |
| 6,12 | 32x32 | semantics | Add friend | `semantics:Add friend` x2 |
| 6,12 | 32x32 | icon | userPlus (0xe1a2) | `icon:userPlus` |
| 6,56 | 94x32 | keyed |  | `key:12D3KooWRsPZ7CSeumSbaRhGZBhvsCHvotXMQj3MtwWqyeHbsqQp` |
| 6,56 | 94x32 | pressable | probe-b | `semantics:probe-b` x2 |
| 6,56 | 94x32 | semantics | probe-b | `semantics:probe-b` x2 |
| 6,1092 | 32x32 | semantics | Annotate the screen | `semantics:Annotate the screen` |
| 6,1092 | 32x32 | icon | pencil (0xe1f9) | `icon:pencil` |
| 13,92 | 50x18 | text | probe-b | `text:probe-b` |
| 14,1143 | 16x16 | icon | 0xe11c | `icon:0xe11c` |
| 14,1189 | 16x16 | icon | 0xe167 | `icon:0xe167` |
| 14,1235 | 16x16 | icon | x (0xe1b2) | `icon:x` x2 |
| 15,66 | 12x13 | text | PR | `text:PR` x2 |
| 15,1032 | 48x15 | text | Annotate | `text:Annotate` |
| 27,77 | 7x7 | semantics | Offline | `semantics:Offline` |
| 60,190 | 60x22 | text | navmap | `text:navmap` |
| 60,1218 | 32x32 | icon | x (0xe1b2) | `icon:x` x2 |
| 60,1218 | 32x32 | semantics | Close server settings | `semantics:Close server settings` x2 |
| 60,1218 | 32x32 | pressable | Close server settings | `semantics:Close server settings` x2 |
| 60,1218 | 32x32 | tooltip | Close server settings (Esc) | `tooltip:Close server settings (Esc)` |
| 68,402 | 720x164 | keyed |  | `key:(45f623ca41ad07fd661d0cbaf0b7938f, ServerSettingsPage.channels)` |
| 68,402 | 720x26 | text | Channels | `text:Channels` x3 |
| 71,153 | 19x18 | text | NA | `text:NA` x2 |
| 82,190 | 85x17 | text | Server settings | `text:Server settings` |
| 102,402 | 720x20 | text | Drag to reorder. Click a channel for who can see it, who can post and the rest. | `text:Drag to reorder. Click a channel for who can see it, who can post and the rest.` |
| 119,154 | 181x15 | text | Server | `text:Server` |
| 138,142 | 205x30 | pressable | Overview | `text:Overview` x2 |
| 144,182 | 153x18 | text | Overview | `text:Overview` x2 |
| 145,154 | 16x16 | icon | 0xe0f9 | `icon:0xe0f9` |
| 146,402 | 128x32 | button | New channel | `text:New channel` x2 |
| 146,538 | 112x29 | button | New category | `text:New category` x2 |
| 146,658 | 67x29 | button | Divider | `text:Divider` x2 |
| 154,414 | 16x16 | icon | plus (0xe13d) | `icon:plus` x2 |
| 154,550 | 88x13 | text | New category | `text:New category` x2 |
| 154,670 | 43x13 | text | Divider | `text:Divider` x2 |
| 156,438 | 80x13 | text | New channel | `text:New channel` x2 |
| 170,142 | 205x30 | pressable | Access | `text:Access` x2 |
| 176,182 | 153x18 | text | Access | `text:Access` x2 |
| 177,154 | 16x16 | icon | lock (0xe10b) | `icon:lock` |
| 190,402 | 710x42 | keyed |  | `key:ch-45f623ca-general` |
| 190,402 | 710x40 | pressable | general. Open its settings | `semantics:general. Open its settings` x2 |
| 190,402 | 710x40 | semantics | general. Open its settings | `semantics:general. Open its settings` x2 |
| 190,402 | 710x42 | keyed |  | `key:[_ReorderableItemGlobalKey _ReorderableListViewChildGlobalKey#e02c6]` |
| 199,402 | 22x22 | semantics | Drag general | `semantics:Drag general` |
| 200,452 | 628x20 | text | general | `text:general` |
| 202,142 | 205x30 | pressable | Channels | `text:Channels` x3 |
| 202,428 | 16x16 | icon | hash (0xe0ef) | `icon:hash` x2 |
| 202,1088 | 16x16 | icon | chevronRight (0xe06f) | `icon:chevronRight` |
| 203,406 | 14x14 | icon | 0xe0eb | `icon:0xe0eb` |
| 208,182 | 153x18 | text | Channels | `text:Channels` x3 |
| 209,154 | 16x16 | icon | hash (0xe0ef) | `icon:hash` x2 |
| 234,142 | 205x30 | pressable | Roles | `text:Roles` x2 |
| 240,182 | 153x18 | text | Roles | `text:Roles` x2 |
| 241,154 | 16x16 | icon | shield (0xe158) | `icon:shield` |
| 266,142 | 205x30 | pressable | Labels | `text:Labels` x2 |
| 272,182 | 153x18 | text | Labels | `text:Labels` x2 |
| 273,154 | 16x16 | icon | tag (0xe17f) | `icon:tag` |
| 298,142 | 205x30 | pressable | Emotes & stickers | `text:Emotes & stickers` x2 |
| 304,182 | 153x18 | text | Emotes & stickers | `text:Emotes & stickers` x2 |
| 305,154 | 16x16 | icon | smile (0xe164) | `icon:smile` |
| 330,142 | 205x30 | pressable | Members | `text:Members` x2 |
| 336,182 | 153x18 | text | Members | `text:Members` x2 |
| 337,154 | 16x16 | icon | users (0xe1a4) | `icon:users` |
| 362,142 | 205x30 | pressable | Files & storage | `text:Files & storage` x2 |
| 368,182 | 153x18 | text | Files & storage | `text:Files & storage` x2 |
| 369,154 | 16x16 | icon | hardDrive (0xe0ed) | `icon:hardDrive` |
| 406,154 | 181x15 | text | You | `text:You` |
| 425,142 | 205x30 | pressable | Profile | `text:Profile` x2 |
| 431,182 | 153x18 | text | Profile | `text:Profile` x2 |
| 432,154 | 16x16 | icon | user (0xe19f) | `icon:user` |
| 457,142 | 205x30 | pressable | Notifications | `text:Notifications` x2 |
| 463,182 | 153x18 | text | Notifications | `text:Notifications` x2 |
| 464,154 | 16x16 | icon | bell (0xe059) | `icon:bell` |
| 634,138 | 40x40 | tooltip | Home | `tooltip:Home` |
| 634,138 | 40x40 | pressable | Home | `semantics:Home` x2 |
| 634,138 | 40x40 | semantics | Home | `semantics:Home` x2 |
| 634,194 | 40x40 | keyed |  | `key:bounce-45f623ca41ad07fd661d0cbaf0b7938f` |
| 634,194 | 40x40 | tooltip | navmap | `tooltip:navmap` |
| 634,194 | 40x40 | pressable | navmap | `semantics:navmap` x2 |
| 634,194 | 40x40 | semantics | navmap | `semantics:navmap` x2 |
| 634,242 | 40x40 | tooltip | Create a server | `tooltip:Create a server` |
| 634,242 | 40x40 | semantics | Create a server | `semantics:Create a server` x2 |
| 634,242 | 40x40 | pressable | Create a server | `semantics:Create a server` x2 |
| 636,12 | 101x36 | semantics | probe-a, Online | `semantics:probe-a, Online` x2 |
| 636,12 | 101x36 | tooltip | Your profile and status | `tooltip:Your profile and status` |
| 636,12 | 101x36 | pressable | probe-a, Online | `semantics:probe-a, Online` x2 |
| 638,949 | 32x32 | semantics | Conferences | `semantics:Conferences` x2 |
| 638,949 | 32x32 | icon | video (0xe1a5) | `icon:video` |
| 638,949 | 32x32 | pressable | Conferences | `semantics:Conferences` x2 |
| 638,949 | 32x32 | tooltip | Conferences | `tooltip:Conferences` |
| 638,985 | 32x32 | tooltip | Public channels | `tooltip:Public channels` |
| 638,985 | 32x32 | pressable | Public channels | `semantics:Public channels` x2 |
| 638,985 | 32x32 | semantics | Public channels | `semantics:Public channels` x2 |
| 638,985 | 32x32 | icon | globe (0xe0e8) | `icon:globe` |
| 638,1021 | 32x32 | tooltip | Share | `tooltip:Share` |
| 638,1021 | 32x32 | pressable | Share | `semantics:Share` x2 |
| 638,1021 | 32x32 | semantics | Share | `semantics:Share` x2 |
| 638,1021 | 32x32 | icon | 0xe156 | `icon:0xe156` |
| 638,1057 | 32x32 | semantics | Archive | `semantics:Archive` x2 |
| 638,1057 | 32x32 | pressable | Archive | `semantics:Archive` x2 |
| 638,1057 | 32x32 | tooltip | Archive | `tooltip:Archive` |
| 638,1057 | 32x32 | icon | 0xe041 | `icon:0xe041` |
| 638,1093 | 32x32 | pressable | Hollow Shop | `semantics:Hollow Shop` x2 |
| 638,1093 | 32x32 | semantics | Hollow Shop | `semantics:Hollow Shop` x2 |
| 638,1093 | 32x32 | icon | 0xe3e4 | `icon:0xe3e4` |
| 638,1093 | 32x32 | tooltip | Hollow Shop | `tooltip:Hollow Shop` |
| 638,1150 | 32x32 | tooltip | Downloads | `tooltip:Downloads` |
| 638,1150 | 32x32 | pressable | Downloads | `semantics:Downloads` x2 |
| 638,1150 | 32x32 | semantics | Downloads | `semantics:Downloads` x2 |
| 638,1150 | 32x32 | icon | download (0xe0b2) | `icon:download` |
| 638,1186 | 32x32 | tooltip | Help | `tooltip:Help` |
| 638,1186 | 32x32 | pressable | Help | `semantics:Help` x2 |
| 638,1186 | 32x32 | icon | 0xe082 | `icon:0xe082` |
| 638,1186 | 32x32 | semantics | Help | `semantics:Help` x2 |
| 638,1222 | 32x32 | semantics | Settings | `semantics:Settings` x2 |
| 638,1222 | 32x32 | pressable | Settings | `semantics:Settings` x2 |
| 638,1222 | 32x32 | tooltip | Settings | `tooltip:Settings` |
| 638,1222 | 32x32 | icon | settings (0xe154) | `icon:settings` |
| 644,252 | 20x20 | icon | plus (0xe13d) | `icon:plus` x2 |
| 645,56 | 49x18 | text | probe-a | `text:probe-a` |
| 645,205 | 19x18 | text | NA | `text:NA` x2 |
| 647,27 | 14x15 | text | PR | `text:PR` x2 |
| 661,41 | 7x7 | semantics | Online | `semantics:Online` |

---

## UI map: 07-member-card

Screen 1265.6 x 682.4 logical pixels. 167 entries.

### Open surfaces

- dialog open: false
- context menu open: false

### Providers

- server: navmap (45f623ca41ad07fd661d0cbaf0b7938f)
- channel: general (45f623ca-general)
- layout mode: LayoutMode.dock
- peer: null
- identity: 12D3KooWFGeEoJ4dHAgiCErWGzmkDPRgynnB3eRwrEB66ixpXHTJ (loaded: true)
- device: 12D3KooWB344tiTY149CzuMB6r3Ct6bBMT9SpQhzd2cPWsXGwuDr
- connection: connected
- relay: relay.anonlisten.com
- friends (1):
  - 12D3KooWRsPZ7CSeumSbaRhGZBhvsCHvotXMQj3MtwWqyeHbsqQp â€” accepted

#### Server strip

```
server navmap
```

#### Stored layout

```
(empty layout)
```

#### Effective layout (stored + unplaced channels)

```
[0] general (text, 45f623ca-general)
```

### On screen

`y,x` is the top-left corner. Paste a target straight into a scenario; `xN` means the target matches N widgets, so scope it (`dialog > ...`) or pass an index.

| y,x | size | kind | label | target |
|---|---|---|---|---|
| 0,0 | 1266x682 | keyed |  | `key:_ScaffoldSlot.body` |
| 0,1128 | 46x44 | semantics | Minimize | `semantics:Minimize` |
| 0,1174 | 46x44 | semantics | Maximize | `semantics:Maximize` |
| 0,1220 | 46x44 | semantics | Close | `semantics:Close` |
| 6,12 | 32x32 | tooltip | Add friend | `tooltip:Add friend` |
| 6,12 | 32x32 | pressable | Add friend | `semantics:Add friend` x2 |
| 6,12 | 32x32 | semantics | Add friend | `semantics:Add friend` x2 |
| 6,12 | 32x32 | icon | userPlus (0xe1a2) | `icon:userPlus` x2 |
| 6,56 | 94x32 | keyed |  | `key:12D3KooWRsPZ7CSeumSbaRhGZBhvsCHvotXMQj3MtwWqyeHbsqQp` |
| 6,56 | 94x32 | pressable | probe-b | `semantics:probe-b` x2 |
| 6,56 | 94x32 | semantics | probe-b | `semantics:probe-b` x2 |
| 6,1092 | 32x32 | semantics | Annotate the screen | `semantics:Annotate the screen` |
| 6,1092 | 32x32 | icon | pencil (0xe1f9) | `icon:pencil` x2 |
| 13,92 | 50x18 | text | probe-b | `text:probe-b` |
| 14,1143 | 16x16 | icon | 0xe11c | `icon:0xe11c` |
| 14,1189 | 16x16 | icon | 0xe167 | `icon:0xe167` |
| 14,1235 | 16x16 | icon | x (0xe1b2) | `icon:x` |
| 15,66 | 12x13 | text | PR | `text:PR` x4 |
| 15,1032 | 48x15 | text | Annotate | `text:Annotate` |
| 27,77 | 7x7 | semantics | Offline | `semantics:Offline` |
| 43,943 | 32x32 | icon | 0xe113 | `icon:0xe113` |
| 43,943 | 32x32 | semantics | View full profile | `semantics:View full profile` x2 |
| 43,943 | 32x32 | pressable | View full profile | `semantics:View full profile` x2 |
| 43,943 | 32x32 | tooltip | View full profile | `tooltip:View full profile` |
| 44,0 | 240x48 | keyed |  | `key:header-navmap` |
| 44,240 | 6x581 | semantics | Resize the channel list | `semantics:Resize the channel list` |
| 44,246 | 734x581 | keyed |  | `key:single` |
| 44,246 | 734x581 | keyed |  | `key:(45f623ca-general, 45f623ca-general)` |
| 44,246 | 734x581 | keyed |  | `key:ch:45f623ca-general` |
| 44,980 | 6x581 | semantics | Resize the member list | `semantics:Resize the member list` |
| 52,864 | 32x32 | tooltip | Search messages | `tooltip:Search messages` |
| 52,864 | 32x32 | pressable | Search messages | `semantics:Search messages` x2 |
| 52,864 | 32x32 | semantics | Search messages | `semantics:Search messages` x2 |
| 52,864 | 32x32 | icon | search (0xe151) | `icon:search` |
| 52,900 | 32x32 | tooltip | Split view | `tooltip:Split view` |
| 52,900 | 32x32 | pressable | Split view | `semantics:Split view` x2 |
| 52,900 | 32x32 | semantics | Split view | `semantics:Split view` x2 |
| 52,900 | 32x32 | icon | 0xe098 | `icon:0xe098` |
| 52,936 | 32x32 | icon | users (0xe1a4) | `icon:users` x3 |
| 52,936 | 32x32 | tooltip | Hide members | `tooltip:Hide members` |
| 52,936 | 32x32 | pressable | Hide members | `semantics:Hide members` x2 |
| 52,936 | 32x32 | semantics | Hide members | `semantics:Hide members` x2 |
| 56,160 | 24x24 | pressable | Invite people | `semantics:Invite people` x2 |
| 56,160 | 24x24 | semantics | Invite people | `semantics:Invite people` x2 |
| 56,160 | 24x24 | tooltip | Invite people | `tooltip:Invite people` |
| 56,184 | 24x24 | tooltip | Files & storage | `tooltip:Files & storage` |
| 56,184 | 24x24 | pressable | Files & storage | `semantics:Files & storage` x2 |
| 56,184 | 24x24 | semantics | Files & storage | `semantics:Files & storage` x2 |
| 56,208 | 24x24 | tooltip | Server settings | `tooltip:Server settings` |
| 56,208 | 24x24 | pressable | Server settings | `semantics:Server settings` x2 |
| 56,208 | 24x24 | semantics | Server settings | `semantics:Server settings` x2 |
| 57,16 | 144x22 | text | navmap | `text:navmap` |
| 57,290 | 57x22 | text | general | `text:general` x3 |
| 57,1030 | 70x22 | text | Members | `text:Members` |
| 58,262 | 20x20 | icon | hash (0xe0ef) | `icon:hash` x3 |
| 58,1002 | 20x20 | icon | users (0xe1a4) | `icon:users` x3 |
| 60,164 | 16x16 | icon | userPlus (0xe1a2) | `icon:userPlus` x2 |
| 60,188 | 16x16 | icon | hardDrive (0xe0ed) | `icon:hardDrive` |
| 60,212 | 16x16 | icon | settings (0xe154) | `icon:settings` x2 |
| 60,787 | 64x15 | tooltip | You're connected. Nobody else is online here right now | `tooltip:You're connected. Nobody else is online here right now` |
| 60,787 | 64x15 | keyed |  | `key:conn-45f623ca41ad07fd661d0cbaf0b7938f` |
| 60,805 | 46x15 | text | Only you | `text:Only you` |
| 61,787 | 14x14 | icon | users (0xe1a4) | `icon:users` x3 |
| 92,0 | 240x533 | keyed |  | `key:server-45f623ca41ad07fd661d0cbaf0b7938f` |
| 92,986 | 280x533 | keyed |  | `key:members:45f623ca41ad07fd661d0cbaf0b7938f` |
| 100,994 | 254x34 | keyed |  | `key:[<'group:Owner'>]` |
| 100,994 | 254x34 | keyed |  | `key:group:Owner` |
| 100,994 | 254x34 | pressable | Collapse Owner, 1 member | `semantics:Collapse Owner, 1 member` x2 |
| 100,994 | 254x34 | semantics | Collapse Owner, 1 member | `semantics:Collapse Owner, 1 member` x2 |
| 104,210 | 22x22 | pressable | Create channel | `semantics:Create channel` x2 |
| 104,210 | 22x22 | semantics | Create channel | `semantics:Create channel` x2 |
| 106,18 | 85x18 | text | Text channels | `text:Text channels` |
| 108,214 | 14x14 | icon | plus (0xe13d) | `icon:plus` x3 |
| 108,1002 | 41x18 | text | Owner | `text:Owner` x2 |
| 110,1051 | 7x15 | text | 1 | `text:1` |
| 110,1226 | 14x14 | icon | chevronDown (0xe06d) | `icon:chevronDown` |
| 126,704 | 64x64 | semantics | probe-a | `semantics:probe-a` x3 |
| 134,994 | 254x36 | keyed |  | `key:[<'member:12D3KooWFGeEoJ4dHAgiCErWGzmkDPRgynnB3eRwrEB66ixpXHTJ'>]` |
| 134,994 | 254x36 | keyed |  | `key:member:12D3KooWFGeEoJ4dHAgiCErWGzmkDPRgynnB3eRwrEB66ixpXHTJ` |
| 134,994 | 254x36 | pressable | probe-a | `semantics:probe-a` x3 |
| 134,994 | 254x36 | semantics | probe-a | `semantics:probe-a` x3 |
| 138,0 | 230x40 | keyed |  | `key:[<'ach-45f623ca-general'>]` |
| 138,0 | 230x40 | keyed |  | `key:ach-45f623ca-general` |
| 140,10 | 220x36 | pressable | general | `text:general` x3 |
| 141,719 | 32x34 | text | PR | `text:PR` x4 |
| 142,1042 | 53x20 | text | probe-a | `text:probe-a` x3 |
| 144,1010 | 16x17 | text | PR | `text:PR` x4 |
| 148,46 | 174x20 | text | general | `text:general` x3 |
| 149,20 | 18x18 | icon | hash (0xe0ef) | `icon:hash` x3 |
| 161,1027 | 7x7 | semantics | Online | `semantics:Online` x2 |
| 205,701 | 61x22 | text | probe-a | `text:probe-a` x3 |
| 231,713 | 35x17 | text | Online | `text:Online` |
| 262,723 | 32x14 | text | Owner | `text:Owner` x2 |
| 289,601 | 24x24 | icon | hash (0xe0ef) | `icon:hash` x3 |
| 290,701 | 120x32 | button | Edit profile | `text:Edit profile` x2 |
| 290,829 | 138x32 | button | Edit showcase | `text:Edit showcase` x2 |
| 298,716 | 16x16 | icon | pencil (0xe1f9) | `icon:pencil` x2 |
| 298,841 | 16x16 | icon | 0xe0ff | `icon:0xe0ff` |
| 300,740 | 66x13 | text | Edit profile | `text:Edit profile` x2 |
| 300,865 | 90x13 | text | Edit showcase | `text:Edit showcase` x2 |
| 325,543 | 140x20 | text | Welcome to #general | `text:Welcome to #general` |
| 349,521 | 185x15 | text | This is the beginning of the channel. | `text:This is the beginning of the channel.` |
| 569,310 | 606x48 | field | hint "Message #general" | `hint:Message #general` |
| 573,258 | 44x44 | tooltip | Attach a file | `tooltip:Attach a file` |
| 573,258 | 44x44 | pressable | Attach a file | `semantics:Attach a file` x2 |
| 573,258 | 44x44 | icon | plus (0xe13d) | `icon:plus` x3 |
| 573,258 | 44x44 | semantics | Attach a file | `semantics:Attach a file` x2 |
| 573,924 | 44x44 | icon | mic (0xe118) | `icon:mic` |
| 573,924 | 44x44 | semantics | Record a voice message | `semantics:Record a voice message` x2 |
| 573,924 | 44x44 | pressable | Record a voice message | `semantics:Record a voice message` x2 |
| 573,924 | 44x44 | tooltip | Record a voice message | `tooltip:Record a voice message` |
| 577,880 | 32x32 | icon | smile (0xe164) | `icon:smile` |
| 577,880 | 32x32 | tooltip | Emoji, GIFs and stickers | `tooltip:Emoji, GIFs and stickers` |
| 577,880 | 32x32 | pressable | Emoji, GIFs and stickers | `semantics:Emoji, GIFs and stickers` x2 |
| 577,880 | 32x32 | semantics | Emoji, GIFs and stickers | `semantics:Emoji, GIFs and stickers` x2 |
| 583,326 | 550x20 | input |  | `type:EditableText` |
| 583,326 | 550x20 | text | Message #general | `text:Message #general` |
| 634,138 | 40x40 | tooltip | Home | `tooltip:Home` |
| 634,138 | 40x40 | semantics | Home | `semantics:Home` x2 |
| 634,138 | 40x40 | pressable | Home | `semantics:Home` x2 |
| 634,194 | 40x40 | keyed |  | `key:bounce-45f623ca41ad07fd661d0cbaf0b7938f` |
| 634,194 | 40x40 | tooltip | navmap | `tooltip:navmap` |
| 634,194 | 40x40 | pressable | navmap | `semantics:navmap` x2 |
| 634,194 | 40x40 | semantics | navmap | `semantics:navmap` x2 |
| 634,242 | 40x40 | tooltip | Create a server | `tooltip:Create a server` |
| 634,242 | 40x40 | pressable | Create a server | `semantics:Create a server` x2 |
| 634,242 | 40x40 | semantics | Create a server | `semantics:Create a server` x2 |
| 636,12 | 101x36 | tooltip | Your profile and status | `tooltip:Your profile and status` |
| 636,12 | 101x36 | pressable | probe-a, Online | `semantics:probe-a, Online` x2 |
| 636,12 | 101x36 | semantics | probe-a, Online | `semantics:probe-a, Online` x2 |
| 638,949 | 32x32 | tooltip | Conferences | `tooltip:Conferences` |
| 638,949 | 32x32 | pressable | Conferences | `semantics:Conferences` x2 |
| 638,949 | 32x32 | semantics | Conferences | `semantics:Conferences` x2 |
| 638,949 | 32x32 | icon | video (0xe1a5) | `icon:video` |
| 638,985 | 32x32 | pressable | Public channels | `semantics:Public channels` x2 |
| 638,985 | 32x32 | semantics | Public channels | `semantics:Public channels` x2 |
| 638,985 | 32x32 | icon | globe (0xe0e8) | `icon:globe` |
| 638,985 | 32x32 | tooltip | Public channels | `tooltip:Public channels` |
| 638,1021 | 32x32 | icon | 0xe156 | `icon:0xe156` |
| 638,1021 | 32x32 | semantics | Share | `semantics:Share` x2 |
| 638,1021 | 32x32 | pressable | Share | `semantics:Share` x2 |
| 638,1021 | 32x32 | tooltip | Share | `tooltip:Share` |
| 638,1057 | 32x32 | icon | 0xe041 | `icon:0xe041` |
| 638,1057 | 32x32 | semantics | Archive | `semantics:Archive` x2 |
| 638,1057 | 32x32 | pressable | Archive | `semantics:Archive` x2 |
| 638,1057 | 32x32 | tooltip | Archive | `tooltip:Archive` |
| 638,1093 | 32x32 | icon | 0xe3e4 | `icon:0xe3e4` |
| 638,1093 | 32x32 | semantics | Hollow Shop | `semantics:Hollow Shop` x2 |
| 638,1093 | 32x32 | pressable | Hollow Shop | `semantics:Hollow Shop` x2 |
| 638,1093 | 32x32 | tooltip | Hollow Shop | `tooltip:Hollow Shop` |
| 638,1150 | 32x32 | icon | download (0xe0b2) | `icon:download` |
| 638,1150 | 32x32 | semantics | Downloads | `semantics:Downloads` x2 |
| 638,1150 | 32x32 | pressable | Downloads | `semantics:Downloads` x2 |
| 638,1150 | 32x32 | tooltip | Downloads | `tooltip:Downloads` |
| 638,1186 | 32x32 | icon | 0xe082 | `icon:0xe082` |
| 638,1186 | 32x32 | pressable | Help | `semantics:Help` x2 |
| 638,1186 | 32x32 | tooltip | Help | `tooltip:Help` |
| 638,1186 | 32x32 | semantics | Help | `semantics:Help` x2 |
| 638,1222 | 32x32 | pressable | Settings | `semantics:Settings` x2 |
| 638,1222 | 32x32 | semantics | Settings | `semantics:Settings` x2 |
| 638,1222 | 32x32 | icon | settings (0xe154) | `icon:settings` x2 |
| 638,1222 | 32x32 | tooltip | Settings | `tooltip:Settings` |
| 644,252 | 20x20 | icon | plus (0xe13d) | `icon:plus` x3 |
| 645,56 | 49x18 | text | probe-a | `text:probe-a` x3 |
| 645,205 | 19x18 | text | NA | `text:NA` |
| 647,27 | 14x15 | text | PR | `text:PR` x4 |
| 661,41 | 7x7 | semantics | Online | `semantics:Online` x2 |

---

## UI map: 08-settings

Screen 1265.6 x 682.4 logical pixels. 155 entries.

### Open surfaces

- dialog open: false
- context menu open: false

### Providers

- server: navmap (45f623ca41ad07fd661d0cbaf0b7938f)
- channel: general (45f623ca-general)
- layout mode: LayoutMode.dock
- peer: null
- identity: 12D3KooWFGeEoJ4dHAgiCErWGzmkDPRgynnB3eRwrEB66ixpXHTJ (loaded: true)
- device: 12D3KooWB344tiTY149CzuMB6r3Ct6bBMT9SpQhzd2cPWsXGwuDr
- connection: connected
- relay: relay.anonlisten.com
- friends (1):
  - 12D3KooWRsPZ7CSeumSbaRhGZBhvsCHvotXMQj3MtwWqyeHbsqQp â€” accepted

#### Server strip

```
server navmap
```

#### Stored layout

```
(empty layout)
```

#### Effective layout (stored + unplaced channels)

```
[0] general (text, 45f623ca-general)
```

### On screen

`y,x` is the top-left corner. Paste a target straight into a scenario; `xN` means the target matches N widgets, so scope it (`dialog > ...`) or pass an index.

| y,x | size | kind | label | target |
|---|---|---|---|---|
| 0,0 | 1266x682 | keyed |  | `key:_ScaffoldSlot.body` |
| 0,1128 | 46x44 | semantics | Minimize | `semantics:Minimize` |
| 0,1174 | 46x44 | semantics | Maximize | `semantics:Maximize` |
| 0,1220 | 46x44 | semantics | Close | `semantics:Close` |
| 6,12 | 32x32 | tooltip | Add friend | `tooltip:Add friend` |
| 6,12 | 32x32 | pressable | Add friend | `semantics:Add friend` x2 |
| 6,12 | 32x32 | semantics | Add friend | `semantics:Add friend` x2 |
| 6,12 | 32x32 | icon | userPlus (0xe1a2) | `icon:userPlus` |
| 6,56 | 94x32 | keyed |  | `key:12D3KooWRsPZ7CSeumSbaRhGZBhvsCHvotXMQj3MtwWqyeHbsqQp` |
| 6,56 | 94x32 | pressable | probe-b | `semantics:probe-b` x2 |
| 6,56 | 94x32 | semantics | probe-b | `semantics:probe-b` x2 |
| 6,1092 | 32x32 | icon | pencil (0xe1f9) | `icon:pencil` |
| 6,1092 | 32x32 | semantics | Annotate the screen | `semantics:Annotate the screen` |
| 13,92 | 50x18 | text | probe-b | `text:probe-b` |
| 14,1143 | 16x16 | icon | 0xe11c | `icon:0xe11c` |
| 14,1189 | 16x16 | icon | 0xe167 | `icon:0xe167` |
| 14,1235 | 16x16 | icon | x (0xe1b2) | `icon:x` x2 |
| 15,66 | 12x13 | text | PR | `text:PR` x4 |
| 15,1032 | 48x15 | text | Annotate | `text:Annotate` |
| 27,77 | 7x7 | semantics | Offline | `semantics:Offline` |
| 60,142 | 211x26 | text | Settings | `text:Settings` |
| 60,1218 | 32x32 | pressable | Close settings | `semantics:Close settings` x2 |
| 60,1218 | 32x32 | icon | x (0xe1b2) | `icon:x` x2 |
| 60,1218 | 32x32 | semantics | Close settings | `semantics:Close settings` x2 |
| 60,1218 | 32x32 | tooltip | Close settings (Esc) | `tooltip:Close settings (Esc)` |
| 68,402 | 720x1243 | keyed |  | `key:SettingsCategory.profile` |
| 68,402 | 720x26 | text | Profile | `text:Profile` x3 |
| 98,142 | 215x28 | field | hint "Search settings" | `hint:Search settings` |
| 102,186 | 155x20 | input |  | `type:EditableText` x4 |
| 102,186 | 155x20 | text | Search settings | `text:Search settings` |
| 104,142 | 40x16 | icon | search (0xe151) | `icon:search` |
| 131,462 | 43x20 | text | Avatar | `text:Avatar` |
| 136,718 | 71x29 | button | Change avatar | `semantics:Change avatar` x2 |
| 136,718 | 71x29 | semantics | Change avatar | `semantics:Change avatar` x2 |
| 136,797 | 73x29 | button | Remove avatar | `semantics:Remove avatar` x2 |
| 136,797 | 73x29 | semantics | Remove avatar | `semantics:Remove avatar` x2 |
| 137,414 | 24x26 | text | PR | `text:PR` x4 |
| 138,154 | 181x15 | text | Account | `text:Account` |
| 144,730 | 47x13 | text | Change | `text:Change` x2 |
| 144,809 | 49x13 | text | Remove | `text:Remove` x2 |
| 153,462 | 225x17 | text | Square. A GIF or animated WebP moves. | `text:Square. A GIF or animated WebP moves.` |
| 157,142 | 205x30 | pressable | Profile | `text:Profile` x3 |
| 163,182 | 153x18 | text | Profile | `text:Profile` x3 |
| 164,154 | 16x16 | icon | user (0xe19f) | `icon:user` |
| 189,142 | 205x30 | pressable | Security | `text:Security` x2 |
| 190,462 | 47x20 | text | Banner | `text:Banner` |
| 195,182 | 153x18 | text | Security | `text:Security` x2 |
| 195,718 | 71x29 | semantics | Change banner | `semantics:Change banner` x2 |
| 195,718 | 71x29 | button | Change banner | `semantics:Change banner` x2 |
| 195,797 | 73x29 | button | Remove banner | `semantics:Remove banner` x2 |
| 195,797 | 73x29 | semantics | Remove banner | `semantics:Remove banner` x2 |
| 195,932 | 28x30 | text | PR | `text:PR` x4 |
| 196,154 | 16x16 | icon | shield (0xe158) | `icon:shield` |
| 203,730 | 47x13 | text | Change | `text:Change` x2 |
| 203,809 | 49x13 | text | Remove | `text:Remove` x2 |
| 212,462 | 75x17 | text | Wide, 2.5 to 1 | `text:Wide, 2.5 to 1` |
| 221,142 | 205x30 | pressable | Devices | `text:Devices` x2 |
| 227,182 | 153x18 | text | Devices | `text:Devices` x2 |
| 228,154 | 16x16 | icon | 0xe163 | `icon:0xe163` |
| 242,918 | 61x22 | text | probe-a | `text:probe-a` x2 |
| 250,462 | 41x20 | text | Frame | `text:Frame` |
| 255,799 | 71x29 | button | Choose | `text:Choose` x2 |
| 263,811 | 47x13 | text | Choose | `text:Choose` x2 |
| 265,154 | 181x15 | text | App | `text:App` |
| 272,462 | 30x17 | text | None | `text:None` |
| 284,142 | 205x30 | pressable | Appearance | `text:Appearance` x2 |
| 290,182 | 153x18 | text | Appearance | `text:Appearance` x2 |
| 291,154 | 16x16 | icon | 0xe1dd | `icon:0xe1dd` |
| 313,402 | 468x18 | text | Display name | `text:Display name` |
| 316,142 | 205x30 | pressable | Accessibility | `text:Accessibility` x2 |
| 322,182 | 153x18 | text | Accessibility | `text:Accessibility` x2 |
| 323,154 | 16x16 | icon | 0xe297 | `icon:0xe297` |
| 335,402 | 468x48 | field | hint "Enter a display name" | `hint:Enter a display name` |
| 348,142 | 205x30 | pressable | Notifications | `text:Notifications` x2 |
| 349,418 | 436x20 | input | probe-a | `type:EditableText` x4 |
| 349,418 | 436x20 | text | Enter a display name | `text:Enter a display name` |
| 354,182 | 153x18 | text | Notifications | `text:Notifications` x2 |
| 355,154 | 16x16 | icon | bell (0xe059) | `icon:bell` |
| 380,142 | 205x30 | pressable | Audio & video | `text:Audio & video` x2 |
| 386,182 | 153x18 | text | Audio & video | `text:Audio & video` x2 |
| 387,154 | 16x16 | icon | mic (0xe118) | `icon:mic` |
| 387,846 | 24x15 | text | 7/32 | `text:7/32` |
| 412,142 | 205x30 | pressable | Shortcuts | `text:Shortcuts` x2 |
| 414,402 | 468x18 | text | Status | `text:Status` |
| 418,182 | 153x18 | text | Shortcuts | `text:Shortcuts` x2 |
| 419,154 | 16x16 | icon | 0xe284 | `icon:0xe284` |
| 436,402 | 468x48 | field | hint "What are you up to?" | `hint:What are you up to?` |
| 450,418 | 436x20 | text | What are you up to? | `text:What are you up to?` |
| 450,418 | 436x20 | input |  | `type:EditableText` x4 |
| 456,154 | 181x15 | text | Connection and data | `text:Connection and data` |
| 475,142 | 205x30 | pressable | Network | `text:Network` x2 |
| 481,182 | 153x18 | text | Network | `text:Network` x2 |
| 482,154 | 16x16 | icon | globe (0xe0e8) | `icon:globe` x2 |
| 488,844 | 26x15 | text | 0/48 | `text:0/48` |
| 507,142 | 205x30 | pressable | Files & storage | `text:Files & storage` x2 |
| 513,182 | 153x18 | text | Files & storage | `text:Files & storage` x2 |
| 514,154 | 16x16 | icon | hardDrive (0xe0ed) | `icon:hardDrive` |
| 515,402 | 468x18 | text | About me | `text:About me` |
| 537,402 | 468x76 | field |  | `type:TextField` |
| 545,418 | 436x60 | input |  | `type:EditableText` x4 |
| 556,142 | 205x30 | pressable | About | `text:About` x2 |
| 562,182 | 153x18 | text | About | `text:About` x2 |
| 563,154 | 16x16 | icon | 0xe0f9 | `icon:0xe0f9` |
| 617,840 | 30x15 | text | 0/128 | `text:0/128` |
| 634,138 | 40x40 | pressable | Home | `semantics:Home` x2 |
| 634,138 | 40x40 | semantics | Home | `semantics:Home` x2 |
| 634,138 | 40x40 | tooltip | Home | `tooltip:Home` |
| 634,194 | 40x40 | tooltip | navmap | `tooltip:navmap` |
| 634,194 | 40x40 | semantics | navmap | `semantics:navmap` x2 |
| 634,194 | 40x40 | keyed |  | `key:bounce-45f623ca41ad07fd661d0cbaf0b7938f` |
| 634,194 | 40x40 | pressable | navmap | `semantics:navmap` x2 |
| 634,242 | 40x40 | tooltip | Create a server | `tooltip:Create a server` |
| 634,242 | 40x40 | pressable | Create a server | `semantics:Create a server` x2 |
| 634,242 | 40x40 | semantics | Create a server | `semantics:Create a server` x2 |
| 636,12 | 101x36 | tooltip | Your profile and status | `tooltip:Your profile and status` |
| 636,12 | 101x36 | pressable | probe-a, Online | `semantics:probe-a, Online` x2 |
| 636,12 | 101x36 | semantics | probe-a, Online | `semantics:probe-a, Online` x2 |
| 638,949 | 32x32 | pressable | Conferences | `semantics:Conferences` x2 |
| 638,949 | 32x32 | tooltip | Conferences | `tooltip:Conferences` |
| 638,949 | 32x32 | semantics | Conferences | `semantics:Conferences` x2 |
| 638,949 | 32x32 | icon | video (0xe1a5) | `icon:video` |
| 638,985 | 32x32 | tooltip | Public channels | `tooltip:Public channels` |
| 638,985 | 32x32 | pressable | Public channels | `semantics:Public channels` x2 |
| 638,985 | 32x32 | semantics | Public channels | `semantics:Public channels` x2 |
| 638,985 | 32x32 | icon | globe (0xe0e8) | `icon:globe` x2 |
| 638,1021 | 32x32 | pressable | Share | `semantics:Share` x2 |
| 638,1021 | 32x32 | semantics | Share | `semantics:Share` x2 |
| 638,1021 | 32x32 | icon | 0xe156 | `icon:0xe156` |
| 638,1021 | 32x32 | tooltip | Share | `tooltip:Share` |
| 638,1057 | 32x32 | tooltip | Archive | `tooltip:Archive` |
| 638,1057 | 32x32 | pressable | Archive | `semantics:Archive` x2 |
| 638,1057 | 32x32 | semantics | Archive | `semantics:Archive` x2 |
| 638,1057 | 32x32 | icon | 0xe041 | `icon:0xe041` |
| 638,1093 | 32x32 | pressable | Hollow Shop | `semantics:Hollow Shop` x2 |
| 638,1093 | 32x32 | semantics | Hollow Shop | `semantics:Hollow Shop` x2 |
| 638,1093 | 32x32 | icon | 0xe3e4 | `icon:0xe3e4` |
| 638,1093 | 32x32 | tooltip | Hollow Shop | `tooltip:Hollow Shop` |
| 638,1150 | 32x32 | icon | download (0xe0b2) | `icon:download` |
| 638,1150 | 32x32 | pressable | Downloads | `semantics:Downloads` x2 |
| 638,1150 | 32x32 | tooltip | Downloads | `tooltip:Downloads` |
| 638,1150 | 32x32 | semantics | Downloads | `semantics:Downloads` x2 |
| 638,1186 | 32x32 | pressable | Help | `semantics:Help` x2 |
| 638,1186 | 32x32 | semantics | Help | `semantics:Help` x2 |
| 638,1186 | 32x32 | icon | 0xe082 | `icon:0xe082` |
| 638,1186 | 32x32 | tooltip | Help | `tooltip:Help` |
| 638,1222 | 32x32 | tooltip | Settings | `tooltip:Settings` |
| 638,1222 | 32x32 | pressable | Settings | `semantics:Settings` x2 |
| 638,1222 | 32x32 | semantics | Settings | `semantics:Settings` x2 |
| 638,1222 | 32x32 | icon | settings (0xe154) | `icon:settings` |
| 644,252 | 20x20 | icon | plus (0xe13d) | `icon:plus` |
| 645,56 | 49x18 | text | probe-a | `text:probe-a` x2 |
| 645,205 | 19x18 | text | NA | `text:NA` |
| 647,27 | 14x15 | text | PR | `text:PR` x4 |
| 661,41 | 7x7 | semantics | Online | `semantics:Online` |
| 681,402 | 71x22 | text | Presence | `text:Presence` |

---

## UI map: 09-home-dock

Screen 1265.6 x 682.4 logical pixels. 124 entries.

### Open surfaces

- dialog open: false
- context menu open: false

### Providers

- server: null (null)
- channel: null (null)
- layout mode: LayoutMode.dock
- peer: null
- identity: 12D3KooWFGeEoJ4dHAgiCErWGzmkDPRgynnB3eRwrEB66ixpXHTJ (loaded: true)
- device: 12D3KooWB344tiTY149CzuMB6r3Ct6bBMT9SpQhzd2cPWsXGwuDr
- connection: connected
- relay: relay.anonlisten.com
- friends (1):
  - 12D3KooWRsPZ7CSeumSbaRhGZBhvsCHvotXMQj3MtwWqyeHbsqQp â€” accepted

#### Server strip

```
server navmap
```

#### Stored layout

```
(empty layout)
```

### On screen

`y,x` is the top-left corner. Paste a target straight into a scenario; `xN` means the target matches N widgets, so scope it (`dialog > ...`) or pass an index.

| y,x | size | kind | label | target |
|---|---|---|---|---|
| 0,0 | 1266x682 | keyed |  | `key:_ScaffoldSlot.body` |
| 0,1128 | 46x44 | semantics | Minimize | `semantics:Minimize` |
| 0,1174 | 46x44 | semantics | Maximize | `semantics:Maximize` |
| 0,1220 | 46x44 | semantics | Close | `semantics:Close` |
| 6,12 | 32x32 | tooltip | Add friend | `tooltip:Add friend` |
| 6,12 | 32x32 | pressable | Add friend | `semantics:Add friend` x2 |
| 6,12 | 32x32 | semantics | Add friend | `semantics:Add friend` x2 |
| 6,12 | 32x32 | icon | userPlus (0xe1a2) | `icon:userPlus` |
| 6,56 | 94x32 | keyed |  | `key:12D3KooWRsPZ7CSeumSbaRhGZBhvsCHvotXMQj3MtwWqyeHbsqQp` |
| 6,56 | 94x32 | pressable | probe-b | `semantics:probe-b` x2 |
| 6,56 | 94x32 | semantics | probe-b | `semantics:probe-b` x2 |
| 6,1092 | 32x32 | semantics | Annotate the screen | `semantics:Annotate the screen` |
| 6,1092 | 32x32 | icon | pencil (0xe1f9) | `icon:pencil` |
| 13,92 | 50x18 | text | probe-b | `text:probe-b` x2 |
| 14,1143 | 16x16 | icon | 0xe11c | `icon:0xe11c` |
| 14,1189 | 16x16 | icon | 0xe167 | `icon:0xe167` |
| 14,1235 | 16x16 | icon | x (0xe1b2) | `icon:x` |
| 15,66 | 12x13 | text | PR | `text:PR` x3 |
| 15,1032 | 48x15 | text | Annotate | `text:Annotate` |
| 27,77 | 7x7 | semantics | Offline | `semantics:Offline` x2 |
| 44,0 | 1266x581 | keyed |  | `key:single` |
| 44,0 | 1266x581 | keyed |  | `key:(empty, empty)` |
| 68,792 | 142x36 | button | New message | `text:New message` x2 |
| 68,987 | 249x229 | pressable | News | `text:News` x2 |
| 72,544 | 240x28 | field | hint "Search conversations" | `hint:Search conversations` |
| 73,32 | 500x26 | text | Good afternoon, probe-a | `text:Good afternoon, probe-a` |
| 76,588 | 180x20 | input |  | `type:EditableText` |
| 76,588 | 180x20 | text | Search conversations | `text:Search conversations` |
| 78,544 | 40x16 | icon | search (0xe151) | `icon:search` |
| 78,808 | 16x16 | icon | plus (0xe13d) | `icon:plus` x2 |
| 80,832 | 86x13 | text | New message | `text:New message` x2 |
| 85,1003 | 163x18 | text | News | `text:News` x2 |
| 86,1169 | 46x15 | text | v0.11.1 | `text:v0.11.1` |
| 115,1003 | 217x60 | text | v0.11.1 - Linux Call Audio, Self-Hosted Relays, Personal Emotes & Relay Restarts | `text:v0.11.1 - Linux Call Audio, Self-Hosted Relays, Personal Emotes & Relay Restarts` |
| 128,738 | 33x28 | pressable | All | `text:All` x2 |
| 128,778 | 63x28 | pressable | Unread | `text:Unread` x2 |
| 128,849 | 74x28 | pressable | Mentions | `text:Mentions` x2 |
| 131,32 | 109x22 | text | Conversations | `text:Conversations` |
| 133,747 | 15x18 | text | All | `text:All` x2 |
| 133,787 | 45x18 | text | Unread | `text:Unread` x2 |
| 133,858 | 56x18 | text | Mentions | `text:Mentions` x2 |
| 164,24 | 908x53 | keyed |  | `key:[<'saved'>]` |
| 164,24 | 908x53 | keyed |  | `key:saved` |
| 164,24 | 908x53 | pressable | Saved messages,  | `semantics:Saved messages, ` x2 |
| 164,24 | 908x53 | semantics | Saved messages, | `semantics:Saved messages, ` x2 |
| 172,80 | 111x20 | text | Saved messages | `text:Saved messages` |
| 177,1003 | 103x15 | text | September 10, 2026 | `text:September 10, 2026` |
| 182,41 | 18x18 | icon | 0xe060 | `icon:0xe060` |
| 200,1003 | 217x51 | text | Linux got a bit upgrade on the call stability. Lots of issues with it are now pa... | `text:Linux got a bit upgrade on the call stability. Lots of issues with it are now pa...` |
| 217,24 | 908x53 | pressable | probe-b, No messages yet | `semantics:probe-b, No messages yet` x2 |
| 217,24 | 908x53 | semantics | probe-b, No messages yet | `semantics:probe-b, No messages yet` x2 |
| 217,24 | 908x53 | keyed |  | `key:dm:12D3KooWRsPZ7CSeumSbaRhGZBhvsCHvotXMQj3MtwWqyeHbsqQp` |
| 217,24 | 908x53 | keyed |  | `key:[<'dm:12D3KooWRsPZ7CSeumSbaRhGZBhvsCHvotXMQj3MtwWqyeHbsqQp'>]` |
| 225,80 | 54x20 | text | probe-b | `text:probe-b` x2 |
| 234,41 | 18x19 | text | PR | `text:PR` x3 |
| 245,80 | 97x17 | text | No messages yet | `text:No messages yet` |
| 254,60 | 8x8 | semantics | Offline | `semantics:Offline` x2 |
| 263,1003 | 120x18 | semantics | What's new in 0.11.1 | `semantics:What's new in 0.11.1` |
| 263,1003 | 120x18 | text | What's new in 0.11.1 | `text:What's new in 0.11.1` |
| 329,1003 | 143x18 | text | Relay | `text:Relay` |
| 330,1157 | 62x17 | text | Connected | `text:Connected` |
| 349,1003 | 217x15 | text | relay.anonlisten.com | `text:relay.anonlisten.com` |
| 376,1019 | 127x14 | text | RAM | `text:RAM` |
| 376,1149 | 70x14 | text | 625 / 7940 MB | `text:625 / 7940 MB` |
| 377,1003 | 12x12 | icon | 0xe445 | `icon:0xe445` |
| 406,1019 | 127x14 | text | Bandwidth | `text:Bandwidth` |
| 406,1150 | 70x14 | text | 0.1 / 950 Mbps | `text:0.1 / 950 Mbps` |
| 407,1003 | 12x12 | icon | 0xe038 | `icon:0xe038` |
| 446,1019 | 194x14 | text | Online | `text:Online` |
| 446,1213 | 7x14 | text | 5 | `text:5` |
| 447,1003 | 12x12 | icon | users (0xe1a4) | `icon:users` |
| 492,987 | 88x22 | text | Active Now | `text:Active Now` |
| 522,987 | 156x17 | text | Nobody is around right now | `text:Nobody is around right now` |
| 543,987 | 249x30 | text | Friends who are online, and voice rooms they are in, show up here. | `text:Friends who are online, and voice rooms they are in, show up here.` |
| 634,138 | 40x40 | tooltip | Home | `tooltip:Home` |
| 634,138 | 40x40 | pressable | Home | `semantics:Home` x2 |
| 634,138 | 40x40 | semantics | Home | `semantics:Home` x2 |
| 634,194 | 40x40 | keyed |  | `key:bounce-45f623ca41ad07fd661d0cbaf0b7938f` |
| 634,194 | 40x40 | tooltip | navmap | `tooltip:navmap` |
| 634,194 | 40x40 | pressable | navmap | `semantics:navmap` x2 |
| 634,194 | 40x40 | semantics | navmap | `semantics:navmap` x2 |
| 634,242 | 40x40 | tooltip | Create a server | `tooltip:Create a server` |
| 634,242 | 40x40 | pressable | Create a server | `semantics:Create a server` x2 |
| 634,242 | 40x40 | semantics | Create a server | `semantics:Create a server` x2 |
| 636,12 | 101x36 | semantics | probe-a, Online | `semantics:probe-a, Online` x2 |
| 636,12 | 101x36 | tooltip | Your profile and status | `tooltip:Your profile and status` |
| 636,12 | 101x36 | pressable | probe-a, Online | `semantics:probe-a, Online` x2 |
| 638,949 | 32x32 | semantics | Conferences | `semantics:Conferences` x2 |
| 638,949 | 32x32 | icon | video (0xe1a5) | `icon:video` |
| 638,949 | 32x32 | pressable | Conferences | `semantics:Conferences` x2 |
| 638,949 | 32x32 | tooltip | Conferences | `tooltip:Conferences` |
| 638,985 | 32x32 | tooltip | Public channels | `tooltip:Public channels` |
| 638,985 | 32x32 | pressable | Public channels | `semantics:Public channels` x2 |
| 638,985 | 32x32 | semantics | Public channels | `semantics:Public channels` x2 |
| 638,985 | 32x32 | icon | globe (0xe0e8) | `icon:globe` |
| 638,1021 | 32x32 | tooltip | Share | `tooltip:Share` |
| 638,1021 | 32x32 | pressable | Share | `semantics:Share` x2 |
| 638,1021 | 32x32 | semantics | Share | `semantics:Share` x2 |
| 638,1021 | 32x32 | icon | 0xe156 | `icon:0xe156` |
| 638,1057 | 32x32 | semantics | Archive | `semantics:Archive` x2 |
| 638,1057 | 32x32 | pressable | Archive | `semantics:Archive` x2 |
| 638,1057 | 32x32 | tooltip | Archive | `tooltip:Archive` |
| 638,1057 | 32x32 | icon | 0xe041 | `icon:0xe041` |
| 638,1093 | 32x32 | pressable | Hollow Shop | `semantics:Hollow Shop` x2 |
| 638,1093 | 32x32 | semantics | Hollow Shop | `semantics:Hollow Shop` x2 |
| 638,1093 | 32x32 | icon | 0xe3e4 | `icon:0xe3e4` |
| 638,1093 | 32x32 | tooltip | Hollow Shop | `tooltip:Hollow Shop` |
| 638,1150 | 32x32 | tooltip | Downloads | `tooltip:Downloads` |
| 638,1150 | 32x32 | pressable | Downloads | `semantics:Downloads` x2 |
| 638,1150 | 32x32 | semantics | Downloads | `semantics:Downloads` x2 |
| 638,1150 | 32x32 | icon | download (0xe0b2) | `icon:download` |
| 638,1186 | 32x32 | tooltip | Help | `tooltip:Help` |
| 638,1186 | 32x32 | pressable | Help | `semantics:Help` x2 |
| 638,1186 | 32x32 | icon | 0xe082 | `icon:0xe082` |
| 638,1186 | 32x32 | semantics | Help | `semantics:Help` x2 |
| 638,1222 | 32x32 | semantics | Settings | `semantics:Settings` x2 |
| 638,1222 | 32x32 | pressable | Settings | `semantics:Settings` x2 |
| 638,1222 | 32x32 | tooltip | Settings | `tooltip:Settings` |
| 638,1222 | 32x32 | icon | settings (0xe154) | `icon:settings` |
| 644,252 | 20x20 | icon | plus (0xe13d) | `icon:plus` x2 |
| 645,56 | 49x18 | text | probe-a | `text:probe-a` |
| 645,205 | 19x18 | text | NA | `text:NA` |
| 647,27 | 14x15 | text | PR | `text:PR` x3 |
| 661,41 | 7x7 | semantics | Online | `semantics:Online` |

