pub const inputKey = enum(u8) {
    BACKSPACE = 127,    // set to ASCII DEL char
    ARROW_LEFT = 150,   // these map to an arbitrary value outside the ASCII range
    ARROW_RIGHT,
    ARROW_UP,
    ARROW_DOWN,
    DEL_KEY,
    HOME_KEY,
    END_KEY,
    PAGE_UP,
    PAGE_DOWN,
};
