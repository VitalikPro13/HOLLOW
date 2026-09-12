# UI navigation map

Generated 2026-08-20 by `scripts\ui_nav_map.ps1` from the running app.
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
- [07-members](#ui-map-07-members)
- [08-home-dock](#ui-map-08-home-dock)

---

## UI map: 01-home

Screen 1264.0 x 681.0 logical pixels. 214 entries.

### Open surfaces

- dialog open: false
- context menu open: false

### Providers

- server: null (null)
- channel: null (null)
- layout mode: LayoutMode.dock

#### Stored layout

```
(empty layout)
```

### On screen

`y,x` is the top-left corner. Paste a target straight into a scenario; `xN` means the target matches N widgets, so scope it (`dialog > ...`) or pass an index.

| y,x | size | kind | label | target |
|---|---|---|---|---|
| 0,1126 | 46x32 | semantics | Minimize | `semantics:Minimize` |
| 0,1172 | 46x32 | semantics | Maximize | `semantics:Maximize` |
| 0,1218 | 46x32 | semantics | Close | `semantics:Close` |
| 7,16 | 44x18 | text | Hollow | `text:Hollow` |
| 7,1090 | 32x18 | icon | pencil (0xe1f9) | `icon:pencil` |
| 8,1141 | 16x16 | icon | 0xe11c | `icon:0xe11c` |
| 8,1233 | 16x16 | icon | x (0xe1b2) | `icon:x` |
| 9,1188 | 14x14 | icon | 0xe167 | `icon:0xe167` |
| 32,0 | 1264x649 | keyed |  | `key:_ScaffoldSlot.body` |
| 32,66 | 81x43 | tooltip | MacOS | `tooltip:MacOS` |
| 32,66 | 81x43 | pressable | 12 | `text:12` x22 |
| 32,153 | 68x43 | tooltip | Pixel | `tooltip:Pixel` |
| 32,153 | 68x43 | pressable | Pixel | `text:Pixel` x4 |
| 32,227 | 118x43 | pressable | 12 | `text:12` x22 |
| 32,227 | 118x43 | tooltip | iPhone 13 mini | `tooltip:iPhone 13 mini` |
| 32,351 | 92x43 | tooltip | UbuLinux | `tooltip:UbuLinux` |
| 32,351 | 92x43 | pressable | 12 | `text:12` x22 |
| 32,449 | 96x43 | pressable | virtual bro | `text:virtual bro` x4 |
| 32,449 | 96x43 | tooltip | virtual bro | `tooltip:virtual bro` |
| 41,8 | 34x26 | semantics | Add friend | `semantics:Add friend` x2 |
| 41,8 | 34x26 | tooltip | Add Friend | `tooltip:Add Friend` |
| 41,8 | 34x26 | pressable | Add friend | `semantics:Add friend` x2 |
| 41,1146 | 34x26 | tooltip | Saved messages | `tooltip:Saved messages` |
| 41,1146 | 34x26 | pressable | Saved messages | `semantics:Saved messages` x2 |
| 41,1146 | 34x26 | semantics | Saved messages | `semantics:Saved messages` x2 |
| 41,1184 | 34x26 | tooltip | Conferences | `tooltip:Conferences` |
| 41,1184 | 34x26 | pressable | Conferences | `semantics:Conferences` x2 |
| 41,1184 | 34x26 | semantics | Conferences | `semantics:Conferences` x2 |
| 41,1222 | 34x26 | pressable | Help | `semantics:Help` x2 |
| 41,1222 | 34x26 | tooltip | Help | `tooltip:Help` |
| 41,1222 | 34x26 | semantics | Help | `semantics:Help` x2 |
| 45,16 | 18x18 | icon | userPlus (0xe1a2) | `icon:userPlus` |
| 45,1154 | 18x18 | icon | 0xe060 | `icon:0xe060` |
| 45,1192 | 18x18 | icon | video (0xe1a5) | `icon:video` |
| 45,1230 | 18x18 | icon | 0xe082 | `icon:0xe082` |
| 46,104 | 35x15 | text | MacOS | `text:MacOS` x2 |
| 46,191 | 22x15 | text | Pixel | `text:Pixel` x4 |
| 46,265 | 72x15 | text | iPhone 13 mini | `text:iPhone 13 mini` x2 |
| 46,389 | 46x15 | text | UbuLinux | `text:UbuLinux` x2 |
| 46,487 | 50x15 | text | virtual bro | `text:virtual bro` x4 |
| 47,82 | 9x13 | text | 12 | `text:12` x22 |
| 47,243 | 9x13 | text | 12 | `text:12` x22 |
| 47,367 | 9x13 | text | 12 | `text:12` x22 |
| 59,92 | 7x7 | semantics | Offline | `semantics:Offline` x14 |
| 59,178 | 7x7 | semantics | Offline | `semantics:Offline` x14 |
| 59,252 | 7x7 | semantics | Offline | `semantics:Offline` x14 |
| 59,376 | 7x7 | semantics | Offline | `semantics:Offline` x14 |
| 59,474 | 7x7 | semantics | Offline | `semantics:Offline` x14 |
| 76,0 | 1264x546 | keyed |  | `key:[<[<'single-empty'>]>]` |
| 76,0 | 1264x546 | keyed |  | `key:[<'single-empty'>]` |
| 76,0 | 1264x546 | keyed |  | `key:single-empty` |
| 76,0 | 1264x546 | keyed |  | `key:[<[<'empty'>]>]` |
| 76,0 | 1264x546 | keyed |  | `key:[<'empty'>]` |
| 76,0 | 1264x546 | keyed |  | `key:empty` |
| 116,323 | 156x22 | text | Recent Conversations | `text:Recent Conversations` |
| 116,1006 | 62x22 | text | Network | `text:Network` |
| 118,297 | 18x18 | icon | messageCircle (0xe116) | `icon:messageCircle` |
| 118,980 | 18x18 | icon | 0xe038 | `icon:0xe038` x2 |
| 150,297 | 650x52 | pressable | 12 | `text:12` x22 |
| 159,353 | 41x18 | text | MacOS | `text:MacOS` x2 |
| 161,1007 | 59x17 | text | Connected | `text:Connected` |
| 167,320 | 13x19 | text | 12 | `text:12` x22 |
| 169,911 | 24x14 | text | 07:19 | `text:07:19` |
| 178,1007 | 84x14 | text | 0 friends reachable | `text:0 friends reachable` |
| 179,353 | 82x15 | text | You: ÐÐ¾Ñ€Ð¼Ð°Ð»ÑŒÐ½Ð¾ | `text:You: ÐÐ¾Ñ€Ð¼Ð°Ð»ÑŒÐ½Ð¾` |
| 185,336 | 8x8 | semantics | Offline | `semantics:Offline` x14 |
| 200,98 | 92x23 | text | AnonListen | `text:AnonListen` x3 |
| 206,297 | 650x52 | pressable | 12 | `text:12` x22 |
| 215,353 | 86x18 | text | iPhone 13 mini | `text:iPhone 13 mini` x2 |
| 219,980 | 45x14 | text | FRIENDS | `text:FRIENDS` |
| 223,320 | 13x19 | text | 12 | `text:12` x22 |
| 225,915 | 20x14 | text | 8/17 | `text:8/17` |
| 227,134 | 32x15 | text | Online | `text:Online` |
| 235,353 | 17x15 | text | hey | `text:hey` |
| 241,336 | 8x8 | semantics | Offline | `semantics:Offline` x14 |
| 241,1229 | 11x17 | text | 13 | `text:13` x2 |
| 242,997 | 32x15 | text | Offline | `text:Offline` |
| 243,980 | 13x13 | icon | 0xe1af | `icon:0xe1af` |
| 250,94 | 100x17 | text | Working on Hollow | `text:Working on Hollow` |
| 262,297 | 650x52 | pressable | 12 | `text:12` x22 |
| 271,353 | 36x18 | text | krigo2 | `text:krigo2` |
| 278,980 | 75x14 | text | RELAY SERVER | `text:RELAY SERVER` |
| 279,320 | 13x19 | text | 12 | `text:12` x22 |
| 281,915 | 20x14 | text | 8/16 | `text:8/16` x2 |
| 291,353 | 47x15 | text | You: yeah | `text:You: yeah` |
| 292,77 | 134x17 | text | â€œNonprofessional listenerâ€ | `text:â€œNonprofessional listenerâ€` |
| 297,336 | 8x8 | semantics | Offline | `semantics:Offline` x14 |
| 311,1007 | 153x14 | text | RAM | `text:RAM` |
| 311,1164 | 65x14 | text | 593 / 7940 MB | `text:593 / 7940 MB` |
| 312,991 | 12x12 | icon | 0xe445 | `icon:0xe445` |
| 318,297 | 650x52 | pressable | 12 | `text:12` x22 |
| 327,353 | 73x18 | text | 12D3KooW... | `text:12D3KooW...` |
| 334,24 | 240x49 | semantics | System status: All systems operational | `semantics:System status: All systems operational` |
| 335,320 | 13x19 | text | 12 | `text:12` x22 |
| 337,915 | 20x14 | text | 8/16 | `text:8/16` x2 |
| 341,1007 | 141x14 | text | Bandwidth | `text:Bandwidth` |
| 341,1152 | 77x14 | text | 13.2 / 1000 Mbps | `text:13.2 / 1000 Mbps` |
| 342,991 | 12x12 | icon | 0xe038 | `icon:0xe038` x2 |
| 343,57 | 75x17 | text | System Status | `text:System Status` |
| 344,35 | 14x14 | icon | 0xe226 | `icon:0xe226` |
| 347,353 | 33x15 | text | You: hi | `text:You: hi` |
| 353,336 | 8x8 | semantics | Offline | `semantics:Offline` x14 |
| 360,57 | 102x14 | text | All systems operational | `text:All systems operational` |
| 371,991 | 238x14 | tooltip | Relay traffic for your connection today: uploads and downloads (files, images, s... | `tooltip:Relay traffic for your connection today: uploads and downloads (files, images, sync). Shared by every device on your network (counted per IP). Direct P2P transfers don't count.` |
| 371,1007 | 70x14 | text | Daily relay data | `text:Daily relay data` |
| 372,991 | 12x12 | icon | 0xe1bf | `icon:0xe1bf` |
| 374,297 | 650x52 | pressable | 12 | `text:12` x22 |
| 383,353 | 31x18 | text | vm22 | `text:vm22` |
| 391,320 | 13x19 | text | 12 | `text:12` x22 |
| 393,920 | 15x14 | text | 8/6 | `text:8/6` |
| 396,991 | 71x13 | text | 3.3 MB of 10.0 GB | `text:3.3 MB of 10.0 GB` |
| 396,1167 | 62x13 | text | resets in 4h 3m | `text:resets in 4h 3m` |
| 398,1154 | 9x9 | icon | 0xe087 | `icon:0xe087` |
| 403,353 | 16x15 | text | reh | `text:reh` |
| 406,52 | 64x14 | text | YOUR STATS | `text:YOUR STATS` |
| 407,35 | 13x13 | icon | 0xe2a3 | `icon:0xe2a3` |
| 409,336 | 8x8 | semantics | Offline | `semantics:Offline` x14 |
| 428,242 | 11x17 | text | 13 | `text:13` x2 |
| 429,55 | 35x15 | text | Friends | `text:Friends` |
| 430,297 | 650x52 | pressable | virtual bro | `text:virtual bro` x4 |
| 431,35 | 12x12 | icon | users (0xe1a4) | `icon:users` |
| 439,353 | 59x18 | text | virtual bro | `text:virtual bro` x4 |
| 447,980 | 31x14 | text | NEWS | `text:NEWS` |
| 449,920 | 15x14 | text | 8/3 | `text:8/3` |
| 451,246 | 7x17 | text | 6 | `text:6` |
| 452,55 | 35x15 | text | Servers | `text:Servers` |
| 454,35 | 12x12 | icon | server (0xe153) | `icon:server` |
| 459,353 | 246x15 | text | You: https://www.instagram.com/p/Dbi4tVWNcFZ/ | `text:You: https://www.instagram.com/p/Dbi4tVWNcFZ/` |
| 465,336 | 8x8 | semantics | Offline | `semantics:Offline` x14 |
| 474,228 | 25x17 | text | 1062 | `text:1062` |
| 475,55 | 68x15 | text | DM messages | `text:DM messages` |
| 477,35 | 12x12 | icon | messageSquare (0xe117) | `icon:messageSquare` |
| 480,991 | 238x51 | text | v0.10 - Screen Share Forwarding, Mobile Audio Devices, Interface Sounds & Flutte... | `text:v0.10 - Screen Share Forwarding, Mobile Audio Devices, Interface Sounds & Flutte...` |
| 486,297 | 650x52 | pressable | 12 | `text:12` x22 |
| 495,353 | 54x18 | text | UbuLinux | `text:UbuLinux` x2 |
| 497,248 | 5x17 | text | 1 | `text:1` |
| 498,55 | 37x15 | text | Devices | `text:Devices` |
| 500,35 | 12x12 | icon | 0xe163 | `icon:0xe163` |
| 503,320 | 13x19 | text | 12 | `text:12` x22 |
| 505,920 | 15x14 | text | 8/1 | `text:8/1` |
| 515,353 | 449x15 | text | You: [a:s:dbb417106aab0fcf3fc210f6395a21a55f79422ddb31104a74faf75a87d98b31:512:2... | `text:You: [a:s:dbb417106aab0fcf3fc210f6395a21a55f79422ddb31104a74faf75a87d98b31:512:2...` |
| 521,336 | 8x8 | semantics | Offline | `semantics:Offline` x14 |
| 533,991 | 71x14 | text | August 19, 2026 | `text:August 19, 2026` |
| 542,297 | 650x52 | pressable | Pixel | `text:Pixel` x4 |
| 551,353 | 26x18 | text | Pixel | `text:Pixel` x4 |
| 555,991 | 238x221 | input | Probably one of the harshest updates shipped so far... in a nutshell, the screen... | `type:EditableText` |
| 561,915 | 20x14 | text | 7/20 | `text:7/20` |
| 571,353 | 30x15 | text | You: 1 | `text:You: 1` |
| 577,83 | 123x21 | pressable | 12D3KooW...T7iS4F | `text:12D3KooW...T7iS4F` x2 |
| 577,336 | 8x8 | semantics | Offline | `semantics:Offline` x14 |
| 581,105 | 93x13 | text | 12D3KooW...T7iS4F | `text:12D3KooW...T7iS4F` x2 |
| 583,91 | 10x10 | icon | copy (0xe09e) | `icon:copy` |
| 598,297 | 650x52 | pressable | 12 | `text:12` x22 |
| 607,353 | 40x18 | text | iPhone | `text:iPhone` |
| 615,320 | 13x19 | text | 12 | `text:12` x22 |
| 617,915 | 20x14 | text | 7/16 | `text:7/16` |
| 627,353 | 48x15 | text | You: what | `text:You: what` |
| 633,149 | 38x38 | semantics | Home | `semantics:Home` |
| 633,149 | 38x38 | tooltip | Home | `tooltip:Home` |
| 633,336 | 8x8 | semantics | Offline | `semantics:Offline` x14 |
| 633,493 | 38x38 | keyed |  | `key:bounce-1a88f45832c2a648a914fc259f602a12` |
| 633,493 | 38x38 | semantics | testing | `semantics:testing` |
| 633,493 | 38x38 | tooltip | testing | `tooltip:testing` |
| 633,535 | 38x38 | tooltip | another one! | `tooltip:another one!` |
| 633,535 | 38x38 | semantics | another one! | `semantics:another one!` |
| 633,535 | 38x38 | keyed |  | `key:bounce-8f3d5c37a26835ddf04b07f2c91da556` |
| 633,577 | 38x38 | tooltip | MyEpicServer | `tooltip:MyEpicServer` |
| 633,577 | 38x38 | semantics | MyEpicServer | `semantics:MyEpicServer` |
| 633,577 | 38x38 | keyed |  | `key:bounce-b7d2030be50e7bd8708c4364102c4029` |
| 633,619 | 38x38 | semantics | qww | `semantics:qww` |
| 633,619 | 38x38 | tooltip | qww | `tooltip:qww` |
| 633,619 | 38x38 | keyed |  | `key:bounce-703162ad1c1dd3f77a506828f71c5f8d` |
| 633,661 | 38x38 | semantics | test | `semantics:test` |
| 633,661 | 38x38 | keyed |  | `key:bounce-6ec23029e3003347d7cdd73988293dd7` |
| 633,661 | 38x38 | tooltip | test | `tooltip:test` |
| 633,703 | 38x38 | semantics | test3 | `semantics:test3` |
| 633,703 | 38x38 | keyed |  | `key:bounce-6ae8032accaad737890ca2d4f9e97752` |
| 633,703 | 38x38 | tooltip | test3 | `tooltip:test3` |
| 633,1047 | 38x38 | tooltip | Create a server | `tooltip:Create a server` |
| 633,1047 | 38x38 | semantics | Create a server | `semantics:Create a server` |
| 638,0 | 140x28 | pressable | AnonListen | `text:AnonListen` x3 |
| 638,0 | 140x28 | tooltip | Online | `tooltip:Online` |
| 639,1114 | 26x26 | tooltip | Browse Public Channels | `tooltip:Browse Public Channels` |
| 639,1114 | 26x26 | semantics | Browse public channels | `semantics:Browse public channels` x2 |
| 639,1114 | 26x26 | pressable | Browse public channels | `semantics:Browse public channels` x2 |
| 639,1140 | 26x26 | pressable | Share | `semantics:Share` x2 |
| 639,1140 | 26x26 | tooltip | Share | `tooltip:Share` |
| 639,1140 | 26x26 | semantics | Share | `semantics:Share` x2 |
| 639,1166 | 26x26 | tooltip | Archive | `tooltip:Archive` |
| 639,1166 | 26x26 | semantics | Archive | `semantics:Archive` x2 |
| 639,1166 | 26x26 | pressable | Archive | `semantics:Archive` x2 |
| 639,1192 | 26x26 | tooltip | Downloads | `tooltip:Downloads` |
| 639,1192 | 26x26 | semantics | Downloads | `semantics:Downloads` x2 |
| 639,1192 | 26x26 | pressable | Downloads | `semantics:Downloads` x2 |
| 639,1218 | 26x26 | tooltip | Settings | `tooltip:Settings` |
| 639,1218 | 26x26 | pressable | Settings | `semantics:Settings` x2 |
| 639,1218 | 26x26 | semantics | Settings | `semantics:Settings` x2 |
| 640,161 | 14x25 | text | H | `text:H` |
| 642,585 | 21x20 | text | MY | `text:MY` |
| 642,673 | 15x20 | text | TE | `text:TE` x2 |
| 642,715 | 15x20 | text | TE | `text:TE` x2 |
| 643,1057 | 18x18 | icon | plus (0xe13d) | `icon:plus` |
| 643,1118 | 18x18 | icon | globe (0xe0e8) | `icon:globe` |
| 643,1144 | 18x18 | icon | 0xe156 | `icon:0xe156` |
| 643,1170 | 18x18 | icon | 0xe041 | `icon:0xe041` |
| 643,1196 | 18x18 | icon | download (0xe0b2) | `icon:download` |
| 643,1222 | 18x18 | icon | settings (0xe154) | `icon:settings` |
| 644,59 | 69x17 | text | AnonListen | `text:AnonListen` x3 |
| 649,48 | 7x7 | semantics | Online | `semantics:Online` |
| 654,297 | 650x52 | pressable | 12 | `text:12` x22 |
| 663,353 | 30x18 | text | Linux | `text:Linux` |
| 671,320 | 13x19 | text | 12 | `text:12` x22 |
| 673,915 | 20x14 | text | 6/22 | `text:6/22` |
| 679,998 | 33x13 | text | Installed | `text:Installed` |

---

## UI map: 02-server

Screen 1264.0 x 681.0 logical pixels. 272 entries.

### Open surfaces

- dialog open: false
- context menu open: false

### Providers

- server: test3 (6ae8032accaad737890ca2d4f9e97752)
- channel: general (6ae8032a-general)
- layout mode: LayoutMode.dock

#### Stored layout

```
[0] general (text, 6ae8032a-general)
[1] test (text, 6ae8032a-3f35dfa2)
[2] test3 (voice, 6ae8032a-5af0eb9e)
[3] CATEGORY "233"
    [4] 23 (text, 6ae8032a-75134eee)
```

### On screen

`y,x` is the top-left corner. Paste a target straight into a scenario; `xN` means the target matches N widgets, so scope it (`dialog > ...`) or pass an index.

| y,x | size | kind | label | target |
|---|---|---|---|---|
| 0,1126 | 46x32 | semantics | Minimize | `semantics:Minimize` |
| 0,1172 | 46x32 | semantics | Maximize | `semantics:Maximize` |
| 0,1218 | 46x32 | semantics | Close | `semantics:Close` |
| 7,16 | 44x18 | text | Hollow | `text:Hollow` |
| 7,1090 | 32x18 | icon | pencil (0xe1f9) | `icon:pencil` |
| 8,1141 | 16x16 | icon | 0xe11c | `icon:0xe11c` |
| 8,1233 | 16x16 | icon | x (0xe1b2) | `icon:x` |
| 9,1188 | 14x14 | icon | 0xe167 | `icon:0xe167` |
| 32,0 | 1264x649 | keyed |  | `key:_ScaffoldSlot.body` |
| 32,66 | 81x43 | tooltip | MacOS | `tooltip:MacOS` |
| 32,66 | 81x43 | pressable | 12 | `text:12` x12 |
| 32,153 | 68x43 | tooltip | Pixel | `tooltip:Pixel` |
| 32,153 | 68x43 | pressable | Pixel | `text:Pixel` x2 |
| 32,227 | 118x43 | tooltip | iPhone 13 mini | `tooltip:iPhone 13 mini` |
| 32,227 | 118x43 | pressable | 12 | `text:12` x12 |
| 32,351 | 92x43 | pressable | 12 | `text:12` x12 |
| 32,351 | 92x43 | tooltip | UbuLinux | `tooltip:UbuLinux` |
| 32,449 | 96x43 | pressable | virtual bro | `text:virtual bro` x4 |
| 32,449 | 96x43 | tooltip | virtual bro | `tooltip:virtual bro` |
| 41,8 | 34x26 | tooltip | Add Friend | `tooltip:Add Friend` |
| 41,8 | 34x26 | pressable | Add friend | `semantics:Add friend` x2 |
| 41,8 | 34x26 | semantics | Add friend | `semantics:Add friend` x2 |
| 41,1146 | 34x26 | semantics | Saved messages | `semantics:Saved messages` x2 |
| 41,1146 | 34x26 | pressable | Saved messages | `semantics:Saved messages` x2 |
| 41,1146 | 34x26 | tooltip | Saved messages | `tooltip:Saved messages` |
| 41,1184 | 34x26 | semantics | Conferences | `semantics:Conferences` x2 |
| 41,1184 | 34x26 | pressable | Conferences | `semantics:Conferences` x2 |
| 41,1184 | 34x26 | tooltip | Conferences | `tooltip:Conferences` |
| 41,1222 | 34x26 | pressable | Help | `semantics:Help` x2 |
| 41,1222 | 34x26 | tooltip | Help | `tooltip:Help` |
| 41,1222 | 34x26 | semantics | Help | `semantics:Help` x2 |
| 45,16 | 18x18 | icon | userPlus (0xe1a2) | `icon:userPlus` x2 |
| 45,1154 | 18x18 | icon | 0xe060 | `icon:0xe060` |
| 45,1192 | 18x18 | icon | video (0xe1a5) | `icon:video` |
| 45,1230 | 18x18 | icon | 0xe082 | `icon:0xe082` |
| 46,104 | 35x15 | text | MacOS | `text:MacOS` |
| 46,191 | 22x15 | text | Pixel | `text:Pixel` x2 |
| 46,265 | 72x15 | text | iPhone 13 mini | `text:iPhone 13 mini` x4 |
| 46,389 | 46x15 | text | UbuLinux | `text:UbuLinux` |
| 46,487 | 50x15 | text | virtual bro | `text:virtual bro` x4 |
| 47,82 | 9x13 | text | 12 | `text:12` x12 |
| 47,243 | 9x13 | text | 12 | `text:12` x12 |
| 47,367 | 9x13 | text | 12 | `text:12` x12 |
| 59,92 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 59,178 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 59,252 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 59,376 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 59,474 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 76,0 | 239x48 | keyed |  | `key:header-test3` |
| 76,0 | 239x48 | keyed |  | `key:[<null>]` |
| 76,0 | 239x48 | keyed |  | `key:null` |
| 76,240 | 784x546 | keyed |  | `key:[<[<'single-6ae8032a-general'>]>]` |
| 76,240 | 784x546 | keyed |  | `key:[<'single-6ae8032a-general'>]` |
| 76,240 | 784x546 | keyed |  | `key:single-6ae8032a-general` |
| 76,240 | 784x546 | keyed |  | `key:[<[<'6ae8032a-general'>]>]` |
| 76,240 | 784x546 | keyed |  | `key:[<'6ae8032a-general'>]` |
| 76,240 | 784x546 | keyed |  | `key:6ae8032a-general` |
| 76,240 | 784x546 | keyed |  | `key:ch:6ae8032a-general` |
| 76,1025 | 239x546 | keyed |  | `key:[<[<'server-members-6ae8032accaad737890ca2d4f9e97752'>]>]` |
| 76,1025 | 239x546 | keyed |  | `key:server-members-6ae8032accaad737890ca2d4f9e97752` |
| 76,1025 | 239x546 | keyed |  | `key:[<'server-members-6ae8032accaad737890ca2d4f9e97752'>]` |
| 86,946 | 28x28 | tooltip | Toggle member panel | `tooltip:Toggle member panel` |
| 86,946 | 28x28 | pressable | Toggle member panel | `semantics:Toggle member panel` x2 |
| 86,946 | 28x28 | semantics | Toggle member panel | `semantics:Toggle member panel` x2 |
| 87,912 | 26x26 | semantics | Search messages | `semantics:Search messages` x2 |
| 87,912 | 26x26 | tooltip | Search messages | `tooltip:Search messages` |
| 87,912 | 26x26 | pressable | Search messages | `semantics:Search messages` x2 |
| 87,982 | 26x26 | tooltip | Split view | `tooltip:Split view` |
| 87,982 | 26x26 | pressable | Split view | `semantics:Split view` x2 |
| 87,982 | 26x26 | semantics | Split view | `semantics:Split view` x2 |
| 88,159 | 24x24 | pressable | Invite people | `semantics:Invite people` x2 |
| 88,159 | 24x24 | semantics | Invite people | `semantics:Invite people` x2 |
| 88,159 | 24x24 | tooltip | Invite people | `tooltip:Invite people` |
| 88,183 | 24x24 | tooltip | Storage | `tooltip:Storage` |
| 88,183 | 24x24 | pressable | Storage | `semantics:Storage` x2 |
| 88,183 | 24x24 | semantics | Storage | `semantics:Storage` x2 |
| 88,207 | 24x24 | tooltip | Server settings | `tooltip:Server settings` |
| 88,207 | 24x24 | pressable | Server settings | `semantics:Server settings` x2 |
| 88,207 | 24x24 | semantics | Server settings | `semantics:Server settings` x2 |
| 89,16 | 143x22 | text | test3 | `text:test3` x3 |
| 89,284 | 546x22 | text | general | `text:general` x3 |
| 90,256 | 20x20 | icon | hash (0xe0ef) | `icon:hash` x4 |
| 90,950 | 20x20 | icon | users (0xe1a4) | `icon:users` x2 |
| 91,916 | 18x18 | icon | search (0xe151) | `icon:search` |
| 91,986 | 18x18 | icon | 0xe098 | `icon:0xe098` |
| 92,163 | 16x16 | icon | userPlus (0xe1a2) | `icon:userPlus` x2 |
| 92,187 | 16x16 | icon | hardDrive (0xe0ed) | `icon:hardDrive` |
| 92,211 | 16x16 | icon | settings (0xe154) | `icon:settings` x2 |
| 92,1035 | 53x15 | text | Members | `text:Members` |
| 92,1247 | 7x15 | text | 4 | `text:4` |
| 93,842 | 62x15 | keyed |  | `key:conn-6ae8032accaad737890ca2d4f9e97752` |
| 93,842 | 62x15 | tooltip | You're connected. Nobody else is online here right now | `tooltip:You're connected. Nobody else is online here right now` |
| 93,842 | 14x14 | icon | users (0xe1a4) | `icon:users` x2 |
| 93,860 | 44x15 | text | Only you | `text:Only you` |
| 124,0 | 239x498 | keyed |  | `key:[<[<'server-6ae8032accaad737890ca2d4f9e97752'>]>]` |
| 124,0 | 239x498 | keyed |  | `key:server-6ae8032accaad737890ca2d4f9e97752` |
| 124,0 | 239x498 | keyed |  | `key:[<'server-6ae8032accaad737890ca2d4f9e97752'>]` |
| 125,240 | 784x432 | keyed |  | `key:ch-list-6ae8032accaad737890ca2d4f9e97752-6ae8032a-general` |
| 125,240 | 784x432 | keyed |  | `key:Ping` |
| 128,0 | 239x40 | keyed |  | `key:[<'ach-6ae8032a-general'>]` |
| 128,0 | 239x40 | keyed |  | `key:ach-6ae8032a-general` |
| 130,8 | 223x36 | pressable | general | `text:general` x3 |
| 132,1025 | 239x31 | keyed |  | `key:div-Owner` |
| 132,1025 | 239x31 | keyed |  | `key:[<'div-Owner'>]` |
| 138,44 | 177x20 | text | general | `text:general` x3 |
| 139,18 | 18x18 | icon | hash (0xe0ef) | `icon:hash` x4 |
| 140,1035 | 37x15 | text | Owner | `text:Owner` x2 |
| 140,1249 | 5x15 | text | 1 | `text:1` |
| 163,1025 | 239x50 | keyed |  | `key:[<'mem-12D3KooWJJU9fygVAYVJqVM4FAtTyaUBHSsfRkuavwY53nT7iS4F'>]` |
| 163,1025 | 239x50 | keyed |  | `key:mem-12D3KooWJJU9fygVAYVJqVM4FAtTyaUBHSsfRkuavwY53nT7iS4F` |
| 163,1025 | 239x50 | pressable | AnonListen | `text:AnonListen` x6 |
| 166,1071 | 59x17 | text | AnonListen | `text:AnonListen` x6 |
| 168,0 | 239x40 | keyed |  | `key:[<'ach-6ae8032a-3f35dfa2'>]` |
| 168,0 | 239x40 | keyed |  | `key:ach-6ae8032a-3f35dfa2` |
| 170,8 | 223x36 | pressable | test | `text:test` x3 |
| 178,44 | 177x20 | text | test | `text:test` x3 |
| 179,18 | 18x18 | icon | hash (0xe0ef) | `icon:hash` x4 |
| 183,1071 | 29x14 | text | Owner | `text:Owner` x2 |
| 191,240 | 784x96 | keyed |  | `key:556dcb2e16ed2a4ade7b38948840ff3f` x2 |
| 191,240 | 784x96 | keyed |  | `key:556dcb2e16ed2a4ade7b38948840ff3f` x2 |
| 191,240 | 784x96 | keyed |  | `key:[<556dcb2e16ed2a4ade7b38948840ff3f>]` |
| 195,1056 | 7x7 | semantics | Online | `semantics:Online` x2 |
| 197,1084 | 41x13 | text | anonlisten | `text:anonlisten` |
| 199,1071 | 10x10 | icon | 0xf58a | `icon:0xf58a` |
| 205,595 | 75x15 | text | August 7, 2026 | `text:August 7, 2026` |
| 208,0 | 239x40 | keyed |  | `key:[<'ach-6ae8032a-5af0eb9e'>]` |
| 208,0 | 239x40 | keyed |  | `key:ach-6ae8032a-5af0eb9e` |
| 210,8 | 223x36 | pressable | test3 | `text:test3` x3 |
| 213,1025 | 239x31 | keyed |  | `key:[<'div-Offline'>]` |
| 213,1025 | 239x31 | keyed |  | `key:div-Offline` |
| 218,44 | 177x20 | text | test3 | `text:test3` x3 |
| 219,18 | 18x18 | icon | volume2 (0xe1ab) | `icon:volume2` |
| 221,1035 | 40x15 | text | Offline | `text:Offline` |
| 221,1247 | 7x15 | text | 3 | `text:3` |
| 242,294 | 66x18 | text | AnonListen | `text:AnonListen` x6 |
| 242,294 | 66x18 | semantics | Open profile | `semantics:Open profile` x8 |
| 244,368 | 24x14 | text | 19:33 | `text:19:33` |
| 244,1025 | 239x34 | pressable | 12 | `text:12` x12 |
| 244,1025 | 239x34 | keyed |  | `key:mem-12D3KooWKS8jL9xFsxkMgwrLGJpnSngi8KgtPRuFyNRVL4PnKh8C` |
| 244,1025 | 239x34 | keyed |  | `key:[<'mem-12D3KooWKS8jL9xFsxkMgwrLGJpnSngi8KgtPRuFyNRVL4PnKh8C'>]` |
| 247,252 | 32x32 | semantics | Open profile | `semantics:Open profile` x8 |
| 253,1071 | 29x17 | text | vm22 | `text:vm22` |
| 254,1044 | 10x15 | text | 12 | `text:12` x12 |
| 260,10 | 221x15 | pressable | 233 | `text:233` x2 |
| 260,24 | 207x15 | text | 233 | `text:233` x2 |
| 263,10 | 10x10 | icon | chevronDown (0xe06d) | `icon:chevronDown` |
| 263,294 | 23x20 | text | test | `text:test` x3 |
| 268,1056 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 278,1025 | 239x34 | keyed |  | `key:mem-12D3KooWF5kuBjyDMSzFviHHvdtS6uaZTqq57pA9ik2PAnffNXdk` |
| 278,1025 | 239x34 | keyed |  | `key:[<'mem-12D3KooWF5kuBjyDMSzFviHHvdtS6uaZTqq57pA9ik2PAnffNXdk'>]` |
| 278,1025 | 239x34 | pressable | virtual bro | `text:virtual bro` x4 |
| 279,0 | 239x40 | keyed |  | `key:ach-6ae8032a-75134eee` |
| 279,0 | 239x40 | keyed |  | `key:[<'ach-6ae8032a-75134eee'>]` |
| 281,8 | 223x36 | pressable | 23 | `text:23` x2 |
| 287,240 | 784x24 | keyed |  | `key:[<4ce7ee57dbfb849322935d80678e1326>]` |
| 287,240 | 784x24 | keyed |  | `key:4ce7ee57dbfb849322935d80678e1326` x2 |
| 287,240 | 784x24 | keyed |  | `key:4ce7ee57dbfb849322935d80678e1326` x2 |
| 287,1071 | 54x17 | text | virtual bro | `text:virtual bro` x4 |
| 289,44 | 177x20 | text | 23 | `text:23` x2 |
| 289,294 | 25x20 | text | teto | `text:teto` x2 |
| 290,18 | 18x18 | icon | hash (0xe0ef) | `icon:hash` x4 |
| 302,1056 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 311,240 | 784x96 | keyed |  | `key:[<c61bfc6746d4e10f3f6c2610b81d3b56>]` |
| 311,240 | 784x96 | keyed |  | `key:c61bfc6746d4e10f3f6c2610b81d3b56` x2 |
| 311,240 | 784x96 | keyed |  | `key:c61bfc6746d4e10f3f6c2610b81d3b56` x2 |
| 312,1025 | 239x34 | pressable | 12 | `text:12` x12 |
| 312,1025 | 239x34 | keyed |  | `key:mem-12D3KooWLyj5mKdcjKWKRCtJni4bPD7dKiU5SEWMDNWQNNbfdhAL` |
| 312,1025 | 239x34 | keyed |  | `key:[<'mem-12D3KooWLyj5mKdcjKWKRCtJni4bPD7dKiU5SEWMDNWQNNbfdhAL'>]` |
| 321,1071 | 79x17 | text | iPhone 13 mini | `text:iPhone 13 mini` x4 |
| 322,1044 | 10x15 | text | 12 | `text:12` x12 |
| 325,592 | 79x15 | text | August 16, 2026 | `text:August 16, 2026` |
| 336,1056 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 362,294 | 86x18 | semantics | Open profile | `semantics:Open profile` x8 |
| 362,294 | 86x18 | text | iPhone 13 mini | `text:iPhone 13 mini` x4 |
| 364,388 | 24x14 | text | 13:41 | `text:13:41` x2 |
| 367,252 | 32x32 | semantics | Open profile | `semantics:Open profile` x8 |
| 375,262 | 12x17 | text | 12 | `text:12` x12 |
| 383,294 | 25x20 | text | teto | `text:teto` x2 |
| 407,240 | 784x59 | keyed |  | `key:51692019ab6c1b2232a279bde0aac13b` x2 |
| 407,240 | 784x59 | keyed |  | `key:[<51692019ab6c1b2232a279bde0aac13b>]` |
| 407,240 | 784x59 | keyed |  | `key:51692019ab6c1b2232a279bde0aac13b` x2 |
| 421,294 | 66x18 | text | AnonListen | `text:AnonListen` x6 |
| 421,294 | 66x18 | semantics | Open profile | `semantics:Open profile` x8 |
| 423,368 | 24x14 | text | 13:41 | `text:13:41` x2 |
| 426,252 | 32x32 | semantics | Open profile | `semantics:Open profile` x8 |
| 442,294 | 78x20 | text | kasane teto? | `text:kasane teto?` |
| 466,240 | 784x24 | keyed |  | `key:[<30470f31c83c54d5d0d6dec208c9cccf>]` |
| 466,240 | 784x24 | keyed |  | `key:30470f31c83c54d5d0d6dec208c9cccf` x2 |
| 466,240 | 784x24 | keyed |  | `key:30470f31c83c54d5d0d6dec208c9cccf` x2 |
| 468,294 | 20x20 | text | yes | `text:yes` |
| 490,240 | 784x59 | keyed |  | `key:[<bca4f49faa4635e7ba2466dc3f2deeeb>]` |
| 490,240 | 784x59 | keyed |  | `key:bca4f49faa4635e7ba2466dc3f2deeeb` x2 |
| 490,240 | 784x59 | keyed |  | `key:bca4f49faa4635e7ba2466dc3f2deeeb` x2 |
| 504,294 | 86x18 | semantics | Open profile | `semantics:Open profile` x8 |
| 504,294 | 86x18 | text | iPhone 13 mini | `text:iPhone 13 mini` x4 |
| 506,388 | 24x14 | text | 16:24 | `text:16:24` |
| 509,252 | 32x32 | semantics | Open profile | `semantics:Open profile` x8 |
| 517,262 | 12x17 | text | 12 | `text:12` x12 |
| 525,294 | 4x20 | text | f | `text:f` |
| 566,332 | 515x48 | field | hint "Message #general" | `hint:Message #general` |
| 572,252 | 36x36 | semantics | Attach file | `semantics:Attach file` x2 |
| 572,252 | 36x36 | pressable | Attach file | `semantics:Attach file` x2 |
| 572,292 | 36x36 | semantics | Record voice message | `semantics:Record voice message` x2 |
| 572,292 | 36x36 | pressable | Record voice message | `semantics:Record voice message` x2 |
| 572,851 | 41x36 | semantics | Insert GIF | `semantics:Insert GIF` x2 |
| 572,851 | 41x36 | pressable | Insert GIF | `semantics:Insert GIF` x2 |
| 572,892 | 36x36 | semantics | Insert sticker | `semantics:Insert sticker` x2 |
| 572,892 | 36x36 | pressable | Insert sticker | `semantics:Insert sticker` x2 |
| 572,932 | 36x36 | semantics | Insert emoji | `semantics:Insert emoji` x2 |
| 572,932 | 36x36 | pressable | Insert emoji | `semantics:Insert emoji` x2 |
| 572,976 | 36x36 | pressable | Send message | `semantics:Send message` x2 |
| 572,976 | 36x36 | semantics | Send message | `semantics:Send message` x2 |
| 580,260 | 20x20 | icon | 0xe12d | `icon:0xe12d` |
| 580,300 | 20x20 | icon | mic (0xe118) | `icon:mic` |
| 580,348 | 483x20 | text | Message #general | `text:Message #general` |
| 580,348 | 483x20 | input |  | `type:EditableText` |
| 580,900 | 20x20 | icon | 0xe302 | `icon:0xe302` |
| 580,940 | 20x20 | icon | smile (0xe164) | `icon:smile` |
| 580,984 | 20x20 | icon | 0xe152 | `icon:0xe152` |
| 586,863 | 16x9 | text | GIF | `text:GIF` |
| 632,182 | 5x8 | text | 7 | `text:7` |
| 633,149 | 38x38 | semantics | Home | `semantics:Home` |
| 633,149 | 38x38 | tooltip | Home | `tooltip:Home` |
| 633,493 | 38x38 | keyed |  | `key:bounce-1a88f45832c2a648a914fc259f602a12` |
| 633,493 | 38x38 | semantics | testing | `semantics:testing` |
| 633,493 | 38x38 | tooltip | testing | `tooltip:testing` |
| 633,535 | 38x38 | keyed |  | `key:bounce-8f3d5c37a26835ddf04b07f2c91da556` |
| 633,535 | 38x38 | semantics | another one! | `semantics:another one!` |
| 633,535 | 38x38 | tooltip | another one! | `tooltip:another one!` |
| 633,577 | 38x38 | keyed |  | `key:bounce-b7d2030be50e7bd8708c4364102c4029` |
| 633,577 | 38x38 | semantics | MyEpicServer | `semantics:MyEpicServer` |
| 633,577 | 38x38 | tooltip | MyEpicServer | `tooltip:MyEpicServer` |
| 633,619 | 38x38 | keyed |  | `key:bounce-703162ad1c1dd3f77a506828f71c5f8d` |
| 633,619 | 38x38 | semantics | qww | `semantics:qww` |
| 633,619 | 38x38 | tooltip | qww | `tooltip:qww` |
| 633,661 | 38x38 | keyed |  | `key:bounce-6ec23029e3003347d7cdd73988293dd7` |
| 633,661 | 38x38 | semantics | test | `semantics:test` |
| 633,661 | 38x38 | tooltip | test | `tooltip:test` |
| 633,703 | 38x38 | keyed |  | `key:bounce-6ae8032accaad737890ca2d4f9e97752` |
| 633,703 | 38x38 | semantics | test3 | `semantics:test3` |
| 633,703 | 38x38 | tooltip | test3 | `tooltip:test3` |
| 633,1047 | 38x38 | semantics | Create a server | `semantics:Create a server` |
| 633,1047 | 38x38 | tooltip | Create a server | `tooltip:Create a server` |
| 638,0 | 140x28 | pressable | AnonListen | `text:AnonListen` x6 |
| 638,0 | 140x28 | tooltip | Online | `tooltip:Online` |
| 639,1114 | 26x26 | tooltip | Browse Public Channels | `tooltip:Browse Public Channels` |
| 639,1114 | 26x26 | pressable | Browse public channels | `semantics:Browse public channels` x2 |
| 639,1114 | 26x26 | semantics | Browse public channels | `semantics:Browse public channels` x2 |
| 639,1140 | 26x26 | tooltip | Share | `tooltip:Share` |
| 639,1140 | 26x26 | pressable | Share | `semantics:Share` x2 |
| 639,1140 | 26x26 | semantics | Share | `semantics:Share` x2 |
| 639,1166 | 26x26 | pressable | Archive | `semantics:Archive` x2 |
| 639,1166 | 26x26 | tooltip | Archive | `tooltip:Archive` |
| 639,1166 | 26x26 | semantics | Archive | `semantics:Archive` x2 |
| 639,1192 | 26x26 | semantics | Downloads | `semantics:Downloads` x2 |
| 639,1192 | 26x26 | pressable | Downloads | `semantics:Downloads` x2 |
| 639,1192 | 26x26 | tooltip | Downloads | `tooltip:Downloads` |
| 639,1218 | 26x26 | pressable | Settings | `semantics:Settings` x2 |
| 639,1218 | 26x26 | semantics | Settings | `semantics:Settings` x2 |
| 639,1218 | 26x26 | tooltip | Settings | `tooltip:Settings` |
| 640,161 | 14x25 | text | H | `text:H` |
| 642,585 | 21x20 | text | MY | `text:MY` |
| 642,673 | 15x20 | text | TE | `text:TE` x2 |
| 642,715 | 15x20 | text | TE | `text:TE` x2 |
| 643,1057 | 18x18 | icon | plus (0xe13d) | `icon:plus` |
| 643,1118 | 18x18 | icon | globe (0xe0e8) | `icon:globe` |
| 643,1144 | 18x18 | icon | 0xe156 | `icon:0xe156` |
| 643,1170 | 18x18 | icon | 0xe041 | `icon:0xe041` |
| 643,1196 | 18x18 | icon | download (0xe0b2) | `icon:download` |
| 643,1222 | 18x18 | icon | settings (0xe154) | `icon:settings` x2 |
| 644,59 | 69x17 | text | AnonListen | `text:AnonListen` x6 |
| 649,48 | 7x7 | semantics | Online | `semantics:Online` x2 |

---

## UI map: 03-channel-menu

Screen 1264.0 x 681.0 logical pixels. 298 entries.

### Open surfaces

- dialog open: false
- context menu open: true
- menu rows: Mark as read | Mute channel | Rename channel | Visibility | Admin+ | Who can post | Everyone | Temporary access | Delete channel

### Providers

- server: test3 (6ae8032accaad737890ca2d4f9e97752)
- channel: general (6ae8032a-general)
- layout mode: LayoutMode.dock

#### Stored layout

```
[0] general (text, 6ae8032a-general)
[1] test (text, 6ae8032a-3f35dfa2)
[2] test3 (voice, 6ae8032a-5af0eb9e)
[3] CATEGORY "233"
    [4] 23 (text, 6ae8032a-75134eee)
```

### On screen

`y,x` is the top-left corner. Paste a target straight into a scenario; `xN` means the target matches N widgets, so scope it (`dialog > ...`) or pass an index.

| y,x | size | kind | label | target |
|---|---|---|---|---|
| 0,1126 | 46x32 | semantics | Minimize | `semantics:Minimize` |
| 0,1172 | 46x32 | semantics | Maximize | `semantics:Maximize` |
| 0,1218 | 46x32 | semantics | Close | `semantics:Close` |
| 7,16 | 44x18 | text | Hollow | `text:Hollow` |
| 7,1090 | 32x18 | icon | pencil (0xe1f9) | `icon:pencil` x2 |
| 8,1141 | 16x16 | icon | 0xe11c | `icon:0xe11c` |
| 8,1233 | 16x16 | icon | x (0xe1b2) | `icon:x` |
| 9,1188 | 14x14 | icon | 0xe167 | `icon:0xe167` |
| 32,0 | 1264x649 | keyed |  | `key:_ScaffoldSlot.body` |
| 32,0 | 1264x649 | surface |  | `type:_HollowMenuHost` |
| 32,66 | 81x43 | pressable | 12 | `text:12` x12 |
| 32,66 | 81x43 | tooltip | MacOS | `tooltip:MacOS` |
| 32,153 | 68x43 | tooltip | Pixel | `tooltip:Pixel` |
| 32,153 | 68x43 | pressable | Pixel | `text:Pixel` x2 |
| 32,227 | 118x43 | pressable | 12 | `text:12` x12 |
| 32,227 | 118x43 | tooltip | iPhone 13 mini | `tooltip:iPhone 13 mini` |
| 32,351 | 92x43 | pressable | 12 | `text:12` x12 |
| 32,351 | 92x43 | tooltip | UbuLinux | `tooltip:UbuLinux` |
| 32,449 | 96x43 | pressable | virtual bro | `text:virtual bro` x4 |
| 32,449 | 96x43 | tooltip | virtual bro | `tooltip:virtual bro` |
| 41,8 | 34x26 | semantics | Add friend | `semantics:Add friend` x2 |
| 41,8 | 34x26 | pressable | Add friend | `semantics:Add friend` x2 |
| 41,8 | 34x26 | tooltip | Add Friend | `tooltip:Add Friend` |
| 41,1146 | 34x26 | tooltip | Saved messages | `tooltip:Saved messages` |
| 41,1146 | 34x26 | pressable | Saved messages | `semantics:Saved messages` x2 |
| 41,1146 | 34x26 | semantics | Saved messages | `semantics:Saved messages` x2 |
| 41,1184 | 34x26 | tooltip | Conferences | `tooltip:Conferences` |
| 41,1184 | 34x26 | pressable | Conferences | `semantics:Conferences` x2 |
| 41,1184 | 34x26 | semantics | Conferences | `semantics:Conferences` x2 |
| 41,1222 | 34x26 | pressable | Help | `semantics:Help` x2 |
| 41,1222 | 34x26 | tooltip | Help | `tooltip:Help` |
| 41,1222 | 34x26 | semantics | Help | `semantics:Help` x2 |
| 45,16 | 18x18 | icon | userPlus (0xe1a2) | `icon:userPlus` x3 |
| 45,1154 | 18x18 | icon | 0xe060 | `icon:0xe060` |
| 45,1192 | 18x18 | icon | video (0xe1a5) | `icon:video` |
| 45,1230 | 18x18 | icon | 0xe082 | `icon:0xe082` |
| 46,104 | 35x15 | text | MacOS | `text:MacOS` |
| 46,191 | 22x15 | text | Pixel | `text:Pixel` x2 |
| 46,265 | 72x15 | text | iPhone 13 mini | `text:iPhone 13 mini` x4 |
| 46,389 | 46x15 | text | UbuLinux | `text:UbuLinux` |
| 46,487 | 50x15 | text | virtual bro | `text:virtual bro` x4 |
| 47,82 | 9x13 | text | 12 | `text:12` x12 |
| 47,243 | 9x13 | text | 12 | `text:12` x12 |
| 47,367 | 9x13 | text | 12 | `text:12` x12 |
| 59,92 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 59,178 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 59,252 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 59,376 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 59,474 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 76,0 | 239x48 | keyed |  | `key:[<null>]` |
| 76,0 | 239x48 | keyed |  | `key:null` |
| 76,0 | 239x48 | keyed |  | `key:header-test3` |
| 76,240 | 784x546 | keyed |  | `key:ch:6ae8032a-general` |
| 76,240 | 784x546 | keyed |  | `key:6ae8032a-general` |
| 76,240 | 784x546 | keyed |  | `key:[<'6ae8032a-general'>]` |
| 76,240 | 784x546 | keyed |  | `key:[<[<'6ae8032a-general'>]>]` |
| 76,240 | 784x546 | keyed |  | `key:[<[<'single-6ae8032a-general'>]>]` |
| 76,240 | 784x546 | keyed |  | `key:[<'single-6ae8032a-general'>]` |
| 76,240 | 784x546 | keyed |  | `key:single-6ae8032a-general` |
| 76,1025 | 239x546 | keyed |  | `key:[<[<'server-members-6ae8032accaad737890ca2d4f9e97752'>]>]` |
| 76,1025 | 239x546 | keyed |  | `key:server-members-6ae8032accaad737890ca2d4f9e97752` |
| 76,1025 | 239x546 | keyed |  | `key:[<'server-members-6ae8032accaad737890ca2d4f9e97752'>]` |
| 86,946 | 28x28 | semantics | Toggle member panel | `semantics:Toggle member panel` x2 |
| 86,946 | 28x28 | pressable | Toggle member panel | `semantics:Toggle member panel` x2 |
| 86,946 | 28x28 | tooltip | Toggle member panel | `tooltip:Toggle member panel` |
| 87,912 | 26x26 | semantics | Search messages | `semantics:Search messages` x2 |
| 87,912 | 26x26 | tooltip | Search messages | `tooltip:Search messages` |
| 87,912 | 26x26 | pressable | Search messages | `semantics:Search messages` x2 |
| 87,982 | 26x26 | tooltip | Split view | `tooltip:Split view` |
| 87,982 | 26x26 | pressable | Split view | `semantics:Split view` x2 |
| 87,982 | 26x26 | semantics | Split view | `semantics:Split view` x2 |
| 88,159 | 24x24 | semantics | Invite people | `semantics:Invite people` x2 |
| 88,159 | 24x24 | pressable | Invite people | `semantics:Invite people` x2 |
| 88,159 | 24x24 | tooltip | Invite people | `tooltip:Invite people` |
| 88,183 | 24x24 | semantics | Storage | `semantics:Storage` x2 |
| 88,183 | 24x24 | pressable | Storage | `semantics:Storage` x2 |
| 88,183 | 24x24 | tooltip | Storage | `tooltip:Storage` |
| 88,207 | 24x24 | semantics | Server settings | `semantics:Server settings` x2 |
| 88,207 | 24x24 | pressable | Server settings | `semantics:Server settings` x2 |
| 88,207 | 24x24 | tooltip | Server settings | `tooltip:Server settings` |
| 89,16 | 143x22 | text | test3 | `text:test3` x3 |
| 89,284 | 546x22 | text | general | `text:general` x3 |
| 90,256 | 20x20 | icon | hash (0xe0ef) | `icon:hash` x4 |
| 90,950 | 20x20 | icon | users (0xe1a4) | `icon:users` x2 |
| 91,916 | 18x18 | icon | search (0xe151) | `icon:search` |
| 91,986 | 18x18 | icon | 0xe098 | `icon:0xe098` |
| 92,163 | 16x16 | icon | userPlus (0xe1a2) | `icon:userPlus` x3 |
| 92,187 | 16x16 | icon | hardDrive (0xe0ed) | `icon:hardDrive` |
| 92,211 | 16x16 | icon | settings (0xe154) | `icon:settings` x2 |
| 92,1035 | 53x15 | text | Members | `text:Members` |
| 92,1247 | 7x15 | text | 4 | `text:4` |
| 93,842 | 62x15 | keyed |  | `key:conn-6ae8032accaad737890ca2d4f9e97752` |
| 93,842 | 62x15 | tooltip | You're connected. Nobody else is online here right now | `tooltip:You're connected. Nobody else is online here right now` |
| 93,842 | 14x14 | icon | users (0xe1a4) | `icon:users` x2 |
| 93,860 | 44x15 | text | Only you | `text:Only you` |
| 124,0 | 239x498 | keyed |  | `key:[<[<'server-6ae8032accaad737890ca2d4f9e97752'>]>]` |
| 124,0 | 239x498 | keyed |  | `key:server-6ae8032accaad737890ca2d4f9e97752` |
| 124,0 | 239x498 | keyed |  | `key:[<'server-6ae8032accaad737890ca2d4f9e97752'>]` |
| 125,240 | 784x432 | keyed |  | `key:ch-list-6ae8032accaad737890ca2d4f9e97752-6ae8032a-general` |
| 125,240 | 784x432 | keyed |  | `key:Ping` |
| 128,0 | 239x40 | keyed |  | `key:[<'ach-6ae8032a-general'>]` |
| 128,0 | 239x40 | keyed |  | `key:ach-6ae8032a-general` |
| 130,8 | 223x36 | pressable | general | `text:general` x3 |
| 132,1025 | 239x31 | keyed |  | `key:[<'div-Owner'>]` |
| 132,1025 | 239x31 | keyed |  | `key:div-Owner` |
| 138,44 | 177x20 | text | general | `text:general` x3 |
| 139,18 | 18x18 | icon | hash (0xe0ef) | `icon:hash` x4 |
| 140,1035 | 37x15 | text | Owner | `text:Owner` x2 |
| 140,1249 | 5x15 | text | 1 | `text:1` |
| 149,28 | 318x34 | pressable | Mark as read | `text:Mark as read` x2 |
| 157,61 | 275x18 | text | Mark as read | `text:Mark as read` x2 |
| 159,38 | 15x15 | icon | 0xe38e | `icon:0xe38e` |
| 163,1025 | 239x50 | keyed |  | `key:mem-12D3KooWJJU9fygVAYVJqVM4FAtTyaUBHSsfRkuavwY53nT7iS4F` |
| 163,1025 | 239x50 | pressable | AnonListen | `text:AnonListen` x6 |
| 163,1025 | 239x50 | keyed |  | `key:[<'mem-12D3KooWJJU9fygVAYVJqVM4FAtTyaUBHSsfRkuavwY53nT7iS4F'>]` |
| 166,1071 | 59x17 | text | AnonListen | `text:AnonListen` x6 |
| 168,0 | 239x40 | keyed |  | `key:[<'ach-6ae8032a-3f35dfa2'>]` |
| 168,0 | 239x40 | keyed |  | `key:ach-6ae8032a-3f35dfa2` |
| 170,8 | 223x36 | pressable | test | `text:test` x3 |
| 178,44 | 177x20 | text | test | `text:test` x3 |
| 179,18 | 18x18 | icon | hash (0xe0ef) | `icon:hash` x4 |
| 183,28 | 318x34 | pressable | Mute channel | `text:Mute channel` x2 |
| 183,1071 | 29x14 | text | Owner | `text:Owner` x2 |
| 191,61 | 275x18 | text | Mute channel | `text:Mute channel` x2 |
| 191,240 | 784x96 | keyed |  | `key:556dcb2e16ed2a4ade7b38948840ff3f` x2 |
| 191,240 | 784x96 | keyed |  | `key:556dcb2e16ed2a4ade7b38948840ff3f` x2 |
| 191,240 | 784x96 | keyed |  | `key:[<556dcb2e16ed2a4ade7b38948840ff3f>]` |
| 193,38 | 15x15 | icon | bellOff (0xe05a) | `icon:bellOff` |
| 195,1056 | 7x7 | semantics | Online | `semantics:Online` x2 |
| 197,1084 | 41x13 | text | anonlisten | `text:anonlisten` |
| 199,1071 | 10x10 | icon | 0xf58a | `icon:0xf58a` |
| 205,595 | 75x15 | text | August 7, 2026 | `text:August 7, 2026` |
| 208,0 | 239x40 | keyed |  | `key:ach-6ae8032a-5af0eb9e` |
| 208,0 | 239x40 | keyed |  | `key:[<'ach-6ae8032a-5af0eb9e'>]` |
| 210,8 | 223x36 | pressable | test3 | `text:test3` x3 |
| 213,1025 | 239x31 | keyed |  | `key:[<'div-Offline'>]` |
| 213,1025 | 239x31 | keyed |  | `key:div-Offline` |
| 218,44 | 177x20 | text | test3 | `text:test3` x3 |
| 219,18 | 18x18 | icon | volume2 (0xe1ab) | `icon:volume2` |
| 221,1035 | 40x15 | text | Offline | `text:Offline` |
| 221,1247 | 7x15 | text | 3 | `text:3` |
| 222,28 | 318x34 | pressable | Rename channel | `text:Rename channel` x2 |
| 230,61 | 275x18 | text | Rename channel | `text:Rename channel` x2 |
| 232,38 | 15x15 | icon | pencil (0xe1f9) | `icon:pencil` x2 |
| 242,294 | 66x18 | text | AnonListen | `text:AnonListen` x6 |
| 242,294 | 66x18 | semantics | Open profile | `semantics:Open profile` x8 |
| 244,368 | 24x14 | text | 19:33 | `text:19:33` |
| 244,1025 | 239x34 | keyed |  | `key:[<'mem-12D3KooWKS8jL9xFsxkMgwrLGJpnSngi8KgtPRuFyNRVL4PnKh8C'>]` |
| 244,1025 | 239x34 | keyed |  | `key:mem-12D3KooWKS8jL9xFsxkMgwrLGJpnSngi8KgtPRuFyNRVL4PnKh8C` |
| 244,1025 | 239x34 | pressable | 12 | `text:12` x12 |
| 247,252 | 32x32 | semantics | Open profile | `semantics:Open profile` x8 |
| 253,1071 | 29x17 | text | vm22 | `text:vm22` |
| 254,1044 | 10x15 | text | 12 | `text:12` x12 |
| 256,28 | 318x34 | pressable | Visibility | `text:Visibility` x2 |
| 260,10 | 221x15 | pressable | 233 | `text:233` x2 |
| 260,24 | 207x15 | text | 233 | `text:233` x2 |
| 263,10 | 10x10 | icon | chevronDown (0xe06d) | `icon:chevronDown` |
| 263,294 | 23x20 | text | test | `text:test` x3 |
| 264,61 | 210x18 | text | Visibility | `text:Visibility` x2 |
| 266,38 | 15x15 | icon | eye (0xe0ba) | `icon:eye` |
| 266,279 | 39x15 | text | Admin+ | `text:Admin+` |
| 266,322 | 14x14 | icon | chevronRight (0xe06f) | `icon:chevronRight` x2 |
| 268,1056 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 278,1025 | 239x34 | keyed |  | `key:[<'mem-12D3KooWF5kuBjyDMSzFviHHvdtS6uaZTqq57pA9ik2PAnffNXdk'>]` |
| 278,1025 | 239x34 | pressable | virtual bro | `text:virtual bro` x4 |
| 278,1025 | 239x34 | keyed |  | `key:mem-12D3KooWF5kuBjyDMSzFviHHvdtS6uaZTqq57pA9ik2PAnffNXdk` |
| 279,0 | 239x40 | keyed |  | `key:ach-6ae8032a-75134eee` |
| 279,0 | 239x40 | keyed |  | `key:[<'ach-6ae8032a-75134eee'>]` |
| 281,8 | 223x36 | pressable | 23 | `text:23` x2 |
| 287,240 | 784x24 | keyed |  | `key:4ce7ee57dbfb849322935d80678e1326` x2 |
| 287,240 | 784x24 | keyed |  | `key:4ce7ee57dbfb849322935d80678e1326` x2 |
| 287,240 | 784x24 | keyed |  | `key:[<4ce7ee57dbfb849322935d80678e1326>]` |
| 287,1071 | 54x17 | text | virtual bro | `text:virtual bro` x4 |
| 289,44 | 177x20 | text | 23 | `text:23` x2 |
| 289,294 | 25x20 | text | teto | `text:teto` x2 |
| 290,18 | 18x18 | icon | hash (0xe0ef) | `icon:hash` x4 |
| 290,28 | 318x34 | pressable | Who can post | `text:Who can post` x2 |
| 298,61 | 205x18 | text | Who can post | `text:Who can post` x2 |
| 300,38 | 15x15 | icon | messageSquare (0xe117) | `icon:messageSquare` |
| 300,274 | 44x15 | text | Everyone | `text:Everyone` |
| 300,322 | 14x14 | icon | chevronRight (0xe06f) | `icon:chevronRight` x2 |
| 302,1056 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 311,240 | 784x96 | keyed |  | `key:c61bfc6746d4e10f3f6c2610b81d3b56` x2 |
| 311,240 | 784x96 | keyed |  | `key:c61bfc6746d4e10f3f6c2610b81d3b56` x2 |
| 311,240 | 784x96 | keyed |  | `key:[<c61bfc6746d4e10f3f6c2610b81d3b56>]` |
| 312,1025 | 239x34 | keyed |  | `key:[<'mem-12D3KooWLyj5mKdcjKWKRCtJni4bPD7dKiU5SEWMDNWQNNbfdhAL'>]` |
| 312,1025 | 239x34 | keyed |  | `key:mem-12D3KooWLyj5mKdcjKWKRCtJni4bPD7dKiU5SEWMDNWQNNbfdhAL` |
| 312,1025 | 239x34 | pressable | 12 | `text:12` x12 |
| 321,1071 | 79x17 | text | iPhone 13 mini | `text:iPhone 13 mini` x4 |
| 322,1044 | 10x15 | text | 12 | `text:12` x12 |
| 324,28 | 318x34 | pressable | Temporary access | `text:Temporary access` x2 |
| 325,592 | 79x15 | text | August 16, 2026 | `text:August 16, 2026` |
| 332,61 | 275x18 | text | Temporary access | `text:Temporary access` x2 |
| 334,38 | 15x15 | icon | userPlus (0xe1a2) | `icon:userPlus` x3 |
| 336,1056 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 362,294 | 86x18 | text | iPhone 13 mini | `text:iPhone 13 mini` x4 |
| 362,294 | 86x18 | semantics | Open profile | `semantics:Open profile` x8 |
| 363,28 | 318x34 | pressable | Delete channel | `text:Delete channel` x2 |
| 364,388 | 24x14 | text | 13:41 | `text:13:41` x2 |
| 367,252 | 32x32 | semantics | Open profile | `semantics:Open profile` x8 |
| 371,61 | 275x18 | text | Delete channel | `text:Delete channel` x2 |
| 373,38 | 15x15 | icon | trash2 (0xe18e) | `icon:trash2` |
| 375,262 | 12x17 | text | 12 | `text:12` x12 |
| 383,294 | 25x20 | text | teto | `text:teto` x2 |
| 407,240 | 784x59 | keyed |  | `key:51692019ab6c1b2232a279bde0aac13b` x2 |
| 407,240 | 784x59 | keyed |  | `key:51692019ab6c1b2232a279bde0aac13b` x2 |
| 407,240 | 784x59 | keyed |  | `key:[<51692019ab6c1b2232a279bde0aac13b>]` |
| 421,294 | 66x18 | text | AnonListen | `text:AnonListen` x6 |
| 421,294 | 66x18 | semantics | Open profile | `semantics:Open profile` x8 |
| 423,368 | 24x14 | text | 13:41 | `text:13:41` x2 |
| 426,252 | 32x32 | semantics | Open profile | `semantics:Open profile` x8 |
| 442,294 | 78x20 | text | kasane teto? | `text:kasane teto?` |
| 466,240 | 784x24 | keyed |  | `key:30470f31c83c54d5d0d6dec208c9cccf` x2 |
| 466,240 | 784x24 | keyed |  | `key:30470f31c83c54d5d0d6dec208c9cccf` x2 |
| 466,240 | 784x24 | keyed |  | `key:[<30470f31c83c54d5d0d6dec208c9cccf>]` |
| 468,294 | 20x20 | text | yes | `text:yes` |
| 490,240 | 784x59 | keyed |  | `key:bca4f49faa4635e7ba2466dc3f2deeeb` x2 |
| 490,240 | 784x59 | keyed |  | `key:bca4f49faa4635e7ba2466dc3f2deeeb` x2 |
| 490,240 | 784x59 | keyed |  | `key:[<bca4f49faa4635e7ba2466dc3f2deeeb>]` |
| 504,294 | 86x18 | text | iPhone 13 mini | `text:iPhone 13 mini` x4 |
| 504,294 | 86x18 | semantics | Open profile | `semantics:Open profile` x8 |
| 506,388 | 24x14 | text | 16:24 | `text:16:24` |
| 509,252 | 32x32 | semantics | Open profile | `semantics:Open profile` x8 |
| 517,262 | 12x17 | text | 12 | `text:12` x12 |
| 525,294 | 4x20 | text | f | `text:f` |
| 566,332 | 515x48 | field | hint "Message #general" | `hint:Message #general` |
| 572,252 | 36x36 | semantics | Attach file | `semantics:Attach file` x2 |
| 572,252 | 36x36 | pressable | Attach file | `semantics:Attach file` x2 |
| 572,292 | 36x36 | pressable | Record voice message | `semantics:Record voice message` x2 |
| 572,292 | 36x36 | semantics | Record voice message | `semantics:Record voice message` x2 |
| 572,851 | 41x36 | semantics | Insert GIF | `semantics:Insert GIF` x2 |
| 572,851 | 41x36 | pressable | Insert GIF | `semantics:Insert GIF` x2 |
| 572,892 | 36x36 | pressable | Insert sticker | `semantics:Insert sticker` x2 |
| 572,892 | 36x36 | semantics | Insert sticker | `semantics:Insert sticker` x2 |
| 572,932 | 36x36 | semantics | Insert emoji | `semantics:Insert emoji` x2 |
| 572,932 | 36x36 | pressable | Insert emoji | `semantics:Insert emoji` x2 |
| 572,976 | 36x36 | pressable | Send message | `semantics:Send message` x2 |
| 572,976 | 36x36 | semantics | Send message | `semantics:Send message` x2 |
| 580,260 | 20x20 | icon | 0xe12d | `icon:0xe12d` |
| 580,300 | 20x20 | icon | mic (0xe118) | `icon:mic` |
| 580,348 | 483x20 | input |  | `type:EditableText` |
| 580,348 | 483x20 | text | Message #general | `text:Message #general` |
| 580,900 | 20x20 | icon | 0xe302 | `icon:0xe302` |
| 580,940 | 20x20 | icon | smile (0xe164) | `icon:smile` |
| 580,984 | 20x20 | icon | 0xe152 | `icon:0xe152` |
| 586,863 | 16x9 | text | GIF | `text:GIF` |
| 632,182 | 5x8 | text | 7 | `text:7` |
| 633,149 | 38x38 | tooltip | Home | `tooltip:Home` |
| 633,149 | 38x38 | semantics | Home | `semantics:Home` |
| 633,493 | 38x38 | tooltip | testing | `tooltip:testing` |
| 633,493 | 38x38 | semantics | testing | `semantics:testing` |
| 633,493 | 38x38 | keyed |  | `key:bounce-1a88f45832c2a648a914fc259f602a12` |
| 633,535 | 38x38 | tooltip | another one! | `tooltip:another one!` |
| 633,535 | 38x38 | semantics | another one! | `semantics:another one!` |
| 633,535 | 38x38 | keyed |  | `key:bounce-8f3d5c37a26835ddf04b07f2c91da556` |
| 633,577 | 38x38 | tooltip | MyEpicServer | `tooltip:MyEpicServer` |
| 633,577 | 38x38 | semantics | MyEpicServer | `semantics:MyEpicServer` |
| 633,577 | 38x38 | keyed |  | `key:bounce-b7d2030be50e7bd8708c4364102c4029` |
| 633,619 | 38x38 | semantics | qww | `semantics:qww` |
| 633,619 | 38x38 | keyed |  | `key:bounce-703162ad1c1dd3f77a506828f71c5f8d` |
| 633,619 | 38x38 | tooltip | qww | `tooltip:qww` |
| 633,661 | 38x38 | tooltip | test | `tooltip:test` |
| 633,661 | 38x38 | semantics | test | `semantics:test` |
| 633,661 | 38x38 | keyed |  | `key:bounce-6ec23029e3003347d7cdd73988293dd7` |
| 633,703 | 38x38 | keyed |  | `key:bounce-6ae8032accaad737890ca2d4f9e97752` |
| 633,703 | 38x38 | tooltip | test3 | `tooltip:test3` |
| 633,703 | 38x38 | semantics | test3 | `semantics:test3` |
| 633,1047 | 38x38 | tooltip | Create a server | `tooltip:Create a server` |
| 633,1047 | 38x38 | semantics | Create a server | `semantics:Create a server` |
| 638,0 | 140x28 | tooltip | Online | `tooltip:Online` |
| 638,0 | 140x28 | pressable | AnonListen | `text:AnonListen` x6 |
| 639,1114 | 26x26 | semantics | Browse public channels | `semantics:Browse public channels` x2 |
| 639,1114 | 26x26 | pressable | Browse public channels | `semantics:Browse public channels` x2 |
| 639,1114 | 26x26 | tooltip | Browse Public Channels | `tooltip:Browse Public Channels` |
| 639,1140 | 26x26 | semantics | Share | `semantics:Share` x2 |
| 639,1140 | 26x26 | tooltip | Share | `tooltip:Share` |
| 639,1140 | 26x26 | pressable | Share | `semantics:Share` x2 |
| 639,1166 | 26x26 | tooltip | Archive | `tooltip:Archive` |
| 639,1166 | 26x26 | pressable | Archive | `semantics:Archive` x2 |
| 639,1166 | 26x26 | semantics | Archive | `semantics:Archive` x2 |
| 639,1192 | 26x26 | tooltip | Downloads | `tooltip:Downloads` |
| 639,1192 | 26x26 | pressable | Downloads | `semantics:Downloads` x2 |
| 639,1192 | 26x26 | semantics | Downloads | `semantics:Downloads` x2 |
| 639,1218 | 26x26 | tooltip | Settings | `tooltip:Settings` |
| 639,1218 | 26x26 | pressable | Settings | `semantics:Settings` x2 |
| 639,1218 | 26x26 | semantics | Settings | `semantics:Settings` x2 |
| 640,161 | 14x25 | text | H | `text:H` |
| 642,585 | 21x20 | text | MY | `text:MY` |
| 642,673 | 15x20 | text | TE | `text:TE` x2 |
| 642,715 | 15x20 | text | TE | `text:TE` x2 |
| 643,1057 | 18x18 | icon | plus (0xe13d) | `icon:plus` |
| 643,1118 | 18x18 | icon | globe (0xe0e8) | `icon:globe` |
| 643,1144 | 18x18 | icon | 0xe156 | `icon:0xe156` |
| 643,1170 | 18x18 | icon | 0xe041 | `icon:0xe041` |
| 643,1196 | 18x18 | icon | download (0xe0b2) | `icon:download` |
| 643,1222 | 18x18 | icon | settings (0xe154) | `icon:settings` x2 |
| 644,59 | 69x17 | text | AnonListen | `text:AnonListen` x6 |
| 649,48 | 7x7 | semantics | Online | `semantics:Online` x2 |

---

## UI map: 04-sidebar-menu

Screen 1264.0 x 681.0 logical pixels. 288 entries.

### Open surfaces

- dialog open: false
- context menu open: true
- menu rows: Mark server as read | Create channel | Create category | Invite people | Server settings

### Providers

- server: test3 (6ae8032accaad737890ca2d4f9e97752)
- channel: general (6ae8032a-general)
- layout mode: LayoutMode.dock

#### Stored layout

```
[0] general (text, 6ae8032a-general)
[1] test (text, 6ae8032a-3f35dfa2)
[2] test3 (voice, 6ae8032a-5af0eb9e)
[3] CATEGORY "233"
    [4] 23 (text, 6ae8032a-75134eee)
```

### On screen

`y,x` is the top-left corner. Paste a target straight into a scenario; `xN` means the target matches N widgets, so scope it (`dialog > ...`) or pass an index.

| y,x | size | kind | label | target |
|---|---|---|---|---|
| 0,1126 | 46x32 | semantics | Minimize | `semantics:Minimize` |
| 0,1172 | 46x32 | semantics | Maximize | `semantics:Maximize` |
| 0,1218 | 46x32 | semantics | Close | `semantics:Close` |
| 7,16 | 44x18 | text | Hollow | `text:Hollow` |
| 7,1090 | 32x18 | icon | pencil (0xe1f9) | `icon:pencil` |
| 8,1141 | 16x16 | icon | 0xe11c | `icon:0xe11c` |
| 8,1233 | 16x16 | icon | x (0xe1b2) | `icon:x` |
| 9,1188 | 14x14 | icon | 0xe167 | `icon:0xe167` |
| 32,0 | 1264x649 | keyed |  | `key:_ScaffoldSlot.body` |
| 32,0 | 1264x649 | surface |  | `type:_HollowMenuHost` |
| 32,66 | 81x43 | tooltip | MacOS | `tooltip:MacOS` |
| 32,66 | 81x43 | pressable | 12 | `text:12` x12 |
| 32,153 | 68x43 | tooltip | Pixel | `tooltip:Pixel` |
| 32,153 | 68x43 | pressable | Pixel | `text:Pixel` x2 |
| 32,227 | 118x43 | tooltip | iPhone 13 mini | `tooltip:iPhone 13 mini` |
| 32,227 | 118x43 | pressable | 12 | `text:12` x12 |
| 32,351 | 92x43 | tooltip | UbuLinux | `tooltip:UbuLinux` |
| 32,351 | 92x43 | pressable | 12 | `text:12` x12 |
| 32,449 | 96x43 | pressable | virtual bro | `text:virtual bro` x4 |
| 32,449 | 96x43 | tooltip | virtual bro | `tooltip:virtual bro` |
| 41,8 | 34x26 | tooltip | Add Friend | `tooltip:Add Friend` |
| 41,8 | 34x26 | pressable | Add friend | `semantics:Add friend` x2 |
| 41,8 | 34x26 | semantics | Add friend | `semantics:Add friend` x2 |
| 41,1146 | 34x26 | semantics | Saved messages | `semantics:Saved messages` x2 |
| 41,1146 | 34x26 | pressable | Saved messages | `semantics:Saved messages` x2 |
| 41,1146 | 34x26 | tooltip | Saved messages | `tooltip:Saved messages` |
| 41,1184 | 34x26 | semantics | Conferences | `semantics:Conferences` x2 |
| 41,1184 | 34x26 | pressable | Conferences | `semantics:Conferences` x2 |
| 41,1184 | 34x26 | tooltip | Conferences | `tooltip:Conferences` |
| 41,1222 | 34x26 | pressable | Help | `semantics:Help` x2 |
| 41,1222 | 34x26 | tooltip | Help | `tooltip:Help` |
| 41,1222 | 34x26 | semantics | Help | `semantics:Help` x2 |
| 45,16 | 18x18 | icon | userPlus (0xe1a2) | `icon:userPlus` x3 |
| 45,1154 | 18x18 | icon | 0xe060 | `icon:0xe060` |
| 45,1192 | 18x18 | icon | video (0xe1a5) | `icon:video` |
| 45,1230 | 18x18 | icon | 0xe082 | `icon:0xe082` |
| 46,104 | 35x15 | text | MacOS | `text:MacOS` |
| 46,191 | 22x15 | text | Pixel | `text:Pixel` x2 |
| 46,265 | 72x15 | text | iPhone 13 mini | `text:iPhone 13 mini` x4 |
| 46,389 | 46x15 | text | UbuLinux | `text:UbuLinux` |
| 46,487 | 50x15 | text | virtual bro | `text:virtual bro` x4 |
| 47,82 | 9x13 | text | 12 | `text:12` x12 |
| 47,243 | 9x13 | text | 12 | `text:12` x12 |
| 47,367 | 9x13 | text | 12 | `text:12` x12 |
| 59,92 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 59,178 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 59,252 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 59,376 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 59,474 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 76,0 | 239x48 | keyed |  | `key:[<null>]` |
| 76,0 | 239x48 | keyed |  | `key:null` |
| 76,0 | 239x48 | keyed |  | `key:header-test3` |
| 76,240 | 784x546 | keyed |  | `key:6ae8032a-general` |
| 76,240 | 784x546 | keyed |  | `key:[<'6ae8032a-general'>]` |
| 76,240 | 784x546 | keyed |  | `key:[<[<'single-6ae8032a-general'>]>]` |
| 76,240 | 784x546 | keyed |  | `key:[<'single-6ae8032a-general'>]` |
| 76,240 | 784x546 | keyed |  | `key:single-6ae8032a-general` |
| 76,240 | 784x546 | keyed |  | `key:[<[<'6ae8032a-general'>]>]` |
| 76,240 | 784x546 | keyed |  | `key:ch:6ae8032a-general` |
| 76,1025 | 239x546 | keyed |  | `key:[<[<'server-members-6ae8032accaad737890ca2d4f9e97752'>]>]` |
| 76,1025 | 239x546 | keyed |  | `key:[<'server-members-6ae8032accaad737890ca2d4f9e97752'>]` |
| 76,1025 | 239x546 | keyed |  | `key:server-members-6ae8032accaad737890ca2d4f9e97752` |
| 86,946 | 28x28 | tooltip | Toggle member panel | `tooltip:Toggle member panel` |
| 86,946 | 28x28 | pressable | Toggle member panel | `semantics:Toggle member panel` x2 |
| 86,946 | 28x28 | semantics | Toggle member panel | `semantics:Toggle member panel` x2 |
| 87,912 | 26x26 | tooltip | Search messages | `tooltip:Search messages` |
| 87,912 | 26x26 | pressable | Search messages | `semantics:Search messages` x2 |
| 87,912 | 26x26 | semantics | Search messages | `semantics:Search messages` x2 |
| 87,982 | 26x26 | tooltip | Split view | `tooltip:Split view` |
| 87,982 | 26x26 | pressable | Split view | `semantics:Split view` x2 |
| 87,982 | 26x26 | semantics | Split view | `semantics:Split view` x2 |
| 88,159 | 24x24 | semantics | Invite people | `semantics:Invite people` x2 |
| 88,159 | 24x24 | pressable | Invite people | `semantics:Invite people` x2 |
| 88,159 | 24x24 | tooltip | Invite people | `tooltip:Invite people` |
| 88,183 | 24x24 | tooltip | Storage | `tooltip:Storage` |
| 88,183 | 24x24 | pressable | Storage | `semantics:Storage` x2 |
| 88,183 | 24x24 | semantics | Storage | `semantics:Storage` x2 |
| 88,207 | 24x24 | tooltip | Server settings | `tooltip:Server settings` |
| 88,207 | 24x24 | pressable | Server settings | `semantics:Server settings` x2 |
| 88,207 | 24x24 | semantics | Server settings | `semantics:Server settings` x2 |
| 89,16 | 143x22 | text | test3 | `text:test3` x3 |
| 89,284 | 546x22 | text | general | `text:general` x3 |
| 90,256 | 20x20 | icon | hash (0xe0ef) | `icon:hash` x4 |
| 90,950 | 20x20 | icon | users (0xe1a4) | `icon:users` x2 |
| 91,916 | 18x18 | icon | search (0xe151) | `icon:search` |
| 91,986 | 18x18 | icon | 0xe098 | `icon:0xe098` |
| 92,163 | 16x16 | icon | userPlus (0xe1a2) | `icon:userPlus` x3 |
| 92,187 | 16x16 | icon | hardDrive (0xe0ed) | `icon:hardDrive` |
| 92,211 | 16x16 | icon | settings (0xe154) | `icon:settings` x3 |
| 92,1035 | 53x15 | text | Members | `text:Members` |
| 92,1247 | 7x15 | text | 4 | `text:4` |
| 93,842 | 62x15 | keyed |  | `key:conn-6ae8032accaad737890ca2d4f9e97752` |
| 93,842 | 62x15 | tooltip | You're connected. Nobody else is online here right now | `tooltip:You're connected. Nobody else is online here right now` |
| 93,842 | 14x14 | icon | users (0xe1a4) | `icon:users` x2 |
| 93,860 | 44x15 | text | Only you | `text:Only you` |
| 124,0 | 239x498 | keyed |  | `key:[<[<'server-6ae8032accaad737890ca2d4f9e97752'>]>]` |
| 124,0 | 239x498 | keyed |  | `key:[<'server-6ae8032accaad737890ca2d4f9e97752'>]` |
| 124,0 | 239x498 | keyed |  | `key:server-6ae8032accaad737890ca2d4f9e97752` |
| 125,240 | 784x432 | keyed |  | `key:Ping` |
| 125,240 | 784x432 | keyed |  | `key:ch-list-6ae8032accaad737890ca2d4f9e97752-6ae8032a-general` |
| 128,0 | 239x40 | keyed |  | `key:[<'ach-6ae8032a-general'>]` |
| 128,0 | 239x40 | keyed |  | `key:ach-6ae8032a-general` |
| 130,8 | 223x36 | pressable | general | `text:general` x3 |
| 132,1025 | 239x31 | keyed |  | `key:div-Owner` |
| 132,1025 | 239x31 | keyed |  | `key:[<'div-Owner'>]` |
| 138,44 | 177x20 | text | general | `text:general` x3 |
| 139,18 | 18x18 | icon | hash (0xe0ef) | `icon:hash` x4 |
| 140,1035 | 37x15 | text | Owner | `text:Owner` x2 |
| 140,1249 | 5x15 | text | 1 | `text:1` |
| 163,1025 | 239x50 | keyed |  | `key:[<'mem-12D3KooWJJU9fygVAYVJqVM4FAtTyaUBHSsfRkuavwY53nT7iS4F'>]` |
| 163,1025 | 239x50 | pressable | AnonListen | `text:AnonListen` x6 |
| 163,1025 | 239x50 | keyed |  | `key:mem-12D3KooWJJU9fygVAYVJqVM4FAtTyaUBHSsfRkuavwY53nT7iS4F` |
| 166,1071 | 59x17 | text | AnonListen | `text:AnonListen` x6 |
| 168,0 | 239x40 | keyed |  | `key:ach-6ae8032a-3f35dfa2` |
| 168,0 | 239x40 | keyed |  | `key:[<'ach-6ae8032a-3f35dfa2'>]` |
| 170,8 | 223x36 | pressable | test | `text:test` x3 |
| 178,44 | 177x20 | text | test | `text:test` x3 |
| 179,18 | 18x18 | icon | hash (0xe0ef) | `icon:hash` x4 |
| 183,1071 | 29x14 | text | Owner | `text:Owner` x2 |
| 191,240 | 784x96 | keyed |  | `key:556dcb2e16ed2a4ade7b38948840ff3f` x2 |
| 191,240 | 784x96 | keyed |  | `key:556dcb2e16ed2a4ade7b38948840ff3f` x2 |
| 191,240 | 784x96 | keyed |  | `key:[<556dcb2e16ed2a4ade7b38948840ff3f>]` |
| 195,1056 | 7x7 | semantics | Online | `semantics:Online` x2 |
| 197,1084 | 41x13 | text | anonlisten | `text:anonlisten` |
| 199,1071 | 10x10 | icon | 0xf58a | `icon:0xf58a` |
| 205,595 | 75x15 | text | August 7, 2026 | `text:August 7, 2026` |
| 208,0 | 239x40 | keyed |  | `key:ach-6ae8032a-5af0eb9e` |
| 208,0 | 239x40 | keyed |  | `key:[<'ach-6ae8032a-5af0eb9e'>]` |
| 210,8 | 223x36 | pressable | test3 | `text:test3` x3 |
| 213,1025 | 239x31 | keyed |  | `key:div-Offline` |
| 213,1025 | 239x31 | keyed |  | `key:[<'div-Offline'>]` |
| 218,44 | 177x20 | text | test3 | `text:test3` x3 |
| 219,18 | 18x18 | icon | volume2 (0xe1ab) | `icon:volume2` |
| 221,1035 | 40x15 | text | Offline | `text:Offline` |
| 221,1247 | 7x15 | text | 3 | `text:3` |
| 242,294 | 66x18 | text | AnonListen | `text:AnonListen` x6 |
| 242,294 | 66x18 | semantics | Open profile | `semantics:Open profile` x8 |
| 244,368 | 24x14 | text | 19:33 | `text:19:33` |
| 244,1025 | 239x34 | pressable | 12 | `text:12` x12 |
| 244,1025 | 239x34 | keyed |  | `key:mem-12D3KooWKS8jL9xFsxkMgwrLGJpnSngi8KgtPRuFyNRVL4PnKh8C` |
| 244,1025 | 239x34 | keyed |  | `key:[<'mem-12D3KooWKS8jL9xFsxkMgwrLGJpnSngi8KgtPRuFyNRVL4PnKh8C'>]` |
| 247,252 | 32x32 | semantics | Open profile | `semantics:Open profile` x8 |
| 253,1071 | 29x17 | text | vm22 | `text:vm22` |
| 254,1044 | 10x15 | text | 12 | `text:12` x12 |
| 260,10 | 221x15 | pressable | 233 | `text:233` x2 |
| 260,24 | 207x15 | text | 233 | `text:233` x2 |
| 263,10 | 10x10 | icon | chevronDown (0xe06d) | `icon:chevronDown` |
| 263,294 | 23x20 | text | test | `text:test` x3 |
| 268,1056 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 278,1025 | 239x34 | pressable | virtual bro | `text:virtual bro` x4 |
| 278,1025 | 239x34 | keyed |  | `key:[<'mem-12D3KooWF5kuBjyDMSzFviHHvdtS6uaZTqq57pA9ik2PAnffNXdk'>]` |
| 278,1025 | 239x34 | keyed |  | `key:mem-12D3KooWF5kuBjyDMSzFviHHvdtS6uaZTqq57pA9ik2PAnffNXdk` |
| 279,0 | 239x40 | keyed |  | `key:ach-6ae8032a-75134eee` |
| 279,0 | 239x40 | keyed |  | `key:[<'ach-6ae8032a-75134eee'>]` |
| 281,8 | 223x36 | pressable | 23 | `text:23` x2 |
| 287,240 | 784x24 | keyed |  | `key:4ce7ee57dbfb849322935d80678e1326` x2 |
| 287,240 | 784x24 | keyed |  | `key:[<4ce7ee57dbfb849322935d80678e1326>]` |
| 287,240 | 784x24 | keyed |  | `key:4ce7ee57dbfb849322935d80678e1326` x2 |
| 287,1071 | 54x17 | text | virtual bro | `text:virtual bro` x4 |
| 289,44 | 177x20 | text | 23 | `text:23` x2 |
| 289,294 | 25x20 | text | teto | `text:teto` x2 |
| 290,18 | 18x18 | icon | hash (0xe0ef) | `icon:hash` x4 |
| 302,1056 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 311,240 | 784x96 | keyed |  | `key:c61bfc6746d4e10f3f6c2610b81d3b56` x2 |
| 311,240 | 784x96 | keyed |  | `key:c61bfc6746d4e10f3f6c2610b81d3b56` x2 |
| 311,240 | 784x96 | keyed |  | `key:[<c61bfc6746d4e10f3f6c2610b81d3b56>]` |
| 312,1025 | 239x34 | keyed |  | `key:mem-12D3KooWLyj5mKdcjKWKRCtJni4bPD7dKiU5SEWMDNWQNNbfdhAL` |
| 312,1025 | 239x34 | keyed |  | `key:[<'mem-12D3KooWLyj5mKdcjKWKRCtJni4bPD7dKiU5SEWMDNWQNNbfdhAL'>]` |
| 312,1025 | 239x34 | pressable | 12 | `text:12` x12 |
| 321,1071 | 79x17 | text | iPhone 13 mini | `text:iPhone 13 mini` x4 |
| 322,1044 | 10x15 | text | 12 | `text:12` x12 |
| 325,592 | 79x15 | text | August 16, 2026 | `text:August 16, 2026` |
| 336,1056 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 362,294 | 86x18 | text | iPhone 13 mini | `text:iPhone 13 mini` x4 |
| 362,294 | 86x18 | semantics | Open profile | `semantics:Open profile` x8 |
| 364,388 | 24x14 | text | 13:41 | `text:13:41` x2 |
| 367,252 | 32x32 | semantics | Open profile | `semantics:Open profile` x8 |
| 375,262 | 12x17 | text | 12 | `text:12` x12 |
| 383,294 | 25x20 | text | teto | `text:teto` x2 |
| 399,111 | 318x34 | pressable | Mark server as read | `text:Mark server as read` x2 |
| 407,144 | 275x18 | text | Mark server as read | `text:Mark server as read` x2 |
| 407,240 | 784x59 | keyed |  | `key:51692019ab6c1b2232a279bde0aac13b` x2 |
| 407,240 | 784x59 | keyed |  | `key:51692019ab6c1b2232a279bde0aac13b` x2 |
| 407,240 | 784x59 | keyed |  | `key:[<51692019ab6c1b2232a279bde0aac13b>]` |
| 409,121 | 15x15 | icon | 0xe38e | `icon:0xe38e` |
| 421,294 | 66x18 | text | AnonListen | `text:AnonListen` x6 |
| 421,294 | 66x18 | semantics | Open profile | `semantics:Open profile` x8 |
| 423,368 | 24x14 | text | 13:41 | `text:13:41` x2 |
| 426,252 | 32x32 | semantics | Open profile | `semantics:Open profile` x8 |
| 438,111 | 318x34 | pressable | Create channel | `text:Create channel` x2 |
| 442,294 | 78x20 | text | kasane teto? | `text:kasane teto?` |
| 446,144 | 275x18 | text | Create channel | `text:Create channel` x2 |
| 448,121 | 15x15 | icon | plus (0xe13d) | `icon:plus` x2 |
| 466,240 | 784x24 | keyed |  | `key:[<30470f31c83c54d5d0d6dec208c9cccf>]` |
| 466,240 | 784x24 | keyed |  | `key:30470f31c83c54d5d0d6dec208c9cccf` x2 |
| 466,240 | 784x24 | keyed |  | `key:30470f31c83c54d5d0d6dec208c9cccf` x2 |
| 468,294 | 20x20 | text | yes | `text:yes` |
| 472,111 | 318x34 | pressable | Create category | `text:Create category` x2 |
| 480,144 | 275x18 | text | Create category | `text:Create category` x2 |
| 482,121 | 15x15 | icon | 0xe0d9 | `icon:0xe0d9` |
| 490,240 | 784x59 | keyed |  | `key:[<bca4f49faa4635e7ba2466dc3f2deeeb>]` |
| 490,240 | 784x59 | keyed |  | `key:bca4f49faa4635e7ba2466dc3f2deeeb` x2 |
| 490,240 | 784x59 | keyed |  | `key:bca4f49faa4635e7ba2466dc3f2deeeb` x2 |
| 504,294 | 86x18 | text | iPhone 13 mini | `text:iPhone 13 mini` x4 |
| 504,294 | 86x18 | semantics | Open profile | `semantics:Open profile` x8 |
| 506,388 | 24x14 | text | 16:24 | `text:16:24` |
| 509,252 | 32x32 | semantics | Open profile | `semantics:Open profile` x8 |
| 511,111 | 318x34 | pressable | Invite people | `text:Invite people` x2 |
| 517,262 | 12x17 | text | 12 | `text:12` x12 |
| 519,144 | 275x18 | text | Invite people | `text:Invite people` x2 |
| 521,121 | 15x15 | icon | userPlus (0xe1a2) | `icon:userPlus` x3 |
| 525,294 | 4x20 | text | f | `text:f` |
| 545,111 | 318x34 | pressable | Server settings | `text:Server settings` x2 |
| 553,144 | 275x18 | text | Server settings | `text:Server settings` x2 |
| 555,121 | 15x15 | icon | settings (0xe154) | `icon:settings` x3 |
| 566,332 | 515x48 | field | hint "Message #general" | `hint:Message #general` |
| 572,252 | 36x36 | pressable | Attach file | `semantics:Attach file` x2 |
| 572,252 | 36x36 | semantics | Attach file | `semantics:Attach file` x2 |
| 572,292 | 36x36 | pressable | Record voice message | `semantics:Record voice message` x2 |
| 572,292 | 36x36 | semantics | Record voice message | `semantics:Record voice message` x2 |
| 572,851 | 41x36 | pressable | Insert GIF | `semantics:Insert GIF` x2 |
| 572,851 | 41x36 | semantics | Insert GIF | `semantics:Insert GIF` x2 |
| 572,892 | 36x36 | pressable | Insert sticker | `semantics:Insert sticker` x2 |
| 572,892 | 36x36 | semantics | Insert sticker | `semantics:Insert sticker` x2 |
| 572,932 | 36x36 | semantics | Insert emoji | `semantics:Insert emoji` x2 |
| 572,932 | 36x36 | pressable | Insert emoji | `semantics:Insert emoji` x2 |
| 572,976 | 36x36 | semantics | Send message | `semantics:Send message` x2 |
| 572,976 | 36x36 | pressable | Send message | `semantics:Send message` x2 |
| 580,260 | 20x20 | icon | 0xe12d | `icon:0xe12d` |
| 580,300 | 20x20 | icon | mic (0xe118) | `icon:mic` |
| 580,348 | 483x20 | text | Message #general | `text:Message #general` |
| 580,348 | 483x20 | input |  | `type:EditableText` |
| 580,900 | 20x20 | icon | 0xe302 | `icon:0xe302` |
| 580,940 | 20x20 | icon | smile (0xe164) | `icon:smile` |
| 580,984 | 20x20 | icon | 0xe152 | `icon:0xe152` |
| 586,863 | 16x9 | text | GIF | `text:GIF` |
| 632,182 | 5x8 | text | 7 | `text:7` |
| 633,149 | 38x38 | semantics | Home | `semantics:Home` |
| 633,149 | 38x38 | tooltip | Home | `tooltip:Home` |
| 633,493 | 38x38 | semantics | testing | `semantics:testing` |
| 633,493 | 38x38 | tooltip | testing | `tooltip:testing` |
| 633,493 | 38x38 | keyed |  | `key:bounce-1a88f45832c2a648a914fc259f602a12` |
| 633,535 | 38x38 | keyed |  | `key:bounce-8f3d5c37a26835ddf04b07f2c91da556` |
| 633,535 | 38x38 | semantics | another one! | `semantics:another one!` |
| 633,535 | 38x38 | tooltip | another one! | `tooltip:another one!` |
| 633,577 | 38x38 | keyed |  | `key:bounce-b7d2030be50e7bd8708c4364102c4029` |
| 633,577 | 38x38 | semantics | MyEpicServer | `semantics:MyEpicServer` |
| 633,577 | 38x38 | tooltip | MyEpicServer | `tooltip:MyEpicServer` |
| 633,619 | 38x38 | keyed |  | `key:bounce-703162ad1c1dd3f77a506828f71c5f8d` |
| 633,619 | 38x38 | semantics | qww | `semantics:qww` |
| 633,619 | 38x38 | tooltip | qww | `tooltip:qww` |
| 633,661 | 38x38 | keyed |  | `key:bounce-6ec23029e3003347d7cdd73988293dd7` |
| 633,661 | 38x38 | semantics | test | `semantics:test` |
| 633,661 | 38x38 | tooltip | test | `tooltip:test` |
| 633,703 | 38x38 | keyed |  | `key:bounce-6ae8032accaad737890ca2d4f9e97752` |
| 633,703 | 38x38 | semantics | test3 | `semantics:test3` |
| 633,703 | 38x38 | tooltip | test3 | `tooltip:test3` |
| 633,1047 | 38x38 | semantics | Create a server | `semantics:Create a server` |
| 633,1047 | 38x38 | tooltip | Create a server | `tooltip:Create a server` |
| 638,0 | 140x28 | pressable | AnonListen | `text:AnonListen` x6 |
| 638,0 | 140x28 | tooltip | Online | `tooltip:Online` |
| 639,1114 | 26x26 | semantics | Browse public channels | `semantics:Browse public channels` x2 |
| 639,1114 | 26x26 | pressable | Browse public channels | `semantics:Browse public channels` x2 |
| 639,1114 | 26x26 | tooltip | Browse Public Channels | `tooltip:Browse Public Channels` |
| 639,1140 | 26x26 | pressable | Share | `semantics:Share` x2 |
| 639,1140 | 26x26 | tooltip | Share | `tooltip:Share` |
| 639,1140 | 26x26 | semantics | Share | `semantics:Share` x2 |
| 639,1166 | 26x26 | tooltip | Archive | `tooltip:Archive` |
| 639,1166 | 26x26 | pressable | Archive | `semantics:Archive` x2 |
| 639,1166 | 26x26 | semantics | Archive | `semantics:Archive` x2 |
| 639,1192 | 26x26 | tooltip | Downloads | `tooltip:Downloads` |
| 639,1192 | 26x26 | pressable | Downloads | `semantics:Downloads` x2 |
| 639,1192 | 26x26 | semantics | Downloads | `semantics:Downloads` x2 |
| 639,1218 | 26x26 | tooltip | Settings | `tooltip:Settings` |
| 639,1218 | 26x26 | pressable | Settings | `semantics:Settings` x2 |
| 639,1218 | 26x26 | semantics | Settings | `semantics:Settings` x2 |
| 640,161 | 14x25 | text | H | `text:H` |
| 642,585 | 21x20 | text | MY | `text:MY` |
| 642,673 | 15x20 | text | TE | `text:TE` x2 |
| 642,715 | 15x20 | text | TE | `text:TE` x2 |
| 643,1057 | 18x18 | icon | plus (0xe13d) | `icon:plus` x2 |
| 643,1118 | 18x18 | icon | globe (0xe0e8) | `icon:globe` |
| 643,1144 | 18x18 | icon | 0xe156 | `icon:0xe156` |
| 643,1170 | 18x18 | icon | 0xe041 | `icon:0xe041` |
| 643,1196 | 18x18 | icon | download (0xe0b2) | `icon:download` |
| 643,1222 | 18x18 | icon | settings (0xe154) | `icon:settings` x3 |
| 644,59 | 69x17 | text | AnonListen | `text:AnonListen` x6 |
| 649,48 | 7x7 | semantics | Online | `semantics:Online` x2 |

---

## UI map: 05-server-settings

Screen 1264.0 x 681.0 logical pixels. 243 entries.

### Open surfaces

- dialog open: false
- context menu open: false

### Providers

- server: test3 (6ae8032accaad737890ca2d4f9e97752)
- channel: general (6ae8032a-general)
- layout mode: LayoutMode.dock

#### Stored layout

```
[0] general (text, 6ae8032a-general)
[1] test (text, 6ae8032a-3f35dfa2)
[2] test3 (voice, 6ae8032a-5af0eb9e)
[3] CATEGORY "233"
    [4] 23 (text, 6ae8032a-75134eee)
```

### On screen

`y,x` is the top-left corner. Paste a target straight into a scenario; `xN` means the target matches N widgets, so scope it (`dialog > ...`) or pass an index.

| y,x | size | kind | label | target |
|---|---|---|---|---|
| 0,1126 | 46x32 | semantics | Minimize | `semantics:Minimize` |
| 0,1172 | 46x32 | semantics | Maximize | `semantics:Maximize` |
| 0,1218 | 46x32 | semantics | Close | `semantics:Close` x3 |
| 7,16 | 44x18 | text | Hollow | `text:Hollow` |
| 7,1090 | 32x18 | icon | pencil (0xe1f9) | `icon:pencil` |
| 8,1141 | 16x16 | icon | 0xe11c | `icon:0xe11c` |
| 8,1233 | 16x16 | icon | x (0xe1b2) | `icon:x` x2 |
| 9,1188 | 14x14 | icon | 0xe167 | `icon:0xe167` |
| 32,0 | 1264x649 | keyed |  | `key:_ScaffoldSlot.body` |
| 32,66 | 81x43 | pressable | 12 | `text:12` x10 |
| 32,66 | 81x43 | tooltip | MacOS | `tooltip:MacOS` |
| 32,153 | 68x43 | pressable | Pixel | `text:Pixel` x2 |
| 32,153 | 68x43 | tooltip | Pixel | `tooltip:Pixel` |
| 32,227 | 118x43 | tooltip | iPhone 13 mini | `tooltip:iPhone 13 mini` |
| 32,227 | 118x43 | pressable | 12 | `text:12` x10 |
| 32,351 | 92x43 | tooltip | UbuLinux | `tooltip:UbuLinux` |
| 32,351 | 92x43 | pressable | 12 | `text:12` x10 |
| 32,449 | 96x43 | pressable | virtual bro | `text:virtual bro` x4 |
| 32,449 | 96x43 | tooltip | virtual bro | `tooltip:virtual bro` |
| 41,8 | 34x26 | tooltip | Add Friend | `tooltip:Add Friend` |
| 41,8 | 34x26 | pressable | Add friend | `semantics:Add friend` x2 |
| 41,8 | 34x26 | semantics | Add friend | `semantics:Add friend` x2 |
| 41,1146 | 34x26 | tooltip | Saved messages | `tooltip:Saved messages` |
| 41,1146 | 34x26 | pressable | Saved messages | `semantics:Saved messages` x2 |
| 41,1146 | 34x26 | semantics | Saved messages | `semantics:Saved messages` x2 |
| 41,1184 | 34x26 | pressable | Conferences | `semantics:Conferences` x2 |
| 41,1184 | 34x26 | tooltip | Conferences | `tooltip:Conferences` |
| 41,1184 | 34x26 | semantics | Conferences | `semantics:Conferences` x2 |
| 41,1222 | 34x26 | tooltip | Help | `tooltip:Help` |
| 41,1222 | 34x26 | pressable | Help | `semantics:Help` x2 |
| 41,1222 | 34x26 | semantics | Help | `semantics:Help` x2 |
| 45,16 | 18x18 | icon | userPlus (0xe1a2) | `icon:userPlus` x2 |
| 45,1154 | 18x18 | icon | 0xe060 | `icon:0xe060` |
| 45,1192 | 18x18 | icon | video (0xe1a5) | `icon:video` |
| 45,1230 | 18x18 | icon | 0xe082 | `icon:0xe082` |
| 46,104 | 35x15 | text | MacOS | `text:MacOS` |
| 46,191 | 22x15 | text | Pixel | `text:Pixel` x2 |
| 46,265 | 72x15 | text | iPhone 13 mini | `text:iPhone 13 mini` x2 |
| 46,389 | 46x15 | text | UbuLinux | `text:UbuLinux` |
| 46,487 | 50x15 | text | virtual bro | `text:virtual bro` x4 |
| 47,82 | 9x13 | text | 12 | `text:12` x10 |
| 47,243 | 9x13 | text | 12 | `text:12` x10 |
| 47,367 | 9x13 | text | 12 | `text:12` x10 |
| 59,92 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 59,178 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 59,252 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 59,376 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 59,474 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 76,0 | 239x48 | keyed |  | `key:[<null>]` |
| 76,0 | 239x48 | keyed |  | `key:null` |
| 76,0 | 239x48 | keyed |  | `key:header-test3` |
| 76,240 | 784x546 | keyed |  | `key:[<'settings-6ae8032accaad737890ca2d4f9e97752'>]` |
| 76,240 | 784x546 | keyed |  | `key:settings-6ae8032accaad737890ca2d4f9e97752` |
| 76,240 | 784x546 | keyed |  | `key:[<[<'settings-6ae8032accaad737890ca2d4f9e97752'>]>]` |
| 76,240 | 784x546 | keyed |  | `key:single-settings-6ae8032accaad737890ca2d4f9e97752` |
| 76,240 | 784x546 | keyed |  | `key:[<'single-settings-6ae8032accaad737890ca2d4f9e97752'>]` |
| 76,240 | 784x546 | keyed |  | `key:[<[<'single-settings-6ae8032accaad737890ca2d4f9e97752'>]>]` |
| 76,1025 | 239x546 | keyed |  | `key:[<'server-members-6ae8032accaad737890ca2d4f9e97752'>]` |
| 76,1025 | 239x546 | keyed |  | `key:server-members-6ae8032accaad737890ca2d4f9e97752` |
| 76,1025 | 239x546 | keyed |  | `key:[<[<'server-members-6ae8032accaad737890ca2d4f9e97752'>]>]` |
| 87,982 | 26x26 | semantics | Close | `semantics:Close` x3 |
| 87,982 | 26x26 | pressable | Close | `semantics:Close` x3 |
| 88,159 | 24x24 | tooltip | Invite people | `tooltip:Invite people` |
| 88,159 | 24x24 | pressable | Invite people | `semantics:Invite people` x2 |
| 88,159 | 24x24 | semantics | Invite people | `semantics:Invite people` x2 |
| 88,183 | 24x24 | tooltip | Storage | `tooltip:Storage` |
| 88,183 | 24x24 | pressable | Storage | `semantics:Storage` x2 |
| 88,183 | 24x24 | semantics | Storage | `semantics:Storage` x2 |
| 88,207 | 24x24 | tooltip | Server settings | `tooltip:Server settings` |
| 88,207 | 24x24 | pressable | Server settings | `semantics:Server settings` x2 |
| 88,207 | 24x24 | semantics | Server settings | `semantics:Server settings` x2 |
| 89,16 | 143x22 | text | test3 | `text:test3` x3 |
| 89,282 | 700x22 | text | Server Settings: test3 | `text:Server Settings: test3` |
| 91,256 | 18x18 | icon | settings (0xe154) | `icon:settings` x3 |
| 91,986 | 18x18 | icon | x (0xe1b2) | `icon:x` x2 |
| 92,163 | 16x16 | icon | userPlus (0xe1a2) | `icon:userPlus` x2 |
| 92,187 | 16x16 | icon | hardDrive (0xe0ed) | `icon:hardDrive` |
| 92,211 | 16x16 | icon | settings (0xe154) | `icon:settings` x3 |
| 92,1035 | 53x15 | text | Members | `text:Members` x3 |
| 92,1247 | 7x15 | text | 4 | `text:4` |
| 124,0 | 239x498 | keyed |  | `key:server-6ae8032accaad737890ca2d4f9e97752` |
| 124,0 | 239x498 | keyed |  | `key:[<'server-6ae8032accaad737890ca2d4f9e97752'>]` |
| 124,0 | 239x498 | keyed |  | `key:[<[<'server-6ae8032accaad737890ca2d4f9e97752'>]>]` |
| 127,252 | 97x34 | pressable | Overview | `text:Overview` x2 |
| 127,349 | 94x34 | pressable | Channels | `text:Channels` x2 |
| 127,443 | 72x34 | pressable | Roles | `text:Roles` x2 |
| 127,516 | 78x34 | pressable | Labels | `text:Labels` x2 |
| 127,594 | 84x34 | pressable | Emotes | `text:Emotes` x2 |
| 127,678 | 96x34 | pressable | Members | `text:Members` x3 |
| 127,774 | 115x34 | pressable | Notifications | `text:Notifications` x2 |
| 127,889 | 84x34 | pressable | Danger | `text:Danger` x2 |
| 128,0 | 239x40 | keyed |  | `key:ach-6ae8032a-general` |
| 128,0 | 239x40 | keyed |  | `key:[<'ach-6ae8032a-general'>]` |
| 130,8 | 223x36 | pressable | general | `text:general` x2 |
| 132,1025 | 239x31 | keyed |  | `key:div-Owner` |
| 132,1025 | 239x31 | keyed |  | `key:[<'div-Owner'>]` |
| 135,282 | 55x18 | text | Overview | `text:Overview` x2 |
| 135,379 | 52x18 | text | Channels | `text:Channels` x2 |
| 135,473 | 30x18 | text | Roles | `text:Roles` x2 |
| 135,546 | 36x18 | text | Labels | `text:Labels` x2 |
| 135,624 | 42x18 | text | Emotes | `text:Emotes` x2 |
| 135,708 | 54x18 | text | Members | `text:Members` x3 |
| 135,804 | 73x18 | text | Notifications | `text:Notifications` x2 |
| 135,919 | 42x18 | text | Danger | `text:Danger` x2 |
| 137,264 | 14x14 | icon | 0xe0f9 | `icon:0xe0f9` |
| 137,361 | 14x14 | icon | hash (0xe0ef) | `icon:hash` x4 |
| 137,455 | 14x14 | icon | shield (0xe158) | `icon:shield` |
| 137,528 | 14x14 | icon | tag (0xe17f) | `icon:tag` |
| 137,606 | 14x14 | icon | smile (0xe164) | `icon:smile` |
| 137,690 | 14x14 | icon | users (0xe1a4) | `icon:users` |
| 137,786 | 14x14 | icon | bell (0xe059) | `icon:bell` |
| 137,901 | 14x14 | icon | alertTriangle (0xe193) | `icon:alertTriangle` |
| 138,44 | 177x20 | text | general | `text:general` x2 |
| 139,18 | 18x18 | icon | hash (0xe0ef) | `icon:hash` x4 |
| 140,1035 | 37x15 | text | Owner | `text:Owner` x2 |
| 140,1249 | 5x15 | text | 1 | `text:1` |
| 163,1025 | 239x50 | keyed |  | `key:mem-12D3KooWJJU9fygVAYVJqVM4FAtTyaUBHSsfRkuavwY53nT7iS4F` |
| 163,1025 | 239x50 | pressable | AnonListen | `text:AnonListen` x4 |
| 163,1025 | 239x50 | keyed |  | `key:[<'mem-12D3KooWJJU9fygVAYVJqVM4FAtTyaUBHSsfRkuavwY53nT7iS4F'>]` |
| 164,240 | 784x458 | keyed |  | `key:[<'overview'>]` |
| 164,240 | 784x458 | keyed |  | `key:[<[<'overview'>]>]` |
| 164,240 | 784x458 | keyed |  | `key:overview` |
| 166,1071 | 59x17 | text | AnonListen | `text:AnonListen` x4 |
| 168,0 | 239x40 | keyed |  | `key:[<'ach-6ae8032a-3f35dfa2'>]` |
| 168,0 | 239x40 | keyed |  | `key:ach-6ae8032a-3f35dfa2` |
| 170,8 | 223x36 | pressable | test | `text:test` x2 |
| 178,44 | 177x20 | text | test | `text:test` x2 |
| 179,18 | 18x18 | icon | hash (0xe0ef) | `icon:hash` x4 |
| 183,1071 | 29x14 | text | Owner | `text:Owner` x2 |
| 188,264 | 736x15 | text | SERVER SETTINGS | `text:SERVER SETTINGS` |
| 195,1056 | 7x7 | semantics | Online | `semantics:Online` x2 |
| 197,1084 | 41x13 | text | anonlisten | `text:anonlisten` |
| 199,1071 | 10x10 | icon | 0xf58a | `icon:0xf58a` |
| 208,0 | 239x40 | keyed |  | `key:[<'ach-6ae8032a-5af0eb9e'>]` |
| 208,0 | 239x40 | keyed |  | `key:ach-6ae8032a-5af0eb9e` |
| 210,8 | 223x36 | pressable | test3 | `text:test3` x3 |
| 213,1025 | 239x31 | keyed |  | `key:div-Offline` |
| 213,1025 | 239x31 | keyed |  | `key:[<'div-Offline'>]` |
| 215,264 | 736x18 | text | Server icon | `text:Server icon` |
| 218,44 | 177x20 | text | test3 | `text:test3` x3 |
| 219,18 | 18x18 | icon | volume2 (0xe1ab) | `icon:volume2` |
| 221,1035 | 40x15 | text | Offline | `text:Offline` |
| 221,1247 | 7x15 | text | 3 | `text:3` |
| 244,1025 | 239x34 | keyed |  | `key:[<'mem-12D3KooWKS8jL9xFsxkMgwrLGJpnSngi8KgtPRuFyNRVL4PnKh8C'>]` |
| 244,1025 | 239x34 | keyed |  | `key:mem-12D3KooWKS8jL9xFsxkMgwrLGJpnSngi8KgtPRuFyNRVL4PnKh8C` |
| 244,1025 | 239x34 | pressable | 12 | `text:12` x10 |
| 249,324 | 91x32 | button | Upload | `text:Upload` x4 |
| 253,1071 | 29x17 | text | vm22 | `text:vm22` |
| 254,1044 | 10x15 | text | 12 | `text:12` x10 |
| 255,278 | 20x20 | icon | image (0xe0f6) | `icon:image` x2 |
| 257,336 | 16x16 | icon | 0xe19e | `icon:0xe19e` x2 |
| 259,360 | 43x13 | text | Upload | `text:Upload` x4 |
| 260,10 | 221x15 | pressable | 233 | `text:233` x2 |
| 260,24 | 207x15 | text | 233 | `text:233` x2 |
| 263,10 | 10x10 | icon | chevronDown (0xe06d) | `icon:chevronDown` |
| 268,1056 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 278,1025 | 239x34 | keyed |  | `key:[<'mem-12D3KooWF5kuBjyDMSzFviHHvdtS6uaZTqq57pA9ik2PAnffNXdk'>]` |
| 278,1025 | 239x34 | keyed |  | `key:mem-12D3KooWF5kuBjyDMSzFviHHvdtS6uaZTqq57pA9ik2PAnffNXdk` |
| 278,1025 | 239x34 | pressable | virtual bro | `text:virtual bro` x4 |
| 279,0 | 239x40 | keyed |  | `key:ach-6ae8032a-75134eee` |
| 279,0 | 239x40 | keyed |  | `key:[<'ach-6ae8032a-75134eee'>]` |
| 281,8 | 223x36 | pressable | 23 | `text:23` x2 |
| 287,1071 | 54x17 | text | virtual bro | `text:virtual bro` x4 |
| 289,44 | 177x20 | text | 23 | `text:23` x2 |
| 290,18 | 18x18 | icon | hash (0xe0ef) | `icon:hash` x4 |
| 302,1056 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 305,264 | 736x18 | text | Server banner | `text:Server banner` |
| 312,1025 | 239x34 | keyed |  | `key:[<'mem-12D3KooWLyj5mKdcjKWKRCtJni4bPD7dKiU5SEWMDNWQNNbfdhAL'>]` |
| 312,1025 | 239x34 | keyed |  | `key:mem-12D3KooWLyj5mKdcjKWKRCtJni4bPD7dKiU5SEWMDNWQNNbfdhAL` |
| 312,1025 | 239x34 | pressable | 12 | `text:12` x10 |
| 321,1071 | 79x17 | text | iPhone 13 mini | `text:iPhone 13 mini` x2 |
| 322,1044 | 10x15 | text | 12 | `text:12` x10 |
| 336,1056 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 339,420 | 91x32 | button | Upload | `text:Upload` x4 |
| 345,326 | 20x20 | icon | image (0xe0f6) | `icon:image` x2 |
| 347,432 | 16x16 | icon | 0xe19e | `icon:0xe19e` x2 |
| 349,456 | 43x13 | text | Upload | `text:Upload` x4 |
| 395,264 | 736x18 | text | Server name | `text:Server name` x2 |
| 421,264 | 669x48 | field | hint "Server name" | `hint:Server name` |
| 435,280 | 637x20 | input | test3 | `type:EditableText` x2 |
| 435,280 | 637x20 | text | Server name | `text:Server name` x2 |
| 437,941 | 59x33 | button | Save | `text:Save` x2 |
| 447,957 | 27x13 | text | Save | `text:Save` x2 |
| 472,913 | 20x14 | text | 5/32 | `text:5/32` |
| 510,264 | 736x18 | text | Description | `text:Description` |
| 536,264 | 736x76 | field | hint "What is this server about?" | `hint:What is this server about?` |
| 544,280 | 704x20 | text | What is this server about? | `text:What is this server about?` |
| 544,280 | 704x60 | input |  | `type:EditableText` x2 |
| 615,975 | 25x14 | text | 0/256 | `text:0/256` |
| 632,182 | 5x8 | text | 7 | `text:7` |
| 633,149 | 38x38 | tooltip | Home | `tooltip:Home` |
| 633,149 | 38x38 | semantics | Home | `semantics:Home` |
| 633,493 | 38x38 | tooltip | testing | `tooltip:testing` |
| 633,493 | 38x38 | semantics | testing | `semantics:testing` |
| 633,493 | 38x38 | keyed |  | `key:bounce-1a88f45832c2a648a914fc259f602a12` |
| 633,535 | 38x38 | keyed |  | `key:bounce-8f3d5c37a26835ddf04b07f2c91da556` |
| 633,535 | 38x38 | semantics | another one! | `semantics:another one!` |
| 633,535 | 38x38 | tooltip | another one! | `tooltip:another one!` |
| 633,577 | 38x38 | keyed |  | `key:bounce-b7d2030be50e7bd8708c4364102c4029` |
| 633,577 | 38x38 | semantics | MyEpicServer | `semantics:MyEpicServer` |
| 633,577 | 38x38 | tooltip | MyEpicServer | `tooltip:MyEpicServer` |
| 633,619 | 38x38 | keyed |  | `key:bounce-703162ad1c1dd3f77a506828f71c5f8d` |
| 633,619 | 38x38 | semantics | qww | `semantics:qww` |
| 633,619 | 38x38 | tooltip | qww | `tooltip:qww` |
| 633,661 | 38x38 | keyed |  | `key:bounce-6ec23029e3003347d7cdd73988293dd7` |
| 633,661 | 38x38 | semantics | test | `semantics:test` |
| 633,661 | 38x38 | tooltip | test | `tooltip:test` |
| 633,703 | 38x38 | tooltip | test3 | `tooltip:test3` |
| 633,703 | 38x38 | keyed |  | `key:bounce-6ae8032accaad737890ca2d4f9e97752` |
| 633,703 | 38x38 | semantics | test3 | `semantics:test3` |
| 633,1047 | 38x38 | tooltip | Create a server | `tooltip:Create a server` |
| 633,1047 | 38x38 | semantics | Create a server | `semantics:Create a server` |
| 637,879 | 121x29 | button | Save description | `text:Save description` x2 |
| 638,0 | 140x28 | pressable | AnonListen | `text:AnonListen` x4 |
| 638,0 | 140x28 | tooltip | Online | `tooltip:Online` |
| 639,1114 | 26x26 | tooltip | Browse Public Channels | `tooltip:Browse Public Channels` |
| 639,1114 | 26x26 | pressable | Browse public channels | `semantics:Browse public channels` x2 |
| 639,1114 | 26x26 | semantics | Browse public channels | `semantics:Browse public channels` x2 |
| 639,1140 | 26x26 | tooltip | Share | `tooltip:Share` |
| 639,1140 | 26x26 | pressable | Share | `semantics:Share` x2 |
| 639,1140 | 26x26 | semantics | Share | `semantics:Share` x2 |
| 639,1166 | 26x26 | tooltip | Archive | `tooltip:Archive` |
| 639,1166 | 26x26 | pressable | Archive | `semantics:Archive` x2 |
| 639,1166 | 26x26 | semantics | Archive | `semantics:Archive` x2 |
| 639,1192 | 26x26 | tooltip | Downloads | `tooltip:Downloads` |
| 639,1192 | 26x26 | pressable | Downloads | `semantics:Downloads` x2 |
| 639,1192 | 26x26 | semantics | Downloads | `semantics:Downloads` x2 |
| 639,1218 | 26x26 | tooltip | Settings | `tooltip:Settings` |
| 639,1218 | 26x26 | pressable | Settings | `semantics:Settings` x2 |
| 639,1218 | 26x26 | semantics | Settings | `semantics:Settings` x2 |
| 640,161 | 14x25 | text | H | `text:H` |
| 642,585 | 21x20 | text | MY | `text:MY` |
| 642,673 | 15x20 | text | TE | `text:TE` x2 |
| 642,715 | 15x20 | text | TE | `text:TE` x2 |
| 643,1057 | 18x18 | icon | plus (0xe13d) | `icon:plus` |
| 643,1118 | 18x18 | icon | globe (0xe0e8) | `icon:globe` |
| 643,1144 | 18x18 | icon | 0xe156 | `icon:0xe156` |
| 643,1170 | 18x18 | icon | 0xe041 | `icon:0xe041` |
| 643,1196 | 18x18 | icon | download (0xe0b2) | `icon:download` |
| 643,1222 | 18x18 | icon | settings (0xe154) | `icon:settings` x3 |
| 644,59 | 69x17 | text | AnonListen | `text:AnonListen` x4 |
| 645,891 | 97x13 | text | Save description | `text:Save description` x2 |
| 649,48 | 7x7 | semantics | Online | `semantics:Online` x2 |

---

## UI map: 06-channels-tab

Screen 1264.0 x 681.0 logical pixels. 380 entries.

### Open surfaces

- dialog open: false
- context menu open: false

### Providers

- server: test3 (6ae8032accaad737890ca2d4f9e97752)
- channel: general (6ae8032a-general)
- layout mode: LayoutMode.dock

#### Stored layout

```
[0] general (text, 6ae8032a-general)
[1] test (text, 6ae8032a-3f35dfa2)
[2] test3 (voice, 6ae8032a-5af0eb9e)
[3] CATEGORY "233"
    [4] 23 (text, 6ae8032a-75134eee)
```

### On screen

`y,x` is the top-left corner. Paste a target straight into a scenario; `xN` means the target matches N widgets, so scope it (`dialog > ...`) or pass an index.

| y,x | size | kind | label | target |
|---|---|---|---|---|
| 0,1126 | 46x32 | semantics | Minimize | `semantics:Minimize` |
| 0,1172 | 46x32 | semantics | Maximize | `semantics:Maximize` |
| 0,1218 | 46x32 | semantics | Close | `semantics:Close` x3 |
| 7,16 | 44x18 | text | Hollow | `text:Hollow` |
| 7,1090 | 32x18 | icon | pencil (0xe1f9) | `icon:pencil` x6 |
| 8,1141 | 16x16 | icon | 0xe11c | `icon:0xe11c` x2 |
| 8,1233 | 16x16 | icon | x (0xe1b2) | `icon:x` x2 |
| 9,1188 | 14x14 | icon | 0xe167 | `icon:0xe167` |
| 32,0 | 1264x649 | keyed |  | `key:_ScaffoldSlot.body` |
| 32,66 | 81x43 | tooltip | MacOS | `tooltip:MacOS` |
| 32,66 | 81x43 | pressable | 12 | `text:12` x10 |
| 32,153 | 68x43 | tooltip | Pixel | `tooltip:Pixel` |
| 32,153 | 68x43 | pressable | Pixel | `text:Pixel` x2 |
| 32,227 | 118x43 | tooltip | iPhone 13 mini | `tooltip:iPhone 13 mini` |
| 32,227 | 118x43 | pressable | 12 | `text:12` x10 |
| 32,351 | 92x43 | tooltip | UbuLinux | `tooltip:UbuLinux` |
| 32,351 | 92x43 | pressable | 12 | `text:12` x10 |
| 32,449 | 96x43 | tooltip | virtual bro | `tooltip:virtual bro` |
| 32,449 | 96x43 | pressable | virtual bro | `text:virtual bro` x4 |
| 41,8 | 34x26 | tooltip | Add Friend | `tooltip:Add Friend` |
| 41,8 | 34x26 | pressable | Add friend | `semantics:Add friend` x2 |
| 41,8 | 34x26 | semantics | Add friend | `semantics:Add friend` x2 |
| 41,1146 | 34x26 | tooltip | Saved messages | `tooltip:Saved messages` |
| 41,1146 | 34x26 | pressable | Saved messages | `semantics:Saved messages` x2 |
| 41,1146 | 34x26 | semantics | Saved messages | `semantics:Saved messages` x2 |
| 41,1184 | 34x26 | tooltip | Conferences | `tooltip:Conferences` |
| 41,1184 | 34x26 | semantics | Conferences | `semantics:Conferences` x2 |
| 41,1184 | 34x26 | pressable | Conferences | `semantics:Conferences` x2 |
| 41,1222 | 34x26 | tooltip | Help | `tooltip:Help` |
| 41,1222 | 34x26 | pressable | Help | `semantics:Help` x2 |
| 41,1222 | 34x26 | semantics | Help | `semantics:Help` x2 |
| 45,16 | 18x18 | icon | userPlus (0xe1a2) | `icon:userPlus` x6 |
| 45,1154 | 18x18 | icon | 0xe060 | `icon:0xe060` |
| 45,1192 | 18x18 | icon | video (0xe1a5) | `icon:video` |
| 45,1230 | 18x18 | icon | 0xe082 | `icon:0xe082` |
| 46,104 | 35x15 | text | MacOS | `text:MacOS` |
| 46,191 | 22x15 | text | Pixel | `text:Pixel` x2 |
| 46,265 | 72x15 | text | iPhone 13 mini | `text:iPhone 13 mini` x2 |
| 46,389 | 46x15 | text | UbuLinux | `text:UbuLinux` |
| 46,487 | 50x15 | text | virtual bro | `text:virtual bro` x4 |
| 47,82 | 9x13 | text | 12 | `text:12` x10 |
| 47,243 | 9x13 | text | 12 | `text:12` x10 |
| 47,367 | 9x13 | text | 12 | `text:12` x10 |
| 59,92 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 59,178 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 59,252 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 59,376 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 59,474 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 76,0 | 239x48 | keyed |  | `key:[<null>]` |
| 76,0 | 239x48 | keyed |  | `key:null` |
| 76,0 | 239x48 | keyed |  | `key:header-test3` |
| 76,240 | 784x546 | keyed |  | `key:single-settings-6ae8032accaad737890ca2d4f9e97752` |
| 76,240 | 784x546 | keyed |  | `key:[<'single-settings-6ae8032accaad737890ca2d4f9e97752'>]` |
| 76,240 | 784x546 | keyed |  | `key:[<[<'single-settings-6ae8032accaad737890ca2d4f9e97752'>]>]` |
| 76,240 | 784x546 | keyed |  | `key:[<'settings-6ae8032accaad737890ca2d4f9e97752'>]` |
| 76,240 | 784x546 | keyed |  | `key:settings-6ae8032accaad737890ca2d4f9e97752` |
| 76,240 | 784x546 | keyed |  | `key:[<[<'settings-6ae8032accaad737890ca2d4f9e97752'>]>]` |
| 76,1025 | 239x546 | keyed |  | `key:[<'server-members-6ae8032accaad737890ca2d4f9e97752'>]` |
| 76,1025 | 239x546 | keyed |  | `key:[<[<'server-members-6ae8032accaad737890ca2d4f9e97752'>]>]` |
| 76,1025 | 239x546 | keyed |  | `key:server-members-6ae8032accaad737890ca2d4f9e97752` |
| 87,982 | 26x26 | semantics | Close | `semantics:Close` x3 |
| 87,982 | 26x26 | pressable | Close | `semantics:Close` x3 |
| 88,159 | 24x24 | semantics | Invite people | `semantics:Invite people` x2 |
| 88,159 | 24x24 | pressable | Invite people | `semantics:Invite people` x2 |
| 88,159 | 24x24 | tooltip | Invite people | `tooltip:Invite people` |
| 88,183 | 24x24 | pressable | Storage | `semantics:Storage` x2 |
| 88,183 | 24x24 | semantics | Storage | `semantics:Storage` x2 |
| 88,183 | 24x24 | tooltip | Storage | `tooltip:Storage` |
| 88,207 | 24x24 | semantics | Server settings | `semantics:Server settings` x2 |
| 88,207 | 24x24 | tooltip | Server settings | `tooltip:Server settings` |
| 88,207 | 24x24 | pressable | Server settings | `semantics:Server settings` x2 |
| 89,16 | 143x22 | text | test3 | `text:test3` x4 |
| 89,282 | 700x22 | text | Server Settings: test3 | `text:Server Settings: test3` |
| 91,256 | 18x18 | icon | settings (0xe154) | `icon:settings` x3 |
| 91,986 | 18x18 | icon | x (0xe1b2) | `icon:x` x2 |
| 92,163 | 16x16 | icon | userPlus (0xe1a2) | `icon:userPlus` x6 |
| 92,187 | 16x16 | icon | hardDrive (0xe0ed) | `icon:hardDrive` |
| 92,211 | 16x16 | icon | settings (0xe154) | `icon:settings` x3 |
| 92,1035 | 53x15 | text | Members | `text:Members` x3 |
| 92,1247 | 7x15 | text | 4 | `text:4` |
| 124,0 | 239x498 | keyed |  | `key:[<[<'server-6ae8032accaad737890ca2d4f9e97752'>]>]` |
| 124,0 | 239x498 | keyed |  | `key:server-6ae8032accaad737890ca2d4f9e97752` |
| 124,0 | 239x498 | keyed |  | `key:[<'server-6ae8032accaad737890ca2d4f9e97752'>]` |
| 127,252 | 95x34 | pressable | Overview | `text:Overview` x2 |
| 127,347 | 96x34 | pressable | Channels | `text:Channels` x2 |
| 127,442 | 72x34 | pressable | Roles | `text:Roles` x2 |
| 127,515 | 78x34 | pressable | Labels | `text:Labels` x2 |
| 127,593 | 84x34 | pressable | Emotes | `text:Emotes` x2 |
| 127,677 | 96x34 | pressable | Members | `text:Members` x3 |
| 127,773 | 115x34 | pressable | Notifications | `text:Notifications` x2 |
| 127,888 | 84x34 | pressable | Danger | `text:Danger` x2 |
| 128,0 | 239x40 | keyed |  | `key:ach-6ae8032a-general` |
| 128,0 | 239x40 | keyed |  | `key:[<'ach-6ae8032a-general'>]` |
| 130,8 | 223x36 | pressable | general | `text:general` x3 |
| 132,1025 | 239x31 | keyed |  | `key:[<'div-Owner'>]` |
| 132,1025 | 239x31 | keyed |  | `key:div-Owner` |
| 135,282 | 53x18 | text | Overview | `text:Overview` x2 |
| 135,377 | 54x18 | text | Channels | `text:Channels` x2 |
| 135,472 | 30x18 | text | Roles | `text:Roles` x2 |
| 135,545 | 36x18 | text | Labels | `text:Labels` x2 |
| 135,623 | 42x18 | text | Emotes | `text:Emotes` x2 |
| 135,707 | 54x18 | text | Members | `text:Members` x3 |
| 135,803 | 73x18 | text | Notifications | `text:Notifications` x2 |
| 135,918 | 42x18 | text | Danger | `text:Danger` x2 |
| 137,264 | 14x14 | icon | 0xe0f9 | `icon:0xe0f9` |
| 137,359 | 14x14 | icon | hash (0xe0ef) | `icon:hash` x7 |
| 137,454 | 14x14 | icon | shield (0xe158) | `icon:shield` |
| 137,527 | 14x14 | icon | tag (0xe17f) | `icon:tag` |
| 137,605 | 14x14 | icon | smile (0xe164) | `icon:smile` |
| 137,689 | 14x14 | icon | users (0xe1a4) | `icon:users` |
| 137,785 | 14x14 | icon | bell (0xe059) | `icon:bell` |
| 137,900 | 14x14 | icon | alertTriangle (0xe193) | `icon:alertTriangle` |
| 138,44 | 177x20 | text | general | `text:general` x3 |
| 139,18 | 18x18 | icon | hash (0xe0ef) | `icon:hash` x7 |
| 140,1035 | 37x15 | text | Owner | `text:Owner` x2 |
| 140,1249 | 5x15 | text | 1 | `text:1` |
| 163,1025 | 239x50 | pressable | AnonListen | `text:AnonListen` x4 |
| 163,1025 | 239x50 | keyed |  | `key:mem-12D3KooWJJU9fygVAYVJqVM4FAtTyaUBHSsfRkuavwY53nT7iS4F` |
| 163,1025 | 239x50 | keyed |  | `key:[<'mem-12D3KooWJJU9fygVAYVJqVM4FAtTyaUBHSsfRkuavwY53nT7iS4F'>]` |
| 164,240 | 784x458 | keyed |  | `key:[<'channels'>]` |
| 164,240 | 784x458 | keyed |  | `key:[<[<'channels'>]>]` |
| 164,240 | 784x458 | keyed |  | `key:channels` |
| 166,1071 | 59x17 | text | AnonListen | `text:AnonListen` x4 |
| 168,0 | 239x40 | keyed |  | `key:ach-6ae8032a-3f35dfa2` |
| 168,0 | 239x40 | keyed |  | `key:[<'ach-6ae8032a-3f35dfa2'>]` |
| 170,8 | 223x36 | pressable | test | `text:test` x3 |
| 176,713 | 81x32 | button | Break | `text:Break` x2 |
| 176,802 | 102x32 | button | Category | `text:Category` x2 |
| 176,912 | 96x32 | button | Channel | `text:Channel` x2 |
| 178,44 | 177x20 | text | test | `text:test` x3 |
| 179,18 | 18x18 | icon | hash (0xe0ef) | `icon:hash` x7 |
| 183,1071 | 29x14 | text | Owner | `text:Owner` x2 |
| 184,725 | 16x16 | icon | 0xe11c | `icon:0xe11c` x2 |
| 184,814 | 16x16 | icon | 0xe0d9 | `icon:0xe0d9` |
| 184,924 | 16x16 | icon | plus (0xe13d) | `icon:plus` x2 |
| 185,256 | 457x15 | text | Drag to reorder channels and categories | `text:Drag to reorder channels and categories` |
| 186,749 | 33x13 | text | Break | `text:Break` x2 |
| 186,838 | 54x13 | text | Category | `text:Category` x2 |
| 186,948 | 48x13 | text | Channel | `text:Channel` x2 |
| 195,1056 | 7x7 | semantics | Online | `semantics:Online` x2 |
| 197,1084 | 41x13 | text | anonlisten | `text:anonlisten` |
| 199,1071 | 10x10 | icon | 0xf58a | `icon:0xf58a` |
| 208,0 | 239x40 | keyed |  | `key:ach-6ae8032a-5af0eb9e` |
| 208,0 | 239x40 | keyed |  | `key:[<'ach-6ae8032a-5af0eb9e'>]` |
| 210,8 | 223x36 | pressable | test3 | `text:test3` x4 |
| 213,1025 | 239x31 | keyed |  | `key:div-Offline` |
| 213,1025 | 239x31 | keyed |  | `key:[<'div-Offline'>]` |
| 218,44 | 177x20 | text | test3 | `text:test3` x4 |
| 219,18 | 18x18 | icon | volume2 (0xe1ab) | `icon:volume2` x2 |
| 221,1035 | 40x15 | text | Offline | `text:Offline` |
| 221,1247 | 7x15 | text | 3 | `text:3` |
| 229,252 | 760x42 | keyed |  | `key:[_ReorderableItemGlobalKey _ReorderableListViewChildGlobalKey#01e2b]` |
| 229,252 | 760x42 | keyed |  | `key:ch-6ae8032a-general` |
| 237,878 | 22x22 | tooltip | Restrict this channel to images, GIFs and videos only | `tooltip:Restrict this channel to images, GIFs and videos only` x3 |
| 237,878 | 22x22 | pressable | Make channel media-only, currently allows all messages | `semantics:Make channel media-only, currently allows all messages` x6 |
| 237,878 | 22x22 | semantics | Make channel media-only, currently allows all messages | `semantics:Make channel media-only, currently allows all messages` x6 |
| 237,904 | 22x22 | pressable | Make channel public, currently private | `semantics:Make channel public, currently private` x6 |
| 237,904 | 22x22 | tooltip | Publish this channel so anyone can read it without joining | `tooltip:Publish this channel so anyone can read it without joining` x3 |
| 237,904 | 22x22 | semantics | Make channel public, currently private | `semantics:Make channel public, currently private` x6 |
| 237,930 | 22x22 | tooltip | Give a member time-limited access to this channel | `tooltip:Give a member time-limited access to this channel` x4 |
| 237,930 | 22x22 | pressable | Manage temporary access for channel | `semantics:Manage temporary access for channel` x8 |
| 237,930 | 22x22 | semantics | Manage temporary access for channel | `semantics:Manage temporary access for channel` x8 |
| 237,956 | 22x22 | tooltip | Rename channel | `tooltip:Rename channel` x4 |
| 237,956 | 22x22 | semantics | Rename channel | `semantics:Rename channel` x8 |
| 237,956 | 22x22 | pressable | Rename channel | `semantics:Rename channel` x8 |
| 237,982 | 22x22 | tooltip | Delete channel | `tooltip:Delete channel` x4 |
| 237,982 | 22x22 | pressable | Delete channel | `semantics:Delete channel` x8 |
| 237,982 | 22x22 | semantics | Delete channel | `semantics:Delete channel` x8 |
| 238,308 | 420x20 | text | general | `text:general` x3 |
| 239,728 | 62x18 | tooltip | Who can see this channel | `tooltip:Who can see this channel` x4 |
| 239,794 | 37x18 | tooltip | Who can post | `tooltip:Who can post` x4 |
| 239,835 | 39x18 | tooltip | Minimum delay between each member's messages | `tooltip:Minimum delay between each member's messages` x3 |
| 240,260 | 16x16 | icon | 0xe0eb | `icon:0xe0eb` x5 |
| 240,260 | 16x16 | semantics | Drag to reorder channel | `semantics:Drag to reorder channel` x4 |
| 240,260 | 16x16 | tooltip | Drag to reorder | `tooltip:Drag to reorder` x5 |
| 240,284 | 16x16 | icon | hash (0xe0ef) | `icon:hash` x7 |
| 241,747 | 37x14 | text | Admin+ | `text:Admin+` |
| 241,813 | 12x14 | text | All | `text:All` x6 |
| 241,854 | 14x14 | text | Off | `text:Off` x3 |
| 241,882 | 14x14 | icon | image (0xe0f6) | `icon:image` x3 |
| 241,908 | 14x14 | icon | globe (0xe0e8) | `icon:globe` x4 |
| 241,934 | 14x14 | icon | userPlus (0xe1a2) | `icon:userPlus` x6 |
| 241,960 | 14x14 | icon | pencil (0xe1f9) | `icon:pencil` x6 |
| 241,986 | 14x14 | icon | trash2 (0xe18e) | `icon:trash2` x5 |
| 243,734 | 10x10 | icon | eye (0xe0ba) | `icon:eye` x3 |
| 243,800 | 10x10 | icon | messageSquare (0xe117) | `icon:messageSquare` x4 |
| 243,841 | 10x10 | icon | 0xe1e0 | `icon:0xe1e0` x3 |
| 244,1025 | 239x34 | keyed |  | `key:mem-12D3KooWKS8jL9xFsxkMgwrLGJpnSngi8KgtPRuFyNRVL4PnKh8C` |
| 244,1025 | 239x34 | pressable | 12 | `text:12` x10 |
| 244,1025 | 239x34 | keyed |  | `key:[<'mem-12D3KooWKS8jL9xFsxkMgwrLGJpnSngi8KgtPRuFyNRVL4PnKh8C'>]` |
| 253,1071 | 29x17 | text | vm22 | `text:vm22` |
| 254,1044 | 10x15 | text | 12 | `text:12` x10 |
| 260,10 | 221x15 | pressable | 233 | `text:233` x3 |
| 260,24 | 207x15 | text | 233 | `text:233` x3 |
| 263,10 | 10x10 | icon | chevronDown (0xe06d) | `icon:chevronDown` |
| 268,1056 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 271,252 | 760x42 | keyed |  | `key:ch-6ae8032a-3f35dfa2` |
| 271,252 | 760x42 | keyed |  | `key:[_ReorderableItemGlobalKey _ReorderableListViewChildGlobalKey#34106]` |
| 278,1025 | 239x34 | keyed |  | `key:[<'mem-12D3KooWF5kuBjyDMSzFviHHvdtS6uaZTqq57pA9ik2PAnffNXdk'>]` |
| 278,1025 | 239x34 | keyed |  | `key:mem-12D3KooWF5kuBjyDMSzFviHHvdtS6uaZTqq57pA9ik2PAnffNXdk` |
| 278,1025 | 239x34 | pressable | virtual bro | `text:virtual bro` x4 |
| 279,0 | 239x40 | keyed |  | `key:ach-6ae8032a-75134eee` |
| 279,0 | 239x40 | keyed |  | `key:[<'ach-6ae8032a-75134eee'>]` |
| 279,878 | 22x22 | pressable | Make channel media-only, currently allows all messages | `semantics:Make channel media-only, currently allows all messages` x6 |
| 279,878 | 22x22 | semantics | Make channel media-only, currently allows all messages | `semantics:Make channel media-only, currently allows all messages` x6 |
| 279,878 | 22x22 | tooltip | Restrict this channel to images, GIFs and videos only | `tooltip:Restrict this channel to images, GIFs and videos only` x3 |
| 279,904 | 22x22 | pressable | Make channel public, currently private | `semantics:Make channel public, currently private` x6 |
| 279,904 | 22x22 | tooltip | Publish this channel so anyone can read it without joining | `tooltip:Publish this channel so anyone can read it without joining` x3 |
| 279,904 | 22x22 | semantics | Make channel public, currently private | `semantics:Make channel public, currently private` x6 |
| 279,930 | 22x22 | tooltip | Give a member time-limited access to this channel | `tooltip:Give a member time-limited access to this channel` x4 |
| 279,930 | 22x22 | pressable | Manage temporary access for channel | `semantics:Manage temporary access for channel` x8 |
| 279,930 | 22x22 | semantics | Manage temporary access for channel | `semantics:Manage temporary access for channel` x8 |
| 279,956 | 22x22 | tooltip | Rename channel | `tooltip:Rename channel` x4 |
| 279,956 | 22x22 | pressable | Rename channel | `semantics:Rename channel` x8 |
| 279,956 | 22x22 | semantics | Rename channel | `semantics:Rename channel` x8 |
| 279,982 | 22x22 | tooltip | Delete channel | `tooltip:Delete channel` x4 |
| 279,982 | 22x22 | pressable | Delete channel | `semantics:Delete channel` x8 |
| 279,982 | 22x22 | semantics | Delete channel | `semantics:Delete channel` x8 |
| 280,308 | 441x20 | text | test | `text:test` x3 |
| 281,8 | 223x36 | pressable | 23 | `text:23` x3 |
| 281,749 | 40x18 | tooltip | Who can see this channel | `tooltip:Who can see this channel` x4 |
| 281,794 | 37x18 | tooltip | Who can post | `tooltip:Who can post` x4 |
| 281,835 | 39x18 | tooltip | Minimum delay between each member's messages | `tooltip:Minimum delay between each member's messages` x3 |
| 282,260 | 16x16 | icon | 0xe0eb | `icon:0xe0eb` x5 |
| 282,260 | 16x16 | semantics | Drag to reorder channel | `semantics:Drag to reorder channel` x4 |
| 282,260 | 16x16 | tooltip | Drag to reorder | `tooltip:Drag to reorder` x5 |
| 282,284 | 16x16 | icon | hash (0xe0ef) | `icon:hash` x7 |
| 283,768 | 15x14 | text | 123 | `text:123` |
| 283,813 | 12x14 | text | All | `text:All` x6 |
| 283,854 | 14x14 | text | Off | `text:Off` x3 |
| 283,882 | 14x14 | icon | image (0xe0f6) | `icon:image` x3 |
| 283,908 | 14x14 | icon | globe (0xe0e8) | `icon:globe` x4 |
| 283,934 | 14x14 | icon | userPlus (0xe1a2) | `icon:userPlus` x6 |
| 283,960 | 14x14 | icon | pencil (0xe1f9) | `icon:pencil` x6 |
| 283,986 | 14x14 | icon | trash2 (0xe18e) | `icon:trash2` x5 |
| 285,755 | 10x10 | icon | shieldCheck (0xe1ff) | `icon:shieldCheck` x2 |
| 285,800 | 10x10 | icon | messageSquare (0xe117) | `icon:messageSquare` x4 |
| 285,841 | 10x10 | icon | 0xe1e0 | `icon:0xe1e0` x3 |
| 287,1071 | 54x17 | text | virtual bro | `text:virtual bro` x4 |
| 289,44 | 177x20 | text | 23 | `text:23` x3 |
| 290,18 | 18x18 | icon | hash (0xe0ef) | `icon:hash` x7 |
| 302,1056 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 312,1025 | 239x34 | pressable | 12 | `text:12` x10 |
| 312,1025 | 239x34 | keyed |  | `key:mem-12D3KooWLyj5mKdcjKWKRCtJni4bPD7dKiU5SEWMDNWQNNbfdhAL` |
| 312,1025 | 239x34 | keyed |  | `key:[<'mem-12D3KooWLyj5mKdcjKWKRCtJni4bPD7dKiU5SEWMDNWQNNbfdhAL'>]` |
| 313,252 | 760x42 | keyed |  | `key:ch-6ae8032a-5af0eb9e` |
| 313,252 | 760x42 | keyed |  | `key:[_ReorderableItemGlobalKey _ReorderableListViewChildGlobalKey#c94d1]` |
| 321,930 | 22x22 | tooltip | Give a member time-limited access to this channel | `tooltip:Give a member time-limited access to this channel` x4 |
| 321,930 | 22x22 | semantics | Manage temporary access for channel | `semantics:Manage temporary access for channel` x8 |
| 321,930 | 22x22 | pressable | Manage temporary access for channel | `semantics:Manage temporary access for channel` x8 |
| 321,956 | 22x22 | semantics | Rename channel | `semantics:Rename channel` x8 |
| 321,956 | 22x22 | pressable | Rename channel | `semantics:Rename channel` x8 |
| 321,956 | 22x22 | tooltip | Rename channel | `tooltip:Rename channel` x4 |
| 321,982 | 22x22 | semantics | Delete channel | `semantics:Delete channel` x8 |
| 321,982 | 22x22 | pressable | Delete channel | `semantics:Delete channel` x8 |
| 321,982 | 22x22 | tooltip | Delete channel | `tooltip:Delete channel` x4 |
| 321,1071 | 79x17 | text | iPhone 13 mini | `text:iPhone 13 mini` x2 |
| 322,308 | 540x20 | text | test3 | `text:test3` x4 |
| 322,1044 | 10x15 | text | 12 | `text:12` x10 |
| 323,848 | 37x18 | tooltip | Who can see this channel | `tooltip:Who can see this channel` x4 |
| 323,889 | 37x18 | tooltip | Who can post | `tooltip:Who can post` x4 |
| 324,260 | 16x16 | tooltip | Drag to reorder | `tooltip:Drag to reorder` x5 |
| 324,260 | 16x16 | icon | 0xe0eb | `icon:0xe0eb` x5 |
| 324,260 | 16x16 | semantics | Drag to reorder channel | `semantics:Drag to reorder channel` x4 |
| 324,284 | 16x16 | icon | volume2 (0xe1ab) | `icon:volume2` x2 |
| 325,867 | 12x14 | text | All | `text:All` x6 |
| 325,908 | 12x14 | text | All | `text:All` x6 |
| 325,934 | 14x14 | icon | userPlus (0xe1a2) | `icon:userPlus` x6 |
| 325,960 | 14x14 | icon | pencil (0xe1f9) | `icon:pencil` x6 |
| 325,986 | 14x14 | icon | trash2 (0xe18e) | `icon:trash2` x5 |
| 327,854 | 10x10 | icon | eye (0xe0ba) | `icon:eye` x3 |
| 327,895 | 10x10 | icon | messageSquare (0xe117) | `icon:messageSquare` x4 |
| 336,1056 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 355,252 | 760x44 | keyed |  | `key:cat-3-233` |
| 355,252 | 760x44 | keyed |  | `key:[_ReorderableItemGlobalKey _ReorderableListViewChildGlobalKey#bd3ca]` |
| 364,929 | 22x22 | tooltip | Apply access to all channels | `tooltip:Apply access to all channels` |
| 364,929 | 22x22 | pressable | Apply access settings to all channels in category | `semantics:Apply access settings to all channels in category` x2 |
| 364,929 | 22x22 | semantics | Apply access settings to all channels in category | `semantics:Apply access settings to all channels in category` x2 |
| 364,955 | 22x22 | semantics | Rename category | `semantics:Rename category` x2 |
| 364,955 | 22x22 | tooltip | Rename category | `tooltip:Rename category` |
| 364,955 | 22x22 | pressable | Rename category | `semantics:Rename category` x2 |
| 364,981 | 22x22 | pressable | Delete category | `semantics:Delete category` x2 |
| 364,981 | 22x22 | semantics | Delete category | `semantics:Delete category` x2 |
| 364,981 | 22x22 | tooltip | Delete category | `tooltip:Delete category` |
| 367,261 | 16x16 | icon | 0xe0eb | `icon:0xe0eb` x5 |
| 367,261 | 16x16 | semantics | Drag to reorder category | `semantics:Drag to reorder category` |
| 367,261 | 16x16 | tooltip | Drag to reorder | `tooltip:Drag to reorder` x5 |
| 367,285 | 16x16 | icon | folder (0xe0d7) | `icon:folder` |
| 368,309 | 620x15 | text | 233 | `text:233` x3 |
| 368,933 | 14x14 | icon | shieldCheck (0xe1ff) | `icon:shieldCheck` x2 |
| 368,959 | 14x14 | icon | pencil (0xe1f9) | `icon:pencil` x6 |
| 368,985 | 14x14 | icon | trash2 (0xe18e) | `icon:trash2` x5 |
| 399,252 | 760x42 | keyed |  | `key:ch-6ae8032a-75134eee` |
| 399,252 | 760x42 | keyed |  | `key:[_ReorderableItemGlobalKey _ReorderableListViewChildGlobalKey#4a202]` |
| 407,878 | 22x22 | tooltip | Restrict this channel to images, GIFs and videos only | `tooltip:Restrict this channel to images, GIFs and videos only` x3 |
| 407,878 | 22x22 | pressable | Make channel media-only, currently allows all messages | `semantics:Make channel media-only, currently allows all messages` x6 |
| 407,878 | 22x22 | semantics | Make channel media-only, currently allows all messages | `semantics:Make channel media-only, currently allows all messages` x6 |
| 407,904 | 22x22 | pressable | Make channel public, currently private | `semantics:Make channel public, currently private` x6 |
| 407,904 | 22x22 | tooltip | Publish this channel so anyone can read it without joining | `tooltip:Publish this channel so anyone can read it without joining` x3 |
| 407,904 | 22x22 | semantics | Make channel public, currently private | `semantics:Make channel public, currently private` x6 |
| 407,930 | 22x22 | tooltip | Give a member time-limited access to this channel | `tooltip:Give a member time-limited access to this channel` x4 |
| 407,930 | 22x22 | pressable | Manage temporary access for channel | `semantics:Manage temporary access for channel` x8 |
| 407,930 | 22x22 | semantics | Manage temporary access for channel | `semantics:Manage temporary access for channel` x8 |
| 407,956 | 22x22 | semantics | Rename channel | `semantics:Rename channel` x8 |
| 407,956 | 22x22 | tooltip | Rename channel | `tooltip:Rename channel` x4 |
| 407,956 | 22x22 | pressable | Rename channel | `semantics:Rename channel` x8 |
| 407,982 | 22x22 | semantics | Delete channel | `semantics:Delete channel` x8 |
| 407,982 | 22x22 | pressable | Delete channel | `semantics:Delete channel` x8 |
| 407,982 | 22x22 | tooltip | Delete channel | `tooltip:Delete channel` x4 |
| 408,340 | 413x20 | text | 23 | `text:23` x3 |
| 409,753 | 37x18 | tooltip | Who can see this channel | `tooltip:Who can see this channel` x4 |
| 409,794 | 37x18 | tooltip | Who can post | `tooltip:Who can post` x4 |
| 409,835 | 39x18 | tooltip | Minimum delay between each member's messages | `tooltip:Minimum delay between each member's messages` x3 |
| 410,292 | 16x16 | icon | 0xe0eb | `icon:0xe0eb` x5 |
| 410,292 | 16x16 | tooltip | Drag to reorder | `tooltip:Drag to reorder` x5 |
| 410,292 | 16x16 | semantics | Drag to reorder channel | `semantics:Drag to reorder channel` x4 |
| 410,316 | 16x16 | icon | hash (0xe0ef) | `icon:hash` x7 |
| 411,772 | 12x14 | text | All | `text:All` x6 |
| 411,813 | 12x14 | text | All | `text:All` x6 |
| 411,854 | 14x14 | text | Off | `text:Off` x3 |
| 411,882 | 14x14 | icon | image (0xe0f6) | `icon:image` x3 |
| 411,908 | 14x14 | icon | globe (0xe0e8) | `icon:globe` x4 |
| 411,934 | 14x14 | icon | userPlus (0xe1a2) | `icon:userPlus` x6 |
| 411,960 | 14x14 | icon | pencil (0xe1f9) | `icon:pencil` x6 |
| 411,986 | 14x14 | icon | trash2 (0xe18e) | `icon:trash2` x5 |
| 413,759 | 10x10 | icon | eye (0xe0ba) | `icon:eye` x3 |
| 413,800 | 10x10 | icon | messageSquare (0xe117) | `icon:messageSquare` x4 |
| 413,841 | 10x10 | icon | 0xe1e0 | `icon:0xe1e0` x3 |
| 632,182 | 5x8 | text | 7 | `text:7` |
| 633,149 | 38x38 | semantics | Home | `semantics:Home` |
| 633,149 | 38x38 | tooltip | Home | `tooltip:Home` |
| 633,493 | 38x38 | keyed |  | `key:bounce-1a88f45832c2a648a914fc259f602a12` |
| 633,493 | 38x38 | semantics | testing | `semantics:testing` |
| 633,493 | 38x38 | tooltip | testing | `tooltip:testing` |
| 633,535 | 38x38 | keyed |  | `key:bounce-8f3d5c37a26835ddf04b07f2c91da556` |
| 633,535 | 38x38 | semantics | another one! | `semantics:another one!` |
| 633,535 | 38x38 | tooltip | another one! | `tooltip:another one!` |
| 633,577 | 38x38 | keyed |  | `key:bounce-b7d2030be50e7bd8708c4364102c4029` |
| 633,577 | 38x38 | semantics | MyEpicServer | `semantics:MyEpicServer` |
| 633,577 | 38x38 | tooltip | MyEpicServer | `tooltip:MyEpicServer` |
| 633,619 | 38x38 | semantics | qww | `semantics:qww` |
| 633,619 | 38x38 | tooltip | qww | `tooltip:qww` |
| 633,619 | 38x38 | keyed |  | `key:bounce-703162ad1c1dd3f77a506828f71c5f8d` |
| 633,661 | 38x38 | tooltip | test | `tooltip:test` |
| 633,661 | 38x38 | semantics | test | `semantics:test` |
| 633,661 | 38x38 | keyed |  | `key:bounce-6ec23029e3003347d7cdd73988293dd7` |
| 633,703 | 38x38 | tooltip | test3 | `tooltip:test3` |
| 633,703 | 38x38 | keyed |  | `key:bounce-6ae8032accaad737890ca2d4f9e97752` |
| 633,703 | 38x38 | semantics | test3 | `semantics:test3` |
| 633,1047 | 38x38 | semantics | Create a server | `semantics:Create a server` |
| 633,1047 | 38x38 | tooltip | Create a server | `tooltip:Create a server` |
| 638,0 | 140x28 | tooltip | Online | `tooltip:Online` |
| 638,0 | 140x28 | pressable | AnonListen | `text:AnonListen` x4 |
| 639,1114 | 26x26 | tooltip | Browse Public Channels | `tooltip:Browse Public Channels` |
| 639,1114 | 26x26 | pressable | Browse public channels | `semantics:Browse public channels` x2 |
| 639,1114 | 26x26 | semantics | Browse public channels | `semantics:Browse public channels` x2 |
| 639,1140 | 26x26 | tooltip | Share | `tooltip:Share` |
| 639,1140 | 26x26 | pressable | Share | `semantics:Share` x2 |
| 639,1140 | 26x26 | semantics | Share | `semantics:Share` x2 |
| 639,1166 | 26x26 | tooltip | Archive | `tooltip:Archive` |
| 639,1166 | 26x26 | pressable | Archive | `semantics:Archive` x2 |
| 639,1166 | 26x26 | semantics | Archive | `semantics:Archive` x2 |
| 639,1192 | 26x26 | tooltip | Downloads | `tooltip:Downloads` |
| 639,1192 | 26x26 | pressable | Downloads | `semantics:Downloads` x2 |
| 639,1192 | 26x26 | semantics | Downloads | `semantics:Downloads` x2 |
| 639,1218 | 26x26 | tooltip | Settings | `tooltip:Settings` |
| 639,1218 | 26x26 | pressable | Settings | `semantics:Settings` x2 |
| 639,1218 | 26x26 | semantics | Settings | `semantics:Settings` x2 |
| 640,161 | 14x25 | text | H | `text:H` |
| 642,585 | 21x20 | text | MY | `text:MY` |
| 642,673 | 15x20 | text | TE | `text:TE` x2 |
| 642,715 | 15x20 | text | TE | `text:TE` x2 |
| 643,1057 | 18x18 | icon | plus (0xe13d) | `icon:plus` x2 |
| 643,1118 | 18x18 | icon | globe (0xe0e8) | `icon:globe` x4 |
| 643,1144 | 18x18 | icon | 0xe156 | `icon:0xe156` |
| 643,1170 | 18x18 | icon | 0xe041 | `icon:0xe041` |
| 643,1196 | 18x18 | icon | download (0xe0b2) | `icon:download` |
| 643,1222 | 18x18 | icon | settings (0xe154) | `icon:settings` x3 |
| 644,59 | 69x17 | text | AnonListen | `text:AnonListen` x4 |
| 649,48 | 7x7 | semantics | Online | `semantics:Online` x2 |

---

## UI map: 07-members

Screen 1264.0 x 681.0 logical pixels. 243 entries.

### Open surfaces

- dialog open: false
- context menu open: false

### Providers

- server: test3 (6ae8032accaad737890ca2d4f9e97752)
- channel: general (6ae8032a-general)
- layout mode: LayoutMode.dock

#### Stored layout

```
[0] general (text, 6ae8032a-general)
[1] test (text, 6ae8032a-3f35dfa2)
[2] test3 (voice, 6ae8032a-5af0eb9e)
[3] CATEGORY "233"
    [4] 23 (text, 6ae8032a-75134eee)
```

### On screen

`y,x` is the top-left corner. Paste a target straight into a scenario; `xN` means the target matches N widgets, so scope it (`dialog > ...`) or pass an index.

| y,x | size | kind | label | target |
|---|---|---|---|---|
| 0,1126 | 46x32 | semantics | Minimize | `semantics:Minimize` |
| 0,1172 | 46x32 | semantics | Maximize | `semantics:Maximize` |
| 0,1218 | 46x32 | semantics | Close | `semantics:Close` x3 |
| 7,16 | 44x18 | text | Hollow | `text:Hollow` |
| 7,1090 | 32x18 | icon | pencil (0xe1f9) | `icon:pencil` |
| 8,1141 | 16x16 | icon | 0xe11c | `icon:0xe11c` |
| 8,1233 | 16x16 | icon | x (0xe1b2) | `icon:x` x2 |
| 9,1188 | 14x14 | icon | 0xe167 | `icon:0xe167` |
| 32,0 | 1264x649 | keyed |  | `key:_ScaffoldSlot.body` |
| 32,66 | 81x43 | pressable | 12 | `text:12` x12 |
| 32,66 | 81x43 | tooltip | MacOS | `tooltip:MacOS` |
| 32,153 | 68x43 | pressable | Pixel | `text:Pixel` x2 |
| 32,153 | 68x43 | tooltip | Pixel | `tooltip:Pixel` |
| 32,227 | 118x43 | tooltip | iPhone 13 mini | `tooltip:iPhone 13 mini` |
| 32,227 | 118x43 | pressable | 12 | `text:12` x12 |
| 32,351 | 92x43 | tooltip | UbuLinux | `tooltip:UbuLinux` |
| 32,351 | 92x43 | pressable | 12 | `text:12` x12 |
| 32,449 | 96x43 | pressable | virtual bro | `text:virtual bro` x5 |
| 32,449 | 96x43 | tooltip | virtual bro | `tooltip:virtual bro` |
| 41,8 | 34x26 | tooltip | Add Friend | `tooltip:Add Friend` |
| 41,8 | 34x26 | pressable | Add friend | `semantics:Add friend` x2 |
| 41,8 | 34x26 | semantics | Add friend | `semantics:Add friend` x2 |
| 41,1146 | 34x26 | tooltip | Saved messages | `tooltip:Saved messages` |
| 41,1146 | 34x26 | pressable | Saved messages | `semantics:Saved messages` x2 |
| 41,1146 | 34x26 | semantics | Saved messages | `semantics:Saved messages` x2 |
| 41,1184 | 34x26 | pressable | Conferences | `semantics:Conferences` x2 |
| 41,1184 | 34x26 | tooltip | Conferences | `tooltip:Conferences` |
| 41,1184 | 34x26 | semantics | Conferences | `semantics:Conferences` x2 |
| 41,1222 | 34x26 | tooltip | Help | `tooltip:Help` |
| 41,1222 | 34x26 | pressable | Help | `semantics:Help` x2 |
| 41,1222 | 34x26 | semantics | Help | `semantics:Help` x2 |
| 45,16 | 18x18 | icon | userPlus (0xe1a2) | `icon:userPlus` x2 |
| 45,1154 | 18x18 | icon | 0xe060 | `icon:0xe060` |
| 45,1192 | 18x18 | icon | video (0xe1a5) | `icon:video` |
| 45,1230 | 18x18 | icon | 0xe082 | `icon:0xe082` |
| 46,104 | 35x15 | text | MacOS | `text:MacOS` |
| 46,191 | 22x15 | text | Pixel | `text:Pixel` x2 |
| 46,265 | 72x15 | text | iPhone 13 mini | `text:iPhone 13 mini` x3 |
| 46,389 | 46x15 | text | UbuLinux | `text:UbuLinux` |
| 46,487 | 50x15 | text | virtual bro | `text:virtual bro` x5 |
| 47,82 | 9x13 | text | 12 | `text:12` x12 |
| 47,243 | 9x13 | text | 12 | `text:12` x12 |
| 47,367 | 9x13 | text | 12 | `text:12` x12 |
| 59,92 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 59,178 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 59,252 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 59,376 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 59,474 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 76,0 | 239x48 | keyed |  | `key:[<null>]` |
| 76,0 | 239x48 | keyed |  | `key:null` |
| 76,0 | 239x48 | keyed |  | `key:header-test3` |
| 76,240 | 784x546 | keyed |  | `key:[<'settings-6ae8032accaad737890ca2d4f9e97752'>]` |
| 76,240 | 784x546 | keyed |  | `key:settings-6ae8032accaad737890ca2d4f9e97752` |
| 76,240 | 784x546 | keyed |  | `key:[<[<'settings-6ae8032accaad737890ca2d4f9e97752'>]>]` |
| 76,240 | 784x546 | keyed |  | `key:single-settings-6ae8032accaad737890ca2d4f9e97752` |
| 76,240 | 784x546 | keyed |  | `key:[<'single-settings-6ae8032accaad737890ca2d4f9e97752'>]` |
| 76,240 | 784x546 | keyed |  | `key:[<[<'single-settings-6ae8032accaad737890ca2d4f9e97752'>]>]` |
| 76,1025 | 239x546 | keyed |  | `key:[<'server-members-6ae8032accaad737890ca2d4f9e97752'>]` |
| 76,1025 | 239x546 | keyed |  | `key:server-members-6ae8032accaad737890ca2d4f9e97752` |
| 76,1025 | 239x546 | keyed |  | `key:[<[<'server-members-6ae8032accaad737890ca2d4f9e97752'>]>]` |
| 87,982 | 26x26 | semantics | Close | `semantics:Close` x3 |
| 87,982 | 26x26 | pressable | Close | `semantics:Close` x3 |
| 88,159 | 24x24 | tooltip | Invite people | `tooltip:Invite people` |
| 88,159 | 24x24 | pressable | Invite people | `semantics:Invite people` x2 |
| 88,159 | 24x24 | semantics | Invite people | `semantics:Invite people` x2 |
| 88,183 | 24x24 | tooltip | Storage | `tooltip:Storage` |
| 88,183 | 24x24 | pressable | Storage | `semantics:Storage` x2 |
| 88,183 | 24x24 | semantics | Storage | `semantics:Storage` x2 |
| 88,207 | 24x24 | tooltip | Server settings | `tooltip:Server settings` |
| 88,207 | 24x24 | pressable | Server settings | `semantics:Server settings` x2 |
| 88,207 | 24x24 | semantics | Server settings | `semantics:Server settings` x2 |
| 89,16 | 143x22 | text | test3 | `text:test3` x3 |
| 89,282 | 700x22 | text | Server Settings: test3 | `text:Server Settings: test3` |
| 91,256 | 18x18 | icon | settings (0xe154) | `icon:settings` x3 |
| 91,986 | 18x18 | icon | x (0xe1b2) | `icon:x` x2 |
| 92,163 | 16x16 | icon | userPlus (0xe1a2) | `icon:userPlus` x2 |
| 92,187 | 16x16 | icon | hardDrive (0xe0ed) | `icon:hardDrive` |
| 92,211 | 16x16 | icon | settings (0xe154) | `icon:settings` x3 |
| 92,1035 | 53x15 | text | Members | `text:Members` x3 |
| 92,1247 | 7x15 | text | 4 | `text:4` |
| 124,0 | 239x498 | keyed |  | `key:server-6ae8032accaad737890ca2d4f9e97752` |
| 124,0 | 239x498 | keyed |  | `key:[<'server-6ae8032accaad737890ca2d4f9e97752'>]` |
| 124,0 | 239x498 | keyed |  | `key:[<[<'server-6ae8032accaad737890ca2d4f9e97752'>]>]` |
| 127,252 | 95x34 | pressable | Overview | `text:Overview` x2 |
| 127,347 | 94x34 | pressable | Channels | `text:Channels` x2 |
| 127,441 | 72x34 | pressable | Roles | `text:Roles` x2 |
| 127,514 | 78x34 | pressable | Labels | `text:Labels` x2 |
| 127,591 | 84x34 | pressable | Emotes | `text:Emotes` x2 |
| 127,676 | 98x34 | pressable | Members | `text:Members` x3 |
| 127,773 | 115x34 | pressable | Notifications | `text:Notifications` x2 |
| 127,888 | 84x34 | pressable | Danger | `text:Danger` x2 |
| 128,0 | 239x40 | keyed |  | `key:ach-6ae8032a-general` |
| 128,0 | 239x40 | keyed |  | `key:[<'ach-6ae8032a-general'>]` |
| 130,8 | 223x36 | pressable | general | `text:general` x2 |
| 132,1025 | 239x31 | keyed |  | `key:div-Owner` |
| 132,1025 | 239x31 | keyed |  | `key:[<'div-Owner'>]` |
| 135,282 | 53x18 | text | Overview | `text:Overview` x2 |
| 135,377 | 52x18 | text | Channels | `text:Channels` x2 |
| 135,471 | 30x18 | text | Roles | `text:Roles` x2 |
| 135,544 | 36x18 | text | Labels | `text:Labels` x2 |
| 135,621 | 42x18 | text | Emotes | `text:Emotes` x2 |
| 135,706 | 56x18 | text | Members | `text:Members` x3 |
| 135,803 | 73x18 | text | Notifications | `text:Notifications` x2 |
| 135,918 | 42x18 | text | Danger | `text:Danger` x2 |
| 137,264 | 14x14 | icon | 0xe0f9 | `icon:0xe0f9` |
| 137,359 | 14x14 | icon | hash (0xe0ef) | `icon:hash` x4 |
| 137,453 | 14x14 | icon | shield (0xe158) | `icon:shield` |
| 137,526 | 14x14 | icon | tag (0xe17f) | `icon:tag` |
| 137,603 | 14x14 | icon | smile (0xe164) | `icon:smile` |
| 137,688 | 14x14 | icon | users (0xe1a4) | `icon:users` |
| 137,785 | 14x14 | icon | bell (0xe059) | `icon:bell` |
| 137,900 | 14x14 | icon | alertTriangle (0xe193) | `icon:alertTriangle` |
| 138,44 | 177x20 | text | general | `text:general` x2 |
| 139,18 | 18x18 | icon | hash (0xe0ef) | `icon:hash` x4 |
| 140,1035 | 37x15 | text | Owner | `text:Owner` x3 |
| 140,1249 | 5x15 | text | 1 | `text:1` |
| 163,1025 | 239x50 | keyed |  | `key:[<'mem-12D3KooWJJU9fygVAYVJqVM4FAtTyaUBHSsfRkuavwY53nT7iS4F'>]` |
| 163,1025 | 239x50 | pressable | AnonListen | `text:AnonListen` x5 |
| 163,1025 | 239x50 | keyed |  | `key:mem-12D3KooWJJU9fygVAYVJqVM4FAtTyaUBHSsfRkuavwY53nT7iS4F` |
| 164,240 | 784x458 | keyed |  | `key:[<[<'members'>]>]` |
| 164,240 | 784x458 | keyed |  | `key:[<'members'>]` |
| 164,240 | 784x458 | keyed |  | `key:members` |
| 166,1071 | 59x17 | text | AnonListen | `text:AnonListen` x5 |
| 168,0 | 239x40 | keyed |  | `key:ach-6ae8032a-3f35dfa2` |
| 168,0 | 239x40 | keyed |  | `key:[<'ach-6ae8032a-3f35dfa2'>]` |
| 170,8 | 223x36 | pressable | test | `text:test` x2 |
| 178,44 | 177x20 | text | test | `text:test` x2 |
| 179,18 | 18x18 | icon | hash (0xe0ef) | `icon:hash` x4 |
| 183,1071 | 29x14 | text | Owner | `text:Owner` x3 |
| 188,312 | 69x20 | text | AnonListen | `text:AnonListen` x5 |
| 191,385 | 24x15 | text | (you) | `text:(you)` |
| 195,1056 | 7x7 | semantics | Online | `semantics:Online` x2 |
| 197,1084 | 41x13 | text | anonlisten | `text:anonlisten` |
| 198,955 | 33x15 | text | Owner | `text:Owner` x3 |
| 199,1071 | 10x10 | icon | 0xf58a | `icon:0xf58a` |
| 200,939 | 12x12 | icon | 0xe1d6 | `icon:0xe1d6` |
| 208,0 | 239x40 | keyed |  | `key:[<'ach-6ae8032a-5af0eb9e'>]` |
| 208,0 | 239x40 | keyed |  | `key:ach-6ae8032a-5af0eb9e` |
| 208,312 | 309x15 | text | 12D3KooWJJU9fygVAYVJqVM4FAtTyaUBHSsfRkuavwY53nT7iS4F | `text:12D3KooWJJU9fygVAYVJqVM4FAtTyaUBHSsfRkuavwY53nT7iS4F` |
| 210,8 | 223x36 | pressable | test3 | `text:test3` x3 |
| 213,1025 | 239x31 | keyed |  | `key:div-Offline` |
| 213,1025 | 239x31 | keyed |  | `key:[<'div-Offline'>]` |
| 218,44 | 177x20 | text | test3 | `text:test3` x3 |
| 219,18 | 18x18 | icon | volume2 (0xe1ab) | `icon:volume2` |
| 221,1035 | 40x15 | text | Offline | `text:Offline` |
| 221,1247 | 7x15 | text | 3 | `text:3` |
| 244,1025 | 239x34 | pressable | 12 | `text:12` x12 |
| 244,1025 | 239x34 | keyed |  | `key:[<'mem-12D3KooWKS8jL9xFsxkMgwrLGJpnSngi8KgtPRuFyNRVL4PnKh8C'>]` |
| 244,1025 | 239x34 | keyed |  | `key:mem-12D3KooWKS8jL9xFsxkMgwrLGJpnSngi8KgtPRuFyNRVL4PnKh8C` |
| 247,956 | 40x40 | keyed |  | `key:StandardComponentType.moreButton` x3 |
| 250,312 | 34x20 | text | vm22 | `text:vm22` x2 |
| 253,1071 | 29x17 | text | vm22 | `text:vm22` x2 |
| 254,1044 | 10x15 | text | 12 | `text:12` x12 |
| 259,278 | 12x17 | text | 12 | `text:12` x12 |
| 259,968 | 16x16 | icon | 0xe0b7 | `icon:0xe0b7` x3 |
| 260,10 | 221x15 | pressable | 233 | `text:233` x2 |
| 260,24 | 207x15 | text | 233 | `text:233` x2 |
| 260,902 | 42x15 | text | Member | `text:Member` x3 |
| 261,886 | 12x12 | icon | user (0xe19f) | `icon:user` x3 |
| 263,10 | 10x10 | icon | chevronDown (0xe06d) | `icon:chevronDown` |
| 268,1056 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 270,312 | 313x15 | text | 12D3KooWKS8jL9xFsxkMgwrLGJpnSngi8KgtPRuFyNRVL4PnKh8C | `text:12D3KooWKS8jL9xFsxkMgwrLGJpnSngi8KgtPRuFyNRVL4PnKh8C` |
| 278,1025 | 239x34 | keyed |  | `key:[<'mem-12D3KooWF5kuBjyDMSzFviHHvdtS6uaZTqq57pA9ik2PAnffNXdk'>]` |
| 278,1025 | 239x34 | keyed |  | `key:mem-12D3KooWF5kuBjyDMSzFviHHvdtS6uaZTqq57pA9ik2PAnffNXdk` |
| 278,1025 | 239x34 | pressable | virtual bro | `text:virtual bro` x5 |
| 279,0 | 239x40 | keyed |  | `key:ach-6ae8032a-75134eee` |
| 279,0 | 239x40 | keyed |  | `key:[<'ach-6ae8032a-75134eee'>]` |
| 281,8 | 223x36 | pressable | 23 | `text:23` x2 |
| 287,1071 | 54x17 | text | virtual bro | `text:virtual bro` x5 |
| 289,44 | 177x20 | text | 23 | `text:23` x2 |
| 290,18 | 18x18 | icon | hash (0xe0ef) | `icon:hash` x4 |
| 302,1056 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 311,956 | 40x40 | keyed |  | `key:StandardComponentType.moreButton` x3 |
| 312,1025 | 239x34 | keyed |  | `key:[<'mem-12D3KooWLyj5mKdcjKWKRCtJni4bPD7dKiU5SEWMDNWQNNbfdhAL'>]` |
| 312,1025 | 239x34 | keyed |  | `key:mem-12D3KooWLyj5mKdcjKWKRCtJni4bPD7dKiU5SEWMDNWQNNbfdhAL` |
| 312,1025 | 239x34 | pressable | 12 | `text:12` x12 |
| 314,312 | 63x20 | text | virtual bro | `text:virtual bro` x5 |
| 321,1071 | 79x17 | text | iPhone 13 mini | `text:iPhone 13 mini` x3 |
| 322,1044 | 10x15 | text | 12 | `text:12` x12 |
| 323,968 | 16x16 | icon | 0xe0b7 | `icon:0xe0b7` x3 |
| 324,902 | 42x15 | text | Member | `text:Member` x3 |
| 325,886 | 12x12 | icon | user (0xe19f) | `icon:user` x3 |
| 334,312 | 310x15 | text | 12D3KooWF5kuBjyDMSzFviHHvdtS6uaZTqq57pA9ik2PAnffNXdk | `text:12D3KooWF5kuBjyDMSzFviHHvdtS6uaZTqq57pA9ik2PAnffNXdk` |
| 336,1056 | 7x7 | semantics | Offline | `semantics:Offline` x8 |
| 375,956 | 40x40 | keyed |  | `key:StandardComponentType.moreButton` x3 |
| 378,312 | 92x20 | text | iPhone 13 mini | `text:iPhone 13 mini` x3 |
| 387,278 | 12x17 | text | 12 | `text:12` x12 |
| 387,968 | 16x16 | icon | 0xe0b7 | `icon:0xe0b7` x3 |
| 388,902 | 42x15 | text | Member | `text:Member` x3 |
| 389,886 | 12x12 | icon | user (0xe19f) | `icon:user` x3 |
| 398,312 | 335x15 | text | 12D3KooWLyj5mKdcjKWKRCtJni4bPD7dKiU5SEWMDNWQNNbfdhAL | `text:12D3KooWLyj5mKdcjKWKRCtJni4bPD7dKiU5SEWMDNWQNNbfdhAL` |
| 632,182 | 5x8 | text | 7 | `text:7` |
| 633,149 | 38x38 | semantics | Home | `semantics:Home` |
| 633,149 | 38x38 | tooltip | Home | `tooltip:Home` |
| 633,493 | 38x38 | keyed |  | `key:bounce-1a88f45832c2a648a914fc259f602a12` |
| 633,493 | 38x38 | semantics | testing | `semantics:testing` |
| 633,493 | 38x38 | tooltip | testing | `tooltip:testing` |
| 633,535 | 38x38 | tooltip | another one! | `tooltip:another one!` |
| 633,535 | 38x38 | semantics | another one! | `semantics:another one!` |
| 633,535 | 38x38 | keyed |  | `key:bounce-8f3d5c37a26835ddf04b07f2c91da556` |
| 633,577 | 38x38 | semantics | MyEpicServer | `semantics:MyEpicServer` |
| 633,577 | 38x38 | keyed |  | `key:bounce-b7d2030be50e7bd8708c4364102c4029` |
| 633,577 | 38x38 | tooltip | MyEpicServer | `tooltip:MyEpicServer` |
| 633,619 | 38x38 | keyed |  | `key:bounce-703162ad1c1dd3f77a506828f71c5f8d` |
| 633,619 | 38x38 | semantics | qww | `semantics:qww` |
| 633,619 | 38x38 | tooltip | qww | `tooltip:qww` |
| 633,661 | 38x38 | keyed |  | `key:bounce-6ec23029e3003347d7cdd73988293dd7` |
| 633,661 | 38x38 | semantics | test | `semantics:test` |
| 633,661 | 38x38 | tooltip | test | `tooltip:test` |
| 633,703 | 38x38 | keyed |  | `key:bounce-6ae8032accaad737890ca2d4f9e97752` |
| 633,703 | 38x38 | semantics | test3 | `semantics:test3` |
| 633,703 | 38x38 | tooltip | test3 | `tooltip:test3` |
| 633,1047 | 38x38 | semantics | Create a server | `semantics:Create a server` |
| 633,1047 | 38x38 | tooltip | Create a server | `tooltip:Create a server` |
| 638,0 | 140x28 | pressable | AnonListen | `text:AnonListen` x5 |
| 638,0 | 140x28 | tooltip | Online | `tooltip:Online` |
| 639,1114 | 26x26 | tooltip | Browse Public Channels | `tooltip:Browse Public Channels` |
| 639,1114 | 26x26 | pressable | Browse public channels | `semantics:Browse public channels` x2 |
| 639,1114 | 26x26 | semantics | Browse public channels | `semantics:Browse public channels` x2 |
| 639,1140 | 26x26 | tooltip | Share | `tooltip:Share` |
| 639,1140 | 26x26 | pressable | Share | `semantics:Share` x2 |
| 639,1140 | 26x26 | semantics | Share | `semantics:Share` x2 |
| 639,1166 | 26x26 | tooltip | Archive | `tooltip:Archive` |
| 639,1166 | 26x26 | semantics | Archive | `semantics:Archive` x2 |
| 639,1166 | 26x26 | pressable | Archive | `semantics:Archive` x2 |
| 639,1192 | 26x26 | semantics | Downloads | `semantics:Downloads` x2 |
| 639,1192 | 26x26 | pressable | Downloads | `semantics:Downloads` x2 |
| 639,1192 | 26x26 | tooltip | Downloads | `tooltip:Downloads` |
| 639,1218 | 26x26 | tooltip | Settings | `tooltip:Settings` |
| 639,1218 | 26x26 | pressable | Settings | `semantics:Settings` x2 |
| 639,1218 | 26x26 | semantics | Settings | `semantics:Settings` x2 |
| 640,161 | 14x25 | text | H | `text:H` |
| 642,585 | 21x20 | text | MY | `text:MY` |
| 642,673 | 15x20 | text | TE | `text:TE` x2 |
| 642,715 | 15x20 | text | TE | `text:TE` x2 |
| 643,1057 | 18x18 | icon | plus (0xe13d) | `icon:plus` |
| 643,1118 | 18x18 | icon | globe (0xe0e8) | `icon:globe` |
| 643,1144 | 18x18 | icon | 0xe156 | `icon:0xe156` |
| 643,1170 | 18x18 | icon | 0xe041 | `icon:0xe041` |
| 643,1196 | 18x18 | icon | download (0xe0b2) | `icon:download` |
| 643,1222 | 18x18 | icon | settings (0xe154) | `icon:settings` x3 |
| 644,59 | 69x17 | text | AnonListen | `text:AnonListen` x5 |
| 649,48 | 7x7 | semantics | Online | `semantics:Online` x2 |

---

## UI map: 08-home-dock

Screen 1264.0 x 681.0 logical pixels. 214 entries.

### Open surfaces

- dialog open: false
- context menu open: false

### Providers

- server: null (null)
- channel: null (null)
- layout mode: LayoutMode.dock

#### Stored layout

```
[0] MISSING channel 6ae8032a-general
[1] MISSING channel 6ae8032a-3f35dfa2
[2] MISSING channel 6ae8032a-5af0eb9e
[3] CATEGORY "233"
    [4] MISSING channel 6ae8032a-75134eee
```

#### Effective layout (stored + unplaced channels)

```
[0] CATEGORY "233"
```

### On screen

`y,x` is the top-left corner. Paste a target straight into a scenario; `xN` means the target matches N widgets, so scope it (`dialog > ...`) or pass an index.

| y,x | size | kind | label | target |
|---|---|---|---|---|
| 0,1126 | 46x32 | semantics | Minimize | `semantics:Minimize` |
| 0,1172 | 46x32 | semantics | Maximize | `semantics:Maximize` |
| 0,1218 | 46x32 | semantics | Close | `semantics:Close` |
| 7,16 | 44x18 | text | Hollow | `text:Hollow` |
| 7,1090 | 32x18 | icon | pencil (0xe1f9) | `icon:pencil` |
| 8,1141 | 16x16 | icon | 0xe11c | `icon:0xe11c` |
| 8,1233 | 16x16 | icon | x (0xe1b2) | `icon:x` |
| 9,1188 | 14x14 | icon | 0xe167 | `icon:0xe167` |
| 32,0 | 1264x649 | keyed |  | `key:_ScaffoldSlot.body` |
| 32,66 | 81x43 | tooltip | MacOS | `tooltip:MacOS` |
| 32,66 | 81x43 | pressable | 12 | `text:12` x22 |
| 32,153 | 68x43 | tooltip | Pixel | `tooltip:Pixel` |
| 32,153 | 68x43 | pressable | Pixel | `text:Pixel` x4 |
| 32,227 | 118x43 | pressable | 12 | `text:12` x22 |
| 32,227 | 118x43 | tooltip | iPhone 13 mini | `tooltip:iPhone 13 mini` |
| 32,351 | 92x43 | tooltip | UbuLinux | `tooltip:UbuLinux` |
| 32,351 | 92x43 | pressable | 12 | `text:12` x22 |
| 32,449 | 96x43 | pressable | virtual bro | `text:virtual bro` x4 |
| 32,449 | 96x43 | tooltip | virtual bro | `tooltip:virtual bro` |
| 41,8 | 34x26 | semantics | Add friend | `semantics:Add friend` x2 |
| 41,8 | 34x26 | tooltip | Add Friend | `tooltip:Add Friend` |
| 41,8 | 34x26 | pressable | Add friend | `semantics:Add friend` x2 |
| 41,1146 | 34x26 | tooltip | Saved messages | `tooltip:Saved messages` |
| 41,1146 | 34x26 | pressable | Saved messages | `semantics:Saved messages` x2 |
| 41,1146 | 34x26 | semantics | Saved messages | `semantics:Saved messages` x2 |
| 41,1184 | 34x26 | tooltip | Conferences | `tooltip:Conferences` |
| 41,1184 | 34x26 | pressable | Conferences | `semantics:Conferences` x2 |
| 41,1184 | 34x26 | semantics | Conferences | `semantics:Conferences` x2 |
| 41,1222 | 34x26 | pressable | Help | `semantics:Help` x2 |
| 41,1222 | 34x26 | tooltip | Help | `tooltip:Help` |
| 41,1222 | 34x26 | semantics | Help | `semantics:Help` x2 |
| 45,16 | 18x18 | icon | userPlus (0xe1a2) | `icon:userPlus` |
| 45,1154 | 18x18 | icon | 0xe060 | `icon:0xe060` |
| 45,1192 | 18x18 | icon | video (0xe1a5) | `icon:video` |
| 45,1230 | 18x18 | icon | 0xe082 | `icon:0xe082` |
| 46,104 | 35x15 | text | MacOS | `text:MacOS` x2 |
| 46,191 | 22x15 | text | Pixel | `text:Pixel` x4 |
| 46,265 | 72x15 | text | iPhone 13 mini | `text:iPhone 13 mini` x2 |
| 46,389 | 46x15 | text | UbuLinux | `text:UbuLinux` x2 |
| 46,487 | 50x15 | text | virtual bro | `text:virtual bro` x4 |
| 47,82 | 9x13 | text | 12 | `text:12` x22 |
| 47,243 | 9x13 | text | 12 | `text:12` x22 |
| 47,367 | 9x13 | text | 12 | `text:12` x22 |
| 59,92 | 7x7 | semantics | Offline | `semantics:Offline` x14 |
| 59,178 | 7x7 | semantics | Offline | `semantics:Offline` x14 |
| 59,252 | 7x7 | semantics | Offline | `semantics:Offline` x14 |
| 59,376 | 7x7 | semantics | Offline | `semantics:Offline` x14 |
| 59,474 | 7x7 | semantics | Offline | `semantics:Offline` x14 |
| 76,0 | 1264x546 | keyed |  | `key:[<[<'single-empty'>]>]` |
| 76,0 | 1264x546 | keyed |  | `key:[<'single-empty'>]` |
| 76,0 | 1264x546 | keyed |  | `key:single-empty` |
| 76,0 | 1264x546 | keyed |  | `key:[<[<'empty'>]>]` |
| 76,0 | 1264x546 | keyed |  | `key:[<'empty'>]` |
| 76,0 | 1264x546 | keyed |  | `key:empty` |
| 116,323 | 156x22 | text | Recent Conversations | `text:Recent Conversations` |
| 116,1006 | 62x22 | text | Network | `text:Network` |
| 118,297 | 18x18 | icon | messageCircle (0xe116) | `icon:messageCircle` |
| 118,980 | 18x18 | icon | 0xe038 | `icon:0xe038` x2 |
| 150,297 | 650x52 | pressable | 12 | `text:12` x22 |
| 159,353 | 41x18 | text | MacOS | `text:MacOS` x2 |
| 161,1007 | 59x17 | text | Connected | `text:Connected` |
| 167,320 | 13x19 | text | 12 | `text:12` x22 |
| 169,911 | 24x14 | text | 07:19 | `text:07:19` |
| 178,1007 | 84x14 | text | 0 friends reachable | `text:0 friends reachable` |
| 179,353 | 82x15 | text | You: ÐÐ¾Ñ€Ð¼Ð°Ð»ÑŒÐ½Ð¾ | `text:You: ÐÐ¾Ñ€Ð¼Ð°Ð»ÑŒÐ½Ð¾` |
| 185,336 | 8x8 | semantics | Offline | `semantics:Offline` x14 |
| 200,98 | 92x23 | text | AnonListen | `text:AnonListen` x3 |
| 206,297 | 650x52 | pressable | 12 | `text:12` x22 |
| 215,353 | 86x18 | text | iPhone 13 mini | `text:iPhone 13 mini` x2 |
| 219,980 | 45x14 | text | FRIENDS | `text:FRIENDS` |
| 223,320 | 13x19 | text | 12 | `text:12` x22 |
| 225,915 | 20x14 | text | 8/17 | `text:8/17` |
| 227,134 | 32x15 | text | Online | `text:Online` |
| 235,353 | 17x15 | text | hey | `text:hey` |
| 241,336 | 8x8 | semantics | Offline | `semantics:Offline` x14 |
| 241,1229 | 11x17 | text | 13 | `text:13` x2 |
| 242,997 | 32x15 | text | Offline | `text:Offline` |
| 243,980 | 13x13 | icon | 0xe1af | `icon:0xe1af` |
| 250,94 | 100x17 | text | Working on Hollow | `text:Working on Hollow` |
| 262,297 | 650x52 | pressable | 12 | `text:12` x22 |
| 271,353 | 36x18 | text | krigo2 | `text:krigo2` |
| 278,980 | 75x14 | text | RELAY SERVER | `text:RELAY SERVER` |
| 279,320 | 13x19 | text | 12 | `text:12` x22 |
| 281,915 | 20x14 | text | 8/16 | `text:8/16` x2 |
| 291,353 | 47x15 | text | You: yeah | `text:You: yeah` |
| 292,77 | 134x17 | text | â€œNonprofessional listenerâ€ | `text:â€œNonprofessional listenerâ€` |
| 297,336 | 8x8 | semantics | Offline | `semantics:Offline` x14 |
| 311,1007 | 153x14 | text | RAM | `text:RAM` |
| 311,1164 | 65x14 | text | 595 / 7940 MB | `text:595 / 7940 MB` |
| 312,991 | 12x12 | icon | 0xe445 | `icon:0xe445` |
| 318,297 | 650x52 | pressable | 12 | `text:12` x22 |
| 327,353 | 73x18 | text | 12D3KooW... | `text:12D3KooW...` |
| 334,24 | 240x49 | semantics | System status: All systems operational | `semantics:System status: All systems operational` |
| 335,320 | 13x19 | text | 12 | `text:12` x22 |
| 337,915 | 20x14 | text | 8/16 | `text:8/16` x2 |
| 341,1007 | 141x14 | text | Bandwidth | `text:Bandwidth` |
| 341,1152 | 77x14 | text | 13.0 / 1000 Mbps | `text:13.0 / 1000 Mbps` |
| 342,991 | 12x12 | icon | 0xe038 | `icon:0xe038` x2 |
| 343,57 | 75x17 | text | System Status | `text:System Status` |
| 344,35 | 14x14 | icon | 0xe226 | `icon:0xe226` |
| 347,353 | 33x15 | text | You: hi | `text:You: hi` |
| 353,336 | 8x8 | semantics | Offline | `semantics:Offline` x14 |
| 360,57 | 102x14 | text | All systems operational | `text:All systems operational` |
| 371,991 | 238x14 | tooltip | Relay traffic for your connection today: uploads and downloads (files, images, s... | `tooltip:Relay traffic for your connection today: uploads and downloads (files, images, sync). Shared by every device on your network (counted per IP). Direct P2P transfers don't count.` |
| 371,1007 | 70x14 | text | Daily relay data | `text:Daily relay data` |
| 372,991 | 12x12 | icon | 0xe1bf | `icon:0xe1bf` |
| 374,297 | 650x52 | pressable | 12 | `text:12` x22 |
| 383,353 | 31x18 | text | vm22 | `text:vm22` |
| 391,320 | 13x19 | text | 12 | `text:12` x22 |
| 393,920 | 15x14 | text | 8/6 | `text:8/6` |
| 396,991 | 71x13 | text | 3.3 MB of 10.0 GB | `text:3.3 MB of 10.0 GB` |
| 396,1167 | 62x13 | text | resets in 4h 3m | `text:resets in 4h 3m` |
| 398,1154 | 9x9 | icon | 0xe087 | `icon:0xe087` |
| 403,353 | 16x15 | text | reh | `text:reh` |
| 406,52 | 64x14 | text | YOUR STATS | `text:YOUR STATS` |
| 407,35 | 13x13 | icon | 0xe2a3 | `icon:0xe2a3` |
| 409,336 | 8x8 | semantics | Offline | `semantics:Offline` x14 |
| 428,242 | 11x17 | text | 13 | `text:13` x2 |
| 429,55 | 35x15 | text | Friends | `text:Friends` |
| 430,297 | 650x52 | pressable | virtual bro | `text:virtual bro` x4 |
| 431,35 | 12x12 | icon | users (0xe1a4) | `icon:users` |
| 439,353 | 59x18 | text | virtual bro | `text:virtual bro` x4 |
| 447,980 | 31x14 | text | NEWS | `text:NEWS` |
| 449,920 | 15x14 | text | 8/3 | `text:8/3` |
| 451,246 | 7x17 | text | 6 | `text:6` |
| 452,55 | 35x15 | text | Servers | `text:Servers` |
| 454,35 | 12x12 | icon | server (0xe153) | `icon:server` |
| 459,353 | 246x15 | text | You: https://www.instagram.com/p/Dbi4tVWNcFZ/ | `text:You: https://www.instagram.com/p/Dbi4tVWNcFZ/` |
| 465,336 | 8x8 | semantics | Offline | `semantics:Offline` x14 |
| 474,228 | 25x17 | text | 1062 | `text:1062` |
| 475,55 | 68x15 | text | DM messages | `text:DM messages` |
| 477,35 | 12x12 | icon | messageSquare (0xe117) | `icon:messageSquare` |
| 480,991 | 238x51 | text | v0.10 - Screen Share Forwarding, Mobile Audio Devices, Interface Sounds & Flutte... | `text:v0.10 - Screen Share Forwarding, Mobile Audio Devices, Interface Sounds & Flutte...` |
| 486,297 | 650x52 | pressable | 12 | `text:12` x22 |
| 495,353 | 54x18 | text | UbuLinux | `text:UbuLinux` x2 |
| 497,248 | 5x17 | text | 1 | `text:1` |
| 498,55 | 37x15 | text | Devices | `text:Devices` |
| 500,35 | 12x12 | icon | 0xe163 | `icon:0xe163` |
| 503,320 | 13x19 | text | 12 | `text:12` x22 |
| 505,920 | 15x14 | text | 8/1 | `text:8/1` |
| 515,353 | 449x15 | text | You: [a:s:dbb417106aab0fcf3fc210f6395a21a55f79422ddb31104a74faf75a87d98b31:512:2... | `text:You: [a:s:dbb417106aab0fcf3fc210f6395a21a55f79422ddb31104a74faf75a87d98b31:512:2...` |
| 521,336 | 8x8 | semantics | Offline | `semantics:Offline` x14 |
| 533,991 | 71x14 | text | August 19, 2026 | `text:August 19, 2026` |
| 542,297 | 650x52 | pressable | Pixel | `text:Pixel` x4 |
| 551,353 | 26x18 | text | Pixel | `text:Pixel` x4 |
| 555,991 | 238x221 | input | Probably one of the harshest updates shipped so far... in a nutshell, the screen... | `type:EditableText` |
| 561,915 | 20x14 | text | 7/20 | `text:7/20` |
| 571,353 | 30x15 | text | You: 1 | `text:You: 1` |
| 577,83 | 123x21 | pressable | 12D3KooW...T7iS4F | `text:12D3KooW...T7iS4F` x2 |
| 577,336 | 8x8 | semantics | Offline | `semantics:Offline` x14 |
| 581,105 | 93x13 | text | 12D3KooW...T7iS4F | `text:12D3KooW...T7iS4F` x2 |
| 583,91 | 10x10 | icon | copy (0xe09e) | `icon:copy` |
| 598,297 | 650x52 | pressable | 12 | `text:12` x22 |
| 607,353 | 40x18 | text | iPhone | `text:iPhone` |
| 615,320 | 13x19 | text | 12 | `text:12` x22 |
| 617,915 | 20x14 | text | 7/16 | `text:7/16` |
| 627,353 | 48x15 | text | You: what | `text:You: what` |
| 633,149 | 38x38 | semantics | Home | `semantics:Home` |
| 633,149 | 38x38 | tooltip | Home | `tooltip:Home` |
| 633,336 | 8x8 | semantics | Offline | `semantics:Offline` x14 |
| 633,493 | 38x38 | keyed |  | `key:bounce-1a88f45832c2a648a914fc259f602a12` |
| 633,493 | 38x38 | semantics | testing | `semantics:testing` |
| 633,493 | 38x38 | tooltip | testing | `tooltip:testing` |
| 633,535 | 38x38 | tooltip | another one! | `tooltip:another one!` |
| 633,535 | 38x38 | semantics | another one! | `semantics:another one!` |
| 633,535 | 38x38 | keyed |  | `key:bounce-8f3d5c37a26835ddf04b07f2c91da556` |
| 633,577 | 38x38 | tooltip | MyEpicServer | `tooltip:MyEpicServer` |
| 633,577 | 38x38 | semantics | MyEpicServer | `semantics:MyEpicServer` |
| 633,577 | 38x38 | keyed |  | `key:bounce-b7d2030be50e7bd8708c4364102c4029` |
| 633,619 | 38x38 | semantics | qww | `semantics:qww` |
| 633,619 | 38x38 | tooltip | qww | `tooltip:qww` |
| 633,619 | 38x38 | keyed |  | `key:bounce-703162ad1c1dd3f77a506828f71c5f8d` |
| 633,661 | 38x38 | semantics | test | `semantics:test` |
| 633,661 | 38x38 | keyed |  | `key:bounce-6ec23029e3003347d7cdd73988293dd7` |
| 633,661 | 38x38 | tooltip | test | `tooltip:test` |
| 633,703 | 38x38 | semantics | test3 | `semantics:test3` |
| 633,703 | 38x38 | keyed |  | `key:bounce-6ae8032accaad737890ca2d4f9e97752` |
| 633,703 | 38x38 | tooltip | test3 | `tooltip:test3` |
| 633,1047 | 38x38 | tooltip | Create a server | `tooltip:Create a server` |
| 633,1047 | 38x38 | semantics | Create a server | `semantics:Create a server` |
| 638,0 | 140x28 | pressable | AnonListen | `text:AnonListen` x3 |
| 638,0 | 140x28 | tooltip | Online | `tooltip:Online` |
| 639,1114 | 26x26 | tooltip | Browse Public Channels | `tooltip:Browse Public Channels` |
| 639,1114 | 26x26 | semantics | Browse public channels | `semantics:Browse public channels` x2 |
| 639,1114 | 26x26 | pressable | Browse public channels | `semantics:Browse public channels` x2 |
| 639,1140 | 26x26 | pressable | Share | `semantics:Share` x2 |
| 639,1140 | 26x26 | tooltip | Share | `tooltip:Share` |
| 639,1140 | 26x26 | semantics | Share | `semantics:Share` x2 |
| 639,1166 | 26x26 | tooltip | Archive | `tooltip:Archive` |
| 639,1166 | 26x26 | semantics | Archive | `semantics:Archive` x2 |
| 639,1166 | 26x26 | pressable | Archive | `semantics:Archive` x2 |
| 639,1192 | 26x26 | tooltip | Downloads | `tooltip:Downloads` |
| 639,1192 | 26x26 | semantics | Downloads | `semantics:Downloads` x2 |
| 639,1192 | 26x26 | pressable | Downloads | `semantics:Downloads` x2 |
| 639,1218 | 26x26 | tooltip | Settings | `tooltip:Settings` |
| 639,1218 | 26x26 | pressable | Settings | `semantics:Settings` x2 |
| 639,1218 | 26x26 | semantics | Settings | `semantics:Settings` x2 |
| 640,161 | 14x25 | text | H | `text:H` |
| 642,585 | 21x20 | text | MY | `text:MY` |
| 642,673 | 15x20 | text | TE | `text:TE` x2 |
| 642,715 | 15x20 | text | TE | `text:TE` x2 |
| 643,1057 | 18x18 | icon | plus (0xe13d) | `icon:plus` |
| 643,1118 | 18x18 | icon | globe (0xe0e8) | `icon:globe` |
| 643,1144 | 18x18 | icon | 0xe156 | `icon:0xe156` |
| 643,1170 | 18x18 | icon | 0xe041 | `icon:0xe041` |
| 643,1196 | 18x18 | icon | download (0xe0b2) | `icon:download` |
| 643,1222 | 18x18 | icon | settings (0xe154) | `icon:settings` |
| 644,59 | 69x17 | text | AnonListen | `text:AnonListen` x3 |
| 649,48 | 7x7 | semantics | Online | `semantics:Online` |
| 654,297 | 650x52 | pressable | 12 | `text:12` x22 |
| 663,353 | 30x18 | text | Linux | `text:Linux` |
| 671,320 | 13x19 | text | 12 | `text:12` x22 |
| 673,915 | 20x14 | text | 6/22 | `text:6/22` |
| 679,998 | 33x13 | text | Installed | `text:Installed` |

