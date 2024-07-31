const std = @import("std");
const windows = std.os.windows;
const kernel32 = windows.kernel32;

pub const Terminal = struct {
    stdin: windows.HANDLE,
    stdout: windows.HANDLE,
    global_tty: Terminal,
    initial_codepage: c_uint,
    initial_input_mode: u32,
    initial_output_mode: u32,
    buf: [4]u8 = undefined,
    last_mouse_button_press: u16 = 0,

    pub fn init() !Terminal {
        const stdin = try windows.GetStdHandle(windows.STD_INPUT_HANDLE);
        const stdout = try windows.GetStdHandle(windows.STD_OUTPUT_HANDLE);

        // get and store initial terminal modes
        var initial_input_mode: windows.DWORD = undefined;
        var initial_ouput_mode: windows.DWORD = undefined;
        const initial_output_codepage = kernel32.GetConsoleOutputCP();
        {
            if (kernel32.GetConsoleMode(stdin, &initial_input_mode) == 0) {
                return windows.unexpectedError(kernel32.GetLastError());
            }
            if (kernel32.GetConsoleMode(stdout, &initial_output_mode) == 0) {
                return windows.unexpectedError(kernel32.GetLastError());
            }
        }

        // set raw mode
        {
            if (kernel32.SetConsoleMode(stdin, InputMode.rawMode()) == 0) {
                return windows.unexpectedError(kernel32.GetLastError());
            }

            if (kernel32.SetConsoleMode(stdout, OutputMode.rawMode()) == 0) {
                return windows.unexpectedError(kernel32.GetLastError());
            }

            if (kernel32.SetConsoleOutputCP(utf8_codepage) == 0) {
                return windows.unexpectedError(kernel32.GetLastError());
            }
        }

        const self: Terminal = .{
            .stdin = stdin,
            .stdout = stdout,
            .initial_codepage = initial_output_codepage,
            .initial_input_mode = initial_input_mode,
            .initial_output_mode = initial_output_mode,
        };

        global_tty = self;

        return self;
    };

    pub fn deinit() void {
        _ = kernel32.SetConsoleOutputCP(initial_codepage);
        _ = kernel32.SetConsoleMode(stdin, initial_input_mode);
        _ = kernel32.SetConsoleMode(stdout, initial_output_mode);
        windows.CloseHandle(stdin);
        windows.CloseHandle(stdout);
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
