# Eqemu_lfg
LFG tool that allows lfg and lfm. once invited and accepted player is ported to group...**kinda betaish**

# EQEmu LFG / LFM Plugin (Perl)

A modern, **older-build-safe** Looking For Group / Looking For More system for EQEmu using Perl quest plugins and data buckets.

Designed to work on a wide range of EQEmu servers:
- ✅ Cross-zone messaging
- ✅ Auto-port on group join
- ✅ Anti-spam and anti-grief safeguards
- ✅ Multi-role support with best-fit role selection

---

## Features

### LFG (Looking For Group)
Players can list themselves as LFG with:
- Level range
- Role (manual or auto-detected from class)
- Short note

**Highlights**
- Listings auto-expire
- Clickable **Invite** and **Tell** actions
- Invite sets a pending auto-port snapshot
- Player is automatically transported to the group leader after accepting the invite

---

### LFM (Looking For More)
Group leaders can list open spots with:
- Optional label (`main`, `alt`, etc.)
- Level range
- Role needs (with counts)
- Short note

**Highlights**
- Live tracking of remaining needs
- Needs decrement automatically when players join
- Listing auto-clears when all needs are filled
- Multiple listings per leader supported

---

### Role System (Multi-Role)
Roles are automatically inferred from class and stored as a **set**, not a single value.

Example:
- Paladin → `tank`, `healer`, `support`
- Bard → `support`, `cc`, `pull`

When inviting from LFG into an LFM:
- The plugin **auto-selects the best-fit role** based on remaining needs
- Falls back gracefully if no needs match

Supported roles:
tank | healer | dps | cc | pull | support

---

### Messaging (Tell)
- Cross-zone safe (bucket-based inbox)
- Delivered automatically via timer polling
- Descriptive messages include:
  - Sender name
  - Sender level
  - Sender roles

**Anti-spam protections**
- Per-sender → per-target cooldown
- Per-sender burst limit
- Inbox capped to prevent flooding

---

### Auto-Port on Invite Accept
When a player accepts a group invite:
- They are automatically transported to the group leader’s location

**Safeguards**
- Player consent toggle
- Level-range enforcement
- Pending-invite collision protection
- Optional cross-zone teleport toggle
- Zone blacklist support
- Pending expiration window

### Pending Invite Notifications (Invite Incoming)

When a group leader clicks [Invite] in the LFG list, the plugin now:

Creates a pending invite snapshot (name-based bucket)

Sends the invitee a cross-zone inbox message like:

“Invite incoming from <leader>… accept to auto-port… ?lfg cancel to decline.”

### This helps the invitee understand what’s about to happen before they accept the /invite.

Invitee Cancel Pending Invite

If you don’t want to accept the incoming invite (or you got spammed), you can cancel your own pending invite:
```
?lfg cancel
```

This clears your pending snapshot so no auto-port occurs even if you accept an invite afterward. 

pasted

### Leader Verification Hard Lock (Anti-Wrong-Invite Port)

A rare edge case is “pending invite was from Leader A, but you accepted an invite from Leader B.”

To prevent wrong-porting, the plugin now hard-locks auto-porting:

It checks your current group leader name

It must match the leader stored in the pending snapshot

If it doesn’t match:

auto-port is canceled

pending snapshot is cleared

you get a message explaining why

### This makes auto-port behavior deterministic and grief-resistant. 

---

## Installation

### 1. Plugin File
Place the plugin here:
```
quests/plugins/lfg.pl
```

### 2. Global Player Hooks
Edit:
```
quests/global/global_player.pl
```

Add or merge the following:

```perl
sub EVENT_ENTERZONE {
    quest::settimer("lfg_inbox", 3);
    plugin::lfg_deliver_inbox($client);
    plugin::lfg_try_pending_port($client);
}

sub EVENT_GROUP_CHANGE {
    plugin::lfg_try_pending_port($client);
}

sub EVENT_TIMER {
	if ($timer eq "lfg_inbox") {
        # Only do work if flagged
        if (plugin::lfg_has_mail($client)) {
            plugin::lfg_deliver_inbox($client);
        }
    }
}

```

⚠️ If these events already exist, merge the logic rather than overwriting.

## Usage
All commands are issued via /say.

## LFG Commands
### Post LFG
```
?lfg <min>-<max> [role|auto] <note>
```
Examples:

```
?lfg 20-30 auto LFG dungeon
?lfg 40-50 healer ready to go
```

### List LFG
```
?lfg list
```
### Clear LFG
```
?lfg clear
```
### Invite from LFG
Click [Invite], then type:

```
/invite <player>
```
On accept, the player auto-ports to the leader.

### Cancel pending invite (invitee-side):
```
?lfg cancel
```

### Notify (Tell)
Click [Tell] to send a cross-zone message.

## LFM Commands
### Post LFM
```
?lfm [label] <min>-<max> need:<roles> <note>
```
Examples:

```
?lfm 30-40 need:healer,tank dungeon run
?lfm main 50-60 need:healer=1,tank=1,dps=2 raid prep
```
### List LFM
```
?lfm list
```
### Clear LFM
```
?lfm clear
?lfm clear main
?lfm clear all
```
### Notify (Tell)
Click [Tell] to notify the group leader.

### Consent Control
#### Players can opt out of auto-porting:

```
?lfg consent off
?lfg consent on
```
Consent defaults to **ON** when posting **LFG**.

## Configuration
Inside lfg.pl:

```perl
Copy code
$TTL_SECONDS              # Listing lifetime
$PEND_TTL_SECONDS         # Pending invite lifetime
$PEND_MAX_AGE_SECONDS     # Max age before pending expires
$INVITE_COOLDOWN_SECONDS  # Invite cooldown
$ALLOW_CROSS_ZONE_PORT    # Enable/disable cross-zone auto-port
%ZONE_BLACKLIST           # Zones that block auto-port
```
## Design Notes
All state stored in data buckets

No database schema changes required

Minimal polling, low overhead

Defensive against griefing and spam

Known Limitations
Group invites must be issued manually (/invite)

No raid support (by design, for now)
