const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
});

pub fn enableTerminalSequences() !bool {
    const output_handle = c.GetStdHandle(c.STD_OUTPUT_HANDLE);
    if (output_handle == c.INVALID_HANDLE_VALUE) {
        return error.UnableToGetStdOutHandle;
    }

    if (c.SetConsoleMode(output_handle, c.ENABLE_VIRTUAL_TERMINAL_PROCESSING) == 0) {
        return false;
    }

    return true;
}
