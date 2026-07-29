# Ride profiles + PIN immobiliser

Apply with `git apply ride-profiles-pin-lock.patch` from the repo root, then
re-upload `lisp/main.lisp` to the VESC with VESC Tool and reflash the P4.

## Where the lock actually lives

On the **VESC**, in `lisp/main.lisp`. The display is only a keypad.

That split is the whole point. `motor-control-loop` is the single place that
commands the motor, so a `locked` flag checked there cannot be talked around by
a head unit that is unplugged, crashed, or replaced. If you had put the check in
the ESP32 UI instead, pulling the display would unlock the bike.

## What changed

**`lisp/main.lisp`**

- Profiles are now a table (`profile-speed` / `profile-scale` /
  `profile-needs-pin`) instead of an if-chain: ECO 25 km/h @ 50 % current,
  NORMAL 40 @ 67 %, SPORT 60 @ 100 %. Edit those three functions to retune.
- `sport-needs-pin` (default 1) gates SPORT behind the PIN even after the bike
  is unlocked, so lending the bike out does not lend out full power. The
  handlebar TX button skips gated profiles instead of sticking on them.
- The selected profile is stored in EEPROM slot 4 and restored at boot.
- `locked` / `pin-ok` / `pin-tries`, PIN hash in EEPROM slot 2, "require PIN"
  flag in slot 3. `unlock-with-pin`, `lock-now`, `set-pin`.
- The arbiter zeroes the throttle request while locked, and refuses to arm
  cruise or accept PAS current.
- New panel messages: `0x06` unlock, `0x07` lock, `0x08` select profile,
  `0x09` change PIN. Payloads are **raw int32**, not the ×1000 scaling the rest
  of the protocol uses.
- The DASH packet gained five fields (locked, pin_set, pin_tries,
  profile_count, pin_ok).

**Head unit**

- `vesc_lisp_panel.{h,c}`: the four new commands, on their own queue drained
  from `dash_loop` so they work with the panel drawer shut; DASH v2 parsing
  that degrades cleanly against an old script.
- `custom/lock_overlay.c`: full-screen PIN keypad on `lv_layer_top()` (so it
  covers Android Auto video too) plus the ECO/NORMAL/SPORT modal.
- `vesc_ui_updater.c`: drives the overlay every tick, before the
  "not on the dashboard, skip" early return.
- The dashboard MODE label now reads ECO / NORMAL / SPORT in all three themes.

## One thing left for you to wire

`show_profile_picker()` has no trigger yet — I did not want to guess at your
gesture. Two easy options:

```c
/* tap the MODE label on the amber dashboard */
lv_obj_add_flag(guider_ui.dashboard_Amber_mode_text, LV_OBJ_FLAG_CLICKABLE);
lv_obj_add_event_cb(guider_ui.dashboard_Amber_mode_text,
                    profile_tap_cb, LV_EVENT_CLICKED, NULL);
```

...or a Settings row next to the PAS one. The PIN-change UI is likewise not
built; until it is, set the initial PIN from the VESC Tool Lisp REPL:

```lisp
(set-pin 0 1234)     ; first time: old PIN is 0
(set-pin 1234 0)     ; 0 clears the PIN and disables the immobiliser
```

## Safety notes — please read these

**Brakes are never touched.** The lock zeroes the drive current only;
`l-current-min-scale` and the brake path are untouched, and the arbiter keeps
the brake branch above the lock so regen still works while locked (you can roll
a locked bike down a hill and still stop it). The overlay says so on screen,
because a rider who thinks the brakes are cut will do something unwise.

**The lock will not engage above ~0.5 km/h.** `lock-now` refuses while the
wheel is turning. Dropping drive power under a rider mid-corner is how people
end up on the tarmac. Do not "improve" this by removing the check.

**Script-death fallback.** If the Lisp script dies, the arbiter stops extending
`app-disable-output` and ~1.5 s later the stock ADC throttle comes back — which
would un-immobilise the bike. So the lock *also* sets
`l-current-max-scale` and `max-speed` to 0. Those are RAM-only `conf-set`
writes, so a power cycle restores your VESC Tool values and the script
re-applies the lock at boot. Verify this on a stand: lock the bike, kill the
script from VESC Tool, then twist the throttle and confirm nothing happens.

**This is a deterrent, not theft protection.** Anyone with a laptop and a USB
cable can open VESC Tool, delete the Lisp script and ride away, and the PIN hash
in EEPROM is obfuscation rather than crypto. It is a valet lock and a
"teenager cannot take it out in SPORT" lock. Keep your physical lock.

**Do not lock yourself out.** With the PIN set and the display dead, the bike is
immobilised and the only way in is VESC Tool over USB. If the bike lives
somewhere you might not have a laptop, consider either keeping
`pin-required` off (lock on demand only) or adding a backup unlock via a
knock-code on the handlebar RX/TX buttons before you rely on this.

**Test order:** wheel off the ground, motor unloaded, first boot after flashing.
Confirm locked-at-boot → no drive; correct PIN → drive returns in ECO; SPORT
refused before PIN and allowed after; five wrong PINs → 30 s penalty.
