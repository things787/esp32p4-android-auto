(def cruise-active 0)
(def cruise-rpm 0)
(def rx-button-state 1)
(def tx-button-state 1)
; Motor arbiter state (motor-control-loop). setq'd at runtime → above @const.
(def out-rel 0.0)     ; throttle slew-limiter state (relative current 0..1)
(def brk-rel 0.0)     ; brake slew-limiter state (relative brake current 0..1)
(def cruise-i 0.0)    ; cruise PI integrator (A), seeded on activation (bumpless)
(def armed 0)         ; safe-start: throttle must be seen released once after boot
; Cruise PI gains are HARDCODED here (edit + re-upload to tune): the firmware
; speed-PID gains (s-pid-kp/ki in VESC Tool) are NOT exposed to LISP conf-get,
; so there is nothing to read them from. Ramping times, by contrast, ARE read
; live from the VESC Tool ADC app page — see throttle-out/brake-out.
(def cruise-kp 0.02)  ; cruise PI: A per ERPM of error
(def cruise-ki 0.05)  ; cruise PI: A/s per ERPM of error
; Throttle feel knobs. ctl-dt is the arbiter tick — 100 Hz like Vedder's
; vl_bike pkg: at 20 Hz the ramp advanced in 12.5%-of-max current steps, which
; the FOC loop executes instantly → felt like jerks, not a ramp.
(def ctl-dt 0.01)          ; arbiter period (s)
(def thr-curve-accel 0.0)  ; throttle-curve accel const, -1..1 (0 = linear)
(def thr-curve-mode 0)     ; 0 exponential, 1 natural, 2 polynomial
; ---- ride profiles + PIN immobiliser -------------------------------------
; EEPROM slots 0/1 are the beep/melody volumes; 2..4 are ours.
(def pin-addr 2)          ; hash of the PIN (0 = no PIN configured)
(def pin-enable-addr 3)   ; 1 = require the PIN at every power-on
(def profile-addr 4)      ; last selected profile
(def num-profiles 3)      ; 0 = ECO, 1 = NORMAL, 2 = SPORT
(def sport-needs-pin 1)   ; SPORT is PIN-gated even after the bike is unlocked
(def current-profile (let ((v (eeprom-read-i profile-addr)))
                       (if (and v (>= v 0) (< v num-profiles)) v 0)))
(def first-profile-init 1)
; pin-hash-v / pin-required are read once here and setq'd by set-pin, so they
; MUST stay above @const-start like every other mutable global.
(def pin-hash-v (let ((v (eeprom-read-i pin-addr))) (if v v 0)))
(def pin-required (let ((v (eeprom-read-i pin-enable-addr)))
                    (if (and v (= v 1)) 1 0)))
; locked = the immobiliser. While 1 the arbiter commands no drive current AND
; the drive current scale is held at 0, so the bike does not move. Brakes are
; never touched by any of this.
(def locked (if (and (= pin-required 1) (not (= pin-hash-v 0))) 1 0))
(def pin-ok  (if (= pin-hash-v 0) 1 0))   ; PIN satisfied this power cycle
(def pin-tries 0)
(def pin-lockout 0)
(def rpm-per-ms 0.0)
(def throttle-on 1)
(def tc-on 0)
(def tc-sens 50.0)
(def pbuf (bufcreate 128))
(def pi 0)
(def beep-vol-addr 0)
(def beep-vol (let ((v (eeprom-read-i beep-vol-addr)))
                (if (and v (>= v 0) (<= v 50)) v 30)))
(def beep-vol-dirty 0)
(def melody-vol-addr 1)
(def melody-vol (let ((v (eeprom-read-i melody-vol-addr)))
                  (if (and v (>= v 0) (<= v 50)) v 40)))
(def melody-vol-dirty 0)
(def playing-idx -1)
; Pedal-assist setpoint from the head unit (over COMM_CUSTOM_APP_DATA, msg 0x05).
; pas-amps is the requested motor current (A); pas-seen is the (systime) of the
; last frame, for a staleness check. setq'd at runtime → MUST stay above @const.
(def pas-amps 0.0)
(def pas-seen 0)
; @const-start flashes every definition below, freeing the cons heap. Without it
; all the defun bodies live in RAM and exhaust the heap — panel-event-loop then
; OOMs at runtime and the display goes blank while motor control keeps running.
; Everything mutable MUST stay above this line: setq'd scalars, and especially
; the pbuf buffer (a flashed buffer is read-only, bufset would fail/crash).
@const-start
(defun play-stop () {
    (sleep 0.1)
    (foc-play-stop)
})
; Profiles scale the current limit instead of overwriting it: Motor Current Max
; in VESC Tool stays the master value (applied live, no LISP restart) and each
; profile is a fraction of it. Braking is never scaled — always full.
(defun profile-speed (i) (if (= i 0) 25.0 (if (= i 1) 40.0 60.0)))
(defun profile-scale (i) (if (= i 0) 0.5 (if (= i 1) 0.67 1.0)))
; Which profiles are PIN-gated. SPORT is by default: hand the bike to someone
; else after unlocking and they still cannot reach full power.
(defun profile-needs-pin (i) (if (and (= i 2) (= sport-needs-pin 1)) 1 0))
(defun profile-allowed (i)
    (and (>= i 0) (< i num-profiles)
         (or (= (profile-needs-pin i) 0) (= pin-ok 1))))
(defun profile-beep (i) {
    (foc-play-tone 0 (if (= i 0) 500 (if (= i 1) 750 1000)) 10)
    (spawn 150 play-stop)
})
; Returns 1 if the profile was applied, 0 if it was refused (PIN needed / bad
; index). While locked the scale stays at 0 — see apply-lock-scale — and the
; selected profile is only re-applied on unlock.
(defun apply-profile (profile-index) {
    (if (not (profile-allowed profile-index)) {
        (print "Profile refused: PIN required or bad index")
        (foc-play-tone 0 300 10)
        (spawn 150 play-stop)
        0
    } {
        (setq current-profile profile-index)
        (conf-set 'max-speed (/ (profile-speed profile-index) 3.6))
        (if (= locked 0)
            (conf-set 'l-current-max-scale (profile-scale profile-index)))
        (let ((saved (eeprom-read-i profile-addr)))
            (if (not (and saved (= saved profile-index)))
                (eeprom-store-i profile-addr profile-index)))
        (print (str-merge "Profile " (to-str profile-index)))
        (if (= first-profile-init 0)
            (profile-beep profile-index)
            (setq first-profile-init 0))
        1
    })
})
; ---- immobiliser ---------------------------------------------------------
; Zeroing the drive scale is belt-and-braces. If this script ever dies the
; arbiter stops extending app-disable-output and ~1.5 s later the stock ADC
; throttle comes back — with the scale at 0 that throttle commands ~0 A, so a
; crashed script does not silently un-immobilise the bike. conf-set is RAM
; only, so a power cycle restores the VESC Tool values and this script re-
; applies the lock at boot.
(defun apply-lock-scale () {
    (conf-set 'l-current-max-scale 0.0)
    (conf-set 'max-speed 0.0)
})
; Simple modular hash so the PIN is not sitting in EEPROM in the clear. This is
; obfuscation, not cryptography — anyone with VESC Tool over USB can read the
; slot, dump this script and see the algorithm. Treat the whole feature as a
; valet / deterrent lock, not as theft protection.
(defun pin-hash-r (h v n)
    (if (= n 0) h
        (pin-hash-r (mod (+ (* h 31) (+ 1 (mod v 10))) 1000003) (/ v 10) (- n 1))))
(defun pin-hash (p) (pin-hash-r 7919 (to-i32 p) 8))
; Never engage the lock while the bike is rolling: dropping drive power under a
; rider mid-corner is exactly the kind of thing that puts people on the floor.
(defun lock-now () {
    (if (> (abs (get-speed)) 0.5) {
        (print "Refusing to lock: still moving")
        0
    } {
        (if (= cruise-active 1) (deactivate-cruise-control))
        (setq locked 1)
        (setq pin-ok 0)
        (apply-lock-scale)
        (print "Locked")
        1
    })
})
(defun unlock-with-pin (p) {
    (if (= pin-hash-v 0) {
        (setq pin-ok 1) (setq locked 0) (apply-profile current-profile) 1
    } {
        ; 5 wrong entries buys a 30 s penalty — stops someone brute-forcing a
        ; 4-digit PIN on the touchscreen in a car park.
        (if (and (> pin-tries 4) (< (secs-since pin-lockout) 30.0)) {
            (print "PIN lockout active")
            0
        } {
            (if (= (pin-hash p) pin-hash-v) {
                (setq pin-ok 1)
                (setq pin-tries 0)
                (setq locked 0)
                (apply-profile current-profile)
                (foc-play-tone 0 900 beep-vol)
                (spawn 150 play-stop)
                (print "Unlocked")
                1
            } {
                (setq pin-tries (+ pin-tries 1))
                (if (> pin-tries 4) (setq pin-lockout (systime)))
                (foc-play-tone 0 200 beep-vol)
                (spawn 150 play-stop)
                (print "Wrong PIN")
                0
            })
        })
    })
})
; new = 0 clears the PIN and disables the immobiliser entirely.
(defun set-pin (old new) {
    (if (or (= pin-hash-v 0) (= (pin-hash old) pin-hash-v)) {
        (setq pin-hash-v (if (= new 0) 0 (pin-hash new)))
        (eeprom-store-i pin-addr pin-hash-v)
        (setq pin-required (if (= new 0) 0 1))
        (eeprom-store-i pin-enable-addr pin-required)
        (if (= new 0) { (setq locked 0) (setq pin-ok 1) })
        (print "PIN updated")
        1
    } {
        (print "PIN change refused: wrong current PIN")
        0
    })
})
(gpio-configure 'pin-rx 'pin-mode-in-pu)
(gpio-configure 'pin-tx 'pin-mode-in-pu)
(defun update-rpm-per-ms () {
    (loopwhile t {
        (if (= cruise-active 0) {
            (let ((current-rpm (get-rpm))) {
                (let ((current-speed-ms (get-speed))) {
                    (if (and (> (abs current-rpm) 10) (> (abs current-speed-ms) 0.1)) {
                        (setq rpm-per-ms (/ (abs current-rpm) (abs current-speed-ms)))
                    })
                })
            })
        })
        (sleep 0.2)
    })
})
; Cruise is a PI speed controller with a CURRENT output inside the motor
; arbiter — not the firmware speed PID. No set-rpm mode switch, so engaging
; can't jerk: the integrator is seeded with the actual motor current and the
; loop keeps commanding current smoothly. (De)activation just flips state; the
; arbiter (motor-control-loop) does everything else.
(defun activate-cruise-control () {
    (if (and (= cruise-active 0) (= throttle-on 1) (= locked 0)) {
        (setq cruise-rpm (get-rpm))
        (if (> (abs cruise-rpm) 0) {
            (setq cruise-i (get-current))   ; bumpless transfer
            (setq cruise-active 1)
            (print (str-merge "Cruise control activated at RPM: " (to-str cruise-rpm)))
        } {
            (print "Cannot activate cruise control: speed is zero")
        })
    })
})
(defun deactivate-cruise-control () {
    (if (= cruise-active 1) {
        (setq cruise-active 0)
        (setq cruise-rpm 0)
        (setq rpm-per-ms 0.0)
        (print "Cruise control deactivated")
    })
})
(defun increase-cruise-speed () {
    (if (= cruise-active 1) {
        (if (> rpm-per-ms 0.0) {
            (let ((current-speed-ms (/ (abs cruise-rpm) rpm-per-ms))) {
                (let ((new-speed-ms (+ current-speed-ms (/ 1.0 3.6)))) {
                    (let ((new-rpm (* new-speed-ms rpm-per-ms))) {
                        (if (< cruise-rpm 0) {
                            (setq cruise-rpm (- new-rpm))
                        } {
                            (setq cruise-rpm new-rpm)
                        })
                        (print (str-merge "Cruise speed increased to RPM: " (to-str cruise-rpm)))
                    })
                })
            })
        } {
            (let ((rpm-increment 50)) {
                (if (< cruise-rpm 0) {
                    (setq cruise-rpm (- cruise-rpm rpm-increment))
                } {
                    (setq cruise-rpm (+ cruise-rpm rpm-increment))
                })
                (print (str-merge "Cruise speed increased to RPM: " (to-str cruise-rpm)))
            })
        })
    })
})
(defun monitor-rx-button () {
    (loopwhile t {
        (let ((current-button-state (gpio-read 'pin-rx))) {
            (if (and (= rx-button-state 1) (= current-button-state 0)) {
                (if (= cruise-active 1) {
                    (increase-cruise-speed)
                } {
                    (activate-cruise-control)
                })
            })
            (setq rx-button-state current-button-state)
        })
        (sleep 0.05)
    })
})
; Handlebar TX button. Skips any profile the current PIN state does not allow,
; so the button cycles ECO -> NORMAL while SPORT is PIN-gated and locked out.
(defun next-allowed (i n)
    (if (= n 0) current-profile
        (if (profile-allowed i) i
            (next-allowed (mod (+ i 1) num-profiles) (- n 1)))))
(defun switch-profile () {
    (if (= locked 1)
        (print "Locked: profile change ignored")
        (apply-profile (next-allowed (mod (+ current-profile 1) num-profiles)
                                    num-profiles)))
})
(defun decrease-cruise-speed () {
    (if (= cruise-active 1) {
        (if (> rpm-per-ms 0.0) {
            (let ((current-speed-ms (/ (abs cruise-rpm) rpm-per-ms))) {
                (let ((new-speed-ms (- current-speed-ms (/ 1.0 3.6)))) {
                    (if (> new-speed-ms 0.1) {
                        (let ((new-rpm (* new-speed-ms rpm-per-ms))) {
                            (if (< cruise-rpm 0) {
                                (setq cruise-rpm (- new-rpm))
                            } {
                                (setq cruise-rpm new-rpm)
                            })
                            (print (str-merge "Cruise speed decreased to RPM: " (to-str cruise-rpm)))
                        })
                    } {
                        (deactivate-cruise-control)
                        (print "Cruise control deactivated: speed too low")
                    })
                })
            })
        } {
            (deactivate-cruise-control)
            (print "Cruise control deactivated: no speed ratio available")
        })
    })
})
(defun monitor-tx-button () {
    (loopwhile t {
        (let ((current-button-state (gpio-read 'pin-tx))) {
            (if (and (= tx-button-state 1) (= current-button-state 0)) {
                (if (= cruise-active 1) {
                    (decrease-cruise-speed)
                } {
                    (switch-profile)
                })
            })
            (setq tx-button-state current-button-state)
        })
        (sleep 0.05)
    })
})
; Boot straight into the immobilised state when a PIN is configured, otherwise
; restore the last profile (falling back to ECO if it is PIN-gated).
(if (= locked 1)
    (apply-lock-scale)
    (apply-profile (if (profile-allowed current-profile) current-profile 0)))
(spawn 150 update-rpm-per-ms)
(spawn 150 monitor-rx-button)
(spawn 150 monitor-tx-button)
(defun pu8  (v) { (bufset-u8  pbuf pi v) (setq pi (+ pi 1)) })
(defun pi32 (v) { (bufset-i32 pbuf pi (to-i32 v)) (setq pi (+ pi 4)) })
(defun pstr (s) { (bufcpy pbuf pi s 0 (buflen s)) (setq pi (+ pi (buflen s))) })
(defun panel-send-ui (reply-id) {
    (setq pi 0)
    (pu8 0x56) (pu8 0x50) (pu8 0x81) (pu8 1) (pu8 5)
    (pu8 1) (pu8 1) (pstr "Throttle") (pu8 (if (= throttle-on 1) 1 0))
    (pu8 4) (pu8 2) (pstr "Beep")
    (pu8 5) (pu8 3) (pstr "Beep Vol")
    (pi32 0) (pi32 50000) (pi32 5000) (pi32 (* beep-vol 1000)) (pstr "")
    (pu8 6) (pu8 1) (pstr "Polish Cow") (pu8 (if (= playing-idx 0) 1 0))
    (pu8 7) (pu8 3) (pstr "Melody Vol")
    (pi32 0) (pi32 50000) (pi32 5000) (pi32 (* melody-vol 1000)) (pstr "")
    (send-data pbuf 2 reply-id)
})
(defun panel-send-state (reply-id) {
    (setq pi 0)
    (pu8 0x56) (pu8 0x50) (pu8 0x82) (pu8 4)
    (pu8 1) (pi32 (* (if (= throttle-on 1) 1 0) 1000))
    (pu8 5) (pi32 (* beep-vol 1000))
    (pu8 6) (pi32 (* (if (= playing-idx 0) 1 0) 1000))
    (pu8 7) (pi32 (* melody-vol 1000))
    (send-data pbuf 2 reply-id)
})
(defun panel-send-dash (reply-id) {
    (setq pi 0)
    (pu8 0x56) (pu8 0x50) (pu8 0x84)
    (pi32 (* cruise-active 1000))
    (pi32 (* cruise-rpm 1000))
    (pi32 (* current-profile 1000))
    (pi32 (* rpm-per-ms 1000.0))
    ; --- appended in v2; older head units stop parsing after the 4 above ---
    (pi32 (* locked 1000))
    (pi32 (* (if (= pin-hash-v 0) 0 1) 1000))   ; a PIN is configured
    (pi32 (* pin-tries 1000))
    (pi32 (* num-profiles 1000))
    (pi32 (* (if (= pin-ok 1) 1 0) 1000))       ; PIN satisfied this power cycle
    (send-data pbuf 2 reply-id)
})
; Master enable is just a flag now — the motor arbiter owns all output and
; coasts (set-current 0) while throttle-on = 0. No app juggling needed.
(defun panel-set-throttle (on) {
    (if (= on 0) {
        (if (= cruise-active 1) (deactivate-cruise-control))
        (setq throttle-on 0)
    } {
        (setq throttle-on 1)
    })
})
(defun two-beeps () {
    (foc-play-tone 0 800 beep-vol)
    (sleep 0.1)
    (foc-play-stop)
    (sleep 0.06)
    (foc-play-tone 0 900 beep-vol)
    (sleep 0.1)
    (foc-play-stop)
    (sleep 0.3)
    (foc-play-tone 0 800 beep-vol)
    (sleep 0.1)
    (foc-play-stop)
    (sleep 0.06)
    (foc-play-tone 0 900 beep-vol)
    (sleep 0.1)
    (foc-play-stop)
})
; Run the sequence in its own thread so the sleeps don't block panel-event-loop.
(defun panel-beep () (spawn 150 two-beeps))
(defun play-list (idx lst) {
    (setq playing-idx idx)
    (let ((n (length lst))) {
        (loopwhile (= playing-idx idx) {
            (let ((i 0)) {
                (loopwhile (and (< i n) (= playing-idx idx)) {
                    (let ((note (ix lst i))) {
                        (let ((f (ix note 0)) (d (ix note 1))) {
                            ; Carve a short silence out of the END of each tone so
                            ; consecutive notes are articulated instead of slurring
                            ; together. Gap is taken from d, so the tempo is unchanged.
                            (if (> f 0) {
                                (foc-play-tone 0 f melody-vol)
                                (let ((gap (if (< d 0.09) (/ d 3.0) 0.03))) {
                                    (sleep (- d gap))
                                    (foc-play-stop)
                                    (sleep gap)
                                })
                            } {
                                (foc-play-stop)
                                (sleep d)
                            })
                        })
                    })
                    (setq i (+ i 1))
                })
            })
            (if (= playing-idx idx) (sleep 0.3))
        })
    })
    (if (= playing-idx -1) (foc-play-stop))
})
(defun panel-action (cid val) {
    (cond
        ((= cid 1) (panel-set-throttle (if (> val 0.5) 1 0)))
        ((= cid 4) (panel-beep))
        ((= cid 5) {
            (setq beep-vol (to-i32 val))
            (setq beep-vol-dirty 1)
        })
        ((= cid 6)
            (if (> val 0.5)
                (if (not (= playing-idx 0)) { (setq playing-idx 0) (spawn 200 play-list 0 melody) })
                (if (= playing-idx 0) (setq playing-idx -1))))
        ((= cid 7) {
            (setq melody-vol (to-i32 val))
            (setq melody-vol-dirty 1)
        }))
})
(defun panel-handle (data) {
    (if (and (>= (buflen data) 4)
             (= (bufget-u8 data 0) 0x56)
             (= (bufget-u8 data 1) 0x50))
        (let ((msg (bufget-u8 data 2))
              (reply-id (bufget-u8 data 3))) {
            (cond
                ((= msg 0x01) (panel-send-ui reply-id))
                ((= msg 0x03) (panel-send-state reply-id))
                ((= msg 0x04) (panel-send-dash reply-id))
                ((= msg 0x05) {
                    ; Pedal-assist setpoint (fire-and-forget, no reply). i32 mA at
                    ; byte 4 (after magic[0,1], msg[2], reply-id[3]).
                    (setq pas-amps (/ (bufget-i32 data 4) 1000.0))
                    (setq pas-seen (systime))
                })
                ; --- immobiliser / profile control (raw i32, NOT x1000) ---
                ((= msg 0x06) {                     ; unlock: [i32 pin]
                    (unlock-with-pin (bufget-i32 data 4))
                    (panel-send-dash reply-id) })
                ((= msg 0x07) {                     ; lock now
                    (lock-now)
                    (panel-send-dash reply-id) })
                ((= msg 0x08) {                     ; select profile: [i32 idx]
                    (apply-profile (bufget-i32 data 4))
                    (panel-send-dash reply-id) })
                ((= msg 0x09) {                     ; PIN change: [i32 old][i32 new]
                    (set-pin (bufget-i32 data 4) (bufget-i32 data 8))
                    (panel-send-dash reply-id) })
                ((= msg 0x02)
                    (let ((cid (bufget-u8 data 4))
                          (val (/ (bufget-i32 data 5) 1000.0))) {
                        (panel-action cid val)
                        (panel-send-state reply-id)
                    })))
        }))
})
(defun monitor-traction () {
    (let ((last-erpm 0.0)) {
        (loopwhile t {
            (if (= tc-on 1) {
                (let ((erpm (get-rpm))) {
                    (let ((accel (- (abs erpm) (abs last-erpm)))
                          (limit (- 5000.0 (* tc-sens 40.0)))) {
                        (if (> accel limit) (set-current 0))
                    })
                    (setq last-erpm erpm)
                })
            } {
                (setq last-erpm (get-rpm))
            })
            (sleep 0.02)
        })
    })
})
(defun clampf (v lo hi) (if (< v lo) lo (if (> v hi) hi v)))
; Slew v toward target: up at 1/pos-s per second, down at 1/neg-s per second.
(defun slew (v target pos-s neg-s)
    (if (> target v)
        (clampf (+ v (/ ctl-dt pos-s)) 0.0 target)
        (clampf (- v (/ ctl-dt neg-s)) target 1.0)))
; Ramping times come LIVE from the VESC Tool ADC app page (App Settings → ADC
; → Ramping Time Positive/Negative) — same knobs that shaped the stock throttle,
; so tuning stays in VESC Tool and applies instantly. Clamped away from 0 so a
; zero in the config can't divide-by-zero and kill the arbiter thread.
(defun ramp-pos () (clampf (conf-get 'adc-ramp-time-pos) 0.05 5.0))
(defun ramp-neg () (clampf (conf-get 'adc-ramp-time-neg) 0.05 5.0))
; Throttle output: VESC-Tool-style curve, then a slew limit toward the target
; (replaces the ADC app's pos/neg ramping), then RELATIVE current — scales live
; with l-current-max × profile scale and the thermal derating, so changing
; Motor Current Max in VESC Tool takes effect immediately. A released throttle
; (thr <= 0.05) ramps DOWN through the same slew — the arbiter keeps calling
; this until out-rel reaches 0 instead of cutting the current instantly.
(defun throttle-out (thr) {
    (let ((target (if (> thr 0.05)
                      (throttle-curve thr thr-curve-accel 0.0 thr-curve-mode)
                      0.0)))
        (setq out-rel (slew out-rel target (ramp-pos) (ramp-neg))))
    (set-current-rel out-rel 0.2)
})
; Brake output, same shape and same ADC ramp times (the stock ADC app ramped
; the brake with them too): grabbing the lever is a fast ramp, not an instant
; regen hit, and releasing it tails off instead of stepping to 0.
(defun brake-out (brk) {
    (let ((target (if (> brk 0.05) brk 0.0)))
        (setq brk-rel (slew brk-rel target (ramp-pos) (ramp-neg))))
    (set-brake-rel brk-rel)
})
; Cruise output: PI on ERPM error → current. Integrator anti-windup-clamped to
; the live limit (l-current-max × profile scale, both read fresh each tick so a
; VESC Tool write or profile switch applies immediately; the firmware control
; loop additionally clamps for thermal derating). Sign-aware for reverse cruise.
(defun cruise-out () {
    (let ((err (- cruise-rpm (get-rpm)))
          (imax (* (conf-get 'l-current-max) (conf-get 'l-current-max-scale)))) {
        (if (>= cruise-rpm 0) {
            (setq cruise-i (clampf (+ cruise-i (* cruise-ki err ctl-dt)) 0.0 imax))
            (set-current (clampf (+ (* cruise-kp err) cruise-i) 0.0 imax) 0.2)
        } {
            (setq cruise-i (clampf (+ cruise-i (* cruise-ki err ctl-dt)) (- imax) 0.0))
            (set-current (clampf (+ (* cruise-kp err) cruise-i) (- imax) 0.0) 0.2)
        })
    })
})
; THE motor arbiter — the only place that commands the motor. The native ADC
; app stays configured (its thread keeps decoding the throttle/brake pots for
; get-adc-decoded, and VESC Tool keeps its calibration UI) but its OUTPUT is
; suppressed with a rolling 1.5 s disable that this loop keeps extending. If
; this script ever dies: motor stops via the motor-command timeout (every
; set-* here feeds it), and ~1.5 s later the stock ADC throttle comes back —
; the bike stays rideable (without cruise/PAS) instead of bricking.
; Priority: master-off > brake > throttle > cruise > PAS > coast.
(defun motor-control-loop () {
    (loopwhile t {
        (app-disable-output 1500)
        (let ((thr   (get-adc-decoded 0))
              (brake (get-adc-decoded 1))) {
            ; Safe start: no output until the throttle has been seen released
            ; once (protects against a stuck/held throttle at script start).
            (if (< thr 0.05) (setq armed 1))
            (if (= armed 0) (setq thr 0.0))
            ; Immobiliser: kill the throttle request outright. Deliberately
            ; NOT a branch above the brake — regen braking must keep working
            ; while locked (the bike can still be rolled or pushed downhill).
            (if (= locked 1) {
                (setq thr 0.0)
                (if (= cruise-active 1) (deactivate-cruise-control))
            })
            ; A branch stays selected while its slew tails off (out-rel /
            ; brk-rel > 0), so releasing throttle or brake ramps down smoothly
            ; instead of stepping the current to 0.
            (cond
                ((= throttle-on 0) {          ; panel master switch — coast
                    (setq out-rel 0.0)
                    (setq brk-rel 0.0)
                    (set-current 0) })
                ((or (> brake 0.05) (> brk-rel 0.001)) {  ; 1. brake
                    (if (> brake 0.05) (deactivate-cruise-control))
                    (setq out-rel 0.0)        ; throttle cut is fine under brake
                    (brake-out brake) })      ; full range, never profile-scaled
                ((or (> thr 0.05) (> out-rel 0.001)) {    ; 2. throttle
                    (if (> thr 0.05) (deactivate-cruise-control))
                    (throttle-out thr) })
                ((and (= locked 0) (= cruise-active 1))   ; 3. cruise (PI → current)
                    (cruise-out))
                ((and (= locked 0)            ; 4. pedal assist from head unit
                      (> pas-amps 0.0)
                      (< (secs-since pas-seen) 0.4))
                    ; Stale setpoint (sensor/link dropped) falls through to
                    ; coast — the P4 watchdog also sends an explicit 0.
                    (set-current pas-amps 0.2))  ; fw clamps to lo_current_max
                (t                            ; 5. coast
                    (set-current 0)))
        })
        (sleep ctl-dt)
    })
})
(defun panel-on-shutdown () {
    (if (or (= beep-vol-dirty 1) (= melody-vol-dirty 1)) {
        (shutdown-hold t)
        (if (= beep-vol-dirty 1) {
            (eeprom-store-i beep-vol-addr beep-vol) (setq beep-vol-dirty 0) })
        (if (= melody-vol-dirty 1) {
            (eeprom-store-i melody-vol-addr melody-vol) (setq melody-vol-dirty 0) })
        (shutdown-hold nil)
    })
})
; Volumes change via the panel slider (many intermediate values per drag) and
; must survive a reboot. Persisting only in panel-on-shutdown was unreliable:
; event-shutdown fires only on a real power-off, not on a bench / USB / re-flash
; reboot, so eeprom-store-i never ran. Flush the dirty volumes on a slow timer
; instead — coalesces a drag into ~one flash write and does not depend on a
; clean shutdown. panel-on-shutdown stays as a final flush.
(defun persist-volumes-loop () {
    (loopwhile t {
        (if (= beep-vol-dirty 1) {
            (eeprom-store-i beep-vol-addr beep-vol) (setq beep-vol-dirty 0) })
        (if (= melody-vol-dirty 1) {
            (eeprom-store-i melody-vol-addr melody-vol) (setq melody-vol-dirty 0) })
        (sleep 2)
    })
})
(defun panel-event-loop () {
    (loopwhile t {
        (recv ((event-data-rx . (? data)) (panel-handle data))
              (event-shutdown               (panel-on-shutdown))
              (_ nil))
    })
})
(def melody '(
  (330 0.124) (0 0.124) (330 0.124) (0 0.124) (440 0.124) (0 0.124)
  (440 0.124) (0 0.124) (330 0.124) (0 0.124) (330 0.124) (0 0.124)
  (262 0.124) (0 0.620) (330 0.124) (0 0.372) (330 0.124) (0 0.124)
  (330 0.124) (0 0.372) (330 0.124) (0 0.620) (294 0.124) (0 0.372)
  (294 0.124) (0 0.124) (294 0.124) (0 0.372) (294 0.124) (0 0.372)
  (330 0.124) (0 0.124) (330 0.124) (0 0.124) (440 0.124) (0 0.124)
  (440 0.124) (0 0.124) (330 0.124) (0 0.124) (330 0.124) (0 0.124)
  (262 0.124) (0 0.372) (330 0.124) (0 0.124) (330 0.124) (0 0.124)
  (440 0.124) (0 0.124) (440 0.124) (0 0.124) (330 0.124) (0 0.124)
  (330 0.124) (0 0.124) (262 0.124) (0 0.620) (330 0.124) (0 0.372)
  (330 0.124) (0 0.124) (330 0.124) (0 0.372) (330 0.124) (0 0.620)
  (294 0.124) (0 0.372) (294 0.124) (0 0.124) (294 0.124) (0 0.372)
  (294 0.124) (0 0.372) (330 0.124) (0 0.124) (330 0.124) (0 0.124)
  (440 0.124) (0 0.124) (440 0.124) (0 0.124) (330 0.124) (0 0.124)
  (330 0.124) (0 0.124) (262 0.124) (0 0.372) (330 0.124) (0 0.124)
  (330 0.124) (0 0.124) (440 0.124) (0 0.124) (440 0.124) (0 0.124)
  (330 0.124) (0 0.124) (330 0.124) (0 0.124) (262 0.124) (0 0.620)
  (330 0.124) (0 0.372) (330 0.124) (0 0.124) (330 0.124) (0 0.372)
  (330 0.124) (0 0.620) (294 0.124) (0 0.372) (294 0.124) (0 0.124)
  (294 0.124) (0 0.372) (294 0.124) (0 0.372) (330 0.124) (0 0.124)
  (330 0.124) (0 0.124) (440 0.124) (0 0.124) (440 0.124) (0 0.124)
  (330 0.124) (0 0.124) (330 0.124) (0 0.124) (262 0.124) (0 0.372)
  (330 0.124) (0 0.124) (330 0.124) (0 0.124) (440 0.124) (0 0.124)
  (440 0.124) (0 0.124) (330 0.124) (0 0.124) (330 0.124) (0 0.124)
  (262 0.124) (0 0.620) (330 0.124) (0 0.372) (330 0.124) (0 0.124)
  (330 0.124) (0 0.372) (330 0.124) (0 0.620) (294 0.124) (0 0.372)
  (294 0.124) (0 0.124) (294 0.124) (0 0.372) (294 0.124) (0 0.372)
  (330 0.124) (0 0.124) (330 0.124) (0 0.124) (440 0.124) (0 0.124)
  (440 0.124) (0 0.124) (330 0.124) (0 0.124) (330 0.124) (0 0.124)
  (262 0.124) (0 0.372) (330 0.124)
))

; Spawn threads and enable events LAST — after melody (defined just above)
; is bound. panel-event-loop calls panel-action, which references melody (cid 6);
; spawned earlier, an incoming panel command during load would hit melody while
; still unbound → the handler thread dies → panel/melodies dead.
; These are plain expressions (not definitions), so @const-start does not flash
; them — they just execute here, which is exactly what we want.
(event-register-handler (spawn panel-event-loop))
(event-enable 'event-data-rx)
(event-enable 'event-shutdown)
(spawn 150 persist-volumes-loop)
(spawn 150 motor-control-loop)
@const-end
