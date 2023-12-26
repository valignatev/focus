#scope_module

XCB_Display :: struct {
    #as base: Base_Display;

    xlib_dpy: *X11.Display;
    handle: *xcb_connection_t;
    screen: *xcb_screen_t;
    xi_ext_opcode: u8;
    xkb_event_base: u8;
    file_descriptor: s32;

    cursors: Table(string, xcb_cursor_t);

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

    fixed_scaling: bool;
    dpi_override: float;

    global_atoms: struct {
        WM_PROTOCOLS: xcb_atom_t;
        WM_DELETE_WINDOW: xcb_atom_t;
        WM_NAME: xcb_atom_t;

        _NET_WM_ICON: xcb_atom_t;
        _NET_WM_STATE: xcb_atom_t;
        _NET_WM_STATE_MAXIMIZED_VERT: xcb_atom_t;
        _NET_WM_STATE_MAXIMIZED_HORZ: xcb_atom_t;
        _NET_WM_STATE_FULLSCREEN: xcb_atom_t;

        UTF8_STRING: xcb_atom_t;
    }
    atom_names: Table(xcb_atom_t, string);

    devices: Table(xcb_input_device_id_t, *XCB_Device_Info);

    pending_event: *xcb_generic_event_t;
}

XCB_Window :: struct {
    #as base: Base_Window;

    display: *XCB_Display;
    handle: u32;
}

xcb_init_display :: (display: *Display) -> bool {
    if !load_procs(*xcb,        "libxcb.so",        "xcb_",        *xcb_loaded)        return false;
    if !load_procs(*xcb_input,  "libxcb-xinput.so", "xcb_input_",  *xcb_xinput_loaded) return false;
    if !load_procs(*xcb_xkb,    "libxcb-xkb.so",    "xcb_xkb_",    *xcb_xkb_loaded)    return false;
    if !load_procs(*xcb_cursor, "libxcb-cursor.so", "xcb_cursor_", *xcb_cursor_loaded) return false;
    if !xkbcommon_load(init_xcb_compat=true) return false;

    dpy: *X11.Display;
    connection: *xcb_connection_t;

    if display.base.init_flags & .Pure_XCB {
        log("XCB: initializing with pure xcb connection");
        connection = xcb.connect(null, null);
    } else {
        log("XCB: initializing with Xlib connection");

        if !xlib_load(*X11, init_xcb_compat=true) return false;

        dpy = X11.XOpenDisplay(null);
        if !dpy {
            log_error("Failed to connect to X server");
            return false;
        }

        X11.XSetEventQueueOwner(dpy, .XCB);

        connection = X11.XGetXCBConnection(dpy);
    }
    if !connection {
        log_error("Cannot get xcb connection to X server");
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
    log("XCB: xcb-xkb version %.%", xkb_ver_major, xkb_ver_minor);

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

    atom_names: Table(xcb_atom_t, string);
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

            table_add(*atom_names, i.atom.*, i.name);
        }
    }

    xd: *XCB_Display = display;
    xd.xlib_dpy        = dpy;
    xd.handle          = connection;
    xd.screen          = xcb.setup_roots_iterator(xcb.get_setup(connection)).data;
    xd.xi_ext_opcode   = xi_ext.major_opcode;
    xd.xkb_event_base  = xkb_event_base;
    xd.file_descriptor = xcb.get_file_descriptor(connection);
    xd.atom_names      = atom_names;

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
    if !load_cursors(xd) return false;

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

    set_utf8_property(xw, xx xcb_atom_enum_t.WM_NAME, window_name);

    create_gl_surface(window);

    mask: struct {
        using #as hdr: xcb_input_event_mask_t;
        data: [8]xcb_input_xi_event_mask_t;
    }

    mask.deviceid = xx xcb_input_device_t.ALL_MASTER;
    mask.mask_len = 1;
    mask.data[0]  = .KEY_PRESS | .KEY_RELEASE | .BUTTON_PRESS | .BUTTON_RELEASE;
    xcb_input.xi_select_events(xd.handle, wid, 1, *mask);

    mask.deviceid = xx xcb_input_device_t.ALL_MASTER;
    mask.mask_len = 1;
    mask.data[0]  = .RAW_MOTION;
    xcb_input.xi_select_events(xd.handle, xd.screen.root, 1, *mask);

    xcb.map_window(xd.handle, wid);
    xcb.flush(xd.handle);

    return true;
}

xcb_set_fixed_scaling :: (display: *Display, factor: float) {
    xcb_check_usage(display, null);

    xd : *XCB_Display = display;

    xd.fixed_scaling = (factor >= 0.1);
    xd.dpi_override = factor * 96.0;
    for * xd.base.windows {
        _, _, w, h, _ := xcb_get_dimensions(it, false);
        Input.add_resize_record(xx it, w, h);
    }
}

xcb_wait_for_events :: (display: *Display) {
    xcb_check_usage(display, null);

    xd : *XCB_Display = display;

    while true {
        pfd: [3]pollfd;
        pfd[0].fd = xd.file_descriptor;
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
            assert(xd.pending_event == null);
            xd.pending_event = xcb.poll_for_event(xd.handle);
            if !xd.pending_event {
                xcb.flush(xd.handle);
                continue;
            }
            break;
        }
    }
}

xcb_update_window_events :: (display: *Display) {
    xcb_check_usage(display, null);

    xd: *XCB_Display = display;

    event: *xcb_generic_event_t;
    if xd.pending_event {
        event = xd.pending_event;
        xd.pending_event = null;
    } else {
        event = xcb.poll_for_event(xd.handle);
    }

    while event != null {
        defer event = xcb.poll_for_event(xd.handle);

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
                if geev.extension == xd.xi_ext_opcode  handle_xinput_event(xd, geev);

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
    xcb_check_usage(display, null);
    xd: *XCB_Display = display;

    cookie := xcb.query_pointer(xd.handle, xd.screen.root);
    reply  := xcb.query_pointer_reply(xd.handle, cookie, null);

    return reply.root_x, reply.root_y, true;
}

xcb_set_icon_from_raw_data :: (window: *Window, data: *u8, width: u32, height: u32) {
    xcb_check_usage(null, window);

    xw: *XCB_Window = window;
    xd: *XCB_Display = xw.display;

    size_data := u32.[width, height];
    xcb.change_property(
        xd.handle,
        xx xcb_prop_mode_t.REPLACE,
        xw.handle,
        xd.global_atoms._NET_WM_ICON,
        xx xcb_atom_enum_t.CARDINAL,
        32, xx size_data.count, size_data.data);
    xcb.change_property(
        xd.handle,
        xx xcb_prop_mode_t.APPEND,
        xw.handle,
        xd.global_atoms._NET_WM_ICON,
        xx xcb_atom_enum_t.CARDINAL,
        32, width * height, data);
}

xcb_toggle_fullscreen :: (window: *Window, desire_fullscreen: bool, saved: *Saved_Window_Info) -> success: bool, width: s32, height: s32 {
    xcb_check_usage(null, window);

    op : WM_State_Op = ifx desire_fullscreen then .ADD else .REMOVE;
    set_wm_state(window, op, window.xcb.display.global_atoms._NET_WM_STATE_FULLSCREEN);

    _, _, w, h, ok := xcb_get_dimensions(window, false);
    return ok, w, h;
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
    xw : *XCB_Window = window;
    xd := xw.display;

    cookie := xcb.query_pointer(xd.handle, xw.handle);
    reply  := xcb.query_pointer_reply(xd.handle, cookie, null);

    return reply.win_x, reply.win_y, true;
}

xcb_enable_dnd :: (window: *Window, typelist: []string) {
    xcb_check_usage(null, window);
}

xcb_set_window_title :: (window: *Window, title: string) {
    xcb_check_usage(null, window);
    set_utf8_property(window, xx xcb_atom_enum_t.WM_NAME, title);
}

xcb_maximize_window :: (window: *Window) {
    xcb_check_usage(null, window);
    set_wm_state(window, .ADD,
        window.xcb.display.global_atoms._NET_WM_STATE_MAXIMIZED_VERT,
        window.xcb.display.global_atoms._NET_WM_STATE_MAXIMIZED_HORZ);
}

xcb_set_cursor_from_theme :: (window: *Window, name: string) {
    xcb_check_usage(null, window);
    xw : *XCB_Window = window;
    xd := xw.display;
    cursor, found := table_find(*xd.cursors, name);
    if found {
        attrs: xcb_change_window_attributes_value_list_t;
        attrs.cursor = cursor;
        xcb.change_window_attributes_aux(xd.handle, xw.handle, xx xcb_cw_t.CURSOR, *attrs);
    }
}

xcb_get_dpi_scaling_factor :: (window: *Window) -> float {
    xcb_check_usage(null, window);

    xd := window.xcb.display;
    if xd.fixed_scaling return xd.dpi_override / 96.0;

    screen := xd.screen;
    return (cast(float) screen.width_in_pixels / (cast(float) screen.width_in_millimeters / 25.4)) / 96.0;
}

#scope_file
#import "Basic";
#import "Math";

#load "xcb_fp.jai";
#load "xcb_xinput_fp.jai";
#load "xcb_xkb_fp.jai";
#load "xcb_cursor_fp.jai";


/* we need this to free some stuff that the xcb libraries return */
libc :: #system_library "libc";
libc_free :: (ptr: *void) #foreign libc "free";

generic_c_call :: #type () #c_call;

xcb_loaded := false;
xcb_xinput_loaded := false;
xcb_xkb_loaded := false;
xcb_cursor_loaded := false;

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

handle_xinput_event :: (xd: *XCB_Display, geev: *xcb_ge_generic_event_t) {
    if geev.event_type == {
        case XCB_INPUT_KEY_PRESS; #through;
        case XCB_INPUT_KEY_RELEASE; {
            kpev := cast(*xcb_input_key_press_event_t) geev;

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

        case XCB_INPUT_BUTTON_PRESS; #through;
        case XCB_INPUT_BUTTON_RELEASE;
            bpev := cast(*xcb_input_device_button_press_event_t) geev;
            if bpev.child > 3 || bpev.child < 1 return;

            event: Input.Event;
            event.type = .KEYBOARD;
            event.key_pressed = xx (geev.event_type == XCB_INPUT_BUTTON_PRESS);
            if bpev.child == {
                case 1; event.key_code = Input.Key_Code.MOUSE_BUTTON_LEFT;
                case 2; event.key_code = Input.Key_Code.MOUSE_BUTTON_MIDDLE;
                case 3; event.key_code = Input.Key_Code.MOUSE_BUTTON_RIGHT;
                case; assert(false);
            }

            xd.base.input_button_states[event.key_code] =
                ifx event.key_pressed then (Input.Key_Current_State.START | Input.Key_Current_State.DOWN)
                else Input.Key_Current_State.END;

            array_add(*xd.base.events_this_frame, event);

        case XCB_INPUT_RAW_MOTION;
            rmev := cast(*xcb_input_raw_motion_event_t) geev;
            di := get_device_info(xd, rmev.deviceid);
            if !di return;

            axis: []xcb_input_fp3232_t;
            axis.data = xcb_input.raw_button_press_axisvalues_raw(rmev);
            axis.count = xcb_input.raw_button_press_axisvalues_raw_length(rmev);

            valuator_masks: []u32;
            valuator_masks.data = xcb_input.raw_button_press_valuator_mask(rmev);
            valuator_masks.count = xcb_input.raw_button_press_valuator_mask_length(rmev);

            has_vert_scroll, vert_val := get_valuator_value(di.scroll_vert.number, axis, valuator_masks);
            has_horz_scroll, horz_val := get_valuator_value(di.scroll_horz.number, axis, valuator_masks);

            if has_vert_scroll {
                vs := fp3232_to_float(vert_val) / fp3232_to_float(di.scroll_vert.increment);
                if vs > -1.0 && vs < 0.0 vs = -1.0;
                if vs >= 0.0 && vs < 1.0 vs = 1.0;

                event: Input.Event;
                event.type = .MOUSE_WHEEL;
                event.typical_wheel_delta = WHEEL_DELTA;
                event.wheel_delta = cast(s32)(cast(float64) -WHEEL_DELTA * vs);
                array_add(*xd.base.events_this_frame, event);
                xd.base.mouse_delta_z += event.wheel_delta;
            }
    }
}

fp3232_to_float :: inline (fp: xcb_input_fp3232_t) -> float64 {
    vs := cast(float64) fp.integral;
    if fp.integral < 0 vs -= cast(float64) fp.frac / cast(float64) U32_MAX;
    else vs += cast(float64) fp.frac / cast(float64) U32_MAX;
    return vs;
}

get_valuator_value :: inline (number: u16, values: []xcb_input_fp3232_t, masks: []u32) -> bool, xcb_input_fp3232_t {
    id := cast(u16)1 << number;
    if number == INVALID_VALUATOR || !(masks[(id & 0xffe0) >> 6] & (id & 0x001f)) return false, .{};

    pval := values.data;
    id = 1;
    for 0..cast(s32) number - 1 {
        if masks[(id & 0xffe0) >> 6] & (id & 0x001f) {
            pval += 1;
            assert(pval < values.data + values.count);
        }
        id = id << it;
    }
    return true, pval.*;
}

INVALID_VALUATOR :: U16_MAX;

XCB_Valuator_Class :: struct {
    label: string;
    number: u16;
    min: xcb_input_fp3232_t;
    max: xcb_input_fp3232_t;
    val: xcb_input_fp3232_t;
    resolution: u32;
}

XCB_Scroll_Axis_Info :: struct {
    number: u16 = INVALID_VALUATOR;
    valuator: *XCB_Valuator_Class;
    increment: xcb_input_fp3232_t;
}

XCB_Device_Info :: struct {
    name: string;
    valuators: [..]XCB_Valuator_Class;
    scroll_vert: XCB_Scroll_Axis_Info;
    scroll_horz: XCB_Scroll_Axis_Info;
}

get_device_info :: (xd: *XCB_Display, device_id: xcb_input_device_id_t) -> *XCB_Device_Info {
    ret, found := table_find(*xd.devices, device_id);
    if found return ret;

    xcb_err: *xcb_generic_error_t;
    cookie := xcb_input.xi_query_device(xd.handle, device_id);
    reply := xcb_input.xi_query_device_reply(xd.handle, cookie, *xcb_err);
    defer libc_free(reply);

    device_info: XCB_Device_Info;

    infos_len := xcb_input.xi_query_device_infos_length(reply);
    infos_it  := xcb_input.xi_query_device_infos_iterator(reply);
    if infos_len != 1 {
        log_error("XCB device_id % has % attached device_info entries, refusing to continue", device_id, infos_len);
        return null;
    }

    info := infos_it.data;
    sz_name := xcb_input.xi_device_info_name(info);
    name_len := xcb_input.xi_device_info_name_length(info);
    device_name := to_string(sz_name, name_len);

    valuators: [..]XCB_Valuator_Class;
    scroll_vert: XCB_Scroll_Axis_Info;
    scroll_horz: XCB_Scroll_Axis_Info;

    classes: [..]string;
    classes_count := xcb_input.xi_device_info_classes_length(info);
    classes_it := xcb_input.xi_device_info_classes_iterator(info);
    for 1..classes_count {
        defer xcb_input.device_class_next(*classes_it);

        class := classes_it.data;
        class_type := cast(xcb_input_device_class_type_t) class.type;
        if class_type == {
            case .VALUATOR; {
                val_class := cast(*xcb_input_valuator_class_t) class;
                array_add(*valuators, .{
                    label  = atom_name(xd, val_class.label),
                    number = val_class.number,
                    min    = val_class.min,
                    max    = val_class.max,
                    val    = val_class.value,
                    resolution = val_class.resolution,
                });
            }
            case .SCROLL; {
                scroll_class := cast(*xcb_input_scroll_class_t) class;
                if scroll_class.scroll_type == xx xcb_input_scroll_type_t.VERTICAL {
                    scroll_vert.number = scroll_class.number;
                    scroll_vert.increment = scroll_class.increment;
                } else {
                    assert(scroll_class.scroll_type == xx xcb_input_scroll_type_t.HORIZONTAL);
                    scroll_horz.number = scroll_class.number;
                    scroll_horz.increment = scroll_class.increment;
                }
            }
        }
    }

    if scroll_vert.number != INVALID_VALUATOR || scroll_horz.number != INVALID_VALUATOR {
        scroll_vert.valuator = ifx scroll_vert.number != INVALID_VALUATOR && scroll_vert.number < valuators.count then *valuators[scroll_vert.number] else null;
        scroll_horz.valuator = ifx scroll_horz.number != INVALID_VALUATOR && scroll_horz.number < valuators.count then *valuators[scroll_horz.number] else null;
        if !scroll_vert.valuator && !scroll_horz.valuator {
            log_error("get_device_info(): failed to match scroll wheels to valuators:\n  valuators=%\n  scroll_vert=%\n  scroll_horz=%",
                valuators, scroll_vert, scroll_horz);
            array_reset(*valuators);
            return null;
        }
        device_info.name = copy_string(device_name);
        device_info.valuators = valuators;
        device_info.scroll_vert = scroll_vert;
        device_info.scroll_horz = scroll_horz;
    } else {
        array_reset(*valuators);
        return null;
    }

    fmt := FormatStruct.{
        value = device_info,
        use_long_form_if_more_than_this_many_members = -1,
        use_newlines_if_long_form = true,
    };
    log("NEW DEVICE: %", fmt);
    ret = New(XCB_Device_Info, initialized=false);
    ret.* = device_info;
    table_add(*xd.devices, device_id, ret);

    return ret;
}

set_utf8_property :: (xw: *XCB_Window, property: xcb_atom_t, value: string) {
    xd := xw.display;
    sz_val := tprint("%\0", value);
    xcb.change_property(
        xd.handle,
        xx xcb_prop_mode_t.REPLACE,
        xw.handle,
        xx property,
        xx xd.global_atoms.UTF8_STRING,
        8, xx sz_val.count, sz_val.data);
}

WM_State_Op :: enum u32 {
    REMOVE :: 0;
    ADD    :: 1;
    TOGGLE :: 2;
}

set_wm_state :: (xw: *XCB_Window, op: WM_State_Op, v1: xcb_atom_t, v2: xcb_atom_t = 0) {
    xd := xw.display;

    // https://specifications.freedesktop.org/wm-spec/latest/ar01s05.html
    event: xcb_client_message_event_t;
    event.response_type = XCB_CLIENT_MESSAGE;
    event.format = 32;
    event.type = xd.global_atoms._NET_WM_STATE;
    event.window = xw.handle;
    event.data.data32[0] = xx op;
    event.data.data32[1] = v1;
    event.data.data32[2] = v2;
    event.data.data32[3] = 1;     // https://specifications.freedesktop.org/wm-spec/latest/ar01s09.html#sourceindication
    xcb.send_event(
        xd.handle, 0, xd.screen.root,
        xx (xcb_event_mask_t.SUBSTRUCTURE_NOTIFY | .SUBSTRUCTURE_REDIRECT),
        xx *event);
    xcb.flush(xd.handle);
}

load_cursors :: (xd: *XCB_Display) -> bool {
    ctx: *xcb_cursor_context_t;
    if xcb_cursor.context_new(xd.handle, xd.screen, *ctx) < 0 return false;
    defer xcb_cursor.context_free(ctx);

    preloaded_x_cursors :: string.[
        "default", "pointer", "not-allowed", "col-resize", "row-resize",
        "all-scroll", "nw-resize", "se-resize", "text",
    ];

    deinit(*xd.cursors);
    table_reset(*xd.cursors);
    for preloaded_x_cursors {
        name := temp_c_string(it);
        table_add(*xd.cursors, it, xcb_cursor.load_cursor(ctx, name));
    }

    return true;
}

atom_name :: (xd: *XCB_Display, atom: xcb_atom_t) -> string {
    name, found := table_find(*xd.atom_names, atom);
    if found return name;

    xcb_err: *xcb_generic_error_t;
    cookie := xcb.get_atom_name(xd.handle, atom);
    reply  := xcb.get_atom_name_reply(xd.handle, cookie, *xcb_err);
    defer libc_free(reply);

    if !reply || xcb_err return "";

    n: string;
    n.data  = xcb.get_atom_name_name(reply);
    n.count = xcb.get_atom_name_name_length(reply);
    name = copy_string(n);
    table_add(*xd.atom_names, atom, name);
    return name;
}

#scope_module
xcb: XCB_Symbols;
xcb_input: XCB_XInput_Symbols;
xcb_xkb: XCB_XKB_Symbols;
xcb_cursor: XCB_Cursor_Symbols;
