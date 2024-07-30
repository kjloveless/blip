const std = @import("std");
const windows = std.os.windows;

pub const Terminal = struct {
    stdin: windows.HANDLE,
    stdout: windows.HANDLE,
    initial_codepage: c_uint,
    initial_input_mode: u32,
    initial_output_mode: u32,
    buf: [4]u8 = undefined,
    last_mouse_button_press: u16 = 0,

    pub fn init() !Terminal {
        const stdin = try windows.GetStdHandle(windows.STD_INPUT_HANDLE);
    };
};

const InputMode = struct {
    const enable_window_input: u32 = 0x0008; // resize events
    const enable_mouse_input: u32 = 0x0010;
    const enable_extended_flags: u32 = 0x0080; // allows mouse events
    
    pub fn rawMode() u32 {
        return enable_window_input | enable_mouse_input | enable_extended_flags;
    }
};

const OutputMode = struct {
    const enable_processed_output: u32 = 0x0001;    // handle escape sequences
    const enable_virtual_terminal_processing: u32 = 0x0004;     // handle ANSI sequences
    const disable_newline_auto_return: u32 = 0x0008; //disable inserting anew line when we write at the last column
    const disable_lvb_grid_worldwide: u32 = 0x0010; // enables reverse video and underline
    
    fn rawMode() u32 {
        return enable_processed_output | enable_virtual_terminal_processing |
            disable_newline_auto_return | enable_lvb_grid_worldwide;
    }
};
