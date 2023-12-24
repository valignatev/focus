#scope_module

XCB_Display :: struct {
    #as base: Base_Display;

    handle: *xcb_connection_t;
    screen: *xcb_screen_t;
    xi_ext_opcode: u8;
    xkb_event_base: u8;
    file_descriptor: s32;

    kb_context: *xkb_context;
    kb_keymap : *xkb_keymap;
    kb_state  : *xkb_state;
    kb_compose_table: *xkb_compose_table;
    kb_compose_state: *xkb_compose_state;
    mod_idx_shift     : u32;
    mod_idx_ctrl      : u32;
    mod_idx_alt       : u32;
    mod_idx_caps_lock : u32;
    mod_idx_super     : u32;
    mod_idx_alt_gr    : u32;
    core_kb_id        : s32;

    global_atoms: struct {
        WM_PROTOCOLS: xcb_atom_t;
        WM_DELETE_WINDOW: xcb_atom_t;
        WM_NAME: xcb_atom_t;

        _NET_WM_ICON: xcb_atom_t;
    }
}

XCB_Window :: struct {
    #as base: Base_Window;

    display: *XCB_Display;
    handle: u32;
}

xcb_init_display :: (display: *Display) -> bool {
    if !load_procs(*xcb,       "libxcb.so",        "xcb_",       *xcb_loaded)        return false;
    if !load_procs(*xcb_input, "libxcb-xinput.so", "xcb_input_", *xcb_xinput_loaded) return false;
    if !load_procs(*xcb_xkb,   "libxcb-xkb.so",    "xcb_xkb_",   *xcb_xkb_loaded)    return false;
    if !xkbcommon_load(init_xcb_compat=true) return false;

    connection := xcb.connect(null, null);
    if !connection {
        log_error("Failed to connect to X server");
        return false;
    }

    xi_ext := xcb.get_extension_data(connection, xcb_input.id);
    if !xi_ext || !xi_ext.present {
        log_error("XInput extenstion not available");
        return false;
    }

    xkb_ext := xcb.get_extension_data(connection, xcb_xkb.id);
    if !xkb_ext || !xkb_ext.present {
        log_error("XKB extension not available");
        return false;
    }

    xkb_ver_major : u16 = 1;
    xkb_ver_minor : u16 = 0;
    xkb_event_base : u8;
    if !xkb_x11_setup_xkb_extension(connection, xkb_ver_major, xkb_ver_minor, 0, *xkb_ver_major, *xkb_ver_minor, *xkb_event_base, null) {
        log_error("Failed to set up XKB extension");
        return false;
    }
    log("xcb-xkb version %.%", xkb_ver_major, xkb_ver_minor);

    affect := xcb_xkb_event_type_t.NEW_KEYBOARD_NOTIFY | .MAP_NOTIFY | .STATE_NOTIFY;
    map_parts := xcb_xkb_map_part_t.KEY_TYPES | .KEY_SYMS | .MODIFIER_MAP | .EXPLICIT_COMPONENTS | .KEY_ACTIONS | .VIRTUAL_MODS | .VIRTUAL_MOD_MAP;
    state_parts := xcb_xkb_state_part_t.MODIFIER_BASE | .MODIFIER_LATCH | .MODIFIER_LOCK | .GROUP_BASE | .GROUP_LATCH | .GROUP_LOCK;
    details := xcb_xkb_select_events_details_t.{
        affectNewKeyboard = xx xcb_xkb_nkn_detail_t.KEYCODES,
        newKeyboardDetails = xx xcb_xkb_nkn_detail_t.KEYCODES,
        affectState = xx state_parts,
        stateDetails = xx state_parts,
    };
    core := xkb_x11_get_core_keyboard_device_id(connection);
    xcb_xkb.select_events_aux(connection, xx core, xx affect, 0, 0, xx map_parts, xx map_parts, *details);

    {
        push_allocator(temp);

        tis := cast(*Type_Info_Struct) type_of(display.xcb.global_atoms);
        assert(tis.type == .STRUCT);

        info: [..] struct {
            cookie: xcb_intern_atom_cookie_t;
            atom: *xcb_atom_t;
            name: string;
        };
        array_reserve(*info, tis.members.count);
        for m : tis.members {
            if m.type != type_info(xcb_atom_t) continue;
            array_add(*info, .{
                cookie = xcb.intern_atom(connection, 1, xx m.name.count, m.name.data),
                atom = cast(*xcb_atom_t)(cast(*u8) *display.xcb.global_atoms + m.offset_in_bytes),
                name = m.name,
            });
        }

        for i : info {
            error: *xcb_generic_error_t;
            reply := xcb.intern_atom_reply(connection, i.cookie, *error);
            if !reply {
                if error  log_error("intern_atom_reply(): %", error.*);
                continue;
            }
            i.atom.* = reply.atom;
            libc_free(reply);
        }
    }

    xd: *XCB_Display = display;
    xd.handle          = connection;
    xd.screen          = xcb.setup_roots_iterator(xcb.get_setup(connection)).data;
    xd.xi_ext_opcode   = xi_ext.major_opcode;
    xd.xkb_event_base  = xkb_event_base;
    xd.file_descriptor = xcb.get_file_descriptor(connection);

    bd: *Base_Display = display;
    bd.type = XCB_Display;

    bd.create_window              = xcb_create_window;
    bd.set_fixed_scaling          = xcb_set_fixed_scaling;
    bd.translate_key_code         = x11_translate_key_code;
    bd.wait_for_events            = xcb_wait_for_events;
    bd.update_window_events       = xcb_update_window_events;
    bd.clipboard_set_text         = xcb_clipboard_set_text;
    bd.clipboard_get_text         = xcb_clipboard_get_text;
    bd.get_mouse_pointer_position = xcb_get_mouse_pointer_position;

    if !reinit_xkb_state(xd) return false;

    create_gl_context(display);

    return true;
}

xcb_create_window :: (display: *Display, window: *Window, width: int, height: int, window_name: string,
    window_x: int, window_y: int, parent: *Window, background_color_rgb: [3]float) -> bool
{
    xd : *XCB_Display = display;
    wid := xcb.generate_id(xd.handle);

    prop_mask := xcb_cw_t.BACK_PIXEL | .EVENT_MASK;
    prop_list := u32.[
        xd.screen.black_pixel,
        xx (xcb_event_mask_t.EXPOSURE | .STRUCTURE_NOTIFY | .FOCUS_CHANGE),
    ];

    xcb.create_window_checked(
        c=xd.handle,
        depth=XCB_COPY_FROM_PARENT,
        wid=wid,
        parent=xd.screen.root,
        x=0, y=0, width=xx width, height=xx height, border_width=1,
        _class=.XCB_WINDOW_CLASS_INPUT_OUTPUT,
        visual=xd.screen.root_visual,
        value_mask=prop_mask,
        value_list=prop_list.data,
    );

    xcb.change_property(
        xd.handle,
        xx xcb_prop_mode_t.REPLACE,
        wid,
        xd.global_atoms.WM_PROTOCOLS,
        xx xcb_atom_enum_t.ATOM,
        32, 1, *xd.global_atoms.WM_DELETE_WINDOW);

    xw: *XCB_Window = window;
    xw.display = display;
    xw.handle  = wid;

    bw: *Base_Window = window;
    bw.type    = XCB_Window;
    bw.display = display;

    bw.set_icon_from_raw_data     = xcb_set_icon_from_raw_data;
    bw.toggle_fullscreen          = xcb_toggle_fullscreen;
    bw.has_native_handle          = xcb_has_native_handle;
    bw.get_dimensions             = xcb_get_dimensions;
    bw.get_render_dimensions      = xcb_get_render_dimensions;
    bw.get_mouse_pointer_position = xcb_get_mouse_pointer_position;
    bw.enable_dnd                 = xcb_enable_dnd;
    bw.set_window_title           = xcb_set_window_title;
    bw.maximize_window            = xcb_maximize_window;
    bw.set_cursor_from_theme      = xcb_set_cursor_from_theme;
    bw.get_dpi_scaling_factor     = xcb_get_dpi_scaling_factor;

    create_gl_surface(window);

    mask: struct {
        using #as hdr: xcb_input_event_mask_t;
        data: [8]xcb_input_xi_event_mask_t;
    }
    mask.deviceid = xx xcb_input_device_t.ALL_MASTER;
    mask.mask_len = 1;
    mask.data[0]  = .KEY_PRESS | .KEY_RELEASE;
    xcb_input.xi_select_events(xd.handle, wid, 1, *mask);

    xcb.map_window(xd.handle, wid);
    xcb.flush(xd.handle);

    return true;
}

xcb_set_fixed_scaling :: (display: *Display, factor: float) {
}

xcb_wait_for_events :: (display: *Display) {
    xcb_check_usage(display, null);

    while true {
        pfd: [3]pollfd;
        pfd[0].fd = display.xcb.file_descriptor;
        pfd[0].events = POLLIN;
        pfd[1].fd = timers_epfd;
        pfd[1].events = POLLIN;
        pfd[2].fd = display.base.loop_wakeup_event;
        pfd[2].events = POLLIN;
        result := poll(pfd.data, xx pfd.count, -1);

        if result < 0 {
            error := errno();
            if error == EINTR continue;
            if error == EINVAL {
                log_error("Can't poll on xcb file descriptor. Max amount of opened file descriptors (RLIMIT_NOFILE) exceeded.");
            } else if error == ENOMEM {
                log_error("poll(2) failed with ENOMEM - it is unable to allocate memory for its internal use");
            } else if error == EFAULT {
                log_error("xcb poll is configured incorrectly - file descriptors are outside of the accessible address space");
            } else {
                log_error("Unknown error happened while waiting on xcb file descriptor. Error code: %", error);
            }
            return;
        }

        if pfd[2].revents & POLLIN {
            consume_loop_wakeup_event(display);
            break;
        }

        if pfd[1].revents & POLLIN {
            timers_tick();
            break;
        }

        if pfd[0].revents & POLLIN {
            break;
        }
    }
}

xcb_update_window_events :: (display: *Display) {
    xd: *XCB_Display = display;

    while event_loop := true {
        event := xcb.poll_for_event(xd.handle);
        if !event break;

        if event.response_type == xd.xkb_event_base {
            geev := cast(*xcb_generic_event_t) event;
            if geev.pad0 == {
                case XCB_XKB_NEW_KEYBOARD_NOTIFY; #through;
                case XCB_XKB_MAP_NOTIFY;
                    log("Reloading keyboard map");
                    reinit_xkb_state(xd);

                case XCB_XKB_STATE_NOTIFY;
                    neev := cast(*xcb_xkb_state_notify_event_t) event;
                    xkb_state_update_mask(xd.kb_state,
                        neev.baseMods, neev.latchedMods, neev.lockedMods,
                        xx neev.baseGroup, xx neev.latchedGroup, xx neev.lockedGroup);
            }
        } else if event.response_type & ~0x80 == {
            case XCB_CLIENT_MESSAGE;
                clev := cast(*xcb_client_message_event_t) event;
                if clev.data.data32[0] == xx xd.global_atoms.WM_DELETE_WINDOW {
                    ev: Input.Event;
                    ev.type = .QUIT;
                    array_add(*display.base.events_this_frame, ev);
                }

            case XCB_EXPOSE;
                xcb.flush(xd.handle); // ??

            case XCB_CONFIGURE_NOTIFY;
                cfev := cast(*xcb_configure_notify_event_t) event;
                ld_win := get_by_native_handle(display, xx cfev.window);
                if ld_win Input.add_resize_record(ld_win, cfev.width, cfev.height);

            case XCB_FOCUS_IN;
                Input.input_application_has_focus = true;
                array_add(*display.base.events_this_frame, .{type=.WINDOW});

            case XCB_FOCUS_OUT;
                Input.input_application_has_focus = false;
                array_add(*display.base.events_this_frame, .{type=.WINDOW});

            case XCB_GE_GENERIC;
                geev := cast(*xcb_ge_generic_event_t) event;
                if geev.extension != xd.xi_ext_opcode continue;
                if geev.event_type == {
                    case XCB_INPUT_KEY_PRESS; #through;
                    case XCB_INPUT_KEY_RELEASE;
                        kpev := cast(*xcb_input_key_press_event_t) event;

                        utf32: u32;
                        is_printable: bool;
                        keycode: xkb_keycode_t = kpev.detail;
                        keysym := xkb_state_key_get_one_sym(xd.kb_state, keycode);

                        ji_event: Input.Event;
                        ji_event.type = .KEYBOARD;
                        ji_event.shift_pressed    = xkb_state_mod_index_is_active(xd.kb_state, xd.mod_idx_shift, .XKB_STATE_MODS_EFFECTIVE) == 1;
                        ji_event.ctrl_pressed     = xkb_state_mod_index_is_active(xd.kb_state, xd.mod_idx_ctrl,  .XKB_STATE_MODS_EFFECTIVE) == 1;
                        ji_event.alt_pressed      = xkb_state_mod_index_is_active(xd.kb_state, xd.mod_idx_alt,   .XKB_STATE_MODS_EFFECTIVE) == 1;
                        ji_event.cmd_meta_pressed = xkb_state_mod_index_is_active(xd.kb_state, xd.mod_idx_super, .XKB_STATE_MODS_EFFECTIVE) == 1;

                        if geev.event_type == XCB_INPUT_KEY_PRESS {
                            xkb_compose_state_feed(xd.kb_compose_state, keysym);

                            status := xkb_compose_state_get_status(xd.kb_compose_state);
                            if status == .XKB_COMPOSE_COMPOSED || status == .XKB_COMPOSE_CANCELLED {
                                keysym = xkb_compose_state_get_one_sym(xd.kb_compose_state);
                                xkb_compose_state_reset(xd.kb_compose_state);
                            }

                            utf32 = xkb_keysym_to_utf32(keysym);
                            is_printable = ((utf32 >= 32) && (utf32 != 127));

                            ji_event.key_pressed = 1;
                            ji_event.key_code = x11_translate_key_code(keysym);
                            ji_event.text_input_count = xx is_printable;
                            xd.base.input_button_states[ji_event.key_code] = (Input.Key_Current_State.START | Input.Key_Current_State.DOWN);
                        } else {
                            ji_event.key_pressed = 0;
                            ji_event.key_code = x11_translate_key_code(keysym);
                            xd.base.input_button_states[ji_event.key_code] = Input.Key_Current_State.END;
                        }

                        array_add(*xd.base.events_this_frame, ji_event);

                        if ji_event.key_pressed && is_printable {
                            text_event: Input.Event;
                            text_event.type = .TEXT_INPUT;
                            text_event.key_pressed = 1;
                            text_event.key_code = ji_event.key_code;
                            text_event.utf32 = utf32;
                            array_add(*xd.base.events_this_frame, text_event);
                        }
                }

            case;
                log(">> unhandled event: % %", event.response_type & ~0x80, event.*);
        }
    }
}

xcb_clipboard_set_text :: (display: *Display, text: string) {
}

xcb_clipboard_get_text :: (display: *Display) -> string {
    return "";
}

xcb_get_mouse_pointer_position :: (display: *Display, right_handed := false) -> x: int, y: int, success: bool {
    return 0, 0, true;
}

xcb_set_icon_from_raw_data :: (window: *Window, data: *u8, width: u32, height: u32) {
    xcb_check_usage(null, window);

    xw: *XCB_Window = window;
    xd: *XCB_Display = xw.display;

    // push_allocator(temp);
    // cardinal_data : [..]u64;  // CARDINAL is defined as `long` even though it works with 32bit values...
    // array_resize(*cardinal_data, 2 + width * height, initialize=false);
    // cardinal_data[0] = width;
    // cardinal_data[1] = height;
    // pixels := cast(*u32)data;
    // for 0..width * height - 1 {
    //     cardinal_data[2 + it] = pixels[it];
    // }

    // xcb.change_property_checked(
    //     xd.handle,
    //     xx xcb_prop_mode_t.REPLACE,
    //     xw.handle,
    //     xd.global_atoms._NET_WM_ICON,
    //     xx xcb_atom_enum_t.CARDINAL,
    //     32, xx cardinal_data.count, cardinal_data.data);

    log("set_icon(%x%)", width, height);

    size_data := u32.[width, height];
    xcb.change_property_checked(
        xd.handle,
        xx xcb_prop_mode_t.REPLACE,
        xw.handle,
        xd.global_atoms._NET_WM_ICON,
        xx xcb_atom_enum_t.CARDINAL,
        32, xx size_data.count, size_data.data);
    xcb.change_property_checked(
        xd.handle,
        xx xcb_prop_mode_t.APPEND,
        xw.handle,
        xd.global_atoms._NET_WM_ICON,
        xx xcb_atom_enum_t.CARDINAL,
        32, width * height, data);
}

xcb_toggle_fullscreen :: (window: *Window, desire_fullscreen: bool, saved: *Saved_Window_Info) -> success: bool, width: s32, height: s32 {
    return true, 100, 100;
}

xcb_has_native_handle :: (window: *Window, native_handle: *void) -> bool {
    xcb_check_usage(null, window);
    return window.xcb.handle == xx native_handle;
}

xcb_get_dimensions :: (window: *Window, right_handed: bool) -> (x: s32, y: s32, width: s32, height: s32, success := true) {
    xcb_check_usage(null, window);
    xw : *XCB_Window = window;
    cookie := xcb.get_geometry(xw.display.handle, xw.handle);
    geometry := xcb.get_geometry_reply(xw.display.handle, cookie, null);
    return 0, 0, xx geometry.width, geometry.height, true;
}

xcb_get_render_dimensions :: (window: *Window) -> s32, s32 {
    xcb_check_usage(null, window);
    _, _, w, h, ok := xcb_get_dimensions(window, false);
    if ok return w, h;
    return 1, 1;
}

xcb_get_mouse_pointer_position :: (window: *Window, right_handed: bool) -> x: int, y: int, success: bool {
    xcb_check_usage(null, window);
    return 0, 0, true;
}

xcb_enable_dnd :: (window: *Window, typelist: []string) {
    xcb_check_usage(null, window);
}

xcb_set_window_title :: (window: *Window, title: string) {
    xcb_check_usage(null, window);
}

xcb_maximize_window :: (window: *Window) {
    xcb_check_usage(null, window);
}

xcb_set_cursor_from_theme :: (window: *Window, name: string) {
    xcb_check_usage(null, window);
}

xcb_get_dpi_scaling_factor :: (window: *Window) -> float {
    xcb_check_usage(null, window);
    return 1.0;
}

#scope_file
#load "xcb_fp.jai";
#load "xcb_xinput_fp.jai";
#load "xcb_xkb_fp.jai";

/* we need this to free some stuff that the xcb libraries return */
libc :: #system_library "libc";
libc_free :: (ptr: *void) #foreign libc "free";

generic_c_call :: #type () #c_call;

xcb_loaded := false;
xcb_xinput_loaded := false;
xcb_xkb_loaded := false;

load_procs :: (procs: *$T, libname: string, prefix: $string, loaded: *bool) -> success := false {
    if loaded.* return true;

    dlerror();
    lib := dlopen(temp_c_string(libname), RTLD_NOW);
    if !lib {
        log_error("Failed to load %: %", libname, to_string(dlerror()));
        return false;
    }

    tis := cast(*Type_Info_Struct) type_info(T);
    for m : tis.members {
        dlerror();
        name := tprint("%1%2\0", prefix, m.name);
        if m.type.type == .PROCEDURE {
            if m.flags & .CONSTANT continue;

            pi := cast(*Type_Info_Procedure) m.type;
            if !(pi.procedure_flags & .IS_C_CALL) continue;

            ppfn := cast(*generic_c_call)((cast(*u8) procs) + m.offset_in_bytes);
            ppfn.* = cast(generic_c_call) dlsym(lib, name.data);
            if !ppfn.* {
                log_error("Failed to resolve function '%': %", name, to_string(dlerror()));
                return false;
            }
        } else if m.type.type == .POINTER {
            ppv := cast(**void)((cast(*u8) procs) + m.offset_in_bytes);
            ppv.* = dlsym(lib, name.data);
        }
    }

    loaded.* = true;

    return true;
}

reinit_xkb_state :: (d: *XCB_Display) -> bool {
    core_kb_id := xkb_x11_get_core_keyboard_device_id(d.handle);
    if core_kb_id < 0 {
        log_error("Failed to get device ID for core keyboard");
        return false;
    }

    kb_context := xkb_context_new(.XKB_CONTEXT_NO_FLAGS);
    kb_keymap  := xkb_x11_keymap_new_from_device(kb_context, d.handle, core_kb_id, .XKB_KEYMAP_COMPILE_NO_FLAGS);
    kb_state   := xkb_x11_state_new_from_device(kb_keymap, d.handle, core_kb_id);

    mod_idx_shift     := xkb_keymap_mod_get_index(kb_keymap, XKB_MOD_NAME_SHIFT.data);
    mod_idx_ctrl      := xkb_keymap_mod_get_index(kb_keymap, XKB_MOD_NAME_CTRL.data);
    mod_idx_alt       := xkb_keymap_mod_get_index(kb_keymap, XKB_MOD_NAME_ALT.data);
    mod_idx_caps_lock := xkb_keymap_mod_get_index(kb_keymap, XKB_MOD_NAME_CAPS.data);
    mod_idx_super     := xkb_keymap_mod_get_index(kb_keymap, XKB_MOD_NAME_LOGO.data);
    mod_idx_alt_gr    := xkb_keymap_mod_get_index(kb_keymap, XKB_MOD_NAME_ALT_GR.data);

    kb_compose_table := xkb_compose_table_new_from_locale(kb_context, setlocale(LC_ALL, null), .XKB_COMPOSE_COMPILE_NO_FLAGS);
    kb_compose_state := xkb_compose_state_new(kb_compose_table, .XKB_COMPOSE_STATE_NO_FLAGS);

    xkb_compose_state_unref(d.kb_compose_state);
    xkb_compose_table_unref(d.kb_compose_table);
    xkb_state_unref(d.kb_state);
    xkb_keymap_unref(d.kb_keymap);
    xkb_context_unref(d.kb_context);

    d.kb_context = kb_context;
    d.kb_keymap = kb_keymap;
    d.kb_state = kb_state;
    d.mod_idx_shift = mod_idx_shift;
    d.mod_idx_ctrl = mod_idx_ctrl;
    d.mod_idx_alt = mod_idx_alt;
    d.mod_idx_caps_lock = mod_idx_caps_lock;
    d.mod_idx_super = mod_idx_super;
    d.mod_idx_alt_gr = mod_idx_alt_gr;
    d.kb_compose_table = kb_compose_table;
    d.kb_compose_state = kb_compose_state;
    d.core_kb_id = core_kb_id;

    return true;
}

#scope_module
xcb: XCB_Symbols;
xcb_input: XCB_XInput_Symbols;
xcb_xkb: XCB_XKB_Symbols;
