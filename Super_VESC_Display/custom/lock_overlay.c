/*
 * PIN immobiliser overlay + ride-profile picker.
 *
 * The overlay lives on lv_layer_top() rather than being an lv_scr_load()
 * screen, for two reasons:
 *   - it must cover the Android Auto video output too, not just the dashboard
 *     (ui_mode can be UI_MODE_AA while the bike is locked);
 *   - it must not disturb the screen stack, so whatever the rider had open is
 *     still there when the bike unlocks.
 * Same trick splash_screen.c uses.
 *
 * IMPORTANT: this file is UI only. It cannot immobilise anything. The actual
 * lock lives in the LispBM script on the VESC (lisp/main.lisp: `locked`,
 * consulted by motor-control-loop) and the overlay only mirrors the state the
 * script reports over the DASH packet. If this display is unplugged the bike
 * stays locked; if this display lies, the bike does not care.
 *
 * Device-only — the desktop simulator gets no-op stubs at the bottom.
 */
#include "lvgl.h"
#include "custom.h"

#ifdef LV_REALDEVICE

#include "vesc_can/vesc_lisp_panel.h"

#include <stdio.h>
#include <string.h>
#include <stdlib.h>

/* palette — matches pas_screen.c / realtime_viewer.c */
#define COL_BG      0x07090A
#define COL_PANEL   0x12181C
#define COL_BTN     0x2a3440
#define COL_ACCENT  0xB6FF2E
#define COL_RED     0xFF3B30
#define COL_AMBER   0xFFA500
#define COL_TEXT    0xFFFFFF
#define COL_DIM     0x8A9499

#define PIN_MAX_DIGITS 8

static lv_obj_t *s_overlay;      /* full-screen container on lv_layer_top() */
static lv_obj_t *s_dots;         /* masked PIN entry */
static lv_obj_t *s_msg;          /* status / error line */
static char      s_entry[PIN_MAX_DIGITS + 1];
static int       s_entry_len;
static int       s_last_tries = -1;
static bool      s_waiting;      /* an unlock was sent, awaiting the DASH reply */

static lv_obj_t *s_picker;       /* profile picker modal (independent of lock) */

/* ---------------------------------------------------------------- helpers */

const char *ride_profile_name(uint8_t idx)
{
    switch (idx) {
    case 0:  return "ECO";
    case 1:  return "NORMAL";
    case 2:  return "SPORT";
    default: return "MODE";
    }
}

static void refresh_dots(void)
{
    char buf[PIN_MAX_DIGITS * 2 + 1];
    int  n = 0;
    for (int i = 0; i < s_entry_len && n < (int)sizeof(buf) - 2; i++) {
        buf[n++] = '*';
    }
    buf[n] = '\0';
    lv_label_set_text(s_dots, s_entry_len ? buf : "- - - -");
}

static void set_msg(const char *text, uint32_t colour)
{
    lv_label_set_text(s_msg, text);
    lv_obj_set_style_text_color(s_msg, lv_color_hex(colour), 0);
}

/* --------------------------------------------------------------- keypad */

static void key_cb(lv_event_t *e)
{
    lv_obj_t   *bm  = lv_event_get_target(e);
    const char *txt = lv_btnmatrix_get_btn_text(bm, lv_btnmatrix_get_selected_btn(bm));
    if (!txt) return;

    if (strcmp(txt, LV_SYMBOL_BACKSPACE) == 0) {
        if (s_entry_len > 0) s_entry[--s_entry_len] = '\0';
        refresh_dots();
        return;
    }
    if (strcmp(txt, LV_SYMBOL_OK) == 0) {
        if (s_entry_len < 4) {
            set_msg("PIN is at least 4 digits", COL_AMBER);
            return;
        }
        /* strtol, not atoi: a leading-zero PIN like 0042 must not be read as
         * octal, and we want the whole thing as a plain decimal integer since
         * that is what the script hashes. */
        long pin = strtol(s_entry, NULL, 10);
        vesc_lisp_panel_send_unlock((int32_t)pin);
        s_waiting   = true;
        s_entry_len = 0;
        s_entry[0]  = '\0';
        refresh_dots();
        set_msg("Checking...", COL_DIM);
        return;
    }
    if (s_entry_len < PIN_MAX_DIGITS) {
        s_entry[s_entry_len++] = txt[0];
        s_entry[s_entry_len]   = '\0';
        refresh_dots();
    }
}

static const char *s_keymap[] = {
    "1", "2", "3", "\n",
    "4", "5", "6", "\n",
    "7", "8", "9", "\n",
    LV_SYMBOL_BACKSPACE, "0", LV_SYMBOL_OK, ""
};

static void build_overlay(void)
{
    s_overlay = lv_obj_create(lv_layer_top());
    lv_obj_remove_style_all(s_overlay);
    lv_obj_set_size(s_overlay, LV_PCT(100), LV_PCT(100));
    lv_obj_set_style_bg_color(s_overlay, lv_color_hex(COL_BG), 0);
    lv_obj_set_style_bg_opa(s_overlay, LV_OPA_COVER, 0);
    lv_obj_clear_flag(s_overlay, LV_OBJ_FLAG_SCROLLABLE);
    /* Eats every touch while shown, so nothing behind it can be operated. */
    lv_obj_add_flag(s_overlay, LV_OBJ_FLAG_CLICKABLE);

    lv_obj_t *title = lv_label_create(s_overlay);
    lv_label_set_text(title, LV_SYMBOL_WARNING "  IMMOBILISED");
    lv_obj_set_style_text_color(title, lv_color_hex(COL_RED), 0);
    lv_obj_set_style_text_font(title, &lv_font_montserrat_28, 0);
    lv_obj_align(title, LV_ALIGN_TOP_LEFT, 40, 46);

    lv_obj_t *sub = lv_label_create(s_overlay);
    /* Say this out loud on the screen: a rider who thinks the brakes are cut
     * will do something stupid at a red light. */
    lv_label_set_text(sub, "Enter PIN to ride.\nBrakes and lights are unaffected.");
    lv_obj_set_style_text_color(sub, lv_color_hex(COL_DIM), 0);
    lv_obj_align(sub, LV_ALIGN_TOP_LEFT, 40, 96);

    s_dots = lv_label_create(s_overlay);
    lv_obj_set_style_text_color(s_dots, lv_color_hex(COL_ACCENT), 0);
    lv_obj_set_style_text_font(s_dots, &lv_font_montserrat_28, 0);
    lv_obj_align(s_dots, LV_ALIGN_TOP_LEFT, 40, 176);
    refresh_dots();

    s_msg = lv_label_create(s_overlay);
    lv_obj_set_width(s_msg, 320);
    lv_label_set_long_mode(s_msg, LV_LABEL_LONG_WRAP);
    lv_obj_align(s_msg, LV_ALIGN_TOP_LEFT, 40, 224);
    set_msg("", COL_DIM);

    lv_obj_t *bm = lv_btnmatrix_create(s_overlay);
    lv_btnmatrix_set_map(bm, s_keymap);
    lv_obj_set_size(bm, 300, 360);
    lv_obj_align(bm, LV_ALIGN_TOP_RIGHT, -40, 60);
    lv_obj_set_style_bg_color(bm, lv_color_hex(COL_PANEL), 0);
    lv_obj_set_style_border_width(bm, 0, 0);
    lv_obj_set_style_bg_color(bm, lv_color_hex(COL_BTN), LV_PART_ITEMS);
    lv_obj_set_style_text_color(bm, lv_color_hex(COL_TEXT), LV_PART_ITEMS);
    lv_obj_set_style_text_font(bm, &lv_font_montserrat_28, LV_PART_ITEMS);
    lv_obj_add_event_cb(bm, key_cb, LV_EVENT_VALUE_CHANGED, NULL);
}

/* ------------------------------------------------------------ public API */

void lock_overlay_set_state(bool locked, bool pin_set, int pin_tries)
{
    if (!locked) {
        if (s_overlay) {
            lv_obj_del(s_overlay);
            s_overlay    = NULL;
            s_dots       = NULL;
            s_msg        = NULL;
            s_entry_len  = 0;
            s_entry[0]   = '\0';
            s_last_tries = -1;
            s_waiting    = false;
        }
        return;
    }
    if (!pin_set) return;          /* locked with no PIN configured: no way in */

    if (!s_overlay) {
        build_overlay();
        s_last_tries = pin_tries;
    }

    /* The script's wrong-PIN counter is the only "your PIN was wrong" signal we
     * get — the reply to a failed unlock is just an unchanged DASH packet. */
    if (pin_tries != s_last_tries) {
        if (pin_tries > s_last_tries) {
            if (pin_tries > 4) {
                set_msg("Too many attempts - wait 30 s", COL_RED);
            } else {
                char buf[48];
                snprintf(buf, sizeof(buf), "Wrong PIN (%d of 5)", pin_tries);
                set_msg(buf, COL_RED);
            }
        }
        s_last_tries = pin_tries;
        s_waiting    = false;
    }
}

bool lock_overlay_is_shown(void)
{
    return s_overlay != NULL;
}

/* ---------------------------------------------------- profile picker modal */

static void picker_close(void)
{
    if (s_picker) {
        lv_obj_del(s_picker);
        s_picker = NULL;
    }
}

static void picker_pick_cb(lv_event_t *e)
{
    int idx = (int)(intptr_t)lv_event_get_user_data(e);
    vesc_lisp_panel_send_profile((int32_t)idx);
    picker_close();
}

static void picker_dismiss_cb(lv_event_t *e)
{
    (void)e;
    picker_close();
}

void show_profile_picker(void)
{
    if (s_picker) return;
    if (lock_overlay_is_shown()) return;   /* pick a mode after you unlock */

    vlp_dash_t d;
    bool have = vesc_lisp_panel_get_dash(&d);
    int  count = (have && d.profile_count > 0) ? d.profile_count : 3;
    if (count > 3) count = 3;

    s_picker = lv_obj_create(lv_layer_top());
    lv_obj_remove_style_all(s_picker);
    lv_obj_set_size(s_picker, LV_PCT(100), LV_PCT(100));
    lv_obj_set_style_bg_color(s_picker, lv_color_black(), 0);
    lv_obj_set_style_bg_opa(s_picker, LV_OPA_70, 0);
    lv_obj_add_flag(s_picker, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_add_event_cb(s_picker, picker_dismiss_cb, LV_EVENT_CLICKED, NULL);

    lv_obj_t *card = lv_obj_create(s_picker);
    lv_obj_set_size(card, 560, 260);
    lv_obj_center(card);
    lv_obj_set_style_bg_color(card, lv_color_hex(COL_PANEL), 0);
    lv_obj_set_style_border_width(card, 0, 0);
    lv_obj_set_style_radius(card, 12, 0);
    lv_obj_clear_flag(card, LV_OBJ_FLAG_SCROLLABLE);

    lv_obj_t *t = lv_label_create(card);
    lv_label_set_text(t, "RIDE MODE");
    lv_obj_set_style_text_color(t, lv_color_hex(COL_DIM), 0);
    lv_obj_align(t, LV_ALIGN_TOP_MID, 0, 4);

    for (int i = 0; i < count; i++) {
        /* SPORT is PIN-gated in the script (sport-needs-pin). Grey it out when
         * the PIN has not been entered this power cycle rather than letting the
         * tap silently bounce off the VESC. */
        bool gated = (i == 2) && have && d.pin_set && !d.pin_ok;

        lv_obj_t *b = lv_btn_create(card);
        lv_obj_set_size(b, 160, 120);
        lv_obj_align(b, LV_ALIGN_CENTER, (i - 1) * 176, 16);
        lv_obj_set_style_bg_color(b, lv_color_hex(gated ? COL_PANEL : COL_BTN), 0);
        lv_obj_set_style_border_width(b, 2, 0);
        lv_obj_set_style_border_color(b,
            lv_color_hex((have && d.current_profile == i) ? COL_ACCENT : COL_BTN), 0);

        lv_obj_t *l = lv_label_create(b);
        lv_label_set_text(l, gated ? "SPORT\n" LV_SYMBOL_WARNING " PIN" : ride_profile_name(i));
        lv_obj_set_style_text_color(l, lv_color_hex(gated ? COL_DIM : COL_TEXT), 0);
        lv_obj_set_style_text_align(l, LV_TEXT_ALIGN_CENTER, 0);
        lv_obj_center(l);

        if (!gated) {
            lv_obj_add_event_cb(b, picker_pick_cb, LV_EVENT_CLICKED,
                                (void *)(intptr_t)i);
        }
    }
}

#else  /* simulator */

const char *ride_profile_name(uint8_t idx)
{
    switch (idx) {
    case 0:  return "ECO";
    case 1:  return "NORMAL";
    case 2:  return "SPORT";
    default: return "MODE";
    }
}
void lock_overlay_set_state(bool locked, bool pin_set, int pin_tries)
{
    (void)locked; (void)pin_set; (void)pin_tries;
}
bool lock_overlay_is_shown(void) { return false; }
void show_profile_picker(void) { }

#endif
